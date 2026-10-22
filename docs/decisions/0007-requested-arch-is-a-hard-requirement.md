# 0007 — A requested build arch is a hard requirement

**Status:** accepted (2026-10-01)
**Affects:** `scripts/utils.sh` (`_artifact_satisfies_arch`, `_dlurl_index_*`, the
`build_rv` download gate, `dl_apkpure`/`dl_apkcombo`/`dl_uptodown`), published asset
arch names on the `website`/`archive` branches, `build.json` arch entries

## Context

Download stores are not always published per-ABI. When Uptodown is dead and
`nullcpy/apks` has no matching asset, an APKPure *featured* link — an unlabelled
bundle that carries whichever ABI the store happened to feature — is the only thing
left. The engine used to take it for **every** arch and only *warn*:

> "Deliberately a warning, not a refusal … dropping the build would be worse than
> shipping the only bundle that exists."

In practice that shipped an arm64-v8a bundle under an `arm-v7a` file name (and the
reverse), because the product name came from the requested arch, never the bytes.
Two jobs that wanted the same single-ABI link also re-downloaded it once per arch.
`PocketWhip-hxreborn` v2.3 showed both at once: one 60 MB bundle fetched twice, and
a bogus `pocket-whip-hxreborn-v2.3-arm-v7a.apk` that was really arm64.

## Decision

**A matrix arch is only built when an artifact that actually carries that ABI (or is
universal/arch-agnostic) can be obtained.** Concretely:

- The bytes are the single source of truth. `_artifact_abis` already reads the real
  ABIs off an apk/bundle; `_artifact_satisfies_arch` turns that into a yes/no for a
  requested build arch. Unreadable is treated as a pass (conservative: it can only
  ever be served to itself), never as a reason to drop a build.
- `build_rv` judges each download on that predicate. A wrong single ABI is rejected
  and the run falls through to the next source; if no source yields a matching
  artifact the build is **not produced at all** (the existing "Could not download →
  skip" path). The output file name therefore always matches the bytes.
- Universal is unaffected: an unmixed bundle carries both arm ABIs, satisfies each
  arch, is cached under the shared `-all` key, and is reused by both jobs from one
  fetch. Both channels keep building for universal apps.
- Cross-arch duplication is removed with a **learned** download-link index: a link
  whose URL carries no ABI is fetched **once**, fingerprinted to
  `temp/urlindex/<sha1(url)>` as `ABIs<TAB>blob`, and every later job that resolves
  the same link consults that record — adopting the blob with no network hit when it
  fits, or skipping the source with no network hit when it does not.

The rule is **symmetric**: an arm64-only app produces no `arm-v7a` artifact, and a
v7a-only app produces no `arm64-v8a` artifact.

## Rejected alternatives

- **Warn and ship (the old behaviour).** Preserved coverage but produced mislabeled
  APKs; a v7a name over arm64 code crashes on 32-bit devices and the reverse is a
  lie in the catalog. Rejected outright — correctness of a shipped file is not
  negotiable.
- **Downward-compat exception** (let a v7a-only bundle satisfy the arm64 channel,
  since arm64 devices install v7a). Rejected: it recreates two byte-identical files
  where one is a fabricated 64-bit label. 64-bit users can install the honest 32-bit
  artifact; the builder must not mint a fake arch.
- **Blind early-refusal** (`return 1` whenever the store lists no variant for the
  arch, before any fetch). Rejected: for an arm64-only app building arm64, the only
  link is the unlabelled featured one whose arch is knowable *only from the bytes* —
  refusing it would drop legitimate builds. The index refuses *after* learning, not
  before.
- **An in-memory URL memo.** Rejected: `arch=both` runs as two separate child
  processes (`scripts/build.sh`), so only an on-disk index is visible across them.

## Consequences

- Catalog coverage shrinks for apps that publish a single ABI with no universal
  bundle: the absent channel simply has no artifact. `write_build_info` records only
  what was built, and the website catalog already tolerates a missing arch per app.
- `temp/urlindex/` is a per-run scratch store; it is wiped in the same `rm -rf` as
  the other lock/stage dirs and never enters `apk_cache_dir`'s cache manifest.
- Recovery if a genuinely-universal app is misread as single-ABI: fix
  `_artifact_abis` (it is the one place ABIs are read), not the gate.

## Verification

- `bash .github/traces/test_bundle_helpers.sh` — pins `_artifact_abis`,
  `_abis_satisfies`, `_artifact_satisfies_arch`, and the index adopt/reject paths,
  including the negative controls (unknown link is never refused; a stale blob reads
  as unknown; arm64-only does not satisfy arm-v7a; universal satisfies both).
- `bash .github/traces/test_cache_helpers.sh` — the per-arch cache key rule (a
  sibling single-ABI file is not adopted by the other arch).
- `bash .github/traces/trace_runner.sh verify` — engine goldens stay green (the
  download loop is not exercised by the stubbed traces, so a change here shows up in
  the helper tests, not the goldens).
