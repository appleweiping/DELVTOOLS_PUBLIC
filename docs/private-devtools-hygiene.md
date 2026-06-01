# Private Devtools Hygiene

`D:\devtools` is a live machine workspace. It can contain local agent homes, logs, DBs, caches, generated assets, auth state, and historical experiments. Keep it private.

## Public Pattern

Use `devtools-public` as the open-source template:

- stable launchers
- read-only health checks
- public-safe examples
- runbooks
- Apache-2.0 license
- no live config, logs, DBs, sessions, auth state, or local history

## Private Repo Policy

- Do not change `appleweiping/devtools` visibility.
- Do not force-push or rewrite private history casually.
- When a public artifact is useful, copy or recreate only the safe subset in `devtools-public`.
- If private history must be cleaned, create a written plan first: affected refs, backup branch, secret rotation status, and rollback path.

## Local Cleanup Order

1. Identify ignored runtime state that can be deleted safely.
2. Move reusable scripts into tracked public-safe locations.
3. Keep experimental/research artifacts out of this repo.
4. Run strict scans before every commit.
5. Prefer a fresh public export over publishing old private history.
