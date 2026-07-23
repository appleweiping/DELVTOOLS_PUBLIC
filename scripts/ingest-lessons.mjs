#!/usr/bin/env node

import { createHash, randomUUID } from 'node:crypto';
import {
  access,
  link,
  lstat,
  mkdir,
  open,
  readFile,
  readdir,
  realpath,
  rename,
  unlink,
  writeFile,
} from 'node:fs/promises';
import { basename, dirname, isAbsolute, join, parse, relative, resolve, sep } from 'node:path';
import { createServer } from 'node:net';
import { fileURLToPath, pathToFileURL } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = resolve(SCRIPT_DIR, '..');
const TYPES = new Set(['architecture', 'pattern', 'preference', 'bug', 'workflow', 'fact']);
const SOURCE_AGENTS = new Map([
  ['ecc', 'agent:cc'],
  ['hermes', 'agent:hermes'],
]);
const ALLOWED_FIELDS = new Set(['content', 'type', 'project', 'concepts']);
const MAX_FILE_BYTES = 1024 * 1024;
const MAX_CONTENT_CHARS = 64 * 1024;
const MAX_MCP_RESPONSE_BYTES = 1024 * 1024;
const DEFAULT_MCP_TIMEOUT_MS = 60_000;
const CLIENT_CONTRACT_VERSION = 2;
const RECEIPT_SCHEMA_VERSION = 2;
const RECEIPT_DIRECTORY = '.receipts';
const MIN_EXPLICIT_LOCK_BREAK_AGE_MS = 5 * 60 * 1000;

class GateError extends Error {
  constructor(code) {
    super(code);
    this.name = 'GateError';
    this.code = code;
  }
}

function parseArgs(argv) {
  const values = new Map();
  let dryRun = false;
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === '--dry-run') {
      dryRun = true;
      continue;
    }
    if (arg === '--help' || arg === '-h') {
      return { help: true };
    }
    if (![
      '--pending-root',
      '--ingested-root',
      '--client',
      '--agentmemory-url',
      '--timeout-ms',
      '--resolve-prepared',
      '--break-stale-lock',
    ].includes(arg)) {
      throw new GateError('unknown-option');
    }
    const value = argv[i + 1];
    if (!value || value.startsWith('--')) throw new GateError('missing-option-value');
    values.set(arg, value);
    i += 1;
  }

  const devtoolsRoot = resolve(process.env.DEVTOOLS_ROOT || DEFAULT_ROOT);
  const pendingRoot = resolve(
    values.get('--pending-root')
      || process.env.LESSONS_PENDING_ROOT
      || join(devtoolsRoot, 'data', 'derived', 'lessons', 'pending'),
  );
  const ingestedRoot = resolve(
    values.get('--ingested-root')
      || process.env.LESSONS_INGESTED_ROOT
      || join(devtoolsRoot, 'data', 'derived', 'lessons', 'ingested'),
  );
  const configuredClient = values.get('--client') || process.env.AGENTMEMORY_CLIENT_MODULE;
  const client = configuredClient ? resolve(configuredClient) : null;
  const agentmemoryUrl = values.get('--agentmemory-url')
    || process.env.AGENTMEMORY_URL
    || 'http://127.0.0.1:3111';
  const timeoutMs = parseBoundedInteger(
    values.get('--timeout-ms') || process.env.AGENTMEMORY_PROMOTION_TIMEOUT_MS,
    DEFAULT_MCP_TIMEOUT_MS,
    100,
    300_000,
    'invalid-timeout',
  );
  const resolution = parsePreparedResolution(values.get('--resolve-prepared'));
  const staleLockBreak = parseStaleLockBreak(values.get('--break-stale-lock'));

  const pendingKey = process.platform === 'win32' ? pendingRoot.toLowerCase() : pendingRoot;
  const ingestedKey = process.platform === 'win32' ? ingestedRoot.toLowerCase() : ingestedRoot;
  if (pendingKey === ingestedKey) throw new GateError('roots-must-differ');
  if (process.platform === 'win32' && parse(pendingRoot).root.toLowerCase() !== parse(ingestedRoot).root.toLowerCase()) {
    throw new GateError('roots-must-share-volume');
  }
  if (isPathWithin(pendingRoot, ingestedRoot) || isPathWithin(ingestedRoot, pendingRoot)) {
    throw new GateError('roots-must-not-overlap');
  }
  if (dryRun && resolution) throw new GateError('dry-run-cannot-resolve');
  if (dryRun && staleLockBreak) throw new GateError('dry-run-cannot-break-lock');
  validateAgentmemoryUrl(agentmemoryUrl);
  return {
    pendingRoot,
    ingestedRoot,
    client,
    agentmemoryUrl,
    timeoutMs,
    resolution,
    staleLockBreak,
    dryRun,
    help: false,
  };
}

function parseBoundedInteger(raw, fallback, minimum, maximum, errorCode) {
  if (raw === undefined || raw === null || raw === '') return fallback;
  if (!/^\d+$/.test(String(raw))) throw new GateError(errorCode);
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < minimum || value > maximum) {
    throw new GateError(errorCode);
  }
  return value;
}

function parsePreparedResolution(raw) {
  if (raw === undefined) return null;
  const match = /^([a-f0-9]{64})=(saved|retry)$/.exec(raw);
  if (!match) throw new GateError('invalid-prepared-resolution');
  return { hash: match[1], action: match[2] };
}

function parseStaleLockBreak(raw) {
  if (raw === undefined) return null;
  const match = /^([a-f0-9]{64})=([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})$/i.exec(raw);
  if (!match) throw new GateError('invalid-stale-lock-break');
  return { hash: match[1].toLowerCase(), nonce: match[2].toLowerCase() };
}

function isPathWithin(parent, child) {
  const value = relative(parent, child);
  return value !== '' && value !== '..' && !value.startsWith(`..${sep}`) && !isAbsolute(value);
}

function validateAgentmemoryUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    throw new GateError('invalid-agentmemory-url');
  }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) {
    throw new GateError('invalid-agentmemory-url');
  }
  if (url.protocol === 'http:' && !isLoopbackHostname(url.hostname)) {
    throw new GateError('insecure-agentmemory-url');
  }
}

function isLoopbackHostname(rawHostname) {
  const hostname = rawHostname.toLowerCase().replace(/^\[|\]$/g, '');
  if (hostname === 'localhost' || hostname === '::1') return true;
  const octets = hostname.split('.');
  return octets.length === 4
    && octets.every((octet) => /^\d{1,3}$/.test(octet) && Number(octet) <= 255)
    && Number(octets[0]) === 127;
}

function containsSecretLikeValue(value) {
  const patterns = [
    /-----BEGIN (?:(?:PGP )?(?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?)-----/i,
    /\bsk-[A-Za-z0-9_-]{16,}\b/i,
    /\bgh[pousr]_[A-Za-z0-9]{20,}\b/i,
    /\bgithub_pat_[A-Za-z0-9_]{20,}\b/i,
    /\bxox[baprs]-[A-Za-z0-9-]{12,}\b/i,
    /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/,
    /\bAIza[0-9A-Za-z_-]{35}\b/,
    /\beyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/,
    /\bBearer\s+[A-Za-z0-9._~+\/-]{10,}=*/i,
    /\b(?:api[_-]?key|access[_-]?token|secret|password)\s*[:=]\s*["']?[^\s"',]{8,}/i,
    /\bhttps?:\/\/[^\s/:@]+:[^\s/@]+@[^\s/]+/i,
  ];
  return patterns.some((pattern) => pattern.test(value));
}

function validateCandidate(raw, source) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new GateError('candidate-must-be-object');
  }
  if (Object.keys(raw).some((key) => !ALLOWED_FIELDS.has(key))) {
    throw new GateError('unknown-candidate-field');
  }
  if (typeof raw.content !== 'string') throw new GateError('missing-content');
  const content = raw.content.trim();
  if (!content || content.length > MAX_CONTENT_CHARS) throw new GateError('invalid-content-length');
  if (containsSecretLikeValue(content)) throw new GateError('secret-like-content');

  if (typeof raw.type !== 'string' || !TYPES.has(raw.type)) {
    throw new GateError('unsupported-type');
  }
  if (
    typeof raw.project !== 'string'
    || !/^(?:_global|[a-z0-9]+(?:-[a-z0-9]+)*)$/.test(raw.project)
  ) {
    throw new GateError('invalid-project');
  }
  if (!Array.isArray(raw.concepts)) throw new GateError('concepts-must-be-array');
  const concepts = [];
  for (const item of raw.concepts) {
    if (
      typeof item !== 'string'
      || item.length < 1
      || item.length > 80
      || item !== item.trim()
      || item.includes(',')
      || /[\u0000-\u001f\u007f]/.test(item)
      || containsSecretLikeValue(item)
    ) {
      throw new GateError('invalid-concept');
    }
    if (!concepts.includes(item)) concepts.push(item);
  }

  const topicConcepts = concepts.filter((value) => !(
    value.startsWith('agent:')
    || value === 'derived-lesson'
    || value.startsWith('source:')
    || value.startsWith('lesson-sha256:')
  ));
  if (topicConcepts.length < 2) throw new GateError('insufficient-topic-concepts');

  const expectedAgent = SOURCE_AGENTS.get(source);
  const agentTags = concepts.filter((value) => value.startsWith('agent:'));
  if (agentTags.length > 1) throw new GateError('multiple-agent-tags');
  if (agentTags.length === 1 && agentTags[0] !== expectedAgent) {
    throw new GateError('source-agent-mismatch');
  }
  if (agentTags.length === 0) concepts.push(expectedAgent);
  if (!concepts.includes('derived-lesson')) concepts.push('derived-lesson');
  if (!concepts.includes(`source:${source}`)) concepts.push(`source:${source}`);
  concepts.sort();

  const args = { content, type: raw.type, project: raw.project, concepts };
  const normalized = JSON.stringify(args);
  const hash = createHash('sha256').update(normalized, 'utf8').digest('hex');
  args.concepts.push(`lesson-sha256:${hash}`);
  args.concepts.sort();
  return { args, hash };
}

async function pathExists(path) {
  try {
    await access(path);
    return true;
  } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}

async function collectJsonFiles(root) {
  const output = [];
  async function visit(path) {
    const entries = await readdir(path, { withFileTypes: true });
    entries.sort((left, right) => left.name.localeCompare(right.name));
    for (const entry of entries) {
      const child = join(path, entry.name);
      if (entry.isSymbolicLink()) throw new GateError('symlink-not-allowed');
      if (entry.isDirectory()) {
        await visit(child);
      } else if (entry.isFile() && entry.name.toLowerCase().endsWith('.json')) {
        output.push(child);
      }
    }
  }
  await visit(root);
  return output;
}

async function discover(options) {
  if (!(await pathExists(options.pendingRoot))) return { candidates: [], failures: 0 };
  const entries = await readdir(options.pendingRoot, { withFileTypes: true });
  entries.sort((left, right) => left.name.localeCompare(right.name));
  const candidates = [];
  let failures = 0;
  for (const entry of entries) {
    const source = entry.name;
    if (!entry.isDirectory() || entry.isSymbolicLink() || !SOURCE_AGENTS.has(source)) {
      console.error('[FAIL] rejected unknown or unsafe source');
      failures += 1;
      continue;
    }
    try {
      for (const path of await collectJsonFiles(join(options.pendingRoot, source))) {
        candidates.push({ source, path });
      }
    } catch (error) {
      console.error(`[FAIL] ${error instanceof GateError ? error.code : 'source-read-failed'}`);
      failures += 1;
    }
  }
  return { candidates, failures };
}

async function loadCandidate(candidate) {
  const info = await lstat(candidate.path);
  if (!info.isFile() || info.size > MAX_FILE_BYTES) throw new GateError('invalid-candidate-file');
  let parsed;
  try {
    parsed = JSON.parse(await readFile(candidate.path, 'utf8'));
  } catch {
    throw new GateError('invalid-json');
  }
  return validateCandidate(parsed, candidate.source);
}

function safeBaseName(path) {
  const value = basename(path).replace(/[^A-Za-z0-9._-]+/g, '_');
  return value || 'lesson.json';
}

async function uniqueDestination(root, source, hash, sourcePath, duplicate = false) {
  const folder = join(root, source, duplicate ? 'duplicates' : 'promoted');
  await mkdir(folder, { recursive: true });
  const base = `${hash.slice(0, 12)}_${safeBaseName(sourcePath)}`;
  let candidate = join(folder, base);
  let suffix = 1;
  while (await pathExists(candidate)) {
    candidate = join(folder, `${hash.slice(0, 12)}_${suffix}_${safeBaseName(sourcePath)}`);
    suffix += 1;
  }
  return candidate;
}

async function moveCandidate(options, candidate, hash, duplicate = false) {
  const destination = await uniqueDestination(
    options.ingestedRoot,
    candidate.source,
    hash,
    candidate.path,
    duplicate,
  );
  await rename(candidate.path, destination);
  return relative(options.ingestedRoot, destination);
}

function resultFailed(result) {
  if (!result || result.isError || !Array.isArray(result.content)) return true;
  const texts = result.content
    .filter((item) => item?.type === 'text' && typeof item.text === 'string' && item.text.trim())
    .map((item) => item.text.trim());
  if (texts.length === 0) return true;
  return texts.some((text) => {
    if (/^(?:error|failed|failure)\b/i.test(text)) return true;
    try {
      const parsed = JSON.parse(text);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return true;
      if (parsed.error || parsed.isError || parsed.success === false || parsed.ok === false) return true;
      const officialSuccess = parsed.success === true
        && parsed.memory
        && typeof parsed.memory === 'object'
        && !Array.isArray(parsed.memory)
        && typeof parsed.memory.id === 'string'
        && parsed.memory.id.trim().length > 0;
      return !officialSuccess;
    } catch {
      return true;
    }
  });
}

function receiptPaths(receiptDir, hash) {
  return {
    prepared: join(receiptDir, `${hash}.prepared.json`),
    saved: join(receiptDir, `${hash}.saved.json`),
    lock: join(receiptDir, `${hash}.lock`),
  };
}

async function ensureReceiptDirectory(root) {
  const path = join(root, RECEIPT_DIRECTORY);
  await mkdir(path, { recursive: true });
  const info = await lstat(path);
  if (!info.isDirectory() || info.isSymbolicLink()) throw new GateError('unsafe-receipt-directory');
  return path;
}

async function readJsonFileIfPresent(path, errorCode, maxBytes = 64 * 1024) {
  let info;
  try {
    info = await lstat(path);
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
  if (!info.isFile() || info.isSymbolicLink() || info.size < 2 || info.size > maxBytes) {
    throw new GateError(errorCode);
  }
  try {
    return JSON.parse(await readFile(path, 'utf8'));
  } catch {
    throw new GateError(errorCode);
  }
}

function validateReceipt(receipt, state, expected = {}) {
  if (
    !receipt
    || receipt.schemaVersion !== RECEIPT_SCHEMA_VERSION
    || receipt.state !== state
    || !/^[a-f0-9]{64}$/.test(receipt.sha256 || '')
    || !SOURCE_AGENTS.has(receipt.source)
    || typeof receipt.project !== 'string'
    || typeof receipt.type !== 'string'
  ) {
    throw new GateError('invalid-promotion-receipt');
  }
  for (const [key, value] of Object.entries(expected)) {
    if (receipt[key] !== value) throw new GateError('promotion-receipt-mismatch');
  }
  return receipt;
}

async function readReceipt(path, state, expected = {}) {
  const receipt = await readJsonFileIfPresent(path, 'invalid-promotion-receipt');
  return receipt ? validateReceipt(receipt, state, expected) : null;
}

async function writeJsonExclusive(path, value) {
  const handle = await open(path, 'wx');
  try {
    await handle.writeFile(`${JSON.stringify(value, null, 2)}\n`, 'utf8');
    await handle.sync();
  } finally {
    await handle.close();
  }
}

function processIsAlive(pid) {
  if (!Number.isSafeInteger(pid) || pid < 1) return true;
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error.code !== 'ESRCH';
  }
}

async function promotionMutexEndpoint(lockPath) {
  const physicalPath = join(await realpath(dirname(lockPath)), basename(lockPath));
  const normalized = process.platform === 'win32'
    ? physicalPath.toLowerCase()
    : physicalPath;
  const identity = createHash('sha256').update(normalized, 'utf8').digest('hex').slice(0, 32);
  if (process.platform === 'win32') {
    return `\\\\.\\pipe\\devtools-agentmemory-promotion-${identity}`;
  }
  if (process.platform === 'linux') {
    return `\0devtools-agentmemory-promotion-${identity}`;
  }
  throw new GateError('promotion-mutex-unsupported');
}

async function acquirePromotionMutex(lockPath) {
  let endpoint;
  try {
    endpoint = await promotionMutexEndpoint(lockPath);
  } catch (error) {
    if (error instanceof GateError) throw error;
    throw new GateError('promotion-mutex-unavailable');
  }
  const server = createServer((socket) => socket.destroy());
  try {
    await new Promise((resolveListen, rejectListen) => {
      const onError = (error) => rejectListen(error);
      server.once('error', onError);
      server.listen(endpoint, () => {
        server.off('error', onError);
        resolveListen();
      });
    });
  } catch (error) {
    if (server.listening) server.close();
    if (error.code === 'EADDRINUSE') throw new GateError('promotion-lock-busy');
    throw new GateError('promotion-mutex-unavailable');
  }
  server.on('error', () => {});
  return server;
}

async function releasePromotionMutex(server) {
  if (!server?.listening) return;
  await new Promise((resolveClose) => server.close(() => resolveClose()));
}

async function publishPromotionLock(path, owner) {
  const staged = `${path}.new-${owner.nonce}-${randomUUID()}`;
  try {
    await writeJsonExclusive(staged, owner);
    await link(staged, path);
  } finally {
    await unlink(staged).catch(() => {});
  }
}

async function acquirePromotionLock(path) {
  const mutex = await acquirePromotionMutex(path);
  try {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const nonce = randomUUID();
      try {
        await publishPromotionLock(path, {
          schemaVersion: 1,
          pid: process.pid,
          nonce,
          createdAt: new Date().toISOString(),
        });
        return { path, nonce, mutex };
      } catch (error) {
        if (error.code !== 'EEXIST') throw error;
        const owner = validatePromotionLockOwner(
          await readJsonFileIfPresent(path, 'invalid-promotion-lock', 4096),
        );
        if (processIsAlive(owner.pid)) {
          throw new GateError('promotion-lock-busy');
        }
        await unlink(path);
      }
    }
    throw new GateError('promotion-lock-busy');
  } catch (error) {
    await releasePromotionMutex(mutex);
    throw error;
  }
}

async function releasePromotionLock(lock) {
  if (!lock) return;
  try {
    try {
      const owner = await readJsonFileIfPresent(lock.path, 'invalid-promotion-lock', 4096);
      if (owner?.nonce === lock.nonce) await unlink(lock.path);
    } catch {}
  } finally {
    await releasePromotionMutex(lock.mutex);
  }
}

function validatePromotionLockOwner(owner) {
  const createdAt = Date.parse(owner?.createdAt || '');
  if (
    !owner
    || owner.schemaVersion !== 1
    || !Number.isSafeInteger(owner.pid)
    || owner.pid < 1
    || typeof owner.nonce !== 'string'
    || !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(owner.nonce)
    || !Number.isFinite(createdAt)
  ) {
    throw new GateError('invalid-promotion-lock');
  }
  return { ...owner, createdAtMs: createdAt };
}

async function restoreQuarantinedPromotionLock(quarantine, original) {
  let body;
  try {
    body = await readFile(quarantine);
  } catch (error) {
    if (error.code === 'ENOENT') return;
    throw error;
  }
  let handle;
  try {
    handle = await open(original, 'wx');
    await handle.writeFile(body);
    await handle.sync();
    await handle.close();
    handle = null;
    await unlink(quarantine);
  } catch (error) {
    await handle?.close().catch(() => {});
    if (error.code !== 'EEXIST') throw error;
  }
}

async function breakStalePromotionLock(options) {
  if (!options.staleLockBreak) return;
  const receiptDir = await ensureReceiptDirectory(options.ingestedRoot);
  const paths = receiptPaths(receiptDir, options.staleLockBreak.hash);
  const expected = { sha256: options.staleLockBreak.hash };
  const prepared = await readReceipt(paths.prepared, 'prepared', expected);
  const saved = await readReceipt(paths.saved, 'saved', expected);
  if (!prepared && !saved) throw new GateError('stale-lock-receipt-not-found');
  const mutex = await acquirePromotionMutex(paths.lock);
  try {
    const first = validatePromotionLockOwner(
      await readJsonFileIfPresent(paths.lock, 'invalid-promotion-lock', 4096),
    );
    if (first.nonce !== options.staleLockBreak.nonce) throw new GateError('stale-lock-nonce-mismatch');
    if (Date.now() - first.createdAtMs < MIN_EXPLICIT_LOCK_BREAK_AGE_MS) {
      throw new GateError('promotion-lock-not-stale');
    }

    const quarantine = `${paths.lock}.break-${options.staleLockBreak.nonce}-${randomUUID()}`;
    try {
      await rename(paths.lock, quarantine);
    } catch (error) {
      if (error.code === 'ENOENT') throw new GateError('promotion-lock-changed');
      throw error;
    }
    try {
      const current = validatePromotionLockOwner(
        await readJsonFileIfPresent(quarantine, 'invalid-promotion-lock', 4096),
      );
      if (
        current.nonce !== first.nonce
        || current.nonce !== options.staleLockBreak.nonce
        || current.pid !== first.pid
        || current.createdAt !== first.createdAt
      ) {
        throw new GateError('promotion-lock-changed');
      }
      await unlink(quarantine);
    } catch (error) {
      await restoreQuarantinedPromotionLock(quarantine, paths.lock);
      throw error;
    }
    console.log(`[UNLOCKED] ${options.staleLockBreak.hash.slice(0, 12)} stale promotion lock`);
  } finally {
    await releasePromotionMutex(mutex);
  }
}

function receiptMetadata(candidate, normalized) {
  return {
    schemaVersion: RECEIPT_SCHEMA_VERSION,
    sha256: normalized.hash,
    source: candidate.source,
    project: normalized.args.project,
    type: normalized.args.type,
  };
}

async function moveKnownSavedCandidate(options, paths, candidate, normalized) {
  const expected = receiptMetadata(candidate, normalized);
  const saved = await readReceipt(paths.saved, 'saved', expected);
  if (!saved) return false;
  const prepared = await readReceipt(paths.prepared, 'prepared', expected);
  await moveCandidate(options, candidate, normalized.hash, true);
  if (prepared) await unlink(paths.prepared);
  console.log(`[SKIP] ${candidate.source}/${normalized.hash.slice(0, 12)} duplicate`);
  return true;
}

async function promote(options, client, candidate, normalized) {
  const receiptDir = await ensureReceiptDirectory(options.ingestedRoot);
  const paths = receiptPaths(receiptDir, normalized.hash);
  const expected = receiptMetadata(candidate, normalized);

  const lock = await acquirePromotionLock(paths.lock);
  try {
    if (await moveKnownSavedCandidate(options, paths, candidate, normalized)) return;
    if (await readReceipt(paths.prepared, 'prepared', expected)) {
      throw new GateError('promotion-state-uncertain');
    }

    await writeJsonExclusive(paths.prepared, {
      ...expected,
      state: 'prepared',
      preparedAt: new Date().toISOString(),
    });
    const result = await client.handleToolCall('memory_save', normalized.args);
    if (resultFailed(result)) throw new GateError('memory-save-failed');
    await writeJsonExclusive(paths.saved, {
      ...expected,
      state: 'saved',
      promotedAt: new Date().toISOString(),
    });
    await moveCandidate(options, candidate, normalized.hash, false);
    await unlink(paths.prepared);
    console.log(`[OK] ${candidate.source}/${normalized.hash.slice(0, 12)} promoted`);
  } finally {
    await releasePromotionLock(lock);
  }
}

async function resolvePreparedReceipt(options) {
  if (!options.resolution) return;
  const receiptDir = await ensureReceiptDirectory(options.ingestedRoot);
  const paths = receiptPaths(receiptDir, options.resolution.hash);
  const lock = await acquirePromotionLock(paths.lock);
  try {
    const prepared = await readReceipt(paths.prepared, 'prepared', { sha256: options.resolution.hash });
    if (!prepared) throw new GateError('prepared-receipt-not-found');
    const saved = await readReceipt(paths.saved, 'saved', { sha256: options.resolution.hash });
    if (saved) {
      validateReceipt(saved, 'saved', {
        sha256: prepared.sha256,
        source: prepared.source,
        project: prepared.project,
        type: prepared.type,
      });
    }
    if (options.resolution.action === 'retry') {
      if (saved) throw new GateError('saved-receipt-cannot-retry');
      await unlink(paths.prepared);
    } else if (!saved) {
      await writeJsonExclusive(paths.saved, {
        schemaVersion: RECEIPT_SCHEMA_VERSION,
        state: 'saved',
        sha256: prepared.sha256,
        source: prepared.source,
        project: prepared.project,
        type: prepared.type,
        promotedAt: new Date().toISOString(),
        resolvedFromPrepared: true,
      });
      await unlink(paths.prepared);
    } else {
      await unlink(paths.prepared);
    }
    console.log(`[RESOLVED] ${options.resolution.hash.slice(0, 12)}=${options.resolution.action}`);
  } finally {
    await releasePromotionLock(lock);
  }
}

async function readLimitedResponse(response) {
  if (!response.body) return '';
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > MAX_MCP_RESPONSE_BYTES) {
      await reader.cancel().catch(() => {});
      throw new GateError('mcp-response-too-large');
    }
    chunks.push(Buffer.from(value));
  }
  return Buffer.concat(chunks, total).toString('utf8');
}

function createOfficialMcpClient(options) {
  return {
    async handleToolCall(name, args) {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), options.timeoutMs);
      timer.unref?.();
      try {
        const endpoint = new URL('/agentmemory/mcp/call', options.agentmemoryUrl);
        const headers = { 'content-type': 'application/json' };
        const secret = process.env.AGENTMEMORY_SECRET;
        if (secret) {
          if (/\r|\n/.test(secret)) throw new GateError('invalid-agentmemory-secret');
          headers.authorization = `Bearer ${secret}`;
        }
        const response = await fetch(endpoint, {
          method: 'POST',
          headers,
          body: JSON.stringify({
            name,
            arguments: {
              ...args,
              concepts: Array.isArray(args.concepts) ? args.concepts.join(',') : args.concepts,
            },
          }),
          signal: controller.signal,
        });
        const text = await readLimitedResponse(response);
        if (!response.ok) throw new GateError('authoritative-memory-rejected');
        let result;
        try {
          result = JSON.parse(text);
        } catch {
          throw new GateError('invalid-mcp-response');
        }
        if (!result || typeof result !== 'object' || result.error) {
          throw new GateError('invalid-mcp-response');
        }
        return result;
      } catch (error) {
        if (error instanceof GateError) throw error;
        throw new GateError(error?.name === 'AbortError' ? 'authoritative-memory-timeout' : 'authoritative-memory-unreachable');
      } finally {
        clearTimeout(timer);
      }
    },
  };
}

async function loadPromotionClient(options) {
  if (!options.client) return createOfficialMcpClient(options);
  let client;
  try {
    client = await import(pathToFileURL(options.client).href);
  } catch {
    throw new GateError('client-load-failed');
  }
  if (
    client.promotionClientContract !== CLIENT_CONTRACT_VERSION
    || typeof client.handleToolCall !== 'function'
  ) {
    throw new GateError('client-contract-mismatch');
  }
  return client;
}

async function main() {
  let options;
  try {
    options = parseArgs(process.argv.slice(2));
  } catch (error) {
    console.error(`[ingest-lessons] configuration failed: ${error instanceof GateError ? error.code : 'unknown'}`);
    return 1;
  }
  if (options.help) {
    console.log('Usage: node scripts/ingest-lessons.mjs [--dry-run] [--pending-root PATH] [--ingested-root PATH] [--agentmemory-url URL] [--timeout-ms N] [--client CONTRACT_MODULE] [--resolve-prepared SHA256=saved|retry] [--break-stale-lock SHA256=NONCE]');
    return 0;
  }

  process.env.AGENTMEMORY_URL = options.agentmemoryUrl;
  try {
    await breakStalePromotionLock(options);
    await resolvePreparedReceipt(options);
  } catch (error) {
    console.error(`[ingest-lessons] resolution failed: ${error instanceof GateError ? error.code : 'resolution-failed'}`);
    return 1;
  }
  const discovered = await discover(options);
  let failures = discovered.failures;
  const valid = [];
  for (const candidate of discovered.candidates) {
    try {
      const normalized = await loadCandidate(candidate);
      valid.push({ candidate, normalized });
      if (options.dryRun) {
        console.log(`[DRY] ${candidate.source}/${normalized.hash.slice(0, 12)} valid project=${normalized.args.project} type=${normalized.args.type}`);
      }
    } catch (error) {
      console.error(`[FAIL] ${candidate.source}: ${error instanceof GateError ? error.code : 'validation-failed'}`);
      failures += 1;
    }
  }

  if (discovered.candidates.length === 0 && failures === 0) {
    console.log('[ingest-lessons] no pending lessons');
    return 0;
  }
  if (options.dryRun || valid.length === 0) {
    console.log(`[ingest-lessons] done ok=${valid.length} fail=${failures} dryrun=${options.dryRun}`);
    return failures > 0 ? 1 : 0;
  }

  let client;
  try {
    client = await loadPromotionClient(options);
  } catch (error) {
    console.error(`[ingest-lessons] client unavailable: ${error instanceof GateError ? error.code : 'client-load-failed'}`);
    return 1;
  }

  let promoted = 0;
  for (const item of valid) {
    try {
      await promote(options, client, item.candidate, item.normalized);
      promoted += 1;
    } catch (error) {
      console.error(`[FAIL] ${item.candidate.source}: ${error instanceof GateError ? error.code : 'promotion-failed'}`);
      failures += 1;
    }
  }
  console.log(`[ingest-lessons] done ok=${promoted} fail=${failures} dryrun=false`);
  return failures > 0 ? 1 : 0;
}

process.exitCode = await main();
