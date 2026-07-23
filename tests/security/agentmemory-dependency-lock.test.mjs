import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { isIP } from 'node:net';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';

const repositoryRoot = dirname(dirname(dirname(fileURLToPath(import.meta.url))));
const dependencyRoot = join(repositoryRoot, 'dependencies', 'agentmemory-runtime');
const manifest = JSON.parse(readFileSync(join(dependencyRoot, 'package.json'), 'utf8'));
const lock = JSON.parse(readFileSync(join(dependencyRoot, 'package-lock.json'), 'utf8'));

const expectedDependencies = {
  '@agentmemory/agentmemory': '0.9.27',
  '@agentmemory/mcp': '0.9.27',
};

const expectedLifecyclePackages = [
  'node_modules/onnx-proto/node_modules/protobufjs',
  'node_modules/onnxruntime-node',
  'node_modules/protobufjs',
  'node_modules/sharp',
];

function walkStrings(value, jsonPath = '$', output = []) {
  if (typeof value === 'string') {
    output.push({ jsonPath, value });
    return output;
  }

  if (Array.isArray(value)) {
    value.forEach((entry, index) => walkStrings(entry, `${jsonPath}[${index}]`, output));
    return output;
  }

  if (value && typeof value === 'object') {
    for (const [key, entry] of Object.entries(value)) {
      walkStrings(entry, `${jsonPath}.${key}`, output);
    }
  }

  return output;
}

function isPrivateIpv4(hostname) {
  const octets = hostname.split('.').map(Number);
  if (octets.length !== 4 || octets.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) {
    return false;
  }

  const [first, second] = octets;
  return first === 0
    || first === 10
    || first === 127
    || (first === 100 && second >= 64 && second <= 127)
    || (first === 169 && second === 254)
    || (first === 172 && second >= 16 && second <= 31)
    || (first === 192 && second === 168)
    || (first === 198 && (second === 18 || second === 19))
    || first >= 224;
}

function isPrivateHostname(rawHostname) {
  const hostname = rawHostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (hostname === 'localhost'
    || hostname.endsWith('.localhost')
    || hostname.endsWith('.local')
    || hostname.endsWith('.internal')
    || hostname.endsWith('.lan')
    || hostname.endsWith('.corp')) {
    return true;
  }

  const ipVersion = isIP(hostname);
  if (ipVersion === 4) {
    return isPrivateIpv4(hostname);
  }
  if (ipVersion === 6) {
    return hostname === '::'
      || hostname === '::1'
      || hostname.startsWith('fc')
      || hostname.startsWith('fd')
      || /^fe[89ab]/.test(hostname);
  }

  return false;
}

test('AgentMemory manifest pins the intended Node, npm, and top-level packages', () => {
  assert.equal(manifest.private, true);
  assert.equal(manifest.engines?.node, '22.21.1');
  assert.equal(manifest.packageManager, 'npm@10.9.4');
  assert.deepEqual(manifest.dependencies, expectedDependencies);
  assert.equal(Object.hasOwn(manifest, 'scripts'), false, 'the lock manifest must not define lifecycle scripts');
  assert.equal(Object.hasOwn(manifest, 'devDependencies'), false);
  assert.equal(Object.hasOwn(manifest, 'optionalDependencies'), false);
});

test('lockfile v3 freezes the complete integrity-addressed dependency closure', () => {
  assert.equal(lock.lockfileVersion, 3);
  assert.equal(lock.name, manifest.name);
  assert.equal(lock.version, manifest.version);

  const root = lock.packages?.[''];
  assert.ok(root, 'lockfile root package is missing');
  assert.deepEqual(root.dependencies, expectedDependencies);
  assert.deepEqual(root.engines, manifest.engines);

  const dependencyEntries = Object.entries(lock.packages).filter(([packagePath]) => packagePath !== '');
  assert.equal(dependencyEntries.length, 266, 'dependency closure changed; review and regenerate deliberately');

  for (const [packagePath, metadata] of dependencyEntries) {
    assert.match(packagePath, /^node_modules\//, `${packagePath} is outside node_modules`);
    assert.match(metadata.version ?? '', /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/, `${packagePath} has no exact version`);
    assert.match(metadata.resolved ?? '', /^https:\/\/registry\.npmjs\.org\//, `${packagePath} embeds an unexpected registry URL`);
    assert.equal(metadata.link, undefined, `${packagePath} is a local/link dependency`);
    assert.match(metadata.integrity ?? '', /^sha512-[A-Za-z0-9+/]+={0,2}$/, `${packagePath} lacks SHA-512 integrity`);
    assert.equal(Buffer.from(metadata.integrity.slice('sha512-'.length), 'base64').length, 64, `${packagePath} has malformed SHA-512 integrity`);
    assert.equal(typeof metadata.license, 'string', `${packagePath} has no recorded license metadata`);
    assert.notEqual(metadata.license.trim(), '', `${packagePath} has empty license metadata`);
  }
});

test('lock metadata contains no local, git, private-network, or credential URL', () => {
  const strings = walkStrings(lock);
  const forbiddenScheme = /(?:^|[\s"'(])(?:file|link|workspace|git|git\+https?|git\+ssh|ssh):/i;
  const urlPattern = /https?:\/\/[^\s"'<>]+/gi;

  for (const { jsonPath, value } of strings) {
    assert.equal(forbiddenScheme.test(value), false, `${jsonPath} contains a local or git dependency URL`);
    for (const match of value.matchAll(urlPattern)) {
      const candidate = match[0].replace(/[),.;\]]+$/g, '');
      const parsed = new URL(candidate);
      assert.equal(parsed.username, '', `${jsonPath} URL contains a username`);
      assert.equal(parsed.password, '', `${jsonPath} URL contains a password`);
      assert.equal(isPrivateHostname(parsed.hostname), false, `${jsonPath} URL targets a private host`);
      for (const key of parsed.searchParams.keys()) {
        assert.doesNotMatch(key, /(?:auth|credential|password|secret|token|api[_-]?key)/i, `${jsonPath} URL contains a credential query parameter`);
      }
    }
  }
});

test('lifecycle-bearing transitive packages remain explicit and stable', () => {
  const actual = Object.entries(lock.packages)
    .filter(([, metadata]) => metadata.hasInstallScript === true)
    .map(([packagePath]) => packagePath)
    .sort();

  assert.deepEqual(actual, expectedLifecyclePackages);
});
