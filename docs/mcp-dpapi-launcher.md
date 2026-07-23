# AgentMemory MCP DPAPI launcher

`agentmemory-mcp-dpapi.ps1` lets a local MCP client start the pinned
AgentMemory stdio server without keeping `AGENTMEMORY_SECRET` in that client's
configuration or inherited long-lived environment.

## Prerequisites and trust boundary

Register the scheduled watchdog first as the same interactive Windows user that
will run the MCP client. Registration creates an ignored settings JSON and a
DPAPI `CurrentUser` ciphertext blob. The launcher does not create, rotate, or
persist either file; it consumes the exact watchdog settings already validated
by `agentmemory-watchdog-run.ps1` and decrypts through the shared
`agentmemory-secret-store.ps1` implementation.

The settings path is not a credential, but it is machine-local and must remain
outside Git. Pass its canonical absolute path with `-SettingsPath`. A default
registration produces a file below the ignored log directory with a name like:

```text
D:\devtools\logs\agentmemory-watchdog.settings.port3111.task<task-key>.json
```

DPAPI `CurrentUser` is not a security boundary against another malicious
process already running as that same Windows identity. The design assumes a
trusted single-user workstation account and normal local filesystem ACLs.

## Validation and execution contract

Before decrypting the blob or starting a child, the launcher:

1. reuses the watchdog's closed settings schema, canonical absolute-path
   checks, required-file checks, loopback URL policy, blob containment, and
   ciphertext SHA-256 validation;
2. requires ordinary, non-reparse files and directories for the selected Node
   executable and the dedicated package subtree;
3. accepts only
   `<InstallRoot>\node_modules\@agentmemory\mcp\bin.mjs` with package name
   `@agentmemory/mcp`, version `0.9.27`, ESM type, and the exact declared bin
   entry; and
4. decrypts with DPAPI `CurrentUser` and re-validates the 32--256 character
   URL-safe secret format.

Immediately before process creation, it saves the current process values of
`AGENTMEMORY_SECRET` and `AGENTMEMORY_URL`, sets them to the decrypted secret
and the settings file's exact `http://127.0.0.1:<port>` endpoint, and starts the
pinned Node entry point from the dedicated install prefix. Standard input,
standard output, and standard error are redirected only inside the wrapper.
Three asynchronous raw-stream pumps preserve the MCP client's bytes in both
directions without PowerShell text decoding or object formatting. Each pump
performs `ReadAsync`, `WriteAsync`, and `FlushAsync` for every chunk, so a small
interactive JSON-RPC frame is delivered while stdin remains open. Client stdin
EOF closes the child's stdin explicitly; stdout and stderr continue draining in
parallel. Child exit races the stdin pump so an upstream failure
cannot hang behind a client pipe that remains open: in that case the wrapper
closes the child-side input and does not wait for the unfinished client read.
During child construction the wrapper temporarily selects a BOM-free console
input encoding, obtains the child's input writer, and immediately restores the
previous encoding; this prevents Windows PowerShell 5.1 from inserting a UTF-8
preamble even though all payload I/O uses raw streams. After child exit the
wrapper gives stdout and stderr 15 seconds to finish, flushes both parent
streams, and returns the exact child exit code. A drain failure closes only the
streams and exact child created by this invocation, then follows the fixed
wrapper-error path.

A `finally` block restores both prior environment values, or removes either
variable when it was previously absent. Wrapper-generated failures emit only
`Agentmemory MCP launcher failed.` and exit `127`; validation exceptions do not
include secrets or machine-local paths. Because stdio is intentionally
transparent, text deliberately written by the verified upstream child remains
upstream-controlled and is not filtered by the wrapper.

The MCP package cannot independently prove operating-system listener ownership
before forwarding its inherited bearer secret. Use this launcher only with the
managed local AgentMemory service after its server/readiness path has verified
the exact Host-guard listener and process tree. Do not point the watchdog
settings at an unmanaged endpoint.

## Client configuration

Replace `REPLACE_WITH_TASK_KEY` below with the suffix of the ignored settings
file created by watchdog registration. Do not add `AGENTMEMORY_SECRET` or
`AGENTMEMORY_URL` to the client configuration.

```json
{
  "mcpServers": {
    "agentmemory": {
      "command": "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
      "args": [
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        "D:\\devtools\\agentmemory-mcp-dpapi.ps1",
        "-SettingsPath",
        "D:\\devtools\\logs\\agentmemory-watchdog.settings.port3111.taskREPLACE_WITH_TASK_KEY.json"
      ],
      "env": {
        "AGENTMEMORY_TOOLS": "all"
      }
    }
  }
}
```

The public examples contain only this placeholder. Record the actual generated
settings path only in the private local client configuration.

## Verification

The Pester suite never starts or contacts the AgentMemory runtime. It uses mocks
for secret-boundary cases plus temporary interactive and echo-only Node children
for actual external-process stdio tests. Run it in both supported shells:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command `
  '$r = Invoke-Pester .\tests\core\McpDpapiLauncher.Tests.ps1 -PassThru; if ($r.FailedCount -gt 0) { exit 1 }'

pwsh.exe -NoProfile -Command `
  '$r = Invoke-Pester .\tests\core\McpDpapiLauncher.Tests.ps1 -PassThru; if ($r.FailedCount -gt 0) { exit 1 }'
```

The suite covers the exact package contract, a small request/response that must
flush before parent stdin EOF, a large byte-for-byte JSONL stdin/stdout
backpressure case, stderr, stdin EOF, early child exit while parent stdin remains
open, child exit codes, temporary environment injection, success/failure
restoration, closed settings, ciphertext tampering, path-free errors, and
direct-invocation failure behavior.
