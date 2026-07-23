# Local Devtools Hygiene

This repository is the canonical public `appleweiping/devtools` project. A live
checkout such as `D:\devtools` can also contain ignored local agent homes, logs,
DBs, caches, licensed assets, auth state, and historical experiments. Keep those
local-only trees private even though the tracked repository is public.

## Public Repository Policy

Track only the reusable public workstation layer:

- stable launchers
- read-only health checks
- public-safe examples
- runbooks
- Apache-2.0 license
- no live config, logs, DBs, sessions, auth state, or local history

## Local-Only State Policy

- Do not create a second GitHub mirror for machine state.
- Never merge or force-push historical private workstation commits into this
  public repository.
- Promote a useful local artifact only after recreating or reviewing it against
  the public-surface manifest and secret gates.
- Before retiring an old private repository or checkout, preserve an offline
  bundle and manifest, rotate exposed credentials, and verify the public clone.
- Keep portable local-only roots in the tracked `public-surface.json` and
  `.gitignore`. For reviewed machine-specific root directories whose names must
  remain private, use `.git/info/devtools-local-surface.json` plus exact
  `.git/info/exclude` entries. That local file only suppresses filesystem
  recursion; it cannot authorize tracked or historical content.
- Put reviewed machine-specific root files in `.git/info/exclude` as exact
  entries. Do not use broad globs to hide an unknown surface.
- WEIPING maintenance may summarize private `D:\devtools` purpose, script names, and validation commands, but it must not depend on raw Codex configs, automation prompt bodies, logs, DBs, caches, or local `memory.md`.

## Local Cleanup Order

1. Identify ignored runtime state that can be deleted safely.
2. Move reusable scripts into tracked public-safe locations.
3. Remove retired active surfaces such as Agent Hub mailboxes, tracked DB/log files, old C-drive npm paths, and stale agent configs.
4. Keep experimental/research artifacts out of this repo.
5. Audit the optional Git-local surface file and exact excludes whenever the
   mixed checkout gains a new top-level path.
6. Run strict scans before every commit.
7. Preserve the clean public history; never graft old private history into it.

The active memory architecture is agentmemory-first. See `upstream-memory-systems-map.md` for how mem0 concepts are mapped without adopting OpenMemory or a full mem0 fork.

The pre-push safety gate allows staged deletion of blocked runtime paths so cleanup commits can remove old DB/log/secret surfaces. Any blocked path that remains tracked, staged as an add/modify, or present as an unignored nested repo still fails.
