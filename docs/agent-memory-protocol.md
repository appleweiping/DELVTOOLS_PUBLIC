# Agent memory protocol

agentmemory is the single authoritative read/write path for durable agent
memory. Local intuition systems, session summaries, and learning loops may
produce candidates, but they are not independent memory authorities.

## Runtime contract

The public scripts default to an authenticated local Host guard at
`http://127.0.0.1:3111` and a runtime root derived from the repository checkout.
Override those values with `AGENTMEMORY_URL` and `DEVTOOLS_ROOT`; public port
`R` must be `1..5997`. Never edit an installed package's bundled engine
configuration. Agent configurations start the locally installed AgentMemory MCP
`0.9.27` module directly from
`<root>\npm-global\agentmemory-runtime\node_modules` rather than downloading it
through `npx` on every session.

`AGENTMEMORY_SECRET` is mandatory and must match
`^[A-Za-z0-9_-]{32,256}$`. Supply it through the parent process/user environment;
never put it in a tracked example, generated config, scheduled-task settings or
action, command line, log, or memory record. AgentMemory MCP `0.9.27` forwards
the inherited value as Bearer authorization. Direct HTTP callers must add the
same header themselves:

```powershell
if ($env:AGENTMEMORY_SECRET -notmatch '^[A-Za-z0-9_-]{32,256}$') {
  throw 'A valid inherited AGENTMEMORY_SECRET is required'
}
$headers = @{ Authorization = "Bearer $env:AGENTMEMORY_SECRET" }
Invoke-RestMethod -Method Get -Headers $headers `
  -Uri 'http://127.0.0.1:3111/agentmemory/health'
```

At `R`, the guard accepts only exact loopback Host/Origin values, safe or absent
`Sec-Fetch-Site`, a single valid Bearer credential, and the guard-health or
`/agentmemory/*` routes. Authentication and routing checks happen before any
request body is read or upstream connection is opened. The compatibility viewer
is fixed internally at `127.0.0.2:6002`; it is not at `R + 2`. iii REST, stream,
and worker-manager remain loopback-only on fixed ports `6000`, `6667`, and
`10080`; public `R + 2` and the retired `R + 1` and `R + 46023` layouts must
have no listeners. The iii internal ports are on the
[WHATWG Fetch bad-port list](https://fetch.spec.whatwg.org/#port-blocking), and
the [WebSockets handshake uses Fetch](https://websockets.spec.whatwg.org/#opening-handshake),
providing browser-bypass defense in depth in addition to authentication and
loopback binding.

The viewer API proxy requires Bearer authorization. Its pinned upstream shell
may serve unauthenticated `GET` or `OPTIONS` internally before an API request is
authenticated, so the only allowed Host authority is
`agentmemory-viewer.invalid:6002`. The `.invalid` name makes the viewer
intentionally inaccessible to a normal browser. No interactive viewer is
supported, and users must never enter `AGENTMEMORY_SECRET` into that UI. The
configured Origin is CORS response metadata, not request authentication.

Managed server startup/adoption, readiness, self-heal, and health paths prove
the exact loopback listener set and expected process ownership before sending a
Bearer credential. The upstream MCP module and the derived-lesson ingestion
HTTP client cannot independently prove OS-level listener ownership before
sending their inherited credential. Use them only after the managed runtime has
passed its ownership checks, with `AGENTMEMORY_URL` fixed to the exact local
guard endpoint.

Secrets, auth state, raw prompts, transient progress, and command output do not
belong in memory. A local derivation layer must not read as an authority or write
directly to agentmemory.

## Durable memory schema

Every saved memory has one topic and supplies:

| Field | Rule |
| --- | --- |
| `content` | A durable, complete statement; no credentials or session transcript. |
| `type` | One of `architecture`, `pattern`, `preference`, `bug`, `workflow`, or `fact`. |
| `project` | `_global` or a lowercase, hyphen-separated stable project name. Never use a filesystem path. |
| `concepts` | At least two useful tags and exactly one `agent:<identity>` writer tag. |

Search the same project and topic before saving. Update or supersede an existing
memory when the new material is progress on the same fact; do not create an
iteration log. Store architecture decisions, reusable patterns, stable
workflows, preferences, root-cause fixes, and durable facts. Do not store a
single command result, monitoring heartbeat, temporary plan, or secret.

Projects maintain their own registry of canonical names outside this public
template. A registry entry must use the project-name grammar above and may map
legacy display names to one canonical value without recording personal paths.

## Derived lesson promotion

ECC and Hermes-style derivation layers may emit JSON candidates only under:

```text
<devtools-root>\data\derived\lessons\pending\ecc\*.json
<devtools-root>\data\derived\lessons\pending\hermes\*.json
```

Each candidate uses the durable schema. `scripts/ingest-lessons.mjs` is the
only promotion gate. It validates fields and source identity, rejects
secret-like content, requires at least two non-reserved topic tags, adds
`derived-lesson`, source identity, and a deterministic `lesson-sha256:*` tag,
then saves through the authoritative server's `/agentmemory/mcp/call` endpoint.
The default transport never falls back to a private standalone store and
preserves the canonical `project` field. Failed candidates stay pending.
Dry-run validates without contacting the service, moving data, or printing
lesson content.

Promotion uses validated `prepared` and `saved` receipts plus a recoverable
process lock. Normal promotion and explicit recovery also share an OS-managed,
per-hash local mutex, which is released automatically when its process exits.
The mutex uses a Windows named pipe or Linux abstract socket; promotion fails
closed on platforms without either mechanism.
A confirmed save is recorded before the same-volume atomic move.
If the process loses the save response, the prepared receipt makes the state
explicitly uncertain and future runs fail closed instead of automatically
writing the memory twice. Search the authoritative store for the exact
`lesson-sha256:<hash>` tag and project, then resolve only after inspection:

```powershell
# Use saved only after finding the hash in authoritative memory.
& D:\devtools\node\node.exe .\scripts\ingest-lessons.mjs --resolve-prepared <sha256>=saved

# Use retry only after verifying that authoritative memory does not contain it.
& D:\devtools\node\node.exe .\scripts\ingest-lessons.mjs --resolve-prepared <sha256>=retry
```

A crashed process can leave a lock whose PID has since been reused by an
unrelated process. Do not delete that lock directly. First inspect the matching
`<sha256>.lock` and receipt, verify that no promotion owns it, verify that its
`createdAt` is stale, and copy its exact nonce. The explicit recovery command
requires a valid prepared or saved receipt, an exact hash/nonce pair, and a lock
at least five minutes old; it never makes an automatic save decision:

```powershell
& D:\devtools\node\node.exe .\scripts\ingest-lessons.mjs --break-stale-lock <sha256>=<nonce>
```

After unlocking, the run will still fail closed on a prepared receipt. Resolve
that receipt with `saved` or `retry` only after the authoritative-store check
described above.

Pending and ingested roots must not overlap and must be on the same Windows
volume; this is what makes the final file move atomic. Receipt files are parsed
and matched to source, project, type, and full hash before they may suppress a
save.

```powershell
& D:\devtools\node\node.exe .\scripts\ingest-lessons.mjs --dry-run
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\ingest-lessons.ps1 -DryRun
```

Runtime roots, service URL, and timeout can be selected with CLI parameters or
`LESSONS_PENDING_ROOT`, `LESSONS_INGESTED_ROOT`,
`AGENTMEMORY_URL`, `AGENTMEMORY_PROMOTION_TIMEOUT_MS`, and `DEVTOOLS_ROOT`.
Plain HTTP is accepted only for a loopback hostname; a remote endpoint must use
HTTPS so lesson content and authorization metadata are not sent in cleartext.
`AGENTMEMORY_SECRET` is always required for a live promotion, is read only from
the environment, and is never logged. An explicit
`--client`/`AGENTMEMORY_CLIENT_MODULE` override is for
test or audited adapters only: the module must export
`promotionClientContract = 2`, preserve project scope without local fallback,
and return the same structured success result as the authoritative endpoint:
`{"success":true,"memory":{"id":"..."}}`. Free-form success text and
ambiguous `saved` fields fail closed.
The pending and ingested trees are local state and remain ignored by Git.
