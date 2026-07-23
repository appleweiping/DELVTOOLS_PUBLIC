# Portable Runtime Services

The runtime scripts in this repository are public-safe templates. They discover
their installation from the script directory, accept explicit parameters, and
honor environment-variable overrides. No credential belongs in a script,
scheduled-task action, command line, or tracked log.

## Configuration

Explicit PowerShell parameters take precedence over environment variables. The
defaults are local-only and relative to the directory containing the scripts.

| Variable | Purpose | Safe default |
| --- | --- | --- |
| `DEVTOOLS_ROOT` | Runtime root containing these scripts | Script directory |
| `DEVTOOLS_LOG_DIR` | Local, ignored runtime logs | `<root>\logs` |
| `DEVTOOLS_POWERSHELL` | PowerShell executable used by child processes | `powershell.exe` |
| `AGENTMEMORY_URL` | Authenticated public Host-guard endpoint at port `R`; `R` must be `1..5997` | `http://127.0.0.1:3111` |
| `AGENTMEMORY_SECRET` | Mandatory URL-safe Bearer secret matching `^[A-Za-z0-9_-]{32,256}$`; supplied through the process environment, or recovered by the scheduled watchdog from its DPAPI `CurrentUser` blob | None; live operations fail closed |
| `AGENTMEMORY_PROMOTION_TIMEOUT_MS` | Authoritative derived-lesson save timeout | `60000` |
| `AGENTMEMORY_CONFIG` | Complete canonical engine configuration template | `<root>\agentmemory-iii.yaml` |
| `AGENTMEMORY_DATA_ROOT` | iii state/stream data directory (not every package-owned ancillary file) | `<root>\data` |
| `AGENTMEMORY_INSTALL_ROOT` | Dedicated package/runtime installation root | `<root>\npm-global\agentmemory-runtime` |
| `NODE_EXE` | Trusted absolute Node.js executable used by iii and MCP clients | `<root>\node\node.exe` |
| `AGENTMEMORY_III_EXE` | Pinned engine executable | `<install-root>\iii.exe` |
| `AGENTMEMORY_EMBEDDING_PROVIDER` | Embedding backend | `local` |
| `AGENTMEMORY_SELFHEAL_SCRIPT` | Self-heal entry point | `<root>\agentmemory-selfheal.ps1` |
| `AGENTMEMORY_SERVER_SCRIPT` | Server entry point | `<root>\agentmemory-server.ps1` |
| `AGENTMEMORY_WATCHDOG_SECONDS` | Foreground watchdog interval | `300` |
| `DEVTOOLS_AGENT_RESOURCES_ROOT` | Shared skills/resource root | `AGENT_RESOURCE` on the runtime drive |
| `DEVTOOLS_ARIS_SKILL_ROOT` | Optional ARIS skill directory | `.codex\skills` under the resource root |
| `DEVTOOLS_DIAGNOSTIC_DRIVE` | Drive inspected by `codex-health.ps1` | Runtime drive |

Supply `AGENTMEMORY_SECRET` to direct runtime invocations only through their
process environment using an operator-controlled secret facility. Scheduled
watchdog registration reads it only from the registration process and persists
only DPAPI `CurrentUser` ciphertext, never plaintext. Do not put plaintext in a
command line, tracked or generated config, scheduled-task XML/action/arguments,
or log. The optional
`devtools.local.cmd` file is loaded by launcher templates only; agentmemory
runtime scripts do not source it. Live server startup/adoption/inspection,
self-heal, daily health, diagnostics, watchdog registration/runner, and live
promotion fail closed unless their process receives a 32-256 character value of
ASCII letters, digits, `_`, or `-`; the scheduled runner obtains that value by
decrypting its validated blob. Offline `-ValidateOnly`, registration `-WhatIf`,
and promotion dry-runs do not contact the service or persist watchdog state.
Keep `data`, `logs`, generated engine configuration, auth state, and package
installations outside version control.

## agentmemory Lifecycle

`agentmemory-server.ps1` starts one local server instance. It pins the working
directory, enables the configured server tool surface, defaults embeddings to a
local backend, and rotates timestamped stdout/stderr logs. The trusted Node
executable, tracked Host guard and runtime supervisor, complete template,
dedicated package prefix, and pinned iii engine are all mandatory. There is no package-launcher, downloaded
CLI, package-internal configuration, or partially materialized configuration
fallback.

The tracked `agentmemory-iii.yaml` is a portable template. Before starting the
engine, the server replaces its exact `__AGENTMEMORY_DATA_ROOT_POSIX__`,
`__AGENTMEMORY_HTTP_PORT__`,
`__AGENTMEMORY_INTERNAL_REST_PORT__`, `__AGENTMEMORY_STREAM_PORT__`,
`__AGENTMEMORY_VIEWER_PORT__`, and `__AGENTMEMORY_ENGINE_PORT__` tokens. It
atomically writes a port-specific ignored file such as
`<root>\logs\agentmemory-iii.active.3111.yaml`; this is the config watched by iii
and repaired by self-heal. Port-specific names prevent one requested instance
from overwriting another instance's live config. Every accepted config must be a
full template with all exact tokens; token-free or partially tokenized configs
fail closed because their bind addresses and ports cannot be enforced safely.
External runtime path tokens and any iii external-process `exec` or `watch`
directive are forbidden. The controller also verifies the template's reviewed
SHA-256 before materialization, so an extra worker, listener, or syntax variant
cannot widen the engine surface. The quoted data root may contain ordinary spaces but
rejects `$`, quotes, invalid/control characters, Unicode line separators, and
noncharacters.
The tracked template is never rewritten at runtime.

`agentmemory-server.ps1` directly launches
`agentmemory-runtime-supervisor.mjs` with the pinned Node executable. The
supervisor first starts the pinned iii executable with only an allowlisted
system environment and waits for the fixed REST, stream, and worker-manager
listeners. It then starts the pinned AgentMemory entry point and Host guard as
two additional direct children with `shell: false`, inherited stdio, and the
server-controlled Node environment. iii therefore receives no
`AGENTMEMORY_SECRET`, provider key, or AgentMemory client setting. An internal
readiness failure, any child exit or spawn failure, or a supervisor termination
signal stops all remaining children and produces a nonzero supervisor exit.

The bundled engine is a plaintext local service, so every listener is bound to
the loopback network: the guard and iii listeners use `127.0.0.1`, while the
isolated compatibility viewer uses `127.0.0.2`. For public port `R`, the
accepted range is `1..5997` and the exact listener contract is:

| Port | Owner and purpose |
| --- | --- |
| `R` | Tracked Node Host guard; the only public AgentMemory REST route. |
| `127.0.0.2:6002` | Fixed internal AgentMemory compatibility viewer; not a supported browser UI. |
| `6000` | Internal iii REST upstream. |
| `6667` | Internal iii stream. |
| `10080` | Internal iii worker-manager/WebSocket endpoint. |
| `R + 1`, `R + 2`, `R + 46023` | Public/retired layouts; no listener is permitted. |

The fixed internal ports appear in the
[WHATWG Fetch bad-port table](https://fetch.spec.whatwg.org/#port-blocking), and
the [WebSockets opening handshake is integrated with Fetch](https://websockets.spec.whatwg.org/#opening-handshake).
That prevents ordinary browser Fetch/WebSocket APIs from reaching an internal
iii listener and bypassing the guard. It is defense in depth, not a substitute
for loopback binding or bearer authentication.

The guard accepts only standard HTTP methods and the fixed guard-health route or
`/agentmemory/*`. It requires exactly one Host equal to `localhost:R` or
`127.0.0.1:R`, allows Origin only when it is one of those two exact HTTP
loopback origins, and allows `Sec-Fetch-Site` only when absent or equal to
`same-origin`, `same-site`, or `none`. It rejects duplicate singleton headers,
upgrades, smuggling/hop-by-hop ambiguity, invalid routing, or a missing/invalid
Bearer token. These checks and constant-time secret comparison complete before
the guard reads the request body or opens an upstream connection. The guard
normalizes the authorized request to `Bearer $AGENTMEMORY_SECRET` before
streaming it to `127.0.0.1:6000` with bounded headers, timeouts, backpressure,
and abort propagation.

The fixed viewer's API proxy requires Bearer authorization and accepts only the
reserved `agentmemory-viewer.invalid:6002` Host authority. The pinned upstream
viewer shell may still serve unauthenticated `GET` or `OPTIONS` internally
before an API request is authenticated. The reserved `.invalid` authority
therefore makes the shell intentionally browser-inaccessible: this runtime
supports no interactive viewer, and users must never enter
`AGENTMEMORY_SECRET` into the upstream viewer UI. Its configured Origin is CORS
response metadata, not request authentication. Managed probes connect directly
to `127.0.0.2:6002`, set the reserved Host explicitly, and disable redirects,
proxies, and cookies. Missing and wrong credentials must return `401`. The exact
credential must pass authentication but then return `502`, because pinned
`0.9.27` uses Node Fetch for its proxy and Fetch blocks internal port `6000` as
a WHATWG bad port. A `200` viewer proxy response fails the isolation contract;
only the Host guard at `R` is a supported working REST surface.

If `R` is already listening, startup succeeds only when the authenticated guard
health and AgentMemory health responses have exact identities and versions, the
desired config bytes match the port-specific active file, and process ancestry
proves the exact iii, AgentMemory Node, and Host-guard children own every expected
listener. A drifted, externally bound, split-root, duplicated, unowned, legacy,
or incomplete listener set fails closed without rewriting its live file. Startup
also refuses any collision on the viewer, internal, or retired ports and holds a
per-user, per-port lock until the complete contract is ready.

Process ownership requires exactly one matching Node supervisor root with
exactly three direct children: one pinned iii process, one exact AgentMemory
entry process, and one exact Host guard. Their anchored command lines,
executables, ancestry, and listener PIDs must match the fixed contract. An extra
direct child, arbitrary descendant, split root, or matching child launched
outside the supervisor is rejected before any Bearer probe.

`AGENTMEMORY_DATA_ROOT` controls the iii state and stream stores represented in
this template. In agentmemory `0.9.27`, ancillary package state under
`%USERPROFILE%\.agentmemory` remains upstream-defined; keep it local and ignored.
The pinned `iii.exe`, agentmemory `0.9.27` package manifest, trusted Node
`22.21.1` executable, tracked guard, and complete canonical template are all
required. Install the tracked dependency closure with npm `10.9.4` into the
ignored `<root>\npm-global\agentmemory-runtime` prefix only:

```powershell
$install = 'D:\devtools\npm-global\agentmemory-runtime'
if (Test-Path -LiteralPath $install) { throw 'Audit the existing AgentMemory prefix before replacement' }
New-Item -ItemType Directory -Path $install | Out-Null
Copy-Item -LiteralPath `
  .\dependencies\agentmemory-runtime\package.json, `
  .\dependencies\agentmemory-runtime\package-lock.json `
  -Destination $install
& D:\devtools\node\npm.cmd ci --ignore-scripts --prefix $install --cache D:\devtools\npm-cache
```

Never run `npm ci` in the shared `<root>\npm-global` directory. The tracked
manifest and lockfile freeze the integrity-addressed closure; installed package
payloads remain ignored and are not redistributed. `--ignore-scripts` suppresses
all lifecycle hooks. Audit and provision any optional native/generated payload
separately rather than enabling scripts for the closure. Automatic CLI download,
package launcher fallback, and package-internal config fallback are forbidden.

`agentmemory-selfheal.ps1` is the recovery controller:

Each server-controller invocation directly starts the pinned PowerShell host
with `-NoNewWindow`, redirects stdout and stderr to separate port-specific
controller logs, and waits only on the exact returned process object. It never
uses a native PowerShell pipeline or `Start-Process -Wait`; a surviving runtime
supervisor therefore cannot keep self-heal waiting by retaining an inherited
pipeline handle.

1. Before any Bearer probe, detect a supervisor hard-kill orphan only when there
   is no exact supervisor; exactly one pinned iii child and at most one exact
   AgentMemory/guard child share one absent parent; no duplicate, peer, or
   descendant exists; every present listener has its exact owner and address;
   and every process identity includes the same PID and creation time. Stop that
   bounded full or startup-partial group without adopting it, then require all
   original identities, five managed listeners, and three retired listeners to
   disappear before starting a fresh supervisor. Any ambiguity or failed stop
   remains fail-closed.
2. Probe the application health endpoint up to three consecutive times with a
   25-second timeout, avoiding restarts caused by one slow response.
3. Start the service when its local port is not listening.
4. If the port is live but the application is unhealthy, update only the
   configured engine reload marker and poll for recovery for up to 60 seconds.
5. As a final fallback, restart only matching agentmemory processes and poll for
   up to 90 seconds; failed recovery is logged and signaled best-effort.

Run it manually or at logon through the companion command file:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agentmemory-selfheal.ps1
.\agentmemory-server.cmd
```

`agentmemory-health-daily.ps1` checks health, configuration flags, slots, and
the full MCP proxy tool surface. It calls self-heal once, rechecks, and writes a
local error log only when an initial failure occurred.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agentmemory-health-daily.ps1
```

Managed server startup/adoption, readiness, self-heal, daily health, and
workstation health paths establish the exact loopback listener set and expected
process ownership before any of their HTTP probes send the inherited secret as
a Bearer Authorization header. AgentMemory MCP `0.9.27` already forwards its
inherited `AGENTMEMORY_SECRET`, but that upstream client and the derived-lesson
ingestion HTTP client cannot independently prove OS-level listener ownership
before sending it. Run both only against the managed, already-verified local
service and keep `AGENTMEMORY_URL` pinned to its exact loopback endpoint. The
public MCP examples intentionally contain no secret literal.

For clients that should not inherit a long-lived plaintext secret, use
`agentmemory-mcp-dpapi.ps1` with the canonical absolute path of the ignored
watchdog settings file. It reuses the watchdog's strict settings and DPAPI
validation, locks execution to the dedicated `@agentmemory/mcp@0.9.27` package,
temporarily injects both the secret and exact loopback URL, and byte-pumps all
three redirected stdio streams without PowerShell text conversion. Every chunk
is written and flushed asynchronously, so interactive frames do not wait for
EOF or a large buffer. Client EOF
closes the raw child input stream, while an early child exit does not wait on an
open client input pipe. The launcher drains stdout/stderr with a fixed bound,
flushes the parent streams, preserves the child exit code, and restores the
process environment in `finally`. Its trust and configuration contract is documented in
[`mcp-dpapi-launcher.md`](mcp-dpapi-launcher.md).

## Watchdog Options

For a user-level scheduled watchdog, preview and then register the task. Task
registration is an explicit machine mutation and is never performed by tests or
by the health scripts.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agentmemory-watchdog-register.ps1 -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\agentmemory-watchdog-register.ps1
```

Registration accepts `AGENTMEMORY_SECRET` only from its current process. It
protects the value with Windows DPAPI `CurrentUser` and fixed versioned context,
then atomically writes the ciphertext-only blob under the ignored
`<DataRoot>\run` directory. The ignored, port/task-specific settings JSON has a
closed schema: it stores the blob's canonical absolute path and SHA-256 plus the
resolved non-secret root, data root, endpoint, config, install root, Node/iii
executables, embedding provider, log directory, controller scripts, and shell.
Neither settings, task XML/action/arguments, nor logs contain the plaintext
secret.

The deterministic scheduled task invokes only the short tracked CMD runner and
absolute settings path, repeats every five minutes without expiry, and is
enabled at least privilege under the registering user's exact SID with
`InteractiveToken`. The same current interactive user identity is required so
DPAPI `CurrentUser` can decrypt the blob. After registration, the script
re-queries and validates the complete task XML. A failed handoff restores the
previous task, settings, and ciphertext blob, or removes newly created state.

At execution, the runner validates the closed settings schema, canonical paths,
blob containment under `<DataRoot>\run`, version marker, and ciphertext SHA-256
before decrypting. It temporarily sets `AGENTMEMORY_SECRET` in its process only
so the self-heal child inherits it; `finally` restores the previous value or
clears it and releases the recovered secret reference. The scheduled task does
not depend on a user- or machine-level plaintext environment variable.

`agentmemory-watchdog-loop.ps1` is an
alternative foreground supervisor for hosts where scheduled tasks are not
appropriate; it forwards the same explicit lifecycle overrides, has a singleton
guard, and invokes self-heal every five minutes.

## Read-only Diagnostics

`health-check.ps1` validates the configured agentmemory URL, health/slots/tool
endpoints, pinned local engine, optional companion services, shared resources,
junctions, and launchers. It returns a nonzero exit code for required failures.
Use `-RequirePixelCat` only for a Claude-oriented readiness check.

`codex-health.ps1` reports memory, commit, disk/pagefile pressure, sampled CPU,
agent-family totals, and listening ports. Use `-DiagnosticDrive` or
`DEVTOOLS_DIAGNOSTIC_DRIVE` instead of editing the script.

`codex-agent-report.ps1` lists long-lived agent processes. Executable paths and
command lines are hidden by default. `-ShowPath` normalizes the user-profile
prefix; `-ShowCommandLine` applies redaction to credential-like arguments before
display.

All three diagnostic scripts are read-only.

## Derived lesson promotion

`scripts/ingest-lessons.mjs` is the explicit boundary between local derivation
layers and authoritative agentmemory. It accepts parameterized pending,
ingested, service, timeout, and audited client-adapter locations; validates and
de-duplicates candidates; and never prints lesson content during dry-run. Its
default MCP HTTP transport preserves project scope and fails closed without a
local-store fallback. Prepared/saved receipts prevent automatic duplicate writes
after an ambiguous failure. The PowerShell file beside it transparently forwards
stdout and the exact child exit code. See
`docs/agent-memory-protocol.md` for the schema and authority rules.

## Verification

The core tests use Pester-compatible syntax and import scripts without executing
their entry points:

```powershell
& D:\devtools\node\node.exe --test .\tests\agentmemory-host-guard.test.mjs
& D:\devtools\node\node.exe --test .\tests\agentmemory-runtime-supervisor.test.mjs
& D:\devtools\node\node.exe --test .\tests\security\agentmemory-dependency-lock.test.mjs
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '$r=Invoke-Pester .\tests\core\RuntimeScripts.Tests.ps1 -PassThru; if($r.FailedCount -gt 0){exit 1}'
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '$r=Invoke-Pester .\tests\core\WatchdogPersistence.Tests.ps1 -PassThru; if($r.FailedCount -gt 0){exit 1}'
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '$r=Invoke-Pester .\tests\core\McpDpapiLauncher.Tests.ps1 -PassThru; if($r.FailedCount -gt 0){exit 1}'
pwsh.exe -NoProfile -Command '$r=Invoke-Pester .\tests\core\McpDpapiLauncher.Tests.ps1 -PassThru; if($r.FailedCount -gt 0){exit 1}'
git diff --check
```

Before publishing, also run the repository safety gates documented in
`AGENTS.md`.
