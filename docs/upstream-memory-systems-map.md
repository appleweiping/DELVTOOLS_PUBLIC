# Upstream Memory Systems Map

This public-safe note records the upstream memory systems reviewed for this workstation template.

## Reviewed Upstreams

| Project | Reviewed commit | Role in this setup |
| --- | --- | --- |
| `rohitg00/agentmemory` | `fd9e3bd42d6208a33f0ee9de1442fdbb60eab106` | Active memory, MCP, signals, actions, checkpoints, slots, and coordination substrate. |
| `mem0ai/mem0` | `a3154d59e52386d4e1189c1f5f44819868f76514` | Architecture reference to absorb. Not a bundled runtime or maintained fork. |

## Local Runtime Contract

The supported local service contract is:

- `@agentmemory/agentmemory` version `0.9.24`
- `iii.exe` version `0.11.2`
- REST/MCP service on `http://localhost:3111`
- viewer on `http://localhost:3113`
- `AGENTMEMORY_TOOLS=all`
- `AGENTMEMORY_SLOTS=true`

Use the D-drive npm install under `D:\devtools\npm-global` for local runtime state. Do not depend on `%APPDATA%\npm` package payloads.

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
