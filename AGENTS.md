# DELVTOOLS_PUBLIC Agent Instructions

`DELVTOOLS_PUBLIC` is the sanitized public export for reusable Windows agent workstation scripts. It is related to private `D:\devtools`, but it must remain safe to publish.

Canonical local names: the public export checkout is `D:\DELVTOOLS_PUBLIC`. The GitHub repository and older local spelling may still say `devtools-public`.

## Source Of Truth

Read `README.md` first, then `docs/private-devtools-hygiene.md`, `docs/credential-rotation-runbook.md`, and `tools/Test-PrePushSafety.ps1` when changing public-safety behavior.

## Boundaries

- Do not copy private `D:\devtools` runtime state into this repository.
- Do not commit secrets, `.env`, real MCP configs with keys, auth/session files, DBs, logs, browser profiles, caches, binaries, toolchains, generated images, or research artifacts.
- Keep examples placeholder-only and environment-driven.
- If a credential ever appeared in tracked content or generated public artifacts, document rotation and treat deletion alone as insufficient.

## WEIPING Constellation

`WEIPING_WIKI` may link to this repo as the public-safe export of devtools. Keep links at the level of purpose, scripts, validation gates, and hygiene rules. Do not expose private machine state or require the private devtools repo to use this public repo.

## Validation

Before commit or push:

```powershell
git status --short
powershell .\tools\Test-PublicSafety.ps1
powershell .\tools\Test-HistorySafety.ps1
powershell .\tools\Test-PrePushSafety.ps1
git diff --check
```
