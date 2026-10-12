# 0009 — The patch set that will be applied decides compatibility

**Status:** accepted (2026-10-12)
**Affects:** `scripts/utils.sh` (`_effective_patch_versions`,
`_effective_arch_verdict`, `has_compatible_patches`,
`_get_patch_last_supported_ver`, `build_rv`'s candidate loop, `_cache_target_vc`,
`write_no_patches_failure_descriptor`), `.github/traces/stubs/java`,
`temp/failures/*_np.json` and `build_report_failures.sh`

## Context

`OfflineGames-ggYasin` was unbuilt on both arches with the log ending in
*"Could not download … after trying all supported versions"* and the notification
asking for a manual APK upload to the cache repo. Neither was true: an APK was
never wanted, and the versions the engine tried were the two the bundle itself
advertises.

The engine answered "is this version supported?" from two different views of the
bundle:

- the resolver, `included-patches` branch, read `list-patches --with-versions`,
  which lists every patch including the ones a bundle ships `Enabled: false` →
  advertised `3.15.3`, `3.14.1`;
- the gate, `has_compatible_patches`, read `list-versions`, which counts only the
  patches *used by default* (`-u/--count-unused-patches` is what widens it) →
  answered `INFO:` and nothing else for that package.

Every candidate was therefore advertised and then rejected, on every arch, forever.
The same run also showed a second, quieter defect: the bundle annotates one ABI per
version (`3.15.3: ARM64_V8A=3327`, `3.14.1: ARMEABI_V7A=3204`), yet the arm-v7a job
was offered `3.15.3` first — a download that [0007](0007-requested-arch-is-a-hard-requirement.md)
makes mandatory to reject after the bytes are fetched, and no `versionCode` pin at
all, since `get_patch_version_code` reads the same default-set listing.

## Decision

**Compatibility, version resolution and the target versionCode are all answered
from the patch set that will actually be applied**, in one function:
`_effective_patch_versions` returns `version<TAB>ABI=vc` occurrences, from
`list-patches` restricted to the `included-patches` names when they are configured
(those names reach the CLI as `-e` and apply regardless of `Enabled`), and from
`list-versions` when they are not.

- The gate consults the named table first, then the default one. A config whose
  names match nothing therefore keeps exactly the pre-existing `list-versions`
  behaviour instead of losing the build.
- The "no listing at all" case (`list-versions` failing or printing nothing) stays
  **permissive**; a listing that answered without versions is not.
- A candidate version whose annotation lists other ABIs only is **redirected**: when
  another supported version is viable for the arch it takes that candidate's place, and
  an annotated version contributes its `versionCode` to the cache key and the
  post-download check when `list-versions` had nothing to say. Versions with no
  annotation stay unconstrained: never filtered, never pinned. If NO supported version
  mentions the arch, the download proceeds anyway and `_artifact_satisfies_arch`
  judges the bytes — the annotation is what the patch author tested, not what the store
  ships, so it must not mint a refusal of its own. `arch=all`/`auto` never filters.
- A build skipped because the patch set refused every candidate writes
  `temp/failures/<slug>_np.json` (`type: no_compatible_patches`) and is reported in
  a **Patch Compatibility** section naming the bundle — never as an exhausted
  download, because asking someone to upload an APK nobody fetched is noise, and the
  real fix is a patch release.

## Rejected alternatives

- **Pass `-u` to `list-versions`.** A one-line cure that also rewrites the
  resolver's input and the versionCode pinning for *every* Morphe app: default-
  disabled patches would start advertising "most common" versions that no applied
  patch supports, which is how a zero-patch APK ships. Rejected.
- **Force `version` in the app's TOML.** Any explicit version lands on the same
  gate and is skipped the same way. No config value fixes this.
- **Let the gate trust the resolver** (accept whatever version was chosen). Keeps
  the app building while making the gate decorative for every named-patch app,
  including the misnamed ones. Rejected.
- **Always ship the annotation-mismatched download and let 0007 reject it.** Kept the
  old coverage but fetches a 60 MB bundle per arch per version to throw it away, and
  never gave the version that *does* declare the arch a turn. Rejected in favor of
  redirecting, keeping the byte gate for the case where nothing declares the arch.
- **Refuse a version purely because its annotation omits the arch.** The annotation is
  patch-author intent, not store inventory: a universal bundle for that version would
  satisfy the arch honestly. Rejected — coverage must not depend on an annotation.
- **Report the skip as a build failure.** `build_rv` returns 0 (a skip), so
  `build.sh`'s parent deletes `<slug>.json` *and* the log — the record cannot
  survive that path, which is why the `_np` suffix exists (same reason as `_dl`).

## Consequences

- Bundles whose patches all ship `Enabled: false` build only for apps that name
  those patches in `included-patches`. That is deliberate: naming them is the
  request to apply them.
- A version annotated for another arch no longer occupies the slot of one that
  declares the requested arch, so the per-arch versions in a catalog entry can now
  genuinely differ (`arm64` at one version, `arm-v7a` at another) — which
  `write_build_info` and `build_make_manifest.py` already record per arch.
- `_effective_patch_versions` is memoized per process; `build_rv` calls the gate
  before the verdict so the JVM listing is fetched once, not per candidate. A new
  call site inside `$( )` would silently lose that memo (AGENTS rule 6).
- A build that names patches now reads `list-patches` for the gate as well as for
  resolution: one extra CLI listing per app+arch (memoized after that), paid to stop
  the advertised-and-rejected loop. Apps that name nothing are unchanged.
- A table version is keyed through `_ver_key` (whitespace removed, one leading `v/V`
  dropped), which is the form `version_f` and every cache filename already use.
  Bundle-authored version names are free text — Venus-Patches calls its Discord build
  `348.10 - Stable` — and comparing that raw against the stripped value skips every
  supported version of such an app. The same free text also lists version codes
  comma-separated (`ARM64_V8A=348010, ARMEABI_V7A=348010`), so the annotation is split
  on commas and a code that is not a bare number is never used as a pin.
- The `tried` list in `_np.json` is a wire addition; `build_report_failures.sh`
  reads it and nothing else does.

## Verification

- `bash .github/traces/test_patch_versions.sh` — pins the table parser (named,
  default, `Any`, a name absent from the bundle), the arch verdict both directions,
  the ambiguous/unannotated non-filtering rules, and the gate's permissive-vs-skip
  split. Each rule has a negative control; the suite is a step in
  `trace-verify.yml`.
- `bash .github/traces/trace_runner.sh verify` — the `morphe-disabled` fixture
  golden records the asymmetry itself: `HAS_COMPATIBLE_PATCHES(hit): rc=1` (default
  set, unchanged) beside `HAS_COMPATIBLE_PATCHES(named,hit): rc=0`,
  `EFFECTIVE_PATCH_VERSIONS(named)` and
  `ARCH_VERDICT(1.2.3,arm-v7a): refused`.
- `bash .github/traces/test_cache_helpers.sh` — the cache probe still resolves its
  version code (now also from the effective table).
- A report harness in `temp/` (stubbed `curl`) renders the three sections; the
  `_np` app appears under Patch Compatibility with the bundle link and no search
  links.
