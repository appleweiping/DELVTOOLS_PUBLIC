import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer, request as httpRequest } from "node:http";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

import { loadConfiguration } from "../key-rotator.mjs";

const TEST_DIR = dirname(fileURLToPath(import.meta.url));
const ROTATOR_SCRIPT = resolve(TEST_DIR, "..", "key-rotator.mjs");
const PROCESS_TIMEOUT_MS = 5_000;

function cleanEnvironment(overrides = {}) {
  const environment = {};
  for (const [name, value] of Object.entries(process.env)) {
    if (!name.startsWith("ROTATOR_")) environment[name] = value;
  }
  return { ...environment, ...overrides };
}

function fixtureKey(label) {
  return ["private", "fixture", label, "value"].join("-");
}

const DEFAULT_PROXY_TOKEN = fixtureKey("inbound-proxy-token");

function assertAbsent(output, values) {
  for (const value of values) {
    assert.equal(output.includes(value), false, "output disclosed a protected value");
  }
}

function assertSecretAbsent(output, values) {
  assertAbsent(output, values);
  for (const value of values) {
    if (value.length >= 12) {
      assert.equal(output.includes(value.slice(0, 8)), false, "output disclosed a protected prefix");
      assert.equal(output.includes(value.slice(-8)), false, "output disclosed a protected suffix");
    }
  }
}

function within(promise, timeoutMs, label) {
  let timer;
  const timeout = new Promise((_resolve, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} exceeded ${timeoutMs} ms`)), timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

function waitForExit(child, timeoutMs = PROCESS_TIMEOUT_MS) {
  if (child.exitCode !== null || child.signalCode !== null) {
    return Promise.resolve({ code: child.exitCode, signal: child.signalCode });
  }

  return new Promise((resolveExit, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`child process did not exit within ${timeoutMs} ms`));
    }, timeoutMs);
    child.once("exit", (code, signal) => {
      clearTimeout(timer);
      resolveExit({ code, signal });
    });
  });
}

async function runCli(environment) {
  const child = spawn(process.execPath, [ROTATOR_SCRIPT], {
    env: cleanEnvironment(environment),
    stdio: ["ignore", "pipe", "pipe"],
    windowsHide: true,
  });
  let stdout = "";
  let stderr = "";
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stderr.on("data", (chunk) => { stderr += chunk; });

  try {
    const result = await waitForExit(child);
    return { ...result, stdout, stderr, output: stdout + stderr };
  } catch (error) {
    child.kill();
    throw error;
  }
}

async function startProxy(environment) {
  const proxyToken = environment.ROTATOR_PROXY_TOKEN ?? DEFAULT_PROXY_TOKEN;
  const child = spawn(process.execPath, [ROTATOR_SCRIPT], {
    env: cleanEnvironment({ ROTATOR_PORT: "0", ROTATOR_PROXY_TOKEN: proxyToken, ...environment }),
    stdio: ["ignore", "pipe", "pipe", "ipc"],
    windowsHide: true,
  });
  child.stdout.setEncoding("utf8");
  child.stderr.setEncoding("utf8");

  let stdout = "";
  let stderr = "";
  let settled = false;
  let readyTimer;

  const ready = new Promise((resolveReady, rejectReady) => {
    function inspect() {
      const match = stdout.match(/listening on http:\/\/127\.0\.0\.1:(\d+)\/v1\b/);
      if (match && !settled) {
        settled = true;
        clearTimeout(readyTimer);
        resolveReady(Number(match[1]));
      }
    }

    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      inspect();
    });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.once("exit", (code, signal) => {
      if (!settled) {
        settled = true;
        clearTimeout(readyTimer);
        rejectReady(new Error(`rotator exited before startup (code=${code}, signal=${signal}): ${stdout}${stderr}`));
      }
    });
    readyTimer = setTimeout(() => {
      if (!settled) {
        settled = true;
        rejectReady(new Error(`rotator did not announce startup: ${stdout}${stderr}`));
      }
    }, PROCESS_TIMEOUT_MS);
  });

  let port;
  try {
    port = await ready;
  } catch (error) {
    if (child.exitCode === null && child.signalCode === null) child.kill();
    throw error;
  }

  return {
    child,
    port,
    baseUrl: `http://127.0.0.1:${port}`,
    proxyToken,
    output: () => stdout + stderr,
    async shutdown() {
      if (child.exitCode !== null || child.signalCode !== null) {
        return { code: child.exitCode, signal: child.signalCode };
      }
      child.send({ type: "shutdown" });
      try {
        return await waitForExit(child);
      } catch (error) {
        child.kill();
        throw error;
      }
    },
  };
}

function proxyFetch(proxy, path, options = {}) {
  const headers = new Headers(options.headers);
  headers.set("x-key-rotator-token", proxy.proxyToken);
  return fetch(`${proxy.baseUrl}${path}`, { ...options, headers });
}

async function startUpstream(handler) {
  const server = createServer(handler);
  await new Promise((resolveListen, rejectListen) => {
    server.once("error", rejectListen);
    server.listen(0, "127.0.0.1", resolveListen);
  });
  const address = server.address();
  assert(address && typeof address === "object");

  return {
    server,
    baseUrl: `http://127.0.0.1:${address.port}/v1`,
    async close() {
      server.closeIdleConnections?.();
      server.closeAllConnections?.();
      await new Promise((resolveClose) => server.close(resolveClose));
    },
  };
}

async function readRequestBody(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return Buffer.concat(chunks).toString("utf8");
}

function rawProxyRequest(proxy, { path = "/v1/models", headers = {} } = {}) {
  return within(new Promise((resolveRequest, rejectRequest) => {
    const request = httpRequest({
      host: "127.0.0.1",
      port: proxy.port,
      path,
      method: "GET",
      headers,
    }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.once("end", () => resolveRequest({
        status: response.statusCode,
        body: Buffer.concat(chunks).toString("utf8"),
      }));
    });
    request.once("error", rejectRequest);
    request.end();
  }), PROCESS_TIMEOUT_MS, "raw proxy request");
}

test("missing and mismatched configuration fail with a nonzero exit and no disclosure", async () => {
  const missing = await runCli({});
  assert.equal(missing.code, 2);
  assert.match(missing.stderr, /configuration error/i);

  const firstKey = fixtureKey("alpha");
  const secondKey = fixtureKey("bravo");
  const target = "http://127.0.0.1:19101/v1";
  const mismatched = await runCli({
    ROTATOR_PROXY_TOKEN: DEFAULT_PROXY_TOKEN,
    ROTATOR_KEYS: `${firstKey},${secondKey}`,
    ROTATOR_TARGETS: target,
  });
  assert.equal(mismatched.code, 2);
  assert.match(mismatched.stderr, /same number/i);
  assertSecretAbsent(mismatched.output, [firstKey, secondKey]);
  assertAbsent(mismatched.output, [target]);

  assert.throws(
    () => loadConfiguration({ ROTATOR_KEYS: firstKey, ROTATOR_TARGETS: target }),
    /ROTATOR_PROXY_TOKEN/u,
  );
  const reusedToken = fixtureKey("same-upstream-and-inbound-proxy-token");
  assert.throws(
    () => loadConfiguration({
      ROTATOR_PROXY_TOKEN: reusedToken,
      ROTATOR_KEYS: reusedToken,
      ROTATOR_TARGETS: target,
    }),
    /independent/u,
  );
});

test("targets require HTTPS except for explicit loopback HTTP URLs", async (t) => {
  const key = fixtureKey("charlie");
  const username = ["embedded", "fixture", "user"].join("-");
  const password = ["embedded", "fixture", "password"].join("-");
  const invalidTargets = [
    "not-a-url",
    "ftp://127.0.0.1/v1",
    `http://${username}:${password}@127.0.0.1/v1`,
    "http://example.test/v1",
  ];

  for (const target of invalidTargets) {
    await t.test(target.split(":", 1)[0], async () => {
      const result = await runCli({
        ROTATOR_PROXY_TOKEN: DEFAULT_PROXY_TOKEN,
        ROTATOR_KEYS: key,
        ROTATOR_TARGETS: target,
      });
      assert.equal(result.code, 2);
      assert.match(result.stderr, /configuration error/i);
      assertSecretAbsent(result.output, [key, username, password]);
      assertAbsent(result.output, [target]);
    });
  }
});

test("startup is loopback-only, health is redacted, and IPC shutdown exits cleanly", async () => {
  const upstream = await startUpstream((_request, response) => {
    response.writeHead(200, { "content-type": "application/json" });
    response.end('{"ok":true}');
  });
  const key = fixtureKey("delta");
  const proxy = await startProxy({
    ROTATOR_HOST: "0.0.0.0",
    ROTATOR_KEYS: key,
    ROTATOR_TARGETS: upstream.baseUrl,
  });

  try {
    const healthResponse = await proxyFetch(proxy, "/health");
    assert.equal(healthResponse.status, 200);
    const healthText = await healthResponse.text();
    const health = JSON.parse(healthText);
    assert.equal(health.ok, true);
    assert.equal(health.endpoints.length, 1);
    assert.equal(health.endpoints[0].index, 1);
    assertSecretAbsent(proxy.output() + healthText, [key]);
    assertAbsent(proxy.output() + healthText, [upstream.baseUrl]);
  } finally {
    const exit = await proxy.shutdown();
    await upstream.close();
    assert.equal(exit.code, 0);
    assert.equal(exit.signal, null);
  }
});

test("inbound proxy authentication rejects DNS rebinding and cross-site browser requests", async () => {
  let upstreamCalls = 0;
  let forwardedProxyToken;
  const upstream = await startUpstream((request, response) => {
    upstreamCalls += 1;
    forwardedProxyToken = request.headers["x-key-rotator-token"];
    response.writeHead(200, { "content-type": "application/json" });
    response.end('{"ok":true}');
  });
  const upstreamKey = fixtureKey("boundary-upstream");
  const proxyToken = fixtureKey("boundary-inbound-proxy-token");
  const wrongToken = fixtureKey("boundary-wrong-proxy-token");
  const proxy = await startProxy({
    ROTATOR_PROXY_TOKEN: proxyToken,
    ROTATOR_KEYS: upstreamKey,
    ROTATOR_TARGETS: upstream.baseUrl,
  });

  try {
    const rejected = [
      await rawProxyRequest(proxy),
      await rawProxyRequest(proxy, { headers: { "x-key-rotator-token": wrongToken } }),
      await rawProxyRequest(proxy, {
        headers: {
          host: `attacker.example:${proxy.port}`,
          "x-key-rotator-token": proxyToken,
        },
      }),
      await rawProxyRequest(proxy, {
        headers: {
          origin: "https://attacker.example",
          "sec-fetch-site": "cross-site",
          "x-key-rotator-token": proxyToken,
        },
      }),
      await rawProxyRequest(proxy, {
        headers: {
          origin: proxy.baseUrl,
          "sec-fetch-site": "same-site",
          "x-key-rotator-token": proxyToken,
        },
      }),
    ];
    assert.deepEqual(rejected.map(({ status }) => status), [401, 401, 421, 403, 403]);
    assert.equal(upstreamCalls, 0);

    const accepted = await rawProxyRequest(proxy, {
      headers: {
        origin: proxy.baseUrl,
        "sec-fetch-site": "same-origin",
        "x-key-rotator-token": proxyToken,
      },
    });
    assert.equal(accepted.status, 200);
    assert.equal(upstreamCalls, 1);
    assert.equal(forwardedProxyToken, undefined);
    assertSecretAbsent(proxy.output() + rejected.map(({ body }) => body).join("") + accepted.body, [
      upstreamKey,
      proxyToken,
      wrongToken,
    ]);
  } finally {
    await proxy.shutdown();
    await upstream.close();
  }
});

test("read-only rotation preserves method, path, safe headers, response status, and response body", async () => {
  const observations = [];
  const first = await startUpstream(async (request, response) => {
    observations.push({
      method: request.method,
      url: request.url,
      authorization: request.headers.authorization,
      beta: request.headers["openai-beta"],
      body: await readRequestBody(request),
    });
    response.writeHead(401, { "content-type": "text/plain" });
    response.end("retry");
  });
  const expectedResponseBody = '{"result":"from-second"}';
  const second = await startUpstream(async (request, response) => {
    observations.push({
      method: request.method,
      url: request.url,
      authorization: request.headers.authorization,
      beta: request.headers["openai-beta"],
      body: await readRequestBody(request),
    });
    response.writeHead(207, {
      "content-type": "application/json",
      "x-upstream-result": "second",
    });
    response.end(expectedResponseBody);
  });
  const firstKey = fixtureKey("echo");
  const secondKey = fixtureKey("foxtrot");
  const clientCredential = fixtureKey("client");
  const proxy = await startProxy({
    ROTATOR_KEYS: `${firstKey},${secondKey}`,
    ROTATOR_TARGETS: `${first.baseUrl},${second.baseUrl}`,
  });
  try {
    const response = await proxyFetch(proxy, "/v1/models?mode=fixture", {
      method: "GET",
      headers: {
        authorization: `Bearer ${clientCredential}`,
        "openai-beta": "responses=v1",
      },
    });
    assert.equal(response.status, 207);
    assert.equal(response.headers.get("x-upstream-result"), "second");
    assert.equal(await response.text(), expectedResponseBody);
    assert.equal(observations.length, 2);
    assert.deepEqual(observations.map(({ method, url, beta, body }) => ({ method, url, beta, body })), [
      { method: "GET", url: "/v1/models?mode=fixture", beta: "responses=v1", body: "" },
      { method: "GET", url: "/v1/models?mode=fixture", beta: "responses=v1", body: "" },
    ]);
    assert.equal(observations[0].authorization, `Bearer ${firstKey}`);
    assert.equal(observations[1].authorization, `Bearer ${secondKey}`);

    const healthText = await (await proxyFetch(proxy, "/v1/health")).text();
    const health = JSON.parse(healthText);
    assert.equal(health.current, 2);
    assert.equal(health.endpoints[0].failures, 1);
    assert.equal(health.endpoints[1].successes, 1);
    assertSecretAbsent(proxy.output() + healthText, [firstKey, secondKey, clientCredential]);
    assertAbsent(proxy.output() + healthText, [first.baseUrl, second.baseUrl]);
  } finally {
    await proxy.shutdown();
    await Promise.all([first.close(), second.close()]);
  }
});

test("request credentials are replaced or dropped while required OpenAI headers and body survive", async () => {
  let observed;
  const upstream = await startUpstream(async (request, response) => {
    observed = {
      headers: request.headers,
      body: await readRequestBody(request),
    };
    response.writeHead(200, { "content-type": "application/json" });
    response.end('{"ok":true}');
  });
  const upstreamKey = fixtureKey("header-upstream");
  const clientCredential = fixtureKey("header-client");
  const aliasCredential = fixtureKey("header-alias");
  const requestBody = '{"model":"fixture-model","input":"hello"}';
  const proxy = await startProxy({
    ROTATOR_KEYS: upstreamKey,
    ROTATOR_TARGETS: upstream.baseUrl,
  });

  try {
    const response = await proxyFetch(proxy, "/v1/responses", {
      method: "POST",
      headers: {
        accept: "text/event-stream",
        authorization: `Bearer ${clientCredential}`,
        "content-type": "application/json",
        cookie: `session=${aliasCredential}`,
        "api-key": aliasCredential,
        "x-api-key": aliasCredential,
        "x-auth-token": aliasCredential,
        "x-access-token": aliasCredential,
        "x-amz-security-token": aliasCredential,
        "x-goog-api-key": aliasCredential,
        "private-token": aliasCredential,
        "idempotency-key": "fixture-operation-1",
        "openai-beta": "responses=v1",
        "openai-organization": "org_fixture",
        "openai-project": "proj_fixture",
        "x-request-id": "request_fixture",
      },
      body: requestBody,
    });
    assert.equal(response.status, 200);
    assert.equal(await response.text(), '{"ok":true}');
    assert(observed);
    assert.equal(observed.body, requestBody);
    assert.equal(observed.headers.authorization, `Bearer ${upstreamKey}`);
    assert.equal(observed.headers.accept, "text/event-stream");
    assert.equal(observed.headers["content-type"], "application/json");
    assert.equal(observed.headers["idempotency-key"], "fixture-operation-1");
    assert.equal(observed.headers["openai-beta"], "responses=v1");
    assert.equal(observed.headers["openai-organization"], "org_fixture");
    assert.equal(observed.headers["openai-project"], "proj_fixture");
    assert.equal(observed.headers["x-request-id"], "request_fixture");
    for (const name of [
      "cookie",
      "api-key",
      "x-api-key",
      "x-auth-token",
      "x-access-token",
      "x-amz-security-token",
      "x-goog-api-key",
      "private-token",
    ]) {
      assert.equal(observed.headers[name], undefined, `${name} reached the upstream`);
    }
    assertSecretAbsent(proxy.output(), [upstreamKey, clientCredential, aliasCredential]);
  } finally {
    await proxy.shutdown();
    await upstream.close();
  }
});

test("SSE starts promptly, remains streamed beyond the header timeout, and never rotates after headers", async () => {
  let firstCalls = 0;
  let secondCalls = 0;
  const first = await startUpstream((_request, response) => {
    firstCalls += 1;
    response.writeHead(200, {
      "cache-control": "no-cache",
      "content-type": "text/event-stream",
    });
    response.flushHeaders();
    response.write("data: first\n\n");
    setTimeout(() => {
      response.write("data: second\n\n");
      response.end();
    }, 900).unref?.();
  });
  const second = await startUpstream((_request, response) => {
    secondCalls += 1;
    response.writeHead(200, { "content-type": "text/event-stream" });
    response.end("data: fallback\n\n");
  });
  const proxy = await startProxy({
    ROTATOR_KEYS: `${fixtureKey("stream-a")},${fixtureKey("stream-b")}`,
    ROTATOR_TARGETS: `${first.baseUrl},${second.baseUrl}`,
    ROTATOR_UPSTREAM_TIMEOUT_MS: "100",
  });

  try {
    const startedAt = Date.now();
    const response = await within(proxyFetch(proxy, "/v1/responses"), 500, "SSE response headers");
    assert.equal(response.status, 200);
    assert.equal(response.headers.get("content-type"), "text/event-stream");
    assert(response.body);
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    const firstRead = await within(reader.read(), 500, "first SSE block");
    assert.equal(firstRead.done, false);
    let received = decoder.decode(firstRead.value, { stream: true });
    assert.match(received, /data: first\n\n/u);
    assert(Date.now() - startedAt < 500, "first SSE block was buffered instead of forwarded promptly");

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      received += decoder.decode(value, { stream: true });
    }
    received += decoder.decode();
    assert.match(received, /data: second\n\n/u);
    assert.equal(firstCalls, 1);
    assert.equal(secondCalls, 0);
  } finally {
    await proxy.shutdown();
    await Promise.all([first.close(), second.close()]);
  }
});

test("POST without an idempotency signal is not replayed after 5xx, network failure, or timeout", async (t) => {
  await t.test("5xx", async () => {
    let firstCalls = 0;
    let secondCalls = 0;
    const first = await startUpstream(async (request, response) => {
      firstCalls += 1;
      await readRequestBody(request);
      response.writeHead(503, { "content-type": "text/plain" });
      response.end("executed-once");
    });
    const second = await startUpstream((_request, response) => {
      secondCalls += 1;
      response.end("must-not-run");
    });
    const proxy = await startProxy({
      ROTATOR_KEYS: `${fixtureKey("post-5xx-a")},${fixtureKey("post-5xx-b")}`,
      ROTATOR_TARGETS: `${first.baseUrl},${second.baseUrl}`,
    });
    try {
      const response = await proxyFetch(proxy, "/v1/responses", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: '{"input":"once"}',
      });
      assert.equal(response.status, 503);
      assert.equal(await response.text(), "executed-once");
      assert.equal(firstCalls, 1);
      assert.equal(secondCalls, 0);
    } finally {
      await proxy.shutdown();
      await Promise.all([first.close(), second.close()]);
    }
  });

  await t.test("network failure", async () => {
    const unused = await startUpstream((_request, response) => response.end());
    const unreachableTarget = unused.baseUrl;
    await unused.close();
    let secondCalls = 0;
    const second = await startUpstream((_request, response) => {
      secondCalls += 1;
      response.end("must-not-run");
    });
    const proxy = await startProxy({
      ROTATOR_KEYS: `${fixtureKey("post-network-a")},${fixtureKey("post-network-b")}`,
      ROTATOR_TARGETS: `${unreachableTarget},${second.baseUrl}`,
      ROTATOR_UPSTREAM_TIMEOUT_MS: "200",
    });
    try {
      const response = await proxyFetch(proxy, "/v1/responses", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: '{"input":"once"}',
      });
      assert.equal(response.status, 502);
      assert.equal(secondCalls, 0);
    } finally {
      await proxy.shutdown();
      await second.close();
    }
  });

  await t.test("timeout", async () => {
    let firstCalls = 0;
    let secondCalls = 0;
    const first = await startUpstream(async (request, _response) => {
      firstCalls += 1;
      await readRequestBody(request);
    });
    const second = await startUpstream((_request, response) => {
      secondCalls += 1;
      response.end("must-not-run");
    });
    const proxy = await startProxy({
      ROTATOR_KEYS: `${fixtureKey("post-timeout-a")},${fixtureKey("post-timeout-b")}`,
      ROTATOR_TARGETS: `${first.baseUrl},${second.baseUrl}`,
      // Leave enough time for the loopback server to accept the request even on a
      // saturated Windows runner; the separate bounded-timeout test covers the
      // minimum timeout path.
      ROTATOR_UPSTREAM_TIMEOUT_MS: "1000",
    });
    try {
      const response = await proxyFetch(proxy, "/v1/responses", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: '{"input":"once"}',
      });
      assert.equal(response.status, 502);
      assert.equal(firstCalls, 1);
      assert.equal(secondCalls, 0);
    } finally {
      await proxy.shutdown();
      await Promise.all([first.close(), second.close()]);
    }
  });
});

test("POST is never replayed across slots even when it carries Idempotency-Key", async () => {
  const observations = [];
  let secondCalls = 0;
  const first = await startUpstream(async (request, response) => {
    observations.push({
      body: await readRequestBody(request),
      idempotencyKey: request.headers["idempotency-key"],
    });
    response.writeHead(503, { "content-type": "text/plain" });
    response.end("retry");
  });
  const second = await startUpstream(async (request, response) => {
    secondCalls += 1;
    await readRequestBody(request);
    response.writeHead(201, { "content-type": "application/json" });
    response.end('{"created":true}');
  });
  const proxy = await startProxy({
    ROTATOR_KEYS: `${fixtureKey("idem-a")},${fixtureKey("idem-b")}`,
    ROTATOR_TARGETS: `${first.baseUrl},${second.baseUrl}`,
  });
  const body = '{"input":"safe-to-replay"}';

  try {
    const response = await proxyFetch(proxy, "/v1/responses", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "idempotency-key": "fixture-operation-2",
      },
      body,
    });
    assert.equal(response.status, 503);
    assert.equal(await response.text(), "retry");
    assert.deepEqual(observations, [
      { body, idempotencyKey: "fixture-operation-2" },
    ]);
    assert.equal(secondCalls, 0);

    const health = await proxyFetch(proxy, "/health");
    assert.equal(health.status, 200);
    assert.equal((await health.json()).current, 2);
  } finally {
    await proxy.shutdown();
    await Promise.all([first.close(), second.close()]);
  }
});

test("POST authentication rejection advances the next slot without replaying the request", async (t) => {
  for (const status of [401, 403]) {
    await t.test(String(status), async () => {
      let secondCalls = 0;
      const first = await startUpstream(async (request, response) => {
        await readRequestBody(request);
        response.writeHead(status, { "content-type": "text/plain" });
        response.end("credential rejected");
      });
      const second = await startUpstream(async (request, response) => {
        secondCalls += 1;
        await readRequestBody(request);
        response.writeHead(200, { "content-type": "text/plain" });
        response.end("rotated");
      });
      const proxy = await startProxy({
        ROTATOR_KEYS: `${fixtureKey(`auth-${status}-a`)},${fixtureKey(`auth-${status}-b`)}`,
        ROTATOR_TARGETS: `${first.baseUrl},${second.baseUrl}`,
      });
      try {
        const response = await proxyFetch(proxy, "/v1/responses", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: '{"input":"auth-only-retry"}',
        });
        assert.equal(response.status, status);
        assert.equal(await response.text(), "credential rejected");
        assert.equal(secondCalls, 0);
        const health = await proxyFetch(proxy, "/health");
        assert.equal((await health.json()).current, 2);
      } finally {
        await proxy.shutdown();
        await Promise.all([first.close(), second.close()]);
      }
    });
  }
});

test("nominally idempotent write methods are not replayed across target origins", async (t) => {
  for (const method of ["PUT", "DELETE"]) {
    await t.test(method, async () => {
      let firstCalls = 0;
      let secondCalls = 0;
      const first = await startUpstream(async (request, response) => {
        firstCalls += 1;
        await readRequestBody(request);
        response.writeHead(503, { "content-type": "text/plain" });
        response.end("write-failed");
      });
      const second = await startUpstream(async (request, response) => {
        secondCalls += 1;
        await readRequestBody(request);
        response.end("must-not-run");
      });
      const proxy = await startProxy({
        ROTATOR_KEYS: `${fixtureKey(`${method}-a`)},${fixtureKey(`${method}-b`)}`,
        ROTATOR_TARGETS: `${first.baseUrl},${second.baseUrl}`,
      });
      try {
        const response = await proxyFetch(proxy, "/v1/resource", {
          method,
          headers: { "content-type": "application/json" },
          body: '{"mutation":true}',
        });
        assert.equal(response.status, 503);
        assert.equal(await response.text(), "write-failed");
        assert.equal(firstCalls, 1);
        assert.equal(secondCalls, 0);
      } finally {
        await proxy.shutdown();
        await Promise.all([first.close(), second.close()]);
      }
    });
  }
});

test("upstream redirects are blocked before a client can leak its proxy token or body", async () => {
  let sinkCalls = 0;
  const sink = await startUpstream(async (request, response) => {
    sinkCalls += 1;
    await readRequestBody(request);
    response.end("leaked");
  });
  const redirector = await startUpstream(async (request, response) => {
    await readRequestBody(request);
    response.writeHead(307, { location: `${sink.baseUrl}/capture` });
    response.end();
  });
  const proxy = await startProxy({
    ROTATOR_KEYS: fixtureKey("redirect"),
    ROTATOR_TARGETS: redirector.baseUrl,
  });
  try {
    const response = await proxyFetch(proxy, "/v1/responses", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: '{"input":"once"}',
    });
    assert.equal(response.status, 502);
    assert.equal(response.headers.has("location"), false);
    assert.deepEqual(await response.json(), {
      error: {
        code: "upstream_redirect_blocked",
        message: "Upstream redirects are not allowed.",
      },
    });
    assert.equal(sinkCalls, 0);
  } finally {
    await proxy.shutdown();
    await Promise.all([redirector.close(), sink.close()]);
  }
});

test("each retryable upstream status rotates to the next slot", async (t) => {
  for (const status of [401, 403, 429, 500, 503]) {
    await t.test(String(status), async () => {
      const first = await startUpstream((_request, response) => {
        response.writeHead(status, { "content-type": "text/plain" });
        response.end("retryable");
      });
      const second = await startUpstream((_request, response) => {
        response.writeHead(200, { "content-type": "text/plain" });
        response.end(`recovered-${status}`);
      });
      const proxy = await startProxy({
        ROTATOR_KEYS: `${fixtureKey(`status-${status}-a`)},${fixtureKey(`status-${status}-b`)}`,
        ROTATOR_TARGETS: `${first.baseUrl},${second.baseUrl}`,
      });
      try {
        const response = await proxyFetch(proxy, "/v1/models");
        assert.equal(response.status, 200);
        assert.equal(await response.text(), `recovered-${status}`);
      } finally {
        await proxy.shutdown();
        await Promise.all([first.close(), second.close()]);
      }
    });
  }
});

test("network failures rotate and upstream timeouts are bounded", async () => {
  const unused = await startUpstream((_request, response) => response.end());
  const unreachableTarget = unused.baseUrl;
  await unused.close();

  const hanging = await startUpstream((_request, _response) => {});
  const healthy = await startUpstream((_request, response) => {
    response.writeHead(200, { "content-type": "text/plain" });
    response.end("recovered");
  });

  const networkProxy = await startProxy({
    ROTATOR_KEYS: `${fixtureKey("network-a")},${fixtureKey("network-b")}`,
    ROTATOR_TARGETS: `${unreachableTarget},${healthy.baseUrl}`,
    ROTATOR_UPSTREAM_TIMEOUT_MS: "200",
  });
  try {
    const response = await proxyFetch(networkProxy, "/v1/models");
    assert.equal(response.status, 200);
    assert.equal(await response.text(), "recovered");
  } finally {
    await networkProxy.shutdown();
  }

  const timeoutProxy = await startProxy({
    ROTATOR_KEYS: `${fixtureKey("timeout-a")},${fixtureKey("timeout-b")}`,
    ROTATOR_TARGETS: `${hanging.baseUrl},${healthy.baseUrl}`,
    ROTATOR_UPSTREAM_TIMEOUT_MS: "150",
  });
  const startedAt = Date.now();
  try {
    const response = await proxyFetch(timeoutProxy, "/v1/models");
    assert.equal(response.status, 200);
    assert.equal(await response.text(), "recovered");
    assert(Date.now() - startedAt < 2_000, "timeout retry exceeded its bounded test window");
  } finally {
    await timeoutProxy.shutdown();
    await Promise.all([hanging.close(), healthy.close()]);
  }
});

test("exhaustion errors, health, and logs never reveal keys or target URLs", async () => {
  const marker = ["credential", "like", "target", "path"].join("-");
  const upstream = await startUpstream((_request, response) => {
    response.writeHead(503, { "content-type": "text/plain" });
    response.end("discarded upstream detail");
  });
  const target = `${upstream.baseUrl}/${marker}`;
  const key = fixtureKey("golf");
  const proxy = await startProxy({ ROTATOR_KEYS: key, ROTATOR_TARGETS: target });

  try {
    const response = await proxyFetch(proxy, "/v1/chat/completions");
    assert.equal(response.status, 502);
    const errorText = await response.text();
    const healthText = await (await proxyFetch(proxy, "/health")).text();
    assert.match(errorText, /upstream slots exhausted/i);
    assertSecretAbsent(proxy.output() + errorText + healthText, [key]);
    assertAbsent(proxy.output() + errorText + healthText, [target, marker]);
  } finally {
    await proxy.shutdown();
    await upstream.close();
  }
});
