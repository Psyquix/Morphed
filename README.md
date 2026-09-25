# update branch — module updater wire format

This branch is polled directly by KernelSU/LSPatch module updaters. Every
module zip bakes its update URL into `module.prop` (`updateJson`) at build
time, derived from `update_json_path()` in `scripts/utils.sh`:

    https://raw.githubusercontent.com/<repo>/update/<channel>/<id>-update.json

- `<channel>` is `stable` or `beta` — the folder *is* the channel (no more
  `-beta-` filename infix).
- File names carry no author segment.
- The 2026-09-25 restructure into folders is a hard cutover: modules built
  before it point at old flat root paths and must be reflashed manually.

Rules:
- Paths are a public wire format: never move, rename, or "tidy" these files;
  only create (builds) and delete (cleanup) them.
- Written by `build_update_changelog.sh` (build.yml), pruned by
  `cleanup_update_branch.sh` (cleanup.yml): a pointer dies when its zipUrl
  asset is no longer on the `stable`/`beta` archive release; orphaned
  changelogs die when no surviving pointer cites them.

Fresh module/APK files come from the `stable`/`beta` release downloads;
build metadata history lives on the `website` branch.
