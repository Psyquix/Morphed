# Update branch — module updater endpoints (generated, do not edit)

This branch serves the in-place updater for the KernelSU/LSPatch modules built
by [nullcpy/rvb](https://github.com/nullcpy/rvb). Module zips are baked at
build time with exactly:

    https://raw.githubusercontent.com/nullcpy/rvb/update/<module>-update.json

so **this is a wire format**: files may be deleted by maintenance, but never
moved, renamed, or reorganized — every already-installed module would
silently 404.

## Layout

- `<root>/*-update.json` — one per built app/brand/arch/channel variant,
  e.g. `youtube-morphe-nullcpy-arm64-update.json`, beta channel marked by a
  `-beta-` infix in the filename. KernelSU/LSPatch `update.json` schema:
  `version`, `versionCode` (build number), `zipUrl` (points at the rolling
  `stable`/`beta` archive release asset), `changelog` (points at
  `changelogs/<build>.md` right here).
- `changelogs/<build>.md` — per-build release notes, kept while any live
  `*-update.json` references them or their release still exists.

## Who writes it

- `build_update_changelog.sh` (build.yml) adds/rewrites entries per build and
  pushes via git-auto-commit.
- `cleanup_update_branch.sh` (cleanup.yml) prunes orphaned changelogs and
  fossilized pointers (zipUrl asset gone from the archive AND origin build
  release deleted).

Fresh APK/module files always come from the `stable`/`beta` release downloads;
build metadata history lives on the `website` branch.
