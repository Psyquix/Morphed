# 0012 — A direct source's identity comes from its artifact, not its URL

**Status:** accepted (2026-10-17)
**Affects:** `scripts/utils.sh` (`get_direct_resp`, `dl_direct`, `get_direct_vers`,
`get_direct_pkg_name`, `build_rv`'s post-download re-key and `_vc_pinned_by_config`),
`CONFIG.md` (`direct-dlurl`), `.github/traces/test_direct_source.sh`

## Context

`direct` was the only source that read metadata out of the link's own text:
`get_direct_vers`/`get_direct_pkg_name` split the URL's last path segment on `-`, so
[CONFIG.md](../../CONFIG.md) documented a filename grammar (`<pkg>-<version>-<arch>.apk`)
as a requirement of the key. That made the source useless for the cleanest download
channels, which are a vendor's own fixed endpoint — `telegram.org/dl/android/apk` is a
`302` to a token-bearing CDN path that changes every release, and its last segment is
`apk`. Against such a URL the parser returned an empty version, and `build_rv` aborted
the app with "empty version, not building" before ever fetching.

The requirement was also the wrong kind of trust. A URL's filename is a claim; the APK
is the fact. Telegram's endpoint was measured to serve `org.telegram.messenger.web`
13.0.3 while the sibling "Google Play" configs expect `org.telegram.messenger` — under
the old rule a config author could point a link at a different app entirely and the
engine would have called it by the name in the URL. Every other source already resolves
identity from what it fetched; `direct` was the exception.

## Decision

A `direct` URL carries no metadata obligation. `get_direct_resp` performs one fetch at
source selection, proves the bytes are an APK (zip + readable manifest), reads
`package`, `versionName` and `versionCode` off them, and refuses the source — as a
per-source miss, not a build failure — when the transfer fails, the body is not an
archive, the identity cannot be read, or the package contradicts a configured
`pkg-name`. The getters report only what that probe proved.

The download loop then treats the artifact as the authority before any gate that quotes
a number: the staged file is re-keyed to its real version and versionCode, the
patch-compatibility gate is re-run on the real version, and an unsupported live build
drops `direct` and hands the original version back to the version-selecting sources.
That re-key runs *before* the version-code gate, so the code the build had derived from
the patch annotation for a version we do not hold cannot veto the bytes we do hold —
mirroring [0011](0011-version-code-fallback-to-arch.md). A `version-code` written by
hand in the config is different: it is an order, and it still rejects the artifact.

One fetch serves every architecture: the probed blob goes into the learned download-link
index ([0007](0007-requested-arch-is-a-hard-requirement.md)), so per-arch `dl_direct`
calls adopt it with no network hit, and a single-ABI direct link is refused for an arch
it cannot satisfy instead of downloading it and being caught by the arch gate later.

## Rejected alternatives

- **Keep the filename requirement and pin the version in the config instead.** Solves
  the empty-version abort, but the name still would not describe the bytes: a vendor
  endpoint moves on, and a stale pinned name mislabels the artifact — the failure class
  0007 and 0011 exist to remove.
- **Parse `Content-Disposition` for the filename.** Cheaper than a fetch, and still a
  claim from the server's headers rather than from the artifact. The version lives in
  the manifest; no header carries it.
- **Probe with `HEAD` and read only the redirect target.** Measured: `telegram.org`
  answers a `HEAD` with the bare `302` and never reveals the token URL, and the version
  is nowhere in the resolved URL either.
- **Re-key the version after the gates, as the code did.** The old block ran after the
  version-code check, so a patch-derived code for another version rejected the artifact
  before its real version was ever considered — the source silently never worked.
- **Let an unsupported live build fall through to the other sources at the live
  version.** Would ship an artifact the bundle never tested. Compatibility is judged on
  the version that will actually be published, so the fallback restores the version the
  patches advertise.

## Consequences

- A direct source always costs one full transfer at source selection, even when the
  build ends up using another source. Accepted: for a nameless link there is no
  cheaper way to learn what it is, and the blob is reused by every arch.
- `direct-dlurl` alone no longer identifies an app. Without `pkg-name` the downloaded
  file's package becomes the build's package, so a wrong link patches the wrong app —
  `CONFIG.md` now says to keep `pkg-name` set.
- The watcher (`ci_fetch_app_versions.sh`) still cannot list versions for a direct-only
  app; it has no listing to read and must not download APKs. Such an app needs either
  patches that advertise a version or a versioned store source alongside.
- Recovery if a vendor starts serving a bundle instead of an APK: `_meta_field_of` and
  `_artifact_abis` already understand bundles through `base.apk`, so nothing here needs
  changing; if the manifest read starts failing, fix the reader, not the gate.

## Verification

`bash .github/traces/test_direct_source.sh` — a nameless URL resolves the artifact's
version and package; a URL whose filename contradicts the bytes reports the bytes;
nothing is answered before a probe (negative control); a non-zip body, an unreadable
identity, and a package mismatch each drop the source; the probe is fetched once and
adopted by both arches; a recorded arm64-only link is refused for arm-v7a without a
re-fetch. `bash .github/traces/trace_runner.sh verify` stays green — the download loop
is not in the golden surface, as noted in
[0007](0007-requested-arch-is-a-hard-requirement.md).
