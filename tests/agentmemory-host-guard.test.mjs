import assert from 'node:assert/strict';
import { once } from 'node:events';
import http from 'node:http';
import net from 'node:net';
import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import test, { after, before, beforeEach } from 'node:test';

import {
  GUARD_HEALTH_PATH,
  GUARD_SERVICE,
  GUARD_VERSION,
  INTERNAL_REST_PORT,
  constantTimeTokenEqual,
  createAgentMemoryHostGuard,
  validateAgentMemorySecret,
} from '../agentmemory-host-guard.mjs';

const SECRET = 'Guard_Test_Secret-0123456789abcdef';
const SCRIPT = resolve(import.meta.dirname, '..', 'agentmemory-host-guard.mjs');

let guard;
let guardPort;
let upstream;
let upstreamHits;
let upstreamHandler;

function listen(server, port, host = '127.0.0.1') {
  return new Promise((resolvePromise, reject) => {
    const onError = (error) => reject(error);
    server.once('error', onError);
    server.listen(port, host, () => {
      server.off('error', onError);
      resolvePromise(server.address());
    });
  });
}

function closeServer(server) {
  return new Promise((resolvePromise, reject) => {
    server.close((error) => {
      if (error && error.code !== 'ERR_SERVER_NOT_RUNNING') reject(error);
      else resolvePromise();
    });
    server.closeAllConnections?.();
  });
}

function collectRequestBody(request) {
  return new Promise((resolvePromise, reject) => {
    const chunks = [];
    request.on('data', (chunk) => chunks.push(chunk));
    request.once('end', () => resolvePromise(Buffer.concat(chunks)));
    request.once('error', reject);
  });
}

function defaultUpstreamHandler(request, response) {
  void collectRequestBody(request).then((body) => {
    if (request.headers.authorization !== `Bearer ${SECRET}`) {
      response.writeHead(401, { 'Content-Type': 'application/json' });
      response.end('{"error":"unauthorized"}\n');
      return;
    }
    if (request.url === '/agentmemory/health') {
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end('{"status":"ok"}\n');
      return;
    }
    response.writeHead(200, {
      'Content-Type': 'application/json',
      'X-Upstream': 'agentmemory-fixture',
    });
    response.end(`${JSON.stringify({
      authorization: request.headers.authorization,
      body: body.toString('utf8'),
      host: request.headers.host,
      method: request.method,
      url: request.url,
    })}\n`);
  }).catch(() => response.destroy());
}

function requestGuard({
  method = 'GET',
  path = '/agentmemory/health',
  headers = {},
  body,
  port = guardPort,
  secret = SECRET,
} = {}) {
  return new Promise((resolvePromise, reject) => {
    const request = http.request({
      host: '127.0.0.1',
      port,
      method,
      path,
      headers: {
        Authorization: `Bearer ${secret}`,
        Connection: 'close',
        Host: `127.0.0.1:${port}`,
        ...headers,
      },
      agent: false,
    });
    request.once('error', reject);
    request.once('response', (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.once('end', () => resolvePromise({
        body: Buffer.concat(chunks),
        headers: response.headers,
        statusCode: response.statusCode,
      }));
      response.once('error', reject);
    });
    if (body !== undefined) request.write(body);
    request.end();
  });
}

function rawRequest(payload, port = guardPort) {
  return new Promise((resolvePromise, reject) => {
    const socket = net.createConnection({ host: '127.0.0.1', port });
    const chunks = [];
    socket.once('connect', () => socket.end(payload));
    socket.on('data', (chunk) => chunks.push(chunk));
    socket.once('error', reject);
    socket.once('close', () => resolvePromise(Buffer.concat(chunks).toString('latin1')));
  });
}

before(async () => {
  upstream = http.createServer((request, response) => {
    upstreamHits += 1;
    upstreamHandler(request, response);
  });
  await listen(upstream, INTERNAL_REST_PORT);
  guard = createAgentMemoryHostGuard({
    listenPort: 0,
    secret: SECRET,
    maxRequestBodyBytes: 1024,
    requestIdleTimeoutMs: 2_000,
    upstreamTimeoutMs: 2_000,
    responseIdleTimeoutMs: 2_000,
  });
  const address = await guard.listen();
  guardPort = address.port;
});

beforeEach(() => {
  upstreamHits = 0;
  upstreamHandler = defaultUpstreamHandler;
});

after(async () => {
  await guard.close({ forceAfterMs: 100 });
  await closeServer(upstream);
});

test('secret contract is URL-safe, length bounded, and compared via fixed-size digests', () => {
  assert.equal(validateAgentMemorySecret(SECRET), SECRET);
  assert.throws(() => validateAgentMemorySecret('short'), /32-256/);
  assert.throws(() => validateAgentMemorySecret(`${'x'.repeat(31)}!`), /URL-safe/);
  assert.throws(() => validateAgentMemorySecret('x'.repeat(257)), /32-256/);
  assert.equal(constantTimeTokenEqual(SECRET, SECRET), true);
  assert.equal(constantTimeTokenEqual(`${SECRET}x`, SECRET), false);
  assert.equal(constantTimeTokenEqual('', SECRET), false);
});

test('valid requests reach only the fixed upstream with a normalized bearer', async () => {
  const response = await requestGuard({
    method: 'POST',
    path: '/agentmemory/remember?project=fixture',
    headers: {
      'Content-Type': 'application/json',
      Origin: `http://localhost:${guardPort}`,
      'Sec-Fetch-Site': 'same-origin',
      'X-Forwarded-Host': 'rebind.invalid',
    },
    body: '{"content":"safe"}',
  });
  assert.equal(response.statusCode, 200);
  assert.equal(upstreamHits, 1);
  const echoed = JSON.parse(response.body.toString('utf8'));
  assert.equal(echoed.authorization, `Bearer ${SECRET}`);
  assert.equal(echoed.host, `127.0.0.1:${INTERNAL_REST_PORT}`);
  assert.equal(echoed.method, 'POST');
  assert.equal(echoed.url, '/agentmemory/remember?project=fixture');
  assert.equal(echoed.body, '{"content":"safe"}');
  assert.equal(response.headers['x-upstream'], 'agentmemory-fixture');
});

test('guard health is authenticated, probes upstream, and exposes only its fixed schema', async () => {
  const response = await requestGuard({ path: GUARD_HEALTH_PATH });
  assert.equal(response.statusCode, 200);
  assert.equal(upstreamHits, 1);
  const health = JSON.parse(response.body.toString('utf8'));
  assert.deepEqual(health, {
    service: GUARD_SERVICE,
    status: 'healthy',
    version: GUARD_VERSION,
    listenPort: guardPort,
    upstreamPort: INTERNAL_REST_PORT,
  });
  assert.equal(response.body.includes(Buffer.from(SECRET)), false);
});

test('health fails closed with the same native schema when upstream is unhealthy', async () => {
  upstreamHandler = (_request, response) => {
    response.writeHead(401, { 'Content-Type': 'application/json' });
    response.end('{"error":"unauthorized"}\n');
  };
  const response = await requestGuard({ path: GUARD_HEALTH_PATH });
  assert.equal(response.statusCode, 503);
  assert.deepEqual(JSON.parse(response.body.toString('utf8')), {
    service: GUARD_SERVICE,
    status: 'unhealthy',
    version: GUARD_VERSION,
    listenPort: guardPort,
    upstreamPort: INTERNAL_REST_PORT,
  });
});

test('hostile Host, Origin, Sec-Fetch-Site, and bearer never touch upstream', async (t) => {
  const cases = [
    {
      name: 'host',
      options: { headers: { Host: `rebind.invalid:${guardPort}` } },
      statusCode: 421,
    },
    {
      name: 'origin',
      options: { headers: { Origin: `http://rebind.invalid:${guardPort}` } },
      statusCode: 403,
    },
    {
      name: 'fetch site',
      options: { headers: { 'Sec-Fetch-Site': 'cross-site' } },
      statusCode: 403,
    },
    {
      name: 'bearer',
      options: { secret: 'Wrong_Test_Secret-0123456789abcdef' },
      statusCode: 401,
    },
  ];
  for (const fixture of cases) {
    await t.test(fixture.name, async () => {
      upstreamHits = 0;
      const response = await requestGuard(fixture.options);
      assert.equal(response.statusCode, fixture.statusCode);
      assert.equal(upstreamHits, 0);
    });
  }
});

test('duplicate singleton headers and ambiguous framing are rejected before upstream', async (t) => {
  const base = [
    'GET /agentmemory/health HTTP/1.1',
    `Host: 127.0.0.1:${guardPort}`,
    `Authorization: Bearer ${SECRET}`,
  ];
  const fixtures = [
    [
      'duplicate host',
      [...base, `Host: localhost:${guardPort}`, 'Connection: close', '', ''].join('\r\n'),
    ],
    [
      'duplicate authorization',
      [...base, `Authorization: Bearer ${SECRET}`, 'Connection: close', '', ''].join('\r\n'),
    ],
    [
      'content length plus transfer encoding',
      [
        'POST /agentmemory/remember HTTP/1.1',
        `Host: 127.0.0.1:${guardPort}`,
        `Authorization: Bearer ${SECRET}`,
        'Content-Length: 4',
        'Transfer-Encoding: chunked',
        'Connection: close',
        '',
        '0',
        '',
        '',
      ].join('\r\n'),
    ],
  ];
  for (const [name, payload] of fixtures) {
    await t.test(name, async () => {
      upstreamHits = 0;
      const response = await rawRequest(payload);
      assert.match(response, /^HTTP\/1\.1 400 /);
      assert.equal(upstreamHits, 0);
    });
  }
});

test('oversized declared and chunked bodies are bounded', async (t) => {
  await t.test('declared size is rejected without upstream contact', async () => {
    const response = await requestGuard({
      method: 'POST',
      headers: { 'Content-Length': '1025' },
    });
    assert.equal(response.statusCode, 413);
    assert.equal(upstreamHits, 0);
  });

  await t.test('streamed size is cut off at the byte ceiling', async () => {
    const response = await new Promise((resolvePromise, reject) => {
      const request = http.request({
        host: '127.0.0.1',
        port: guardPort,
        method: 'POST',
        path: '/agentmemory/remember',
        headers: {
          Authorization: `Bearer ${SECRET}`,
          Host: `127.0.0.1:${guardPort}`,
          'Transfer-Encoding': 'chunked',
        },
        agent: false,
      });
      request.once('error', reject);
      request.once('response', (incoming) => {
        const chunks = [];
        incoming.on('data', (chunk) => chunks.push(chunk));
        incoming.once('end', () => resolvePromise({
          body: Buffer.concat(chunks),
          statusCode: incoming.statusCode,
        }));
      });
      request.write(Buffer.alloc(700, 0x61));
      request.end(Buffer.alloc(700, 0x62));
    });
    assert.equal(response.statusCode, 413);
    assert.match(response.body.toString('utf8'), /request body too large/);
    assert.ok(upstreamHits <= 1, 'the over-limit stream must not be replayed');
  });
});

test('request and response bodies stream without whole-body buffering', async () => {
  let firstUpstreamChunk;
  const firstUpstreamChunkSeen = new Promise((resolvePromise) => {
    firstUpstreamChunk = resolvePromise;
  });
  upstreamHandler = (request, response) => {
    let body = '';
    request.on('data', (chunk) => {
      body += chunk.toString('utf8');
      firstUpstreamChunk();
    });
    request.once('end', () => {
      response.writeHead(200, { 'Content-Type': 'text/plain' });
      response.write(`first:${body}:`);
      setTimeout(() => response.end('last'), 40);
    });
  };

  const clientRequest = http.request({
    host: '127.0.0.1',
    port: guardPort,
    method: 'POST',
    path: '/agentmemory/stream-test',
    headers: {
      Authorization: `Bearer ${SECRET}`,
      Host: `127.0.0.1:${guardPort}`,
      'Transfer-Encoding': 'chunked',
    },
    agent: false,
  });
  clientRequest.write('alpha');
  await Promise.race([
    firstUpstreamChunkSeen,
    new Promise((_, reject) => setTimeout(() => reject(new Error('request did not stream')), 500)),
  ]);

  const responsePromise = once(clientRequest, 'response').then(([response]) => new Promise((resolvePromise, reject) => {
    const chunks = [];
    const arrivalTimes = [];
    response.on('data', (chunk) => {
      chunks.push(chunk);
      arrivalTimes.push(Date.now());
    });
    response.once('end', () => resolvePromise({ body: Buffer.concat(chunks), arrivalTimes }));
    response.once('error', reject);
  }));
  clientRequest.end('-omega');
  const streamed = await responsePromise;
  assert.equal(streamed.body.toString('utf8'), 'first:alpha-omega:last');
  assert.ok(streamed.arrivalTimes.length >= 2);
  assert.ok(streamed.arrivalTimes.at(-1) - streamed.arrivalTimes[0] >= 20);
});

test('client abort destroys the upstream request and leaves the guard usable', async () => {
  let sawAbort;
  const abortSeen = new Promise((resolvePromise) => {
    sawAbort = resolvePromise;
  });
  upstreamHandler = (request, response) => {
    request.once('aborted', sawAbort);
    request.once('close', () => {
      if (!request.complete) sawAbort();
    });
    response.once('error', () => {});
  };

  const client = http.request({
    host: '127.0.0.1',
    port: guardPort,
    method: 'POST',
    path: '/agentmemory/observe',
    headers: {
      Authorization: `Bearer ${SECRET}`,
      'Content-Length': '100',
      Host: `127.0.0.1:${guardPort}`,
    },
    agent: false,
  });
  client.on('error', () => {});
  client.write('partial');
  await new Promise((resolvePromise) => setTimeout(resolvePromise, 20));
  client.destroy();
  await Promise.race([
    abortSeen,
    new Promise((_, reject) => setTimeout(() => reject(new Error('upstream was not aborted')), 750)),
  ]);

  upstreamHandler = defaultUpstreamHandler;
  const response = await requestGuard();
  assert.equal(response.statusCode, 200);
});

test('upstream timeout fails once with 504 and never replays the request', async () => {
  upstreamHandler = () => {};
  const shortGuard = createAgentMemoryHostGuard({
    listenPort: 0,
    secret: SECRET,
    maxRequestBodyBytes: 1024,
    requestIdleTimeoutMs: 1_000,
    upstreamTimeoutMs: 75,
    responseIdleTimeoutMs: 1_000,
  });
  const address = await shortGuard.listen();
  try {
    const response = await requestGuard({ port: address.port });
    assert.equal(response.statusCode, 504);
    assert.match(response.body.toString('utf8'), /upstream timeout/);
    assert.equal(upstreamHits, 1);
  } finally {
    await shortGuard.close({ forceAfterMs: 100 });
  }
});

test('invalid Expect request is rejected without 100 Continue, body reads, or upstream contact', async () => {
  let continued = false;
  const response = await new Promise((resolvePromise, reject) => {
    const request = http.request({
      host: '127.0.0.1',
      port: guardPort,
      method: 'POST',
      path: '/agentmemory/remember',
      headers: {
        Authorization: 'Bearer Wrong_Test_Secret-0123456789abcdef',
        'Content-Length': '100',
        Expect: '100-continue',
        Host: `127.0.0.1:${guardPort}`,
      },
      agent: false,
    });
    request.once('continue', () => {
      continued = true;
      request.write(Buffer.alloc(100));
    });
    request.once('error', reject);
    request.once('response', (incoming) => {
      incoming.resume();
      incoming.once('end', () => resolvePromise(incoming));
    });
    request.flushHeaders();
  });
  assert.equal(response.statusCode, 401);
  assert.equal(continued, false);
  assert.equal(upstreamHits, 0);
});

test('WebSocket upgrade is unavailable on the public REST listener', async () => {
  const response = await rawRequest([
    'GET /agentmemory/health HTTP/1.1',
    `Host: 127.0.0.1:${guardPort}`,
    `Authorization: Bearer ${SECRET}`,
    'Connection: Upgrade',
    'Upgrade: websocket',
    'Sec-WebSocket-Version: 13',
    'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==',
    '',
    '',
  ].join('\r\n'));
  assert.match(response, /^HTTP\/1\.1 426 /);
  assert.equal(upstreamHits, 0);
});

test('CLI requires exactly one listen port and the fixed upstream port', () => {
  const env = { ...process.env, AGENTMEMORY_SECRET: SECRET };
  const fixtures = [
    [['--listen-port', '3111'], /--upstream-port is required/],
    [['--upstream-port', '6000'], /--listen-port is required/],
    [['--listen-port', '3111', '--upstream-port', '6001'], /exactly 6000/],
    [[
      '--listen-port', '3111', '--listen-port', '3112', '--upstream-port', '6000',
    ], /only once/],
    [['--listen-port', '3111', '--upstream-port', '6000', '--extra'], /unsupported argument/],
  ];
  for (const [args, message] of fixtures) {
    const result = spawnSync(process.execPath, [SCRIPT, ...args], {
      encoding: 'utf8',
      env,
      timeout: 5_000,
      windowsHide: true,
    });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, message);
    assert.equal(result.stderr.includes(SECRET), false);
  }
});
