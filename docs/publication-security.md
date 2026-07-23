# Publication Security Gate

The repository treats `public-surface.json` as the reviewable allowlist for content that may be published. A path being absent from `.gitignore` is not permission to publish it.

## Enforced surface

- Every current root and nested file is named explicitly. Paths must already be
  slash-separated NFC repository-relative names: no trimming, alias
  normalization, traversal, reserved Windows names, case folding, or
  case-colliding index/tree entries is accepted. The schema can express a
  tightly bounded extension/depth tree, but this repository currently uses an
  exact tracked-file allowlist.
- Cache, state, authentication, credential, backup, session, log, database, key, and JSONL paths are rejected at any depth.
- Blobs above the normal size limit, binary files, Git LFS pointers, and symbolic
  links require an exact path, SHA-256 digest, source, license, and all observed
  artifact kinds. A separate 16 MiB hard ceiling applies even to allowlisted
  artifacts.
- `archivePolicy` is fixed to `deny`. Archive extensions and exact ZIP, gzip,
  bzip2, 7z, RAR, XZ, Zstandard, CAB, and tar signatures are rejected with no
  allowlist exception.
- Git submodules require an exact path, upstream URL, release ref, commit,
  license, and license source. `.gitmodules` accepts only one exact `path` and
  one exact `url` per section; duplicate sections/keys/paths, extra keys, case
  aliases, and unsupported syntax fail closed. Other nested `.git` metadata is
  rejected, including ignored working-tree repositories.
- The project license must remain present and match the SPDX policy declared in the manifest.

`localOnlyTrees` is the versioned exception required by the mixed `D:\devtools`
layout. Each entry must be a single exact top-level directory name, must have a
matching top-level `.gitignore` rule, and must not overlap the public surface or
a submodule. The working-tree recursion skips only those named roots, so
`vendor` does not exempt `vendor-cache`. Files force-added from a local-only root
are rejected by the index gate, and any such path found in reachable Git history
fails the history gate.

Machine-specific directory names that should not be published may instead be
declared in the untracked Git metadata file
`.git/info/devtools-local-surface.json`:

```json
{
  "schemaVersion": 1,
  "localOnlyTrees": ["local-tool-cache"]
}
```

Every entry must be one exact canonical top-level Windows directory name and
must also be ignored by Git, normally with an exact `.git/info/exclude` rule.
The local file is size-bounded strict UTF-8 JSON with no extra fields; duplicate,
case-colliding, unsafe, unignored, or public-overlapping names fail closed.
Leading dot/underscore and internal spaces are accepted only here so a mixed
checkout can describe real private machine state without publishing those names.

This local override affects only filesystem recursion for nested repositories
and junctions. It never authorizes an index entry, commit, historical blob,
artifact, or submodule. Force-adding a file from one of its roots still fails,
and a committed-then-removed file still fails history inspection. A plain
`.git/info/exclude` rule without this reviewed local override only reduces
status noise and does not suppress recursive inspection.

An artifact allowlist entry is deliberately narrow. Changing its bytes requires an explicit digest update and a fresh provenance review. Do not use an exception to admit generated runtime state or a private machine export.

## Reachable history contract

History has two independent authorization layers. First, every reachable commit
is checked as a complete tree against the `public-surface.json` stored in that
same tree. A file cannot be committed outside that commit's declared surface,
and old binary/submodule pins must match that commit's provenance.

Second, each ref or pre-push update tip is checked against its **final**
manifest. Every object newly reachable from that tip must still be authorized
there. Temporarily expanding a manifest, committing a file, and then deleting
both does not erase the public Git object and therefore fails. Intentional
retirement uses one of these explicit final-manifest tombstones:

- `historicalAllowedFiles`: exact paths for retired regular text files within
  the normal blob limit;
- `historicalArtifacts`: exact path + SHA-256 + kinds + source + license for
  each retired binary, large, LFS, or symlink version; the kinds and provenance
  must match the artifact declaration in the historical commit;
- `historicalSubmodules`: exact path + URL + ref + commit + license + license
  source; every field must match the historical commit's declaration.

Archive tombstones remain forbidden. Git replace refs and `info/grafts` are
also forbidden so neither layer can inspect a substituted history.

## Secret handling

The gates recognize provider-specific credentials, private keys, embedded URL
credentials, sensitive assignments, JWTs, generic high-entropy tokens, and
absolute Windows/POSIX user-home paths. Profile exceptions are a small exact
list; similarly prefixed real account names are not placeholders. File bodies
are scanned as strict UTF-8, byte-preserving single-byte data, and detected
UTF-16/UTF-32 LE/BE, including allowlisted binary files.

Scanning also covers Git paths, ref names, pre-push local/remote ref names,
commit author/committer fields and messages, and annotated-tag tagger fields and
messages. Structurally valid signature payloads suppress only the generic
high-entropy heuristic; their raw text is still checked for known credential
formats, so an armored block cannot hide a provider token. Findings contain
only the type, line when meaningful, value length/fingerprint, and a redacted
location length/fingerprint. They never print the matched value, path, ref,
account, or even a prefix/suffix of it.

If a finding represents a real credential, rotate it before publication. Removing the current file is insufficient when the value reached Git history.

## Validation and CI

Run from the repository root with Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\security\Test-PublicSafetyGates.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-PublicSafety.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-HistorySafety.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Test-PrePushSafety.ps1
git diff --check
```

The installed pre-push hook forwards Git's standard two remote arguments and
consumes the four-field ref-update records on stdin. For every non-delete
update, it scans the supplied (even otherwise dangling) tip and its complete
ancestry. Rechecking the ancestry is required because the final tip manifest
may have removed an older text, artifact, or submodule tombstone. Delete-only
updates have no new object to publish and are allowed even when unrelated index
work is incomplete. A malformed update or a non-commit/tag target fails closed.
Running the script manually without redirected input
checks the index plus every local ref; `-ScanUntracked` adds untracked files.

The CI checkout uses `fetch-depth: 0`; the history gate rejects shallow clones
and applies both history layers to every local ref. The full-history job keeps a
60-minute timeout budget because it runs the regression suite plus the current,
history, and unified pre-push scans on Windows. Submodule contents are not
executed or checked out by this workflow. Their pinned upstream repositories
retain their own histories and licenses.
