# Upstream Memory Systems Map

This public-safe note records the upstream memory systems reviewed for this workstation template.

## Reviewed Upstreams

| Project | Reviewed commit | Role in this setup |
| --- | --- | --- |
| `rohitg00/agentmemory` | `fd9e3bd42d6208a33f0ee9de1442fdbb60eab106` | Active memory, MCP, signals, actions, checkpoints, slots, and coordination substrate. |
| `mem0ai/mem0` | `a3154d59e52386d4e1189c1f5f44819868f76514` | Architecture reference to absorb. Not a bundled runtime or maintained fork. |

## Local Runtime Contract

The supported local service contract is:

- `@agentmemory/agentmemory` version `0.9.27`
- `@agentmemory/mcp` version `0.9.27`
- `iii.exe` version `0.11.2`
- authenticated REST/MCP Host guard on `http://127.0.0.1:3111`
- internal compatibility viewer fixed at `127.0.0.2:6002`; the public REST port
  plus two must have no listener
- `AGENTMEMORY_TOOLS=all`
- `AGENTMEMORY_SLOTS=true`

The viewer API proxy requires Bearer authorization, but the pinned shell may
serve unauthenticated `GET` or `OPTIONS` internally. Its only permitted Host is
the reserved `agentmemory-viewer.invalid:6002` authority, making it
intentionally browser-inaccessible. Origin is CORS response metadata rather
than request authentication. No interactive viewer is supported, and the
secret must never be entered into the upstream viewer UI.

Managed lifecycle and health probes prove the exact loopback listeners and
expected process ownership before sending a Bearer credential. The upstream MCP
module and derived-lesson ingestion HTTP client cannot independently prove
OS-level listener ownership before sending their inherited credential; use them
only against the managed, already-verified local service.

Use the dedicated D-drive npm install at
`D:\devtools\npm-global\agentmemory-runtime` for local runtime state. Do not
depend on `%APPDATA%\npm` package payloads.
On Windows, `iii.exe` is a separate official release asset rather than an npm
binary. The x86-64 `iii/v0.11.2` archive is pinned in `README.md` by its GitHub
release URL, byte length, archive SHA-256, and extracted executable SHA-256.

## Mem0 Concepts Mapped To Agentmemory

| Mem0 pattern | Agentmemory-local equivalent |
| --- | --- |
| ADD-only fact capture | Add durable facts through memory saves, lessons, and `/agentmemory/remember`; supersede old facts explicitly. |
| User, session, agent memory | Use project-scoped recall, sessions, actions, checkpoints, slots, and optional agent scope. |
| Agent-generated facts | Store findings, decisions, lessons, and handoffs as first-class memories. |
| Entity linking | Use facets, graph, file references, and explicit project/context fields. |
| Hybrid retrieval | Use smart search, recall, lessons, graph query, facets, and timeline views. |
| Temporal reasoning | Record dates, current state, and superseded state in memory and docs. |
| Server and CLI ergonomics | Keep the local service, MCP examples, health checks, and launchers as the supported interface. |

OpenMemory is not part of this template because upstream mem0 marks it as sunsetting for local self-hosted use. This repository intentionally does not ship a full mem0 fork.
