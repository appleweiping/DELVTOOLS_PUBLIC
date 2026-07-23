#!/usr/bin/env node

import { createHash, timingSafeEqual } from 'node:crypto';
import http from 'node:http';
import { resolve } from 'node:path';
import { pipeline } from 'node:stream';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const GUARD_SERVICE = 'devtools-agentmemory-host-guard';
export const GUARD_VERSION = '1';
export const GUARD_HEALTH_PATH = '/__devtools/agentmemory-host-guard/health';
export const INTERNAL_REST_HOST = '127.0.0.1';
export const INTERNAL_REST_PORT = 6000;

const DEFAULT_LISTEN_PORT = 3111;
const DEFAULT_MAX_REQUEST_BODY_BYTES = 64 * 1024 * 1024;
const DEFAULT_REQUEST_IDLE_TIMEOUT_MS = 120_000;
const DEFAULT_UPSTREAM_TIMEOUT_MS = 190_000;
const DEFAULT_RESPONSE_IDLE_TIMEOUT_MS = 300_000;
const DEFAULT_SHUTDOWN_TIMEOUT_MS = 5_000;
const MAX_HEADER_BYTES = 32 * 1024;
const MAX_HEADERS_COUNT = 128;
const MAX_READY_BODY_BYTES = 64 * 1024;

const ALLOWED_METHODS = new Set([
  'GET',
  'HEAD',
  'POST',
  'PUT',
  'PATCH',
  'DELETE',
  'OPTIONS',
]);
const ALLOW_HEADER = [...ALLOWED_METHODS].join(', ');
const SAFE_FETCH_SITES = new Set(['same-origin', 'same-site', 'none']);
const SINGLETON_HEADERS = new Set([
  'authorization',
  'content-length',
  'host',
  'origin',
  'sec-fetch-site',
  'transfer-encoding',
]);
const BASE_HOP_BY_HOP_HEADERS = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
]);
const UNTRUSTED_FORWARDING_HEADERS = new Set([
  'forwarded',
  'via',
  'x-forwarded-for',
  'x-forwarded-host',
  'x-forwarded-port',
  'x-forwarded-proto',
]);

function parseStrictInteger(value, name, minimum, maximum) {
  const text = String(value ?? '');
  if (!/^(0|[1-9][0-9]*)$/.test(text)) {
    throw new Error(`${name} must be a canonical decimal integer`);
  }
  const parsed = Number(text);
  if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
    throw new Error(`${name} must be between ${minimum} and ${maximum}`);
  }
  return parsed;
}

export function validateAgentMemorySecret(secret) {
  if (typeof secret !== 'string' || !/^[A-Za-z0-9_-]{32,256}$/.test(secret)) {
    throw new Error(
      'AGENTMEMORY_SECRET must be a 32-256 character URL-safe value using only A-Z, a-z, 0-9, _ or -',
    );
  }
  return secret;
}

export function constantTimeTokenEqual(candidate, expected) {
  const candidateDigest = createHash('sha256').update(String(candidate), 'utf8').digest();
  const expectedDigest = createHash('sha256').update(String(expected), 'utf8').digest();
  const digestMatches = timingSafeEqual(candidateDigest, expectedDigest);
  const lengthMatches = Buffer.byteLength(String(candidate), 'utf8') === Buffer.byteLength(String(expected), 'utf8');
  return digestMatches && lengthMatches;
}

function headerEntries(rawHeaders) {
  const entries = [];
  for (let index = 0; index < rawHeaders.length; index += 2) {
    entries.push({
      name: String(rawHeaders[index]).toLowerCase(),
      value: String(rawHeaders[index + 1] ?? ''),
    });
  }
  return entries;
}

function getUniqueHeader(entries, name) {
  const values = entries.filter((entry) => entry.name === name).map((entry) => entry.value);
  if (values.length > 1) {
    return { error: `duplicate ${name} header` };
  }
  return { value: values[0] };
}

function parseConnectionTokens(entries) {
  const tokens = new Set();
  for (const entry of entries) {
    if (entry.name !== 'connection') continue;
    for (const token of entry.value.split(',')) {
      const normalized = token.trim().toLowerCase();
      if (normalized) tokens.add(normalized);
    }
  }
  return tokens;
}

function sendJson(response, statusCode, body, extraHeaders = {}) {
  if (response.headersSent || response.destroyed) return;
  const encoded = Buffer.from(`${JSON.stringify(body)}\n`, 'utf8');
  response.writeHead(statusCode, {
    'Cache-Control': 'no-store',
    Connection: 'close',
    'Content-Length': encoded.length,
    'Content-Type': 'application/json; charset=utf-8',
    'X-Content-Type-Options': 'nosniff',
    ...extraHeaders,
  });
  response.end(encoded);
}

function rejectWithoutReading(request, response, statusCode, error, extraHeaders = {}) {
  sendJson(response, statusCode, { error }, extraHeaders);
  response.once('finish', () => {
    if (!request.complete && !request.socket.destroyed) request.socket.destroy();
  });
}

function validateRequest(request, listenPort, secret, maxRequestBodyBytes) {
  const method = String(request.method || '').toUpperCase();
  if (!ALLOWED_METHODS.has(method)) {
    return { statusCode: 405, error: 'method not allowed', headers: { Allow: ALLOW_HEADER } };
  }

  const rawUrl = request.url || '';
  if (!rawUrl.startsWith('/') || rawUrl.startsWith('//') || rawUrl.includes('#')) {
    return { statusCode: 400, error: 'invalid request target' };
  }
  const path = rawUrl.split('?', 1)[0];
  if (path !== GUARD_HEALTH_PATH && !path.startsWith('/agentmemory/')) {
    return { statusCode: 404, error: 'not found' };
  }

  const entries = headerEntries(request.rawHeaders || []);
  for (const name of SINGLETON_HEADERS) {
    if (entries.filter((entry) => entry.name === name).length > 1) {
      return { statusCode: 400, error: `duplicate ${name} header` };
    }
  }

  const hostResult = getUniqueHeader(entries, 'host');
  if (hostResult.error || hostResult.value === undefined) {
    return { statusCode: 400, error: 'exactly one host header is required' };
  }
  const normalizedHost = hostResult.value.toLowerCase();
  const allowedHosts = new Set([`localhost:${listenPort}`, `127.0.0.1:${listenPort}`]);
  if (!allowedHosts.has(normalizedHost)) {
    return { statusCode: 421, error: 'misdirected request' };
  }

  const originResult = getUniqueHeader(entries, 'origin');
  if (originResult.error) return { statusCode: 400, error: originResult.error };
  if (originResult.value !== undefined) {
    const normalizedOrigin = originResult.value.toLowerCase();
    const allowedOrigins = new Set([
      `http://localhost:${listenPort}`,
      `http://127.0.0.1:${listenPort}`,
    ]);
    if (!allowedOrigins.has(normalizedOrigin)) {
      return { statusCode: 403, error: 'forbidden origin' };
    }
  }

  const fetchSiteResult = getUniqueHeader(entries, 'sec-fetch-site');
  if (fetchSiteResult.error) return { statusCode: 400, error: fetchSiteResult.error };
  if (
    fetchSiteResult.value !== undefined
    && !SAFE_FETCH_SITES.has(fetchSiteResult.value.toLowerCase())
  ) {
    return { statusCode: 403, error: 'forbidden fetch site' };
  }

  const authorizationResult = getUniqueHeader(entries, 'authorization');
  if (authorizationResult.error || authorizationResult.value === undefined) {
    return { statusCode: 401, error: 'unauthorized', headers: { 'WWW-Authenticate': 'Bearer' } };
  }
  const authorizationMatch = /^Bearer ([A-Za-z0-9_-]{32,256})$/.exec(authorizationResult.value);
  const suppliedToken = authorizationMatch?.[1] ?? '';
  if (!constantTimeTokenEqual(suppliedToken, secret)) {
    return { statusCode: 401, error: 'unauthorized', headers: { 'WWW-Authenticate': 'Bearer' } };
  }

  const contentLengthResult = getUniqueHeader(entries, 'content-length');
  if (contentLengthResult.error) return { statusCode: 400, error: contentLengthResult.error };
  let contentLength;
  if (contentLengthResult.value !== undefined) {
    if (!/^(0|[1-9][0-9]*)$/.test(contentLengthResult.value)) {
      return { statusCode: 400, error: 'invalid content-length header' };
    }
    contentLength = Number(contentLengthResult.value);
    if (!Number.isSafeInteger(contentLength)) {
      return { statusCode: 400, error: 'invalid content-length header' };
    }
    if (contentLength > maxRequestBodyBytes) {
      return { statusCode: 413, error: 'request body too large' };
    }
  }

  const transferEncodingResult = getUniqueHeader(entries, 'transfer-encoding');
  if (transferEncodingResult.error) return { statusCode: 400, error: transferEncodingResult.error };
  if (contentLength !== undefined && transferEncodingResult.value !== undefined) {
    return { statusCode: 400, error: 'ambiguous request framing' };
  }
  if (
    transferEncodingResult.value !== undefined
    && transferEncodingResult.value.toLowerCase() !== 'chunked'
  ) {
    return { statusCode: 400, error: 'unsupported transfer-encoding' };
  }

  return {
    entries,
    method,
    path,
    rawUrl,
    listenPort,
    contentLength,
  };
}

function buildUpstreamHeaders(validated, secret) {
  const connectionTokens = parseConnectionTokens(validated.entries);
  const blocked = new Set([
    ...BASE_HOP_BY_HOP_HEADERS,
    ...UNTRUSTED_FORWARDING_HEADERS,
    ...connectionTokens,
    'authorization',
    'host',
  ]);
  const headers = {};
  for (const { name, value } of validated.entries) {
    if (blocked.has(name)) continue;
    if (headers[name] === undefined) headers[name] = value;
    else if (Array.isArray(headers[name])) headers[name].push(value);
    else headers[name] = [headers[name], value];
  }
  headers.authorization = `Bearer ${secret}`;
  headers.host = `${INTERNAL_REST_HOST}:${INTERNAL_REST_PORT}`;
  headers.connection = 'close';
  return headers;
}

function filterUpstreamResponseHeaders(upstreamResponse) {
  const connectionHeader = upstreamResponse.headers.connection;
  const connectionTokens = new Set(
    String(connectionHeader || '')
      .split(',')
      .map((token) => token.trim().toLowerCase())
      .filter(Boolean),
  );
  const blocked = new Set([...BASE_HOP_BY_HOP_HEADERS, ...connectionTokens]);
  const headers = {};
  for (const [name, value] of Object.entries(upstreamResponse.headers)) {
    if (value === undefined || blocked.has(name.toLowerCase())) continue;
    headers[name] = value;
  }
  headers.connection = 'close';
  headers['x-content-type-options'] ??= 'nosniff';
  return headers;
}

function pipeRequestBody(request, upstreamRequest, maxRequestBodyBytes, onTooLarge) {
  let received = 0;
  let stopped = false;

  const stop = () => {
    if (stopped) return;
    stopped = true;
    request.unpipe(upstreamRequest);
    upstreamRequest.destroy();
  };

  request.on('data', (chunk) => {
    if (stopped) return;
    received += chunk.length;
    if (received > maxRequestBodyBytes) {
      stop();
      onTooLarge();
    }
  });
  request.once('aborted', stop);
  request.once('error', stop);
  upstreamRequest.once('error', () => request.unpipe(upstreamRequest));
  request.pipe(upstreamRequest);
  return stop;
}

function proxyRequest(request, response, validated, options) {
  const upstreamRequest = http.request({
    host: INTERNAL_REST_HOST,
    port: INTERNAL_REST_PORT,
    method: validated.method,
    path: validated.rawUrl,
    headers: buildUpstreamHeaders(validated, options.secret),
    agent: false,
    insecureHTTPParser: false,
    joinDuplicateHeaders: false,
    maxHeaderSize: MAX_HEADER_BYTES,
  });

  let upstreamResponse;
  let requestTimedOut = false;
  let bodyTooLarge = false;
  let requestBodyEnded = request.readableEnded;

  request.once('end', () => {
    requestBodyEnded = true;
    request.setTimeout(0);
  });

  upstreamRequest.setTimeout(options.upstreamTimeoutMs, () => {
    requestTimedOut = true;
    upstreamRequest.destroy(new Error('upstream timeout'));
  });

  upstreamRequest.once('response', (incoming) => {
    upstreamResponse = incoming;
    const forwardResponse = () => {
      if (bodyTooLarge || response.destroyed) {
        incoming.destroy();
        return;
      }
      incoming.setTimeout(options.responseIdleTimeoutMs, () => {
        incoming.destroy(new Error('upstream response idle timeout'));
      });
      const statusCode = incoming.statusCode || 502;
      const headers = filterUpstreamResponseHeaders(incoming);
      if (incoming.statusMessage) response.writeHead(statusCode, incoming.statusMessage, headers);
      else response.writeHead(statusCode, headers);
      pipeline(incoming, response, (error) => {
        if (error && !response.destroyed) response.destroy(error);
      });
    };
    if (requestBodyEnded) forwardResponse();
    else request.once('end', forwardResponse);
  });

  upstreamRequest.once('error', () => {
    if (bodyTooLarge || response.destroyed) return;
    if (!response.headersSent) {
      sendJson(
        response,
        requestTimedOut ? 504 : 502,
        { error: requestTimedOut ? 'upstream timeout' : 'upstream unavailable' },
      );
    } else {
      response.destroy();
    }
  });

  response.once('close', () => {
    if (!response.writableEnded) {
      upstreamRequest.destroy();
      upstreamResponse?.destroy();
    }
  });

  request.setTimeout(options.requestIdleTimeoutMs, () => {
    upstreamRequest.destroy();
    rejectWithoutReading(request, response, 408, 'request timeout');
  });

  pipeRequestBody(request, upstreamRequest, options.maxRequestBodyBytes, () => {
    bodyTooLarge = true;
    upstreamResponse?.destroy();
    rejectWithoutReading(request, response, 413, 'request body too large');
  });
}

function probeUpstream(secret, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false;
    const finish = (ready) => {
      if (settled) return;
      settled = true;
      resolve(ready);
    };
    const request = http.request({
      host: INTERNAL_REST_HOST,
      port: INTERNAL_REST_PORT,
      method: 'GET',
      path: '/agentmemory/health',
      headers: {
        Authorization: `Bearer ${secret}`,
        Connection: 'close',
        Host: `${INTERNAL_REST_HOST}:${INTERNAL_REST_PORT}`,
      },
      agent: false,
      insecureHTTPParser: false,
      maxHeaderSize: MAX_HEADER_BYTES,
    });
    request.setTimeout(timeoutMs, () => request.destroy(new Error('upstream timeout')));
    request.once('error', () => finish(false));
    request.once('response', (response) => {
      let size = 0;
      response.on('data', (chunk) => {
        size += chunk.length;
        if (size > MAX_READY_BODY_BYTES) response.destroy(new Error('readiness body too large'));
      });
      response.once('end', () => finish(response.statusCode >= 200 && response.statusCode < 300));
      response.once('error', () => finish(false));
    });
    request.end();
  });
}

async function handleHealth(request, response, validated, options) {
  if (validated.method !== 'GET') {
    rejectWithoutReading(request, response, 405, 'method not allowed', { Allow: 'GET' });
    return;
  }
  const ready = await probeUpstream(options.secret, Math.min(options.upstreamTimeoutMs, 25_000));
  const body = {
    service: GUARD_SERVICE,
    status: ready ? 'healthy' : 'unhealthy',
    version: GUARD_VERSION,
    listenPort: validated.listenPort,
    upstreamPort: INTERNAL_REST_PORT,
  };
  sendJson(response, ready ? 200 : 503, body);
}

function rejectUpgrade(socket, statusLine, body) {
  if (socket.destroyed) return;
  const payload = Buffer.from(`${body}\n`, 'utf8');
  socket.end(
    `${statusLine}\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${payload.length}\r\n\r\n${payload}`,
  );
}

export function createAgentMemoryHostGuard({
  listenPort = DEFAULT_LISTEN_PORT,
  secret = process.env.AGENTMEMORY_SECRET,
  maxRequestBodyBytes = DEFAULT_MAX_REQUEST_BODY_BYTES,
  requestIdleTimeoutMs = DEFAULT_REQUEST_IDLE_TIMEOUT_MS,
  upstreamTimeoutMs = DEFAULT_UPSTREAM_TIMEOUT_MS,
  responseIdleTimeoutMs = DEFAULT_RESPONSE_IDLE_TIMEOUT_MS,
} = {}) {
  const normalizedPort = parseStrictInteger(listenPort, 'listenPort', 0, 65_535);
  const normalizedSecret = validateAgentMemorySecret(secret);
  const options = Object.freeze({
    listenPort: normalizedPort,
    secret: normalizedSecret,
    maxRequestBodyBytes: parseStrictInteger(
      maxRequestBodyBytes,
      'maxRequestBodyBytes',
      1,
      1024 * 1024 * 1024,
    ),
    requestIdleTimeoutMs: parseStrictInteger(
      requestIdleTimeoutMs,
      'requestIdleTimeoutMs',
      1,
      24 * 60 * 60 * 1000,
    ),
    upstreamTimeoutMs: parseStrictInteger(
      upstreamTimeoutMs,
      'upstreamTimeoutMs',
      1,
      24 * 60 * 60 * 1000,
    ),
    responseIdleTimeoutMs: parseStrictInteger(
      responseIdleTimeoutMs,
      'responseIdleTimeoutMs',
      1,
      24 * 60 * 60 * 1000,
    ),
  });

  const sockets = new Set();
  const handleRequest = (request, response, sendContinue) => {
    const actualPort = server.address()?.port ?? options.listenPort;
    const validated = validateRequest(
      request,
      actualPort,
      options.secret,
      options.maxRequestBodyBytes,
    );
    if (validated.error) {
      rejectWithoutReading(
        request,
        response,
        validated.statusCode,
        validated.error,
        validated.headers,
      );
      return;
    }
    if (sendContinue) response.writeContinue();
    if (validated.path === GUARD_HEALTH_PATH) {
      void handleHealth(request, response, validated, options).catch(() => {
        if (!response.headersSent) {
          sendJson(response, 503, {
            service: GUARD_SERVICE,
            status: 'unhealthy',
            version: GUARD_VERSION,
            listenPort: actualPort,
            upstreamPort: INTERNAL_REST_PORT,
          });
        } else {
          response.destroy();
        }
      });
      return;
    }
    proxyRequest(request, response, validated, options);
  };
  const handler = (request, response) => handleRequest(request, response, false);

  const server = http.createServer({
    insecureHTTPParser: false,
    joinDuplicateHeaders: false,
    keepAlive: false,
    maxHeaderSize: MAX_HEADER_BYTES,
    requireHostHeader: true,
  }, handler);
  server.headersTimeout = 15_000;
  server.requestTimeout = options.requestIdleTimeoutMs;
  server.keepAliveTimeout = 1_000;
  server.maxHeadersCount = MAX_HEADERS_COUNT;
  server.maxRequestsPerSocket = 100;

  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.once('close', () => sockets.delete(socket));
  });
  server.on('clientError', (error, socket) => {
    const status = error?.code === 'HPE_HEADER_OVERFLOW'
      ? 'HTTP/1.1 431 Request Header Fields Too Large'
      : 'HTTP/1.1 400 Bad Request';
    rejectUpgrade(socket, status, 'bad request');
  });
  server.on('upgrade', (request, socket) => {
    const actualPort = server.address()?.port ?? options.listenPort;
    const validated = validateRequest(
      request,
      actualPort,
      options.secret,
      options.maxRequestBodyBytes,
    );
    if (validated.error) {
      const statusLines = {
        400: 'HTTP/1.1 400 Bad Request',
        401: 'HTTP/1.1 401 Unauthorized',
        403: 'HTTP/1.1 403 Forbidden',
        404: 'HTTP/1.1 404 Not Found',
        405: 'HTTP/1.1 405 Method Not Allowed',
        413: 'HTTP/1.1 413 Content Too Large',
        421: 'HTTP/1.1 421 Misdirected Request',
      };
      rejectUpgrade(
        socket,
        statusLines[validated.statusCode] || 'HTTP/1.1 400 Bad Request',
        validated.error,
      );
      return;
    }
    rejectUpgrade(socket, 'HTTP/1.1 426 Upgrade Required', 'websocket is not available on this listener');
  });
  server.on('connect', (_request, socket) => {
    rejectUpgrade(socket, 'HTTP/1.1 405 Method Not Allowed', 'CONNECT is not allowed');
  });
  server.on('checkContinue', (request, response) => handleRequest(request, response, true));
  server.on('checkExpectation', (_request, response) => {
    sendJson(response, 417, { error: 'expectation failed' });
  });

  return {
    server,
    listen() {
      return new Promise((resolve, reject) => {
        const onError = (error) => reject(error);
        server.once('error', onError);
        server.listen(options.listenPort, '127.0.0.1', () => {
          server.off('error', onError);
          resolve(server.address());
        });
      });
    },
    close({ forceAfterMs = DEFAULT_SHUTDOWN_TIMEOUT_MS } = {}) {
      const timeoutMs = parseStrictInteger(forceAfterMs, 'forceAfterMs', 0, 60_000);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          for (const socket of sockets) socket.destroy();
        }, timeoutMs);
        timer.unref();
        server.close((error) => {
          clearTimeout(timer);
          if (error && error.code !== 'ERR_SERVER_NOT_RUNNING') reject(error);
          else resolve();
        });
        server.closeIdleConnections?.();
      });
    },
  };
}

function parseCliArguments(argv) {
  let listenPort;
  let upstreamPort;
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index];
    if (argument === '--listen-port') {
      if (listenPort !== undefined) throw new Error('--listen-port may be specified only once');
      if (index + 1 >= argv.length) throw new Error('--listen-port requires a value');
      listenPort = argv[++index];
      continue;
    }
    if (argument === '--upstream-port') {
      if (upstreamPort !== undefined) throw new Error('--upstream-port may be specified only once');
      if (index + 1 >= argv.length) throw new Error('--upstream-port requires a value');
      upstreamPort = argv[++index];
      continue;
    }
    throw new Error(`unsupported argument: ${argument}`);
  }
  if (listenPort === undefined) throw new Error('--listen-port is required');
  if (upstreamPort === undefined) throw new Error('--upstream-port is required');
  const parsed = parseStrictInteger(listenPort, 'listenPort', 1, 65_535);
  if (parsed === INTERNAL_REST_PORT) {
    throw new Error(`listenPort must not equal the internal REST port ${INTERNAL_REST_PORT}`);
  }
  const parsedUpstream = parseStrictInteger(upstreamPort, 'upstreamPort', 1, 65_535);
  if (parsedUpstream !== INTERNAL_REST_PORT) {
    throw new Error(`upstreamPort must be exactly ${INTERNAL_REST_PORT}`);
  }
  return { listenPort: parsed, upstreamPort: parsedUpstream };
}

export async function runAgentMemoryHostGuardCli(argv = process.argv.slice(2)) {
  const { listenPort } = parseCliArguments(argv);
  const guard = createAgentMemoryHostGuard({ listenPort });
  await guard.listen();
  process.stdout.write(`${GUARD_SERVICE} listening on http://127.0.0.1:${listenPort}\n`);

  let closing = false;
  const shutdown = async () => {
    if (closing) return;
    closing = true;
    try {
      await guard.close();
      process.exitCode = 0;
    } catch {
      process.exitCode = 1;
    }
  };
  process.once('SIGINT', shutdown);
  process.once('SIGTERM', shutdown);
  return guard;
}

const modulePath = fileURLToPath(import.meta.url);
const invokedPath = process.argv[1] ? fileURLToPath(pathToFileURL(resolve(process.argv[1]))) : '';
const isMain = process.platform === 'win32'
  ? modulePath.toLowerCase() === invokedPath.toLowerCase()
  : modulePath === invokedPath;

if (isMain) {
  runAgentMemoryHostGuardCli().catch((error) => {
    process.stderr.write(`${GUARD_SERVICE}: ${error instanceof Error ? error.message : String(error)}\n`);
    process.exitCode = 1;
  });
}
