import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { writeFileSync } from 'node:fs';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import test from 'node:test';

import {
  createIiiEnvironment,
  parseSupervisorArguments,
  runSupervisor,
} from '../agentmemory-runtime-supervisor.mjs';

const SCRIPT = new URL('../agentmemory-runtime-supervisor.mjs', import.meta.url);

async function withFixture(run) {
  const root = await mkdtemp(join(tmpdir(), 'agentmemory-supervisor-'));
  const fixture = {
    iii: join(root, 'iii.exe'),
    config: join(root, 'active config.yaml'),
    entry: join(root, 'agentmemory entry.mjs'),
    guard: join(root, 'host guard.mjs'),
  };
  for (const path of Object.values(fixture)) writeFileSync(path, 'fixture\n', 'utf8');
  try {
    await run(fixture);
  } finally {
    await rm(root, { force: true, recursive: true });
  }
}

function optionsFor({ iii, config, entry, guard }) {
  return {
    iiiExecutable: iii,
    iiiConfig: config,
    agentmemoryEntry: entry,
    guardScript: guard,
    listenPort: 4111,
    upstreamPort: 6000,
    streamPort: 6667,
    enginePort: 10080,
  };
}

class FakeChild extends EventEmitter {
  constructor(pid) {
    super();
    this.pid = pid;
    this.kills = [];
  }

  kill(signal) {
    this.kills.push(signal);
    return true;
  }
}

test('parser accepts only the closed absolute-path and port contract', async () => {
  await withFixture(async (fixture) => {
    const argv = [
      '--iii-executable', fixture.iii,
      '--iii-config', fixture.config,
      '--agentmemory-entry', fixture.entry,
      '--guard-script', fixture.guard,
      '--listen-port', '4111',
      '--upstream-port', '6000',
      '--stream-port', '6667',
      '--engine-port', '10080',
    ];
    assert.deepEqual(parseSupervisorArguments(argv), optionsFor(fixture));
    assert.equal(parseSupervisorArguments([...argv, '--extra', 'value']), null);
    assert.equal(parseSupervisorArguments(argv.with(9, '5998')), null);
    assert.equal(parseSupervisorArguments(argv.with(1, 'relative.exe')), null);
    assert.equal(parseSupervisorArguments(argv.with(3, fixture.iii)), null);
  });
});

test('iii receives a minimal non-secret environment while both Node children inherit it', async () => {
  await withFixture(async (fixture) => {
    const calls = [];
    const fakeChildren = [new FakeChild(101), new FakeChild(102), new FakeChild(103)];
    const environment = Object.freeze({
      SystemRoot: 'C:\\Windows',
      PATH: 'C:\\Windows\\System32',
      TEMP: 'C:\\Temp',
      AGENTMEMORY_SECRET: 'not-logged-test-value',
      AGENTMEMORY_URL: 'http://127.0.0.1:4111',
      AGENTMEMORY_TOOLS: 'all',
      PROVIDER_API_KEY: 'not-for-iii',
    });
    const signals = new EventEmitter();
    const exits = [];
    const exitCodes = [];
    const diagnostics = [];
    const timers = [];
    const spawnProcess = (file, args, options) => {
      calls.push({ file, args, options });
      return fakeChildren[calls.length - 1];
    };

    await runSupervisor(optionsFor(fixture), {
      environment,
      logEvent: (line) => diagnostics.push(line),
      nodeExecutable: 'C:\\PinnedNode\\node.exe',
      platform: 'win32',
      setExitCode: (code) => exitCodes.push(code),
      signalSource: signals,
      spawnProcess,
      schedule: (callback, delay) => {
        const timer = { callback, delay, unref() {} };
        timers.push(timer);
        return timer;
      },
      terminateProcess: (code) => exits.push(code),
      waitForIiiReady: async (ports) => {
        assert.deepEqual(ports, [6000, 6667, 10080]);
        return true;
      },
    });

    assert.equal(calls.length, 3);
    assert.equal(calls[0].file, fixture.iii);
    assert.deepEqual(calls[0].args, ['--config', fixture.config]);
    assert.deepEqual(calls[0].options.env, {
      SystemRoot: 'C:\\Windows',
      PATH: 'C:\\Windows\\System32',
      TEMP: 'C:\\Temp',
    });
    assert.equal('AGENTMEMORY_SECRET' in calls[0].options.env, false);
    assert.deepEqual(calls[1].args, [fixture.entry]);
    assert.deepEqual(calls[2].args, [
      fixture.guard, '--listen-port', '4111', '--upstream-port', '6000',
    ]);
    for (const call of calls.slice(1)) {
      assert.equal(call.file, 'C:\\PinnedNode\\node.exe');
      assert.equal(call.options.env, environment);
    }
    for (const call of calls) {
      assert.equal(call.options.shell, false);
      assert.equal(call.options.stdio, 'inherit');
      assert.equal(call.options.detached, false);
      assert.equal(call.options.windowsHide, true);
    }
    assert.equal(signals.listenerCount('SIGBREAK'), 1);

    fakeChildren[1].emit('exit', 0, null);
    assert.deepEqual(diagnostics, [
      '[agentmemory-supervisor] child-exit role=agentmemory code=0 signal=none',
    ]);
    assert.deepEqual(exitCodes, [1]);
    assert.deepEqual(fakeChildren[0].kills, ['SIGTERM']);
    assert.deepEqual(fakeChildren[2].kills, ['SIGTERM']);
    fakeChildren[0].emit('exit', null, 'SIGTERM');
    fakeChildren[2].emit('exit', null, 'SIGTERM');
    assert.deepEqual(diagnostics, [
      '[agentmemory-supervisor] child-exit role=agentmemory code=0 signal=none',
      '[agentmemory-supervisor] child-exit role=iii code=none signal=SIGTERM',
      '[agentmemory-supervisor] child-exit role=guard code=none signal=SIGTERM',
    ]);
    assert.deepEqual(exits, [1]);
    assert.deepEqual(timers.map(({ delay }) => delay), [2000, 3000]);
  });
});

test('kill errors do not mark a live child finished or exempt it from force kill', async () => {
  await withFixture(async (fixture) => {
    const children = [new FakeChild(201), new FakeChild(202), new FakeChild(203)];
    const timers = [];
    const exits = [];
    let spawnCount = 0;
    await runSupervisor(optionsFor(fixture), {
      logEvent() {},
      setExitCode() {},
      signalSource: new EventEmitter(),
      spawnProcess: () => children[spawnCount++],
      schedule: (callback, delay) => {
        const timer = { callback, delay, unref() {} };
        timers.push(timer);
        return timer;
      },
      terminateProcess: (code) => exits.push(code),
      waitForIiiReady: async () => true,
    });
    children[1].emit('exit', 1, null);
    children[2].emit('error', new Error('synthetic kill failure'));
    children[0].emit('exit', null, 'SIGTERM');
    assert.deepEqual(exits, []);
    timers.find(({ delay }) => delay === 2000).callback();
    assert.deepEqual(children[2].kills, ['SIGTERM', 'SIGKILL']);
    children[2].emit('exit', null, 'SIGKILL');
    assert.deepEqual(exits, [1]);
  });
});

test('child diagnostics disclose only a fixed role and sanitized status tokens', async () => {
  await withFixture(async (fixture) => {
    const secret = 'DoNotPrintThisChildErrorSecret_123456789';
    const children = [new FakeChild(251), new FakeChild(252), new FakeChild(253)];
    const diagnostics = [];
    let spawnCount = 0;
    await runSupervisor(optionsFor(fixture), {
      logEvent: (line) => diagnostics.push(line),
      setExitCode() {},
      signalSource: new EventEmitter(),
      spawnProcess: () => children[spawnCount++],
      schedule: () => ({ unref() {} }),
      terminateProcess() {},
      waitForIiiReady: async () => true,
    });
    const error = new Error(secret);
    error.code = secret;
    children[1].emit('error', error);
    children[1].emit('exit', 17, null);
    children[0].emit('exit', secret, secret);
    assert.deepEqual(diagnostics, [
      '[agentmemory-supervisor] child-error role=agentmemory code=unknown signal=none',
      '[agentmemory-supervisor] child-exit role=agentmemory code=17 signal=none',
      '[agentmemory-supervisor] child-exit role=iii code=unknown signal=unknown',
    ]);
    assert.equal(diagnostics.join('\n').includes(secret), false);
    assert.equal(diagnostics.join('\n').includes(fixture.entry), false);
  });
});

test('readiness failure stops iii and never starts either Node child', async () => {
  await withFixture(async (fixture) => {
    const iii = new FakeChild(301);
    const calls = [];
    const timers = [];
    await runSupervisor(optionsFor(fixture), {
      setExitCode() {},
      signalSource: new EventEmitter(),
      spawnProcess: (file, args, options) => {
        calls.push({ file, args, options });
        return iii;
      },
      schedule: (callback, delay) => {
        const timer = { callback, delay, unref() {} };
        timers.push(timer);
        return timer;
      },
      terminateProcess() {},
      waitForIiiReady: async () => false,
    });
    assert.equal(calls.length, 1);
    assert.equal(calls[0].file, fixture.iii);
    assert.deepEqual(iii.kills, ['SIGTERM']);
    assert.deepEqual(timers.map(({ delay }) => delay), [2000, 3000]);
  });
});

test('iii exit before readiness completes prevents both Node children from starting', async () => {
  await withFixture(async (fixture) => {
    const iii = new FakeChild(401);
    const calls = [];
    let resolveReadiness;
    const readiness = new Promise((resolve) => { resolveReadiness = resolve; });
    const run = runSupervisor(optionsFor(fixture), {
      setExitCode() {},
      signalSource: new EventEmitter(),
      spawnProcess: (file, args, options) => {
        calls.push({ file, args, options });
        return iii;
      },
      schedule: () => ({ unref() {} }),
      terminateProcess() {},
      waitForIiiReady: async () => readiness,
    });
    assert.equal(calls.length, 1);
    iii.emit('exit', 1, null);
    resolveReadiness(true);
    await run;
    assert.equal(calls.length, 1);
  });
});

test('Windows break signal terminates every direct child', async () => {
  await withFixture(async (fixture) => {
    const children = [new FakeChild(501), new FakeChild(502), new FakeChild(503)];
    const signals = new EventEmitter();
    let spawnCount = 0;
    await runSupervisor(optionsFor(fixture), {
      platform: 'win32',
      setExitCode() {},
      signalSource: signals,
      spawnProcess: () => children[spawnCount++],
      schedule: () => ({ unref() {} }),
      terminateProcess() {},
      waitForIiiReady: async () => true,
    });
    signals.emit('SIGBREAK');
    for (const child of children) assert.deepEqual(child.kills, ['SIGTERM']);
  });
});

test('minimal iii environment uses an allowlist rather than a credential denylist', () => {
  const result = createIiiEnvironment({
    SystemRoot: 'C:\\Windows',
    PATH: 'C:\\Windows\\System32',
    TEMP: 'C:\\Temp',
    AGENTMEMORY_SECRET: 'secret',
    UNKNOWN_TOKEN: 'token',
  });
  assert.deepEqual(result, {
    SystemRoot: 'C:\\Windows',
    PATH: 'C:\\Windows\\System32',
    TEMP: 'C:\\Temp',
  });
});

test('CLI rejects an incomplete contract without disclosing inherited secrets', () => {
  const secret = 'DoNotPrintThisSupervisorSecret_123456789';
  const result = spawnSync(process.execPath, [SCRIPT], {
    encoding: 'utf8',
    env: { ...process.env, AGENTMEMORY_SECRET: secret },
  });
  assert.equal(result.status, 1);
  assert.equal(`${result.stdout}${result.stderr}`.includes(secret), false);
});
