# Third-party notices

The devtools repository contains original scripts and documentation under the
root Apache-2.0 license and may reference or pin third-party dependencies. A
dependency's own license continues to govern that dependency.

## IvanMurzak/Unity-MCP

- Project: <https://github.com/IvanMurzak/Unity-MCP>
- Pinned release: `0.86.1`
- Pinned commit: `e59211c610a1481ef2a8a1e6e7fe8010e7e5a509`
- License: Apache License 2.0
- Distribution form: declared Git submodule at `third_party/Unity-MCP`

The Unity Editor, Unity Hub, generated Unity project data, npm caches, and
`ai-game.dev` credentials are not distributed by this repository. Unity
software and services remain subject to Unity's own terms and subscription
requirements.

## Runtime downloads (not redistributed)

### Node.js

- Project: <https://nodejs.org/>
- Pinned release: `22.21.1` (`node-v22.21.1-win-x64.zip` in the Windows bootstrap)
- Bundled package manager used by the lock workflow: npm `10.9.4`
- License: MIT
- Distribution form: fetched by the operator into ignored `node\`; no Node
  binary is committed here

### agentmemory

- Project: <https://github.com/rohitg00/agentmemory>
- Pinned packages: `@agentmemory/agentmemory@0.9.27` and
  `@agentmemory/mcp@0.9.27`
- Top-level package license metadata: Apache License 2.0
- Lock form: `dependencies/agentmemory-runtime/package.json` and
  `package-lock.json` record exact versions, registry URLs, SHA-512 integrity,
  and npm-published license metadata for the complete dependency closure
- Distribution form: fetched with `npm ci --ignore-scripts` into ignored
  `npm-global\agentmemory-runtime\`; package payloads are not committed here

The root Apache-2.0 license does not relicense AgentMemory's transitive
dependencies. Each package remains subject to its own license, including entries
whose npm metadata says `SEE LICENSE ...` rather than an SPDX identifier. In
particular, the locked `@anthropic-ai/claude-agent-sdk` package and its optional
platform packages are governed by Anthropic's separate terms; Anthropic's
published license notice says “All rights reserved” and points to its Commercial
Terms of Service. See the
[official Anthropic notice](https://github.com/anthropics/claude-code/blob/main/LICENSE.md)
and the
[Agent SDK license-and-terms section](https://github.com/anthropics/claude-agent-sdk-typescript#license-and-terms),
and review the license shipped in the exact installed package before use or
redistribution. The tracked lock metadata is a reproducibility control, not a
grant of redistribution rights and not a substitute for a transitive-license
review.

### iii engine

- Project: <https://github.com/iii-hq/iii>
- Pinned release: `iii/v0.11.2` (`iii-x86_64-pc-windows-msvc.zip` in the
  Windows bootstrap)
- License: Elastic License 2.0 (engine runtime)
- Distribution form: fetched by the operator into ignored
  `npm-global\agentmemory-runtime\iii.exe`; the executable is not committed here

Future third-party dependencies must be added to this file with an immutable
version or commit, upstream URL, license identifier, and distribution form.
