# Website manifests

This branch is machine-managed by `merge_archive_branch.sh` and
`cleanup_website_branch.sh`.

- `manifests/<tag>.json` — per-build manifest
- `archive/stable.json`, `archive/beta.json` — cumulative channel archives

Do not hand-edit these files; the build workflow is their only writer.
