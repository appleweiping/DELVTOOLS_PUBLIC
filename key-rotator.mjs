#!/usr/bin/env node

import { createHash, timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

const LOOPBACK_HOST = "127.0.0.1";
const DEFAULT_PORT = 9100;
const DEFAULT_UPSTREAM_TIMEOUT_MS = 120_000;
const DEFAULT_STREAM_IDLE_TIMEOUT_MS = 300_000;
const MIN_UPSTREAM_TIMEOUT_MS = 50;
const MAX_UPSTREAM_TIMEOUT_MS = 300_000;
const MIN_STREAM_IDLE_TIMEOUT_MS = 1_000;
const MAX_STREAM_IDLE_TIMEOUT_MS = 3_600_000;
const MAX_SLOTS = 32;
const MAX_REQUEST_BODY_BYTES = 32 * 1024 * 1024;
const SHUTDOWN_GRACE_MS = 1_000;
const INBOUND_TOKEN_HEADER = "x-key-rotator-token";
const MIN_PROXY_TOKEN_LENGTH = 32;
const MAX_PROXY_TOKEN_LENGTH = 256;

const ALLOWED_REQUEST_HEADERS = new Set([
  "accept",
  "content-encoding",
  "content-type",
  "idempotency-key",
  "openai-beta",
  "openai-organization",
  "openai-project",
  "traceparent",
  "tracestate",
  "user-agent",
  "x-client-request-id",
  "x-request-id",
  "x-stainless-arch",
  "x-stainless-async",
  "x-stainless-helper-method",
  "x-stainless-lang",
  "x-stainless-os",
  "x-stainless-package-version",
  "x-stainless-read-timeout",
  "x-stainless-retry-count",
  "x-stainless-runtime",
  "x-stainless-runtime-version",
  "x-stainless-timeout",
]);

const REPLAY_SAFE_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);

const RESPONSE_HOP_BY_HOP_HEADERS = new Set([
  "connection",
  "content-encoding",
  "content-length",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

class ConfigurationError extends Error {}
class BodyLimitError extends Error {}

function parseInteger(name, rawValue, fallback, minimum, maximum) {
  if (rawValue === undefined || rawValue === "") return fallback;
  if (!/^\d+$/.test(rawValue)) {
    throw new ConfigurationError(`${name} must be an integer between ${minimum} and ${maximum}.`);
  }
  const value = Number(rawValue);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new ConfigurationError(`${name} must be an integer between ${minimum} and ${maximum}.`);
  }
  return value;
}

function parseRequiredList(name, rawValue) {
  if (typeof rawValue !== "string" || rawValue.trim() === "") {
    throw new ConfigurationError("ROTATOR_KEYS and ROTATOR_TARGETS are required.");
  }
  const values = rawValue.split(",").map((value) => value.trim());
  if (values.some((value) => value === "")) {
    throw new ConfigurationError(`${name} must not contain empty items.`);
  }
  return values;
}

function validateKey(key, index) {
  if (key.length > 4_096 || /\s|[\u0000-\u001f\u007f]/u.test(key)) {
    throw new ConfigurationError(`ROTATOR_KEYS item ${index + 1} is invalid.`);
  }
  return key;
}

function validateProxyToken(rawToken, keys) {
  if (
    typeof rawToken !== "string" ||
    rawToken.length < MIN_PROXY_TOKEN_LENGTH ||
    rawToken.length > MAX_PROXY_TOKEN_LENGTH ||
    !/^[A-Za-z0-9._~-]+$/u.test(rawToken)
  ) {
    throw new ConfigurationError(
      `ROTATOR_PROXY_TOKEN is required and must be ${MIN_PROXY_TOKEN_LENGTH}-${MAX_PROXY_TOKEN_LENGTH} URL-safe ASCII characters.`,
    );
  }
  if (keys.some((key) => key === rawToken)) {
    throw new ConfigurationError("ROTATOR_PROXY_TOKEN must be independent from every ROTATOR_KEYS item.");
  }
  return rawToken;
}

function isLoopbackHostname(rawHostname) {
  const hostname = rawHostname.toLowerCase().replace(/^\[|\]$/gu, "");
  if (hostname === "localhost" || hostname === "::1") return true;
  const octets = hostname.split(".");
  return (
    octets.length === 4 &&
    octets.every((octet) => /^\d{1,3}$/u.test(octet) && Number(octet) <= 255) &&
    Number(octets[0]) === 127
  );
}

function validateTarget(rawTarget, index) {
  let target;
  try {
    target = new URL(rawTarget);
  } catch {
    throw new ConfigurationError(`ROTATOR_TARGETS item ${index + 1} must be a valid HTTP(S) URL without credentials.`);
  }

  if (
    (target.protocol !== "http:" && target.protocol !== "https:") ||
    target.username !== "" ||
    target.password !== "" ||
    target.search !== "" ||
    target.hash !== ""
  ) {
    throw new ConfigurationError(`ROTATOR_TARGETS item ${index + 1} must be a valid HTTP(S) URL without credentials.`);
  }
  if (target.protocol === "http:" && !isLoopbackHostname(target.hostname)) {
    throw new ConfigurationError(`ROTATOR_TARGETS item ${index + 1} must use HTTPS unless its hostname is loopback.`);
  }

  target.pathname = target.pathname.replace(/\/+$/u, "");
  return target;
}

export function loadConfiguration(environment = process.env) {
  const keys = parseRequiredList("ROTATOR_KEYS", environment.ROTATOR_KEYS).map(validateKey);
  const rawTargets = parseRequiredList("ROTATOR_TARGETS", environment.ROTATOR_TARGETS);
  const proxyToken = validateProxyToken(environment.ROTATOR_PROXY_TOKEN, keys);

  if (keys.length !== rawTargets.length) {
    throw new ConfigurationError("ROTATOR_KEYS and ROTATOR_TARGETS must contain the same number of items.");
  }
  if (keys.length > MAX_SLOTS) {
    throw new ConfigurationError(`ROTATOR_KEYS and ROTATOR_TARGETS support at most ${MAX_SLOTS} items.`);
  }

  return Object.freeze({
    host: LOOPBACK_HOST,
    port: parseInteger("ROTATOR_PORT", environment.ROTATOR_PORT, DEFAULT_PORT, 0, 65_535),
    upstreamTimeoutMs: parseInteger(
      "ROTATOR_UPSTREAM_TIMEOUT_MS",
      environment.ROTATOR_UPSTREAM_TIMEOUT_MS,
      DEFAULT_UPSTREAM_TIMEOUT_MS,
      MIN_UPSTREAM_TIMEOUT_MS,
      MAX_UPSTREAM_TIMEOUT_MS,
    ),
    streamIdleTimeoutMs: parseInteger(
      "ROTATOR_STREAM_IDLE_TIMEOUT_MS",
      environment.ROTATOR_STREAM_IDLE_TIMEOUT_MS,
      DEFAULT_STREAM_IDLE_TIMEOUT_MS,
      MIN_STREAM_IDLE_TIMEOUT_MS,
      MAX_STREAM_IDLE_TIMEOUT_MS,
    ),
    proxyToken,
    keys: Object.freeze(keys),
    targets: Object.freeze(rawTargets.map(validateTarget)),
  });
}

function rawHeaderValues(request, expectedName) {
  const values = [];
  for (let index = 0; index < request.rawHeaders.length; index += 2) {
    if (request.rawHeaders[index].toLowerCase() === expectedName) {
      values.push(request.rawHeaders[index + 1]);
    }
  }
  return values;
}

function digestProxyToken(value) {
  return createHash("sha256").update(value, "utf8").digest();
}

function proxyTokenMatches(expectedDigest, suppliedToken) {
  if (typeof suppliedToken !== "string" || suppliedToken.length > MAX_PROXY_TOKEN_LENGTH) return false;
  return timingSafeEqual(expectedDigest, digestProxyToken(suppliedToken));
}

function listenerAuthority(server) {
  const address = server.address();
  if (!address || typeof address !== "object") return null;
  return address.port === 80 ? LOOPBACK_HOST : `${LOOPBACK_HOST}:${address.port}`;
}

function validateInboundRequest(request, server, expectedTokenDigest) {
  const authority = listenerAuthority(server);
  const hosts = rawHeaderValues(request, "host");
  if (authority === null || hosts.length !== 1 || hosts[0] !== authority) {
    return {
      status: 421,
      code: "invalid_host",
      message: "Request host is not accepted.",
    };
  }

  const origins = rawHeaderValues(request, "origin");
  const fetchSites = rawHeaderValues(request, "sec-fetch-site");
  if (
    origins.length > 1 ||
    (origins.length === 1 && origins[0] !== `http://${authority}`) ||
    fetchSites.length > 1 ||
    (fetchSites.length === 1 && fetchSites[0] !== "same-origin")
  ) {
    return {
      status: 403,
      code: "browser_request_forbidden",
      message: "Browser request context is not accepted.",
    };
  }

  const tokens = rawHeaderValues(request, INBOUND_TOKEN_HEADER);
  if (tokens.length !== 1 || !proxyTokenMatches(expectedTokenDigest, tokens[0])) {
    return {
      status: 401,
      code: "proxy_authentication_required",
      message: "Proxy authentication is required.",
    };
  }
  return null;
}

function parseIncomingUrl(rawUrl) {
  if (typeof rawUrl !== "string" || !rawUrl.startsWith("/") || rawUrl.startsWith("//")) {
    return null;
  }
  try {
    return new URL(rawUrl, "http://127.0.0.1");
  } catch {
    return null;
  }
}

function joinTargetUrl(target, incomingUrl) {
  const result = new URL(target.href);
  const requestPath = incomingUrl.pathname.replace(/^\/v1(?=\/|$)/u, "") || "/";
  const basePath = target.pathname.replace(/\/+$/u, "");
  result.pathname = `${basePath}${requestPath.startsWith("/") ? requestPath : `/${requestPath}`}`;
  result.search = incomingUrl.search;
  return result;
}

function buildUpstreamHeaders(incomingHeaders, key) {
  const result = new Headers();

  for (const [rawName, rawValue] of Object.entries(incomingHeaders)) {
    const name = rawName.toLowerCase();
    if (rawValue === undefined || !ALLOWED_REQUEST_HEADERS.has(name)) continue;
    if (Array.isArray(rawValue)) {
      for (const value of rawValue) result.append(name, value);
    } else {
      result.set(name, rawValue);
    }
  }

  result.set("accept-encoding", "identity");
  result.set("authorization", `Bearer ${key}`);
  return result;
}

function buildClientHeaders(upstreamHeaders) {
  const result = {};
  for (const [rawName, value] of upstreamHeaders.entries()) {
    const name = rawName.toLowerCase();
    if (!RESPONSE_HOP_BY_HOP_HEADERS.has(name)) result[name] = value;
  }
  return result;
}

function readRequestBody(request) {
  return new Promise((resolveBody, rejectBody) => {
    const chunks = [];
    let totalBytes = 0;
    let exceeded = false;

    request.on("data", (chunk) => {
      totalBytes += chunk.length;
      if (totalBytes > MAX_REQUEST_BODY_BYTES) {
        exceeded = true;
        chunks.length = 0;
        return;
      }
      if (!exceeded) chunks.push(chunk);
    });
    request.once("end", () => {
      if (exceeded) rejectBody(new BodyLimitError("request body limit exceeded"));
      else resolveBody(Buffer.concat(chunks));
    });
    request.once("aborted", () => rejectBody(new Error("client disconnected")));
    request.once("error", () => rejectBody(new Error("client request error")));
  });
}

async function cancelResponseBody(response) {
  try {
    await response.body?.cancel();
  } catch {}
}

function requestMayBeReplayed(method) {
  // Slots may use different origins or credentials. HTTP method idempotency
  // and Idempotency-Key scopes do not make a mutation safe across those
  // independent domains, so automatic failover is read-only only.
  return REPLAY_SAFE_METHODS.has(method);
}

function retryReasonForStatus(status, mayReplay) {
  if (mayReplay && (status === 401 || status === 403 || status === 429 || status >= 500)) {
    return `http_${status}`;
  }
  return null;
}

function failureReasonForStatus(status) {
  return status === 401 || status === 403 || status === 429 || status >= 500
    ? `http_${status}`
    : null;
}

function waitForDrain(response) {
  if (response.destroyed) return Promise.reject(new Error("client disconnected"));
  return new Promise((resolveDrain, rejectDrain) => {
    const cleanup = () => {
      response.removeListener("drain", onDrain);
      response.removeListener("close", onClose);
      response.removeListener("error", onError);
    };
    const onDrain = () => {
      cleanup();
      resolveDrain();
    };
    const onClose = () => {
      cleanup();
      rejectDrain(new Error("client disconnected"));
    };
    const onError = () => {
      cleanup();
      rejectDrain(new Error("client response error"));
    };
    response.once("drain", onDrain);
    response.once("close", onClose);
    response.once("error", onError);
  });
}

async function streamResponseBody(upstream, response, controller, idleTimeoutMs, streamState) {
  if (!upstream.body) {
    response.end();
    return;
  }

  const reader = upstream.body.getReader();
  let idleTimer;

  const clearIdleTimer = () => clearTimeout(idleTimer);
  const armIdleTimer = () => {
    clearIdleTimer();
    idleTimer = setTimeout(() => {
      streamState.timedOut = true;
      controller.abort();
    }, idleTimeoutMs);
    idleTimer.unref?.();
  };

  try {
    while (true) {
      armIdleTimer();
      const { done, value } = await reader.read();
      clearIdleTimer();
      if (done) break;
      if (!value || value.byteLength === 0) continue;
      if (!response.write(Buffer.from(value))) await waitForDrain(response);
    }
    response.end();
  } finally {
    clearIdleTimer();
  }
}

function writeJson(response, status, payload) {
  if (response.destroyed || response.headersSent) return;
  const body = Buffer.from(JSON.stringify(payload), "utf8");
  response.writeHead(status, {
    "cache-control": "no-store",
    "content-length": String(body.length),
    "content-type": "application/json; charset=utf-8",
  });
  response.end(body);
}

function publicHealth(state) {
  return state.health.map((item, index) => ({
    index: index + 1,
    failures: item.failures,
    successes: item.successes,
    lastFailure: item.lastFailure,
    lastFailureAt: item.lastFailureAt,
  }));
}

function markFailure(state, index, reason) {
  const item = state.health[index];
  item.failures += 1;
  item.lastFailure = reason;
  item.lastFailureAt = new Date().toISOString();
  state.currentIndex = (index + 1) % state.health.length;
}

function markSuccess(state, index) {
  state.health[index].successes += 1;
  state.currentIndex = index;
}

async function attemptUpstream({ request, response, body, config, index, targetUrl, mayReplay }) {
  const controller = new AbortController();
  let timedOut = false;
  let clientDisconnected = false;
  let downstreamStarted = false;
  const streamState = { timedOut: false };
  const onClientDisconnect = () => {
    clientDisconnected = true;
    controller.abort();
  };
  const onResponseClose = () => {
    if (!response.writableEnded) onClientDisconnect();
  };
  const headerTimer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, config.upstreamTimeoutMs);
  headerTimer.unref?.();
  request.once("aborted", onClientDisconnect);
  response.once("close", onResponseClose);

  try {
    const method = request.method || "GET";
    const upstream = await fetch(targetUrl, {
      method,
      headers: buildUpstreamHeaders(request.headers, config.keys[index]),
      body: method === "GET" || method === "HEAD" ? undefined : body,
      redirect: "manual",
      signal: controller.signal,
    });
    clearTimeout(headerTimer);

    if (upstream.status >= 300 && upstream.status < 400) {
      await cancelResponseBody(upstream);
      return { kind: "blocked_redirect", reason: "upstream_redirect" };
    }

    const retryReason = retryReasonForStatus(upstream.status, mayReplay);
    if (retryReason) {
      await cancelResponseBody(upstream);
      return { kind: "retry", reason: retryReason };
    }

    downstreamStarted = true;
    response.writeHead(upstream.status, buildClientHeaders(upstream.headers));
    response.flushHeaders?.();
    await streamResponseBody(upstream, response, controller, config.streamIdleTimeoutMs, streamState);
    return {
      kind: "forwarded",
      failureReason: failureReasonForStatus(upstream.status),
    };
  } catch {
    if (downstreamStarted) {
      controller.abort();
      if (!response.destroyed) response.destroy();
      if (clientDisconnected && !streamState.timedOut) return { kind: "client_disconnected" };
      return {
        kind: "stream_failure",
        reason: streamState.timedOut ? "stream_idle_timeout" : "stream_error",
      };
    }
    if (clientDisconnected) return { kind: "client_disconnected" };
    const reason = timedOut ? "timeout" : "network_error";
    return mayReplay ? { kind: "retry", reason } : { kind: "terminal_failure", reason };
  } finally {
    clearTimeout(headerTimer);
    request.removeListener("aborted", onClientDisconnect);
    response.removeListener("close", onResponseClose);
  }
}

export function createRotatorServer(config, { logger = console } = {}) {
  const expectedTokenDigest = digestProxyToken(config.proxyToken);
  const state = {
    currentIndex: 0,
    health: config.keys.map(() => ({
      failures: 0,
      successes: 0,
      lastFailure: null,
      lastFailureAt: null,
    })),
  };

  const server = createServer(async (request, response) => {
    request.on("error", () => {});
    response.on("error", () => {});

    try {
      const inboundFailure = validateInboundRequest(request, server, expectedTokenDigest);
      if (inboundFailure) {
        writeJson(response, inboundFailure.status, {
          error: { code: inboundFailure.code, message: inboundFailure.message },
        });
        return;
      }

      const incomingUrl = parseIncomingUrl(request.url);
      if (!incomingUrl) {
        writeJson(response, 400, { error: { code: "invalid_request_target", message: "Invalid request target." } });
        return;
      }

      if (incomingUrl.pathname === "/health" || incomingUrl.pathname === "/v1/health") {
        writeJson(response, 200, {
          ok: true,
          current: state.currentIndex + 1,
          endpoints: publicHealth(state),
        });
        return;
      }

      let requestBody;
      try {
        requestBody = await readRequestBody(request);
      } catch (error) {
        if (error instanceof BodyLimitError) {
          writeJson(response, 413, { error: { code: "request_too_large", message: "Request body is too large." } });
        } else if (!response.destroyed) {
          writeJson(response, 400, { error: { code: "request_read_failed", message: "Unable to read request body." } });
        }
        return;
      }

      const startIndex = state.currentIndex;
      const method = (request.method || "GET").toUpperCase();
      const mayReplay = requestMayBeReplayed(method);
      for (let attempt = 0; attempt < config.keys.length; attempt += 1) {
        const index = (startIndex + attempt) % config.keys.length;
        const outcome = await attemptUpstream({
          request,
          response,
          body: requestBody,
          config,
          index,
          targetUrl: joinTargetUrl(config.targets[index], incomingUrl),
          mayReplay,
        });

        if (outcome.kind === "client_disconnected") return;
        if (outcome.kind === "forwarded") {
          if (outcome.failureReason) {
            markFailure(state, index, outcome.failureReason);
            logger.warn(`[key-rotator] slot ${index + 1} failed (${outcome.failureReason}); response forwarded without replay.`);
          } else {
            markSuccess(state, index);
          }
          return;
        }
        if (outcome.kind === "stream_failure") {
          markFailure(state, index, outcome.reason);
          logger.warn(`[key-rotator] slot ${index + 1} failed (${outcome.reason}) after response start; not replayed.`);
          return;
        }
        if (outcome.kind === "blocked_redirect") {
          markFailure(state, index, outcome.reason);
          logger.warn(`[key-rotator] slot ${index + 1} returned a redirect; blocked at the proxy boundary.`);
          writeJson(response, 502, {
            error: {
              code: "upstream_redirect_blocked",
              message: "Upstream redirects are not allowed.",
            },
          });
          return;
        }
        if (outcome.kind === "terminal_failure") {
          markFailure(state, index, outcome.reason);
          logger.warn(`[key-rotator] slot ${index + 1} failed (${outcome.reason}); request was not replay-safe.`);
          writeJson(response, 502, {
            error: {
              code: "upstream_unavailable",
              message: "Upstream request failed and was not replayed.",
            },
          });
          return;
        }

        markFailure(state, index, outcome.reason);
        const nextIndex = (index + 1) % config.keys.length;
        logger.warn(`[key-rotator] slot ${index + 1} failed (${outcome.reason}); rotating to slot ${nextIndex + 1}.`);
      }

      writeJson(response, 502, {
        error: {
          code: "upstream_exhausted",
          message: "All upstream slots exhausted.",
        },
      });
    } catch {
      logger.error("[key-rotator] request failed (internal_error).");
      writeJson(response, 500, { error: { code: "internal_error", message: "Internal proxy error." } });
    }
  });

  server.keepAliveTimeout = 5_000;
  server.requestTimeout = Math.max(1_000, Math.min(config.upstreamTimeoutMs + 5_000, MAX_UPSTREAM_TIMEOUT_MS));
  server.headersTimeout = Math.min(10_000, server.requestTimeout);
  server.on("clientError", (_error, socket) => {
    if (socket.writable) socket.end("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n");
  });

  return {
    server,
    state,
    async listen() {
      if (server.listening) return server.address();
      await new Promise((resolveListen, rejectListen) => {
        const onError = () => {
          server.removeListener("listening", onListening);
          rejectListen(new Error("listen failed"));
        };
        const onListening = () => {
          server.removeListener("error", onError);
          resolveListen();
        };
        server.once("error", onError);
        server.once("listening", onListening);
        server.listen(config.port, LOOPBACK_HOST);
      });
      return server.address();
    },
    async close() {
      if (!server.listening) return;
      await new Promise((resolveClose) => {
        let settled = false;
        const finish = () => {
          if (settled) return;
          settled = true;
          clearTimeout(forceTimer);
          resolveClose();
        };
        const forceTimer = setTimeout(() => {
          server.closeAllConnections?.();
          finish();
        }, SHUTDOWN_GRACE_MS);
        forceTimer.unref?.();
        server.close(finish);
        server.closeIdleConnections?.();
      });
    },
  };
}

async function runCommandLine() {
  let config;
  try {
    config = loadConfiguration(process.env);
  } catch (error) {
    if (error instanceof ConfigurationError) {
      console.error(`[key-rotator] configuration error: ${error.message}`);
      process.exitCode = 2;
      return;
    }
    console.error("[key-rotator] configuration error.");
    process.exitCode = 2;
    return;
  }

  const rotator = createRotatorServer(config);
  try {
    const address = await rotator.listen();
    if (!address || typeof address !== "object") throw new Error("listen failed");
    console.log(`[key-rotator] listening on http://${LOOPBACK_HOST}:${address.port}/v1`);
    console.log(`[key-rotator] ${config.keys.length} upstream slot(s) loaded.`);
  } catch {
    console.error("[key-rotator] startup failed.");
    process.exitCode = 1;
    return;
  }

  let shuttingDown = false;
  const shutdown = async () => {
    if (shuttingDown) return;
    shuttingDown = true;
    await rotator.close();
    if (process.connected) process.disconnect();
    process.exitCode = 0;
  };

  process.once("SIGINT", shutdown);
  process.once("SIGTERM", shutdown);
  process.on("message", (message) => {
    if (message && typeof message === "object" && message.type === "shutdown") void shutdown();
  });
}

const invokedPath = process.argv[1] ? resolve(process.argv[1]) : "";
if (invokedPath === fileURLToPath(import.meta.url)) {
  await runCommandLine();
}
