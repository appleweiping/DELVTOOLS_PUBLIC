# Local licensed asset vault

Purchased Unity Asset Store packages and other proprietary production assets
belong under the local devtools root, not in this public repository:

```text
D:\devtools\assets\licensed\
  unity\packages\
  unity\imports\
  receipts\
  manifests\
```

The entire `assets/` tree is ignored. Preserve original package filenames and
checksums. A local manifest may record product name, publisher, store URL,
purchase account, acquisition date, version, checksum, seat/entity scope, and
projects in which the asset is used. Treat receipts and account identifiers as
private.

Before copying an asset into a game or build pipeline, verify:

1. the account/entity owns the required license and has enough seats;
2. the license permits the intended commercial product and team arrangement;
3. the source package will not be redistributed through a public repository;
4. the shipped build contains only the transformed/runtime form the license
   allows; and
5. attribution or third-party notices are retained when required.

Game repositories should commit only an asset inventory with stable logical
IDs, expected versions/checksums, license category, and an import procedure.
They should not commit store archives, source models, textures, audio stems,
receipt files, access tokens, or cached Unity packages unless the specific
license explicitly allows redistribution.

If the local Unity Asset Store cache is migrated into this vault, first resolve
and record both absolute paths, copy and checksum the files, verify the copy,
then remove the original only when recovery and license records are intact.
