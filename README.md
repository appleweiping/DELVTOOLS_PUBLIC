<p align="center">
  <img src="banner.png" alt="devtools-public" width="100%">
</p>

<h1 align="center">devtools-public</h1>

<p align="center">
  <strong>Public-safe Windows agent workstation scripts for a D-drive-first, agentmemory-first setup.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-Windows_11-lightgrey" alt="Windows">
  <img src="https://img.shields.io/badge/memory-agentmemory-blue" alt="agentmemory">
  <img src="https://img.shields.io/badge/secrets-env_only-red" alt="Secrets via env">
  <img src="https://img.shields.io/badge/license-Apache--2.0-green" alt="Apache-2.0">
</p>

---

## What This Is

`devtools-public` is a clean export of reusable scripts and examples from a local `D:\devtools` agent workstation.

It documents a practical pattern:

- keep agent homes, runtimes, caches, and logs on `D:\devtools`
- use `agentmemory` as the active memory and coordination layer
- keep skills in `D:\agent-resources`
- keep secrets in environment variables or ignored local files
- track only stable scripts, examples, and documentation

This is not a full copy of a machine. It intentionally excludes private agent homes, SQLite DBs, logs, sessions, browser profiles, credentials, model caches, local binaries, and research experiment artifacts.

## Layout

| Path | Purpose |
| --- | --- |
| `agentmemory-server.ps1` / `.cmd` | Starts local agentmemory with all tools and slots enabled on demand. |
| `health-check.ps1` | Read-only infrastructure check for agentmemory, launchers, D-drive junctions, and skill paths. |
| `codex-health.ps1` | Read-only performance and process-family report. |
| `codex-agent-report.ps1` | Read-only long-lived agent/process triage with command-line redaction. |
| `launchers/` | Public-safe launcher templates for Codex, Claude Code, ARIS, and supporting services. |
| `examples/` | Local secret templates and MCP/config examples. |

## Runtime Model

| Component | Default | Role |
| --- | --- | --- |
| `agentmemory` | `http://localhost:3111` | Persistent memory, recall, signals, actions, and checkpoints. |
| agentmemory viewer | `http://localhost:3113` | Optional local visual memory viewer. |
| PixelCat | `127.0.0.1:8990` | Always-on local Claude-compatible proxy for CC-family tools while using Claude. |
| key rotator | `127.0.0.1:9100` | Optional local OpenAI-compatible key/proxy helper. |

Agent Hub is retired and is not part of the active architecture.

## Quick Start

1. Install `agentmemory` using its upstream instructions.
2. Put this repository at `D:\devtools-public` or copy the scripts you want into `D:\devtools`.
3. Copy `examples/devtools.local.example.cmd` to an ignored local file such as `D:\devtools\devtools.local.cmd`.
4. Set only the environment variables you actually use.
5. Start memory:

```powershell
powershell D:\devtools\agentmemory-server.ps1
```

6. Run a read-only check:

```powershell
powershell D:\devtools\health-check.ps1
```

Slots require `AGENTMEMORY_SLOTS=true` at service startup. If `memory_slot_list` returns HTTP 500 while the rest of agentmemory is healthy, restart the service with that environment flag; until then, coordinate through normal memory, signals, actions, checkpoints, git state, and explicit context packs.

## Public-Safety Rules

Do not commit:

- `.env`, `*.local.cmd`, real MCP configs with keys, or shell history
- SQLite DBs, WAL/SHM files, logs, sessions, browser profiles, auth files
- local agent homes, plugin caches, model caches, generated images, toolchains, runtimes, or binaries
- research datasets, checkpoints, experiment outputs, or server logs

Before publishing, run a staged and tracked secret scan:

```powershell
git status --short
rg -n --hidden -S "sk-|api[_-]?key|token|secret|password|BEGIN .*PRIVATE KEY" .
```

Treat every hit as suspicious until reviewed. Placeholder examples are okay; real keys must be removed and rotated.

This repo also ships a stricter reusable gate:

```powershell
powershell .\tools\Test-PublicSafety.ps1
powershell .\tools\Test-PublicSafety.ps1 -Path D:\agent-resources
```

For rotation steps, see [`docs/credential-rotation-runbook.md`](docs/credential-rotation-runbook.md).

For agent collaboration examples, see [`examples/agentmemory-coordination.md`](examples/agentmemory-coordination.md).

For the private/public split, see [`docs/private-devtools-hygiene.md`](docs/private-devtools-hygiene.md).

## Related

| Project | Purpose |
| --- | --- |
| [agentmemory](https://github.com/rohitg00/agentmemory) | Upstream memory and MCP substrate. |
| [agent-resources](https://github.com/appleweiping/agent-resources) | Curated skills and implicit skill-routing map. |
| [vipin-wiki](https://github.com/appleweiping/vipin-wiki) | Public knowledge base and agent operating contract. |

## License

Apache-2.0.
