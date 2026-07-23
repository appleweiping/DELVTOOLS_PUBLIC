# Scheduled watchdog persistence

The scheduled AgentMemory watchdog can restart or repair the local service after
the registering shell exits. It does so without putting the AgentMemory bearer
secret in task XML, task arguments, JSON settings, command lines, or logs.

## Secret boundary

Registration reads `AGENTMEMORY_SECRET` from the invoking process and validates
the same 32--256 character URL-safe format used by the runtime. After the user
confirms the non-`WhatIf` operation, the registrar protects the UTF-8 bytes with
Windows DPAPI using `DataProtectionScope.CurrentUser` and the fixed, public
context entropy `devtools-public/agentmemory-watchdog/secret-store/v1`.

The ignored `<DataRoot>\run` directory receives one binary blob. Its on-disk
format is the seven-byte ASCII magic `AMWDSEC`, a one-byte format version, and
the DPAPI ciphertext. There is no JSON envelope and no plaintext copy. Writes
are staged and atomically replaced in the destination directory. Plaintext,
entropy, ciphertext, digest, and backup byte arrays are cleared when their
owning operation finishes. `*.dpapi` is also ignored as defense in depth when a
custom data root is used.

The watchdog settings JSON contains an absolute blob path and the lowercase
SHA-256 digest of the complete versioned blob. It contains no secret. A digest
detects accidental or malicious ciphertext substitution before DPAPI is called;
DPAPI supplies confidentiality and same-user integrity. Directory ACLs remain
useful defense in depth, but confidentiality does not depend on the runtime
directory being private from other local users.

DPAPI `CurrentUser` deliberately binds recovery to the Windows identity that
registered the task. Moving the blob to another account or machine is not a
supported backup or migration mechanism. Re-register the task as the intended
interactive user instead. DPAPI is not a boundary against a malicious process
already running as that same Windows identity; this design assumes a trusted
single-user workstation account.

## Runner contract

The short scheduled action passes only the absolute settings path to the tracked
runner. Before launching self-heal, the runner:

1. requires the exact versioned settings schema and rejects extra fields;
2. requires canonical absolute paths and keeps the blob under
   `<DataRoot>\run`;
3. verifies every required file, the loopback endpoint, and the ciphertext
   SHA-256 digest;
4. decrypts with DPAPI `CurrentUser` and re-validates the secret format; and
5. sets process-scoped `AGENTMEMORY_SECRET` only around the child invocation.

The child inherits that process environment. A `finally` block restores the
previous value, or removes the variable if it was previously absent. Child
output is suppressed, and validation or launch errors use fixed messages that
do not include the secret or machine-local paths.

The same ignored settings and DPAPI blob can supply the AgentMemory MCP stdio
client through `agentmemory-mcp-dpapi.ps1`. That launcher reuses this runner's
closed settings validator and the same secret-store functions, then temporarily
sets both `AGENTMEMORY_SECRET` and the settings file's exact `AGENTMEMORY_URL`
only around the pinned `@agentmemory/mcp@0.9.27` child. Unlike the watchdog,
the MCP launcher redirects and asynchronously byte-pumps stdin, stdout, and
stderr, flushing every written chunk for interactive delivery. It closes the
raw child input stream on client EOF, returns promptly if
the child exits while client stdin remains open, drains and flushes output, and
preserves the exact child exit code. See
[`mcp-dpapi-launcher.md`](mcp-dpapi-launcher.md) for the package, stdio, error,
and client-configuration boundaries.

## Transactional task registration

The registrar builds deterministic Task Scheduler XML with one executable
action, the exact tracked runner and settings arguments, the current Windows
SID, `InteractiveToken`, `LeastPrivilege`, enabled state, and one indefinite
`PT5M` repetition. The XML has no author or account name. Registration uses the
Task Scheduler COM API with the XML string in memory, so neither new nor prior
task XML is written to a temporary plaintext file.

Before mutation, any task with the requested name is exported in memory. A task
name collision is accepted only when it is a recognizable watchdog for the
same SID, runner, managed settings path, `InteractiveToken`, and
`LeastPrivilege`. Password-logon and arbitrary tasks are rejected because an
export does not contain the credential required to restore them.

Old task XML, settings bytes, and the referenced old ciphertext blob remain
available until the new task passes a fresh XML postcondition check. If task
creation or verification fails, the registrar atomically restores the old
settings, restores the accepted old task from its in-memory XML, or deletes the
new task when none existed. It then removes the new ciphertext. Old ciphertext
is retired only after successful verification. No rollback copy of unknown XML
or settings is written to disk.

`-WhatIf` performs validation only. It does not create `<DataRoot>\run`, a
ciphertext blob, settings, transaction artifacts, or a scheduled task, and it
does not query Task Scheduler.

## Verification

The persistence suite mocks the task boundary; it never creates, updates,
queries, or deletes a live scheduled task. Run it in both supported shells:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
  '$r = Invoke-Pester .\tests\core\WatchdogPersistence.Tests.ps1 -PassThru; if ($r.FailedCount -gt 0) { exit 1 }'

pwsh.exe -NoProfile -Command `
  '$r = Invoke-Pester .\tests\core\WatchdogPersistence.Tests.ps1 -PassThru; if ($r.FailedCount -gt 0) { exit 1 }'

powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
  '$r = Invoke-Pester .\tests\core\McpDpapiLauncher.Tests.ps1 -PassThru; if ($r.FailedCount -gt 0) { exit 1 }'

pwsh.exe -NoProfile -Command `
  '$r = Invoke-Pester .\tests\core\McpDpapiLauncher.Tests.ps1 -PassThru; if ($r.FailedCount -gt 0) { exit 1 }'
```

The suite covers DPAPI round-trip, version magic, ciphertext and hash tampering,
strict schema and path checks, process-environment restoration and removal,
zero-effect `WhatIf`, XML drift, successful commit, task-name collision, and
rollback with and without a prior task.
The MCP launcher suite separately covers the exact package contract, redirected
raw-byte stdio with per-chunk flushing, child exit-code preservation, both environment variables,
settings/blob drift, and path-free failure output.
