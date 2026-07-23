import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';
import test from 'node:test';

const here = dirname(fileURLToPath(import.meta.url));
const repoRoot = resolve(here, '..', '..');
const gate = join(repoRoot, 'scripts', 'ingest-lessons.mjs');

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), 'devtools-lessons-'));
  const pending = join(root, 'pending');
  const ingested = join(root, 'ingested');
  const calls = join(root, 'calls.jsonl');
  const client = join(root, 'fake-client.mjs');
  await mkdir(join(pending, 'ecc'), { recursive: true });
  await mkdir(join(pending, 'hermes'), { recursive: true });
  await writeFile(client, `
import { appendFileSync } from 'node:fs';
export const promotionClientContract = 2;
export async function handleToolCall(name, args) {
  appendFileSync(process.env.FAKE_CALLS, JSON.stringify({ name, args }) + '\\n');
  if (process.env.FAKE_HOLD_MS) await new Promise((resolve) => setTimeout(resolve, Number(process.env.FAKE_HOLD_MS)));
  if (process.env.FAKE_EXIT_AFTER_SAVE === '1') process.exit(86);
  if (process.env.FAKE_THROW_AFTER_SAVE === '1') throw new Error('private ambiguous upstream detail');
  if (process.env.FAKE_FAIL === '1') return { isError: true, content: [{ type: 'text', text: 'private upstream detail' }] };
  return { content: [{ type: 'text', text: '{"success":true,"memory":{"id":"fixture-memory-id"}}' }] };
}
`, 'utf8');
  return { root, pending, ingested, calls, client };
}

function runGate(fx, extraArgs = [], extraEnv = {}, { includeClient = true } = {}) {
  const args = [
    gate,
    '--pending-root', fx.pending,
    '--ingested-root', fx.ingested,
    ...(includeClient ? ['--client', fx.client] : []),
    ...extraArgs,
  ];
  return new Promise((resolveRun, reject) => {
    const child = spawn(process.execPath, args, {
      cwd: repoRoot,
      env: {
        ...process.env,
        AGENTMEMORY_URL: 'http://127.0.0.1:3111',
        AGENTMEMORY_SECRET: '',
        FAKE_CALLS: fx.calls,
        ...extraEnv,
      },
      windowsHide: true,
    });
    let stdout = '';
    let stderr = '';
    child.stdout.setEncoding('utf8');
    child.stderr.setEncoding('utf8');
    child.stdout.on('data', (chunk) => { stdout += chunk; });
    child.stderr.on('data', (chunk) => { stderr += chunk; });
    child.once('error', reject);
    child.once('close', (code, signal) => resolveRun({ code, signal, stdout, stderr }));
  });
}

async function putCandidate(fx, source, name, value) {
  const target = join(fx.pending, source, name);
  await mkdir(dirname(target), { recursive: true });
  await writeFile(target, JSON.stringify(value), 'utf8');
  return target;
}

async function readCalls(fx) {
  try {
    return (await readFile(fx.calls, 'utf8'))
      .trim()
      .split(/\r?\n/)
      .filter(Boolean)
      .map((line) => JSON.parse(line));
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
}

async function waitFor(predicate, timeoutMs = 10_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    if (await predicate()) return;
    await new Promise((resolveWait) => setTimeout(resolveWait, 50));
  }
  throw new Error('fixture-wait-timeout');
}

const valid = {
  content: 'Slow application health probes need consecutive failures before restart.',
  type: 'bug',
  project: 'agent-infra',
  concepts: ['health-probe', 'restart-policy'],
};

async function startMcpFixture(responseBody = { content: [{ type: 'text', text: '{"success":true,"memory":{"id":"fixture-memory-id"}}' }] }) {
  const calls = [];
  const server = createServer(async (request, response) => {
    let body = '';
    request.setEncoding('utf8');
    for await (const chunk of request) body += chunk;
    let parsed = null;
    try { parsed = JSON.parse(body); } catch {}
    calls.push({ method: request.method, url: request.url, body: parsed });
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify(responseBody));
  });
  await new Promise((resolveListen, rejectListen) => {
    server.once('error', rejectListen);
    server.listen(0, '127.0.0.1', resolveListen);
  });
  const address = server.address();
  return {
    calls,
    url: `http://127.0.0.1:${address.port}`,
    close: () => new Promise((resolveClose) => server.close(resolveClose)),
  };
}

test('dry-run validates without importing a client, moving files, or printing content', async () => {
  const fx = await fixture();
  const candidate = await putCandidate(fx, 'ecc', 'lesson.json', valid);
  const marker = 'Slow application health probes';
  const result = await runGate(
    { ...fx, client: join(fx.root, 'missing-client.mjs') },
    ['--dry-run'],
  );
  assert.equal(result.code, 0, result.stderr);
  assert.equal(await readFile(candidate, 'utf8') !== '', true);
  assert.equal(result.stdout.includes(marker), false);
  assert.equal(result.stderr.includes(marker), false);
  assert.deepEqual(await readCalls(fx), []);
});

test('promotion adds the source identity and derived tags, then moves the candidate', async () => {
  const fx = await fixture();
  await putCandidate(fx, 'ecc', 'lesson.json', valid);
  const result = await runGate(fx);
  assert.equal(result.code, 0, result.stderr);
  const calls = await readCalls(fx);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].name, 'memory_save');
  assert.equal(calls[0].args.content, valid.content);
  const concepts = calls[0].args.concepts;
  for (const expected of ['agent:cc', 'derived-lesson', 'health-probe', 'restart-policy', 'source:ecc']) {
    assert.ok(concepts.includes(expected), `missing ${expected}`);
  }
  assert.equal(concepts.filter((value) => /^lesson-sha256:[a-f0-9]{64}$/.test(value)).length, 1);
  assert.deepEqual(await readdir(join(fx.pending, 'ecc')), []);
  assert.equal((await readdir(join(fx.ingested, 'ecc'))).length, 1);
});

test('a client failure leaves the source candidate pending and does not echo private details', async () => {
  const fx = await fixture();
  const candidate = await putCandidate(fx, 'hermes', 'failure.json', {
    ...valid,
    concepts: ['agent:hermes', 'recovery'],
  });
  const result = await runGate(fx, [], { FAKE_FAIL: '1' });
  assert.equal(result.code, 1);
  assert.equal(await readFile(candidate, 'utf8') !== '', true);
  assert.equal(result.stdout.includes('private upstream detail'), false);
  assert.equal(result.stderr.includes('private upstream detail'), false);
});

test('audited adapters require contract v2', async () => {
  const fx = await fixture();
  const oldClient = (await readFile(fx.client, 'utf8'))
    .replace('promotionClientContract = 2', 'promotionClientContract = 1');
  await writeFile(fx.client, oldClient, 'utf8');
  const candidate = await putCandidate(fx, 'ecc', 'lesson.json', valid);
  const result = await runGate(fx);
  assert.equal(result.code, 1);
  assert.match(result.stderr, /client-contract-mismatch/);
  assert.equal((await readCalls(fx)).length, 0);
  assert.equal(await readFile(candidate, 'utf8') !== '', true);
});

test('strict schema rejects unknown sources, invalid projects, multiple agents, and secret-like content', async () => {
  const pemHeader = (...words) => `-----BEGIN ${words.join(' ')}-----`;
  const cases = [
    ['unknown', { ...valid }],
    ['ecc', { ...valid, project: 'D:\\private\\project' }],
    ['ecc', { ...valid, concepts: ['agent:cc', 'agent:hermes'] }],
    ['ecc', { ...valid, concepts: ['health-probe,agent:hermes', 'restart-policy'] }],
    ['ecc', { ...valid, content: 'Credential was sk-exampleSecretValue1234567890' }],
    ['ecc', { ...valid, content: `GitHub token github_pat_${'A1'.repeat(16)}` }],
    ['ecc', { ...valid, content: `AWS access key AKIA${'A1'.repeat(8)}` }],
    ['ecc', { ...valid, content: `Google key AIza${'A'.repeat(35)}` }],
    ['ecc', { ...valid, content: `JWT eyJ${'A'.repeat(18)}.eyJ${'B'.repeat(18)}.${'C'.repeat(24)}` }],
    ['ecc', { ...valid, content: pemHeader('ENCRYPTED', 'PRIVATE', 'KEY') }],
    ['ecc', { ...valid, content: pemHeader('DSA', 'PRIVATE', 'KEY') }],
    ['ecc', { ...valid, content: pemHeader('PGP', 'PRIVATE', 'KEY', 'BLOCK') }],
  ];
  for (const [source, payload] of cases) {
    const fx = await fixture();
    const raw = JSON.stringify(payload);
    await putCandidate(fx, source, 'invalid.json', payload);
    const result = await runGate(fx);
    assert.equal(result.code, 1, `${source}: ${result.stderr}`);
    assert.equal(result.stdout.includes(raw), false);
    assert.equal(result.stderr.includes(raw), false);
    assert.deepEqual(await readCalls(fx), []);
  }
});

test('a receipt prevents the same normalized lesson from being saved twice', async () => {
  const fx = await fixture();
  await putCandidate(fx, 'ecc', 'first.json', valid);
  const first = await runGate(fx);
  assert.equal(first.code, 0, first.stderr);

  await putCandidate(fx, 'ecc', 'second.json', valid);
  const second = await runGate(fx);
  assert.equal(second.code, 0, second.stderr);
  assert.equal((await readCalls(fx)).length, 1);
  assert.deepEqual(await readdir(join(fx.pending, 'ecc')), []);
  assert.equal((await readdir(join(fx.ingested, 'ecc'))).length, 2);
});

test('a malformed receipt cannot suppress promotion', async () => {
  const fx = await fixture();
  await putCandidate(fx, 'ecc', 'first.json', valid);
  const first = await runGate(fx);
  assert.equal(first.code, 0, first.stderr);
  const receiptRoot = join(fx.ingested, '.receipts');
  const receiptName = (await readdir(receiptRoot)).find((name) => name.endsWith('.json'));
  assert.ok(receiptName);
  await writeFile(join(receiptRoot, receiptName), '{}', 'utf8');

  await putCandidate(fx, 'ecc', 'second.json', valid);
  const second = await runGate(fx);
  assert.equal(second.code, 1);
  assert.equal((await readCalls(fx)).length, 1);
  assert.equal((await readdir(join(fx.pending, 'ecc'))).length, 1);
});

test('missing required fields and unsupported types fail closed', async () => {
  const cases = [
    { type: 'bug', project: 'agent-infra', concepts: [] },
    { content: 'x', project: 'agent-infra', concepts: [] },
    { content: 'x', type: 'lesson', project: 'agent-infra', concepts: [] },
    { content: 'x', type: 'fact', concepts: [] },
  ];
  for (const payload of cases) {
    const fx = await fixture();
    await putCandidate(fx, 'ecc', 'invalid.json', payload);
    const result = await runGate(fx);
    assert.equal(result.code, 1);
    assert.deepEqual(await readCalls(fx), []);
  }
});

test('candidates require at least two non-reserved topic concepts', async () => {
  for (const concepts of [[], ['health-probe'], ['agent:cc', 'derived-lesson']]) {
    const fx = await fixture();
    await putCandidate(fx, 'ecc', 'invalid.json', { ...valid, concepts });
    const result = await runGate(fx);
    assert.equal(result.code, 1, result.stderr);
    assert.deepEqual(await readCalls(fx), []);
  }
});

test('default transport uses the official MCP call endpoint and preserves project scope', async () => {
  const fx = await fixture();
  const mcp = await startMcpFixture();
  try {
    await putCandidate(fx, 'ecc', 'lesson.json', valid);
    const result = await runGate(
      fx,
      ['--agentmemory-url', mcp.url],
      {},
      { includeClient: false },
    );
    assert.equal(result.code, 0, result.stderr);
    assert.equal(mcp.calls.length, 1);
    assert.equal(mcp.calls[0].method, 'POST');
    assert.equal(mcp.calls[0].url, '/agentmemory/mcp/call');
    assert.equal(mcp.calls[0].body.name, 'memory_save');
    assert.equal(mcp.calls[0].body.arguments.project, valid.project);
    assert.match(mcp.calls[0].body.arguments.concepts, /health-probe/);
  } finally {
    await mcp.close();
  }
});

test('an unreachable authoritative service fails closed without a standalone fallback', async () => {
  const fx = await fixture();
  const candidate = await putCandidate(fx, 'ecc', 'lesson.json', valid);
  const result = await runGate(
    fx,
    ['--agentmemory-url', 'http://127.0.0.1:1', '--timeout-ms', '200'],
    { HOME: fx.root, USERPROFILE: fx.root },
    { includeClient: false },
  );
  assert.equal(result.code, 1);
  assert.equal(await readFile(candidate, 'utf8') !== '', true);
  await assert.rejects(readFile(join(fx.root, '.agentmemory', 'standalone.json'), 'utf8'), { code: 'ENOENT' });
  assert.doesNotMatch(`${result.stdout}\n${result.stderr}`, /falling back|standalone\.json/i);
});

test('a 2xx MCP response without a tool success result cannot archive the candidate', async () => {
  for (const responseBody of [
    {},
    { content: [{ type: 'text', text: '{"ok":false}' }] },
    { content: [{ type: 'text', text: '{"saved":"false"}' }] },
    { content: [{ type: 'text', text: '{"saved":"not saved"}' }] },
    { content: [{ type: 'text', text: '{"saved":"false."}' }] },
    { content: [{ type: 'text', text: '{"ok":true,"memoryId":"legacy-id"}' }] },
    { content: [{ type: 'text', text: 'memory was not saved' }] },
    { content: [{ type: 'text', text: '{"success":true,"memory":{}}' }] },
  ]) {
    const fx = await fixture();
    const mcp = await startMcpFixture(responseBody);
    const candidate = await putCandidate(fx, 'ecc', 'lesson.json', valid);
    try {
      const result = await runGate(
        fx,
        ['--agentmemory-url', mcp.url],
        {},
        { includeClient: false },
      );
      assert.equal(result.code, 1);
      assert.equal(await readFile(candidate, 'utf8') !== '', true);
    } finally {
      await mcp.close();
    }
  }
});

test('an ambiguous save leaves a prepared receipt and cannot be retried without explicit resolution', async () => {
  const fx = await fixture();
  const candidate = await putCandidate(fx, 'ecc', 'lesson.json', valid);
  const first = await runGate(fx, [], { FAKE_THROW_AFTER_SAVE: '1' });
  assert.equal(first.code, 1);
  assert.equal(first.stdout.includes('private ambiguous upstream detail'), false);
  assert.equal(first.stderr.includes('private ambiguous upstream detail'), false);
  assert.equal(await readFile(candidate, 'utf8') !== '', true);
  assert.equal((await readCalls(fx)).length, 1);

  const receiptNames = await readdir(join(fx.ingested, '.receipts'));
  const prepared = receiptNames.find((name) => /^[a-f0-9]{64}\.prepared\.json$/.test(name));
  assert.ok(prepared, `missing prepared receipt: ${receiptNames.join(', ')}`);
  const hash = prepared.slice(0, 64);

  const second = await runGate(fx);
  assert.equal(second.code, 1);
  assert.equal((await readCalls(fx)).length, 1, 'an uncertain save was automatically repeated');
  assert.equal(await readFile(candidate, 'utf8') !== '', true);

  const resolved = await runGate(fx, ['--resolve-prepared', `${hash}=saved`]);
  assert.equal(resolved.code, 0, resolved.stderr);
  assert.equal((await readCalls(fx)).length, 1);
  assert.deepEqual(await readdir(join(fx.pending, 'ecc')), []);
});

test('a dead promotion process leaves recoverable state instead of a permanent lock', async () => {
  const fx = await fixture();
  await putCandidate(fx, 'ecc', 'lesson.json', valid);
  const killed = await runGate(fx, [], { FAKE_EXIT_AFTER_SAVE: '1' });
  assert.equal(killed.code, 86);
  assert.equal((await readCalls(fx)).length, 1);

  const retry = await runGate(fx);
  assert.equal(retry.code, 1);
  assert.equal((await readCalls(fx)).length, 1);
  assert.match(retry.stderr, /promotion-state-uncertain/);
  assert.doesNotMatch(retry.stderr, /promotion-lock-busy/);
  assert.equal((await readdir(join(fx.ingested, '.receipts'))).some((name) => name.endsWith('.lock')), false);
});

test('an explicitly verified old lock can be broken when its PID was reused', async () => {
  const fx = await fixture();
  await putCandidate(fx, 'ecc', 'lesson.json', valid);
  const killed = await runGate(fx, [], { FAKE_EXIT_AFTER_SAVE: '1' });
  assert.equal(killed.code, 86);
  const receiptRoot = join(fx.ingested, '.receipts');
  const lockName = (await readdir(receiptRoot)).find((name) => name.endsWith('.lock'));
  assert.ok(lockName);
  const lockPath = join(receiptRoot, lockName);
  const owner = JSON.parse(await readFile(lockPath, 'utf8'));
  owner.pid = process.pid;
  owner.createdAt = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  await writeFile(lockPath, `${JSON.stringify(owner)}\n`, 'utf8');
  const hash = lockName.slice(0, 64);

  const blocked = await runGate(fx);
  assert.equal(blocked.code, 1);
  assert.match(blocked.stderr, /promotion-lock-busy/);

  const recovered = await runGate(fx, ['--break-stale-lock', `${hash}=${owner.nonce}`]);
  assert.equal(recovered.code, 1);
  assert.match(recovered.stderr, /promotion-state-uncertain/);
  assert.doesNotMatch(recovered.stderr, /promotion-lock-busy/);
  assert.equal((await readCalls(fx)).length, 1);
  assert.equal((await readdir(receiptRoot)).some((name) => name.endsWith('.lock')), false);
});

test('the OS promotion mutex prevents stale recovery from moving an active owner lock', async () => {
  const fx = await fixture();
  await putCandidate(fx, 'ecc', 'lesson.json', valid);
  const active = runGate(fx, [], { FAKE_HOLD_MS: '5000' });
  const receiptRoot = join(fx.ingested, '.receipts');
  let lockName;
  await waitFor(async () => {
    try {
      lockName = (await readdir(receiptRoot)).find((name) => name.endsWith('.lock'));
      return Boolean(lockName);
    } catch (error) {
      if (error.code === 'ENOENT') return false;
      throw error;
    }
  });
  const lockPath = join(receiptRoot, lockName);
  const owner = JSON.parse(await readFile(lockPath, 'utf8'));
  owner.createdAt = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  await writeFile(lockPath, `${JSON.stringify(owner)}\n`, 'utf8');

  const breaker = await runGate(fx, [
    '--break-stale-lock',
    `${lockName.slice(0, 64)}=${owner.nonce}`,
  ]);
  assert.equal(breaker.code, 1);
  assert.match(breaker.stderr, /promotion-lock-busy/);
  assert.equal(await readFile(lockPath, 'utf8') !== '', true);

  const completed = await active;
  assert.equal(completed.code, 0, completed.stderr);
  assert.equal((await readCalls(fx)).length, 1);
});

test('stale lock recovery fails closed and quarantines before deleting', async () => {
  const wrongNonce = await fixture();
  await putCandidate(wrongNonce, 'ecc', 'lesson.json', valid);
  assert.equal((await runGate(wrongNonce, [], { FAKE_EXIT_AFTER_SAVE: '1' })).code, 86);
  const wrongRoot = join(wrongNonce.ingested, '.receipts');
  const wrongName = (await readdir(wrongRoot)).find((name) => name.endsWith('.lock'));
  const wrongPath = join(wrongRoot, wrongName);
  const wrongOwner = JSON.parse(await readFile(wrongPath, 'utf8'));
  wrongOwner.createdAt = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  await writeFile(wrongPath, `${JSON.stringify(wrongOwner)}\n`, 'utf8');
  const wrongResult = await runGate(wrongNonce, [
    '--break-stale-lock',
    `${wrongName.slice(0, 64)}=00000000-0000-4000-8000-000000000000`,
  ]);
  assert.equal(wrongResult.code, 1);
  assert.match(wrongResult.stderr, /stale-lock-nonce-mismatch/);
  assert.equal(await readFile(wrongPath, 'utf8') !== '', true);

  const fresh = await fixture();
  await putCandidate(fresh, 'ecc', 'lesson.json', valid);
  assert.equal((await runGate(fresh, [], { FAKE_EXIT_AFTER_SAVE: '1' })).code, 86);
  const freshRoot = join(fresh.ingested, '.receipts');
  const freshName = (await readdir(freshRoot)).find((name) => name.endsWith('.lock'));
  const freshPath = join(freshRoot, freshName);
  const freshOwner = JSON.parse(await readFile(freshPath, 'utf8'));
  const freshResult = await runGate(fresh, [
    '--break-stale-lock',
    `${freshName.slice(0, 64)}=${freshOwner.nonce}`,
  ]);
  assert.equal(freshResult.code, 1);
  assert.match(freshResult.stderr, /promotion-lock-not-stale/);
  assert.equal(await readFile(freshPath, 'utf8') !== '', true);

  const missing = await fixture();
  const missingRoot = join(missing.ingested, '.receipts');
  await mkdir(missingRoot, { recursive: true });
  const missingHash = 'a'.repeat(64);
  const missingNonce = '00000000-0000-4000-8000-000000000000';
  const missingPath = join(missingRoot, `${missingHash}.lock`);
  await writeFile(missingPath, `${JSON.stringify({
    schemaVersion: 1,
    pid: process.pid,
    nonce: missingNonce,
    createdAt: new Date(Date.now() - 60 * 60 * 1000).toISOString(),
  })}\n`, 'utf8');
  const missingResult = await runGate(missing, [
    '--break-stale-lock',
    `${missingHash}=${missingNonce}`,
  ]);
  assert.equal(missingResult.code, 1);
  assert.match(missingResult.stderr, /stale-lock-receipt-not-found/);
  assert.equal(await readFile(missingPath, 'utf8') !== '', true);

  const source = await readFile(gate, 'utf8');
  assert.match(source, /async function acquirePromotionMutex\(/);
  const acquisition = source.slice(
    source.indexOf('async function acquirePromotionLock'),
    source.indexOf('async function releasePromotionLock'),
  );
  assert.match(acquisition, /acquirePromotionMutex\(path\)/);
  assert.match(acquisition, /publishPromotionLock\(path,/);
  assert.doesNotMatch(acquisition, /open\(path, 'wx'\)/);
  assert.match(source, /link\(staged, path\)/);
  assert.match(source, /realpath\(dirname\(lockPath\)\)/);
  assert.doesNotMatch(source, /49_152|16_384/);
  const recovery = source.slice(
    source.indexOf('async function breakStalePromotionLock'),
    source.indexOf('function receiptMetadata'),
  );
  assert.match(recovery, /acquirePromotionMutex\(paths\.lock\)/);
  assert.match(recovery, /rename\(paths\.lock, quarantine\)/);
  assert.match(recovery, /unlink\(quarantine\)/);
  assert.doesNotMatch(recovery, /unlink\(paths\.lock\)/);
});

test('Windows pending and ingested roots must share a volume for atomic moves', async (context) => {
  if (process.platform !== 'win32') {
    context.skip('Windows volume contract');
    return;
  }
  const fx = await fixture();
  const result = await runGate({
    ...fx,
    pending: `C:\\nonexistent-lessons-${Date.now()}`,
    ingested: `D:\\nonexistent-lessons-${Date.now()}`,
  });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /roots-must-share-volume/);
});

test('plain HTTP agentmemory endpoints are restricted to loopback', async () => {
  const fx = await fixture();
  const result = await runGate(
    fx,
    ['--agentmemory-url', 'http://example.test:3111'],
    {},
    { includeClient: false },
  );
  assert.equal(result.code, 1);
  assert.match(result.stderr, /insecure-agentmemory-url/);
});
