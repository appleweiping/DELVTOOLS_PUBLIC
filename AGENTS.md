# devtools agent instructions

`devtools` is the sanitized, public, reproducible engineering layer for a local
Windows agent workstation. The intended canonical checkout is `D:\devtools` and
the intended GitHub repository is `appleweiping/devtools`.

## Source of truth

Read `README.md` first. Read `docs/publication-security.md` before changing the
publishable surface, `docs/runtime-services.md` before changing service scripts,
and `docs/unity-mcp-compliance.md` before touching the Unity integration.

## Boundaries

- Track stable source, scripts, tests, docs, examples, and reproducible locks.
- Never commit secrets, `.env`, auth/session files, DBs, logs, browser profiles,
  caches, installed runtimes, proprietary binaries, paid assets, or generated
  machine state.
- Keep purchased assets below the ignored local `assets\licensed` vault and
  publish metadata only when its license permits that metadata.
- Shared skills belong in `D:\AGENT_RESOURCE`; use junctions/symlinks rather
  than duplicate source copies.
- A submodule gitlink is not permission to run third-party code.
- Do not enable, authenticate, start, query, or control Unity Editor through
  Unity-MCP until the authorization evidence required by
  `docs/unity-mcp-compliance.md` has been recorded and verified.
- Preserve unrelated local/runtime files in a mixed public-checkout workstation.

## Validation

Before committing or pushing:

```powershell
node --test .\tests\key-rotator.test.mjs
node --test .\tests\agentmemory-host-guard.test.mjs
node --test .\tests\agentmemory-runtime-supervisor.test.mjs
node --test .\tests\security\agentmemory-dependency-lock.test.mjs
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '$r=Invoke-Pester .\tests\core\RuntimeScripts.Tests.ps1 -PassThru; if($r.FailedCount -gt 0){exit 1}'
pwsh.exe -NoProfile -Command '$r=Invoke-Pester .\tests\core\RuntimeScripts.Tests.ps1 -PassThru; if($r.FailedCount -gt 0){exit 1}'
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '$r=Invoke-Pester .\tests\core\McpDpapiLauncher.Tests.ps1 -PassThru; if($r.FailedCount -gt 0){exit 1}'
pwsh.exe -NoProfile -Command '$r=Invoke-Pester .\tests\core\McpDpapiLauncher.Tests.ps1 -PassThru; if($r.FailedCount -gt 0){exit 1}'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\launchers\Test-LauncherTemplates.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '$r=Invoke-Pester .\tests\shell\ShellReachability.Tests.ps1 -PassThru; if($r.FailedCount -gt 0){exit 1}'
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command '$r=Invoke-Pester .\tests\memory\IngestLessonsWrapper.Tests.ps1 -PassThru; if($r.FailedCount -gt 0){exit 1}'
node --test .\tests\memory\ingest-lessons.test.mjs
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\security\Test-PublicSafetyGates.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-PublicSafety.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-HistorySafety.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-PrePushSafety.ps1
git diff --check
```

The full-history gate must run from a non-shallow checkout. Findings must never
print credential material; rotate any real credential that reached history.
