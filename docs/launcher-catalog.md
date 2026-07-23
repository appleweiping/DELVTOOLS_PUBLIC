# Launcher Catalog

The files in `launchers/` are public-safe Windows command templates. Each launcher derives its default `DEVTOOLS_ROOT` from the parent of its own directory, so the checkout can live on any drive or under any user profile. Set `DEVTOOLS_ROOT` before invocation to override that layout.

Every launcher optionally calls `%DEVTOOLS_ROOT%\devtools.local.cmd`, or the file selected by `DEVTOOLS_LOCAL_CMD` in the invoking environment. That local file is intentionally ignored and must hold only machine-specific paths or provider configuration. The templates do not supply API endpoints, credentials, account state, or authentication defaults.

## Supported launchers

| Launcher | Primary override | Default relative lookup | Notes |
| --- | --- | --- | --- |
| `codex.cmd` | `CODEX_EXE` | `bin\codex.exe`, then a desktop-app bundled executable, then `codex.exe` on `PATH` | Selects the most recently modified desktop bundle without pinning its generated directory name. |
| `codex-light.cmd` | `CODEX_EXE` | Delegates to `codex.cmd` | Disables optional heavy MCP integrations for one invocation. |
| `claude.cmd` | `CLAUDE_EXE` | `npm-global` package/shim, then `claude.exe` on `PATH` | Provider and login configuration pass through untouched. |
| `cc.cmd` | `CLAUDE_EXE` | Delegates to `claude.cmd` | Short alias for Claude Code. |
| `opencode.cmd` | `OPENCODE_EXE` | `npm-global\opencode.cmd`, `bin\opencode.exe`, then `opencode.exe` on `PATH` | Does not include an OpenCode installation. |
| `aris.cmd` | `ARIS_EXE` | `aris-code\aris.exe`, `bin\aris.exe`, then `aris.exe` on `PATH` | Enables UTF-8 process behavior without selecting a provider. |
| `gemini.cmd` | `GEMINI_EXE` | `npm-global\gemini.cmd`, `bin\gemini.exe`, then `gemini.exe` on `PATH` | Uses the CLI's own authentication flow and config home. |
| `claudeseek.cmd` | `CLAUDESEEK_EXE` | Runs `claudeseek\bin\claudeseek.js` with `NODE_EXE` | `CLAUDESEEK_ENTRY` can select a different checked-out entry point. |
| `hermes.cmd` | `HERMES_EXE` | `%HERMES_HOME%\.venv\Scripts\hermes.exe`, then `bin\hermes.exe` | Defaults `HERMES_HOME` below `DEVTOOLS_ROOT` to keep runtime state out of the user profile. |
| `pixelcat.cmd` | `PIXELCAT_EXE` | `pixelcat-app.exe` or `pixelcat\PixelCat.exe` | Starts the desktop process and preserves caller-provided WebView2 flags. |
| `uv.cmd` | `UV_EXE` | `bin\uv.exe`, `uv\uv.exe`, then `uv.exe` on `PATH` | General uv entry point. |
| `uvx.cmd` | `UVX_EXE` | `bin\uvx.exe`, `uv\uvx.exe`, then `uvx.exe` on `PATH` | Companion tool runner supplied with uv. |
| `bun.cmd` | `BUN_EXE` | `bin\bun.exe`, `bun\bun.exe`, `npm-global\bun.cmd`, then `bun.exe` on `PATH` | General Bun entry point. |
| `key-rotator.cmd` | `KEY_ROTATOR_SCRIPT` and absolute `NODE_EXE` | `key-rotator.mjs` plus a root-relative pinned Node runtime | Starts an authenticated loopback-only proxy. Node is never discovered from the current directory or `PATH`. |

## Installation contract

Independent projects and proprietary binaries are not vendored. In particular, ARIS, claudeseek, Hermes, PixelCat, and all upstream CLI packages must be installed or checked out separately under the documented relative locations, or selected with their override variables. Their caches, virtual environments, package trees, auth files, sessions, logs, and paid assets remain local-only.

The typical portable layout is:

```text
<devtools-root>\
  devtools.local.cmd        # ignored, optional
  bin\                      # optional standalone executables
  launchers\                # these tracked templates
  node\                     # optional Node runtime
  npm-global\               # optional npm prefix
  aris-code\                # optional independent checkout/install
  claudeseek\               # optional independent checkout
  hermes\                   # optional home and virtual environment
  pixelcat\                 # optional independent install
  uv\                       # optional independent install
```

For a different layout, set the relevant `*_EXE`, `*_ENTRY`, or home variable. Override values should identify a command or executable only; put command arguments after the launcher so quoting and exit-code forwarding remain predictable.

## Shell reachability and opt-in repair

The session initializers under `tools/` discover every `launchers\*.cmd` file at
runtime, so adding a launcher does not require editing a command list:

```powershell
# Current PowerShell session: functions take precedence over PATH collisions.
& .\tools\agent-shell-init.ps1

# Current interactive cmd.exe session: doskey macros take precedence over PATH.
tools\agent-shell-init.cmd
```

PowerShell uses a single-expansion bridge that preserves literal percent and
exclamation marks in checkout paths and arguments, along with spaced arguments,
output, and the child exit code. The CMD macros expand to
`"<absolute-launcher>" $*` without `call`, preventing a second parse of forwarded
arguments. Literal dollar signs in launcher paths are doubled in the DOSKEY
definition so `$T`, `$G`, `$L`, and `$B` cannot become DOSKEY control tokens; the
generated AutoRun wrapper also disables delayed expansion before using a path.
Neither initializer changes a profile, registry value, scheduled
task, or persistent `PATH`. PowerShell changes only its current process `PATH`
when explicitly given `-PrependPath`; `-WhatIf` previews that operation.

The verifier is read-only by default and returns a nonzero exit code when it
finds drift:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\agent-launcher-verify.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\agent-launcher-verify.ps1 -Apply -WhatIf
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\agent-launcher-verify.ps1 -Apply
```

`-Apply` adds a managed block to the selected PowerShell profile, writes a small
CMD AutoRun wrapper, places that wrapper before existing current-user AutoRun
content, and prepends `LauncherRoot` to current-user `PATH` without duplicating
it. Leading with the managed wrapper prevents an unrelated false `IF` command
from swallowing launcher initialization. Profiles are emitted with a UTF-8 BOM
so Windows PowerShell 5.1 reads non-ASCII paths and retained content correctly;
legacy BOM-free profiles fall back to the current culture's ANSI code page after
strict UTF-8 decoding. Generated CMD wrappers use the current culture's OEM code
page with strict encoding and no BOM, matching how `cmd.exe` reads batch files.
Unrelated profile and AutoRun content is retained, and repeated application is
idempotent. Registry values that are genuinely absent are treated as empty;
access and provider errors abort before `-Apply` writes anything.

Task Scheduler remains untouched unless both `-Apply` and `-RegisterTask` are
supplied; preview that combination with `-WhatIf` first. An existing task is
healthy only when it has exactly one `Exec` action and exactly one daily
`CalendarTrigger`, with no repetition or other action/trigger type. Its
executable, complete argument string, cadence, and start time must match the
requested configuration; it must also run as the current user SID with
`InteractiveToken`, remain enabled at both task and trigger level, use least
privilege when a run level is present, have a start boundary that is no more
than one daily interval ahead (including daylight-saving offset changes), and
have no expired end boundary.

The task action is deliberately short: it invokes the tracked
`agent-launcher-verify-run.cmd` with one ignored, non-secret, content-versioned
JSON settings file under `logs\`. Both action paths must be absolute and reject
CMD metacharacters; the complete action is rejected if it exceeds the
`schtasks.exe /TR` 262-character limit. The JSON schema is closed and the runner
will execute only the verifier at `RepoRoot\tools\agent-launcher-verify.ps1`
with the exact recorded paths. Registration writes the new settings atomically,
switches the task, re-queries and validates the exact task XML, and only then
removes older settings for that task. A failed handoff keeps the prior settings
available.

Profile, AutoRun wrapper, and task-settings writes stage in the destination
directory and replace atomically. If replacement fails after the original was
moved aside, repair restores the original bytes before reporting failure; if
that restoration itself fails, the backup is retained and its path is reported.

`RepoRoot`, `LauncherRoot`, `ProfilePath`, and `CmdAutorunPath` are explicit
parameters, and generated commands quote spaced paths. Session-only initializers
support literal `%NAME%` and `!NAME!` path text, but persistent `-Apply` rejects
percent and exclamation marks because `cmd.exe` and expandable registry strings
can reinterpret them before the wrapper runs. `-Apply` also fails before any
writes when a generated wrapper path is not representable in the active OEM code
page. By default,
`ProfilePath` is the current host's `CurrentUserAllHosts` profile. Run the
verifier once from Windows PowerShell 5.1 and once from PowerShell 7, or pass
each profile path directly, when both hosts should receive the wiring. All
tracked `.cmd` helpers remain CRLF with no BOM.

## Key rotator transport and retry policy

`key-rotator.mjs` accepts equal-length comma-separated `ROTATOR_KEYS` and
`ROTATOR_TARGETS`. `ROTATOR_PROXY_TOKEN` is separately required: use an
independent 32-256 character URL-safe random value that is not any upstream
key, and send it only in `X-Key-Rotator-Token` on every request, including
health checks. The proxy compares a fixed-length digest with a constant-time
primitive and never forwards this header upstream. A target cannot contain
credentials, a query, or a fragment. Remote targets must use HTTPS; HTTP is
limited to `localhost`, IPv4 `127/8`, or IPv6 `::1`. The listener remains fixed
to `127.0.0.1` even if a caller sets another host variable.

The inbound boundary also requires the exact listener authority in `Host`.
When browser context headers are present, `Origin` must be that exact local
origin and `Sec-Fetch-Site` must be exactly `same-origin`; duplicate or
cross-site values fail before a body is read or an upstream is contacted. This
blocks DNS-rebinding and browser-CSRF paths while command-line clients that omit
browser-only headers remain supported. Configure SDK clients with the proxy
token as an explicit default header rather than embedding it in the base URL.

The proxy buffers the request body up to 32 MiB to enforce a hard size bound
and forward the exact bytes once, but it does not buffer an accepted upstream response. Response
headers and body chunks are forwarded immediately, and reads pause when the
local client applies backpressure. Once response headers have been sent, a
stream error only terminates that response; it can affect selection for a later
request but never causes the active request to move to another slot.

`ROTATOR_UPSTREAM_TIMEOUT_MS` is a response-header timeout, not a whole-response
deadline. It defaults to 120 seconds and is cleared as soon as upstream headers
arrive. During the response body, `ROTATOR_STREAM_IDLE_TIMEOUT_MS` instead caps
the time waiting for the next upstream chunk; it defaults to 300 seconds and is
paused while waiting for a backpressured local client to drain. This split lets
SSE and other long-lived responses continue as long as they produce periodic
data without leaving an indefinitely silent upstream attached.

Retries are deliberately narrower than slot rotation alone would suggest:

- Only read-only `GET`, `HEAD`, and `OPTIONS` requests may move to the next slot
  after HTTP 401, 403, 429, 5xx, a response-header timeout, or a network failure.
- Every write method, including `POST`, `PUT`, `PATCH`, and `DELETE`, is sent to
  exactly one slot. This remains true when `Idempotency-Key` is present because
  different target origins or credentials need not share one idempotency domain.
- A failed, non-3xx write response is forwarded as received and selects the
  next slot only for a later client request. A write-side network or
  response-header timeout returns a local 502 without contacting a second slot.
- Every upstream 3xx is converted to a local 502 without a `Location` header.
  This prevents an automatic client redirect from bypassing the proxy and
  carrying its local proxy credential or request body to another origin.

Incoming headers use an allowlist. The proxy authenticates and removes
`X-Key-Rotator-Token`, replaces `Authorization` with the selected slot key, and
never forwards `Cookie`, `Api-Key`, `X-Api-Key`, proxy authorization,
access-token aliases, or arbitrary extension headers. It keeps
the request body plus `Accept`, `Content-Type`, `Content-Encoding`,
`Idempotency-Key`, the supported `OpenAI-*` organization/project/beta headers,
request/trace identifiers, `User-Agent`, and the known OpenAI SDK
`X-Stainless-*` metadata fields. Upstream compression is disabled so response
bytes can be relayed safely. Health responses, logs, and proxy-generated errors
expose slot numbers and reason classes only, never keys or target URLs.

## Safety and verification

- Copy `examples/devtools-config.example.cmd` to the ignored `devtools.local.cmd` file and populate only values needed on that machine. `examples/key-rotator-config.example.cmd` provides the optional service-specific companion.
- Keep the proxy token, all rotator keys, and target URLs in the invoking environment or the ignored service-specific local configuration file.
- Do not add provider URLs, tokens, OAuth material, browser profiles, generated config, or absolute personal paths to these templates.
- All launcher arguments are forwarded unchanged. Synchronous launchers return the child process exit code; desktop/background launchers return the process-start result.
- Run `powershell -NoProfile -ExecutionPolicy Bypass -File tests\launchers\Test-LauncherTemplates.ps1` after editing any launcher or local-config example.
- Run `powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester .\tests\shell\ShellReachability.Tests.ps1"` after editing shell reachability helpers.
- Run `node --test tests\key-rotator.test.mjs` after editing the rotator or its launcher contract.
