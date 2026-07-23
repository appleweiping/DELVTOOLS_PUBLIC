import { spawn } from 'node:child_process';
import { statSync } from 'node:fs';
import { createConnection } from 'node:net';
import { isAbsolute, normalize } from 'node:path';
import { pathToFileURL } from 'node:url';

const FAILURE_EXIT_CODE = 1;
const FORCE_KILL_DELAY_MS = 2_000;
const FORCE_EXIT_DELAY_MS = 3_000;
const III_READY_TIMEOUT_MS = 30_000;
const III_READY_POLL_MS = 100;
const DIAGNOSTIC_SIGNALS = new Set([
  'SIGINT',
  'SIGTERM',
  'SIGHUP',
  'SIGBREAK',
  'SIGKILL',
]);

const III_ENVIRONMENT_ALLOWLIST = new Set([
  'appdata',
  'comspec',
  'homedrive',
  'homepath',
  'localappdata',
  'number_of_processors',
  'os',
  'path',
  'pathext',
  'processor_architecture',
  'processor_identifier',
  'processor_level',
  'processor_revision',
  'programdata',
  'programfiles',
  'programfiles(x86)',
  'programw6432',
  'systemdrive',
  'systemroot',
  'temp',
  'tmp',
  'userdomain',
  'username',
  'userprofile',
  'windir',
]);

export function createIiiEnvironment(environment) {
  return Object.fromEntries(
    Object.entries(environment).filter(([name]) =>
      III_ENVIRONMENT_ALLOWLIST.has(name.toLowerCase())),
  );
}

function parsePort(value, maximum) {
  if (!/^[1-9][0-9]{0,4}$/.test(value ?? '')) return null;
  const port = Number(value);
  return Number.isSafeInteger(port) && port <= maximum ? port : null;
}

export function parseSupervisorArguments(argv) {
  const expectedFlags = [
    '--iii-executable',
    '--iii-config',
    '--agentmemory-entry',
    '--guard-script',
    '--listen-port',
    '--upstream-port',
    '--stream-port',
    '--engine-port',
  ];
  if (argv.length !== expectedFlags.length * 2) return null;

  const values = {};
  for (let index = 0; index < expectedFlags.length; index += 1) {
    const offset = index * 2;
    if (argv[offset] !== expectedFlags[index] || !argv[offset + 1]) return null;
    values[expectedFlags[index]] = argv[offset + 1];
  }

  const iiiExecutable = normalize(values['--iii-executable']);
  const iiiConfig = normalize(values['--iii-config']);
  const agentmemoryEntry = normalize(values['--agentmemory-entry']);
  const guardScript = normalize(values['--guard-script']);
  const listenPort = parsePort(values['--listen-port'], 5_997);
  const upstreamPort = parsePort(values['--upstream-port'], 65_535);
  const streamPort = parsePort(values['--stream-port'], 65_535);
  const enginePort = parsePort(values['--engine-port'], 65_535);
  if (
    !isAbsolute(iiiExecutable) ||
    !isAbsolute(iiiConfig) ||
    !isAbsolute(agentmemoryEntry) ||
    !isAbsolute(guardScript) ||
    new Set([iiiExecutable, iiiConfig, agentmemoryEntry, guardScript]).size !== 4 ||
    listenPort === null ||
    upstreamPort === null ||
    streamPort === null ||
    enginePort === null ||
    new Set([listenPort, upstreamPort, streamPort, enginePort]).size !== 4
  ) {
    return null;
  }

  try {
    if (
      !statSync(iiiExecutable).isFile() ||
      !statSync(iiiConfig).isFile() ||
      !statSync(agentmemoryEntry).isFile() ||
      !statSync(guardScript).isFile()
    ) return null;
  } catch {
    return null;
  }

  return {
    iiiExecutable,
    iiiConfig,
    agentmemoryEntry,
    guardScript,
    listenPort,
    upstreamPort,
    streamPort,
    enginePort,
  };
}

function probeLoopbackPort(port) {
  return new Promise((resolve) => {
    const socket = createConnection({ host: '127.0.0.1', port });
    const finish = (ready) => {
      socket.destroy();
      resolve(ready);
    };
    socket.setTimeout(500);
    socket.once('connect', () => finish(true));
    socket.once('error', () => finish(false));
    socket.once('timeout', () => finish(false));
  });
}

export async function waitForIiiListeners(ports, timeoutMs = III_READY_TIMEOUT_MS) {
  const deadline = Date.now() + timeoutMs;
  do {
    const results = await Promise.all(ports.map((port) => probeLoopbackPort(port)));
    if (results.every(Boolean)) return true;
    if (Date.now() < deadline) {
      await new Promise((resolve) => setTimeout(resolve, III_READY_POLL_MS));
    }
  } while (Date.now() < deadline);
  return false;
}

export async function runSupervisor(options, runtime = {}) {
  const spawnProcess = runtime.spawnProcess ?? spawn;
  const nodeExecutable = runtime.nodeExecutable ?? process.execPath;
  const inheritedEnvironment = runtime.environment ?? process.env;
  const iiiEnvironment = runtime.iiiEnvironment ?? createIiiEnvironment(inheritedEnvironment);
  const waitForIiiReady = runtime.waitForIiiReady ?? waitForIiiListeners;
  const terminateProcess = runtime.terminateProcess ?? ((code) => process.exit(code));
  const setExitCode = runtime.setExitCode ?? ((code) => { process.exitCode = code; });
  const schedule = runtime.schedule ?? setTimeout;
  const signalSource = runtime.signalSource ?? process;
  const logEvent = runtime.logEvent ?? ((line) => process.stderr.write(`${line}\n`));
  const children = [];
  let shuttingDown = false;

  const exitCodeToken = (value) => {
    if (value === null || value === undefined) return 'none';
    return Number.isInteger(value) ? String(value) : 'unknown';
  };

  const signalToken = (value) => {
    if (value === null || value === undefined) return 'none';
    return DIAGNOSTIC_SIGNALS.has(value) ? value : 'unknown';
  };

  const logChildExit = (role, code, signal) => {
    try {
      logEvent(
        `[agentmemory-supervisor] child-exit role=${role}` +
        ` code=${exitCodeToken(code)} signal=${signalToken(signal)}`,
      );
    } catch {
      // Diagnostics must never weaken fail-closed child supervision.
    }
  };

  const logChildError = (role) => {
    try {
      logEvent(
        `[agentmemory-supervisor] child-error role=${role}` +
        ' code=unknown signal=none',
      );
    } catch {
      // Diagnostics must never weaken fail-closed child supervision.
    }
  };

  const allChildrenFinished = () =>
    children.length === 3 && children.every(({ finished }) => finished);

  const finishIfReady = () => {
    if (shuttingDown && allChildrenFinished()) terminateProcess(FAILURE_EXIT_CODE);
  };

  const stopChild = (record, signal = 'SIGTERM') => {
    if (record.finished || !record.child.pid) return;
    try {
      record.child.kill(signal);
    } catch {
      // Shutdown stays fail-closed even if a child disappears between checks.
    }
  };

  const beginShutdown = () => {
    if (shuttingDown) return;
    shuttingDown = true;
    setExitCode(FAILURE_EXIT_CODE);
    for (const record of children) stopChild(record);
    if (allChildrenFinished()) {
      terminateProcess(FAILURE_EXIT_CODE);
      return;
    }
    const forceKillTimer = schedule(() => {
      for (const record of children) stopChild(record, 'SIGKILL');
    }, FORCE_KILL_DELAY_MS);
    forceKillTimer.unref?.();
    const forceExitTimer = schedule(
      () => terminateProcess(FAILURE_EXIT_CODE),
      FORCE_EXIT_DELAY_MS,
    );
    forceExitTimer.unref?.();
  };

  const startChild = (
    role,
    arguments_,
    executable = nodeExecutable,
    environment = inheritedEnvironment,
  ) => {
    const child = spawnProcess(executable, arguments_, {
      detached: false,
      env: environment,
      shell: false,
      stdio: 'inherit',
      windowsHide: true,
    });
    const record = { child, finished: false, role };
    children.push(record);
    child.once('error', () => {
      logChildError(role);
      // A kill failure also emits `error`; only a spawn failure with no PID
      // proves that no process remains to terminate.
      if (!child.pid) record.finished = true;
      beginShutdown();
      finishIfReady();
    });
    child.once('exit', (code, signal) => {
      logChildExit(role, code, signal);
      record.finished = true;
      beginShutdown();
      finishIfReady();
    });
    return record;
  };

  const signals = ['SIGINT', 'SIGTERM', 'SIGHUP'];
  if ((runtime.platform ?? process.platform) === 'win32') signals.push('SIGBREAK');
  for (const signal of signals) signalSource.once(signal, beginShutdown);
  signalSource.once('uncaughtException', beginShutdown);
  signalSource.once('unhandledRejection', beginShutdown);

  try {
    startChild('iii', ['--config', options.iiiConfig], options.iiiExecutable, iiiEnvironment);
    const iiiReady = await waitForIiiReady([
      options.upstreamPort,
      options.streamPort,
      options.enginePort,
    ]);
    if (!iiiReady || shuttingDown) {
      beginShutdown();
      return { children, beginShutdown };
    }
    startChild('agentmemory', [options.agentmemoryEntry]);
    startChild('guard', [
      options.guardScript,
      '--listen-port',
      String(options.listenPort),
      '--upstream-port',
      String(options.upstreamPort),
    ]);
  } catch {
    beginShutdown();
  }

  return { children, beginShutdown };
}

function main() {
  const options = parseSupervisorArguments(process.argv.slice(2));
  if (!options) {
    process.exitCode = FAILURE_EXIT_CODE;
    return;
  }
  runSupervisor(options).catch(() => {
    process.exitCode = FAILURE_EXIT_CODE;
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) main();
