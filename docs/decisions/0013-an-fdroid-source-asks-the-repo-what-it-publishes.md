# 0013 — An F-Droid source asks the repo what it publishes

**Status:** accepted (2026-10-17)
**Affects:** `scripts/utils.sh` (`DL_SRCS`, `get_fdroid_resp`, `get_fdroid_vers`,
`get_fdroid_pkg_name`, `dl_fdroid`, `_fdroid_split_url`), `CONFIG.md` (`fdroid-dlurl`),
`.github/traces/fixtures/fdroid/*`, `.github/traces/test_fdroid_source.sh`

## Context

F-Droid is the most reliable Android app repository to scrape: no Cloudflare wall, a
JSON endpoint per package, and a deterministic file layout. Adding it as a source has one
trap, which is the same trap `direct` had until
[0012](0012-direct-source-identity-comes-from-its-artifact.md): a URL can be *guessed*
instead of *asked*. The repo's file names look guessable — every release of every app is
`<pkg>_<versionCode>.apk` — so the tempting implementation constructs URLs from a version
name without ever consulting the repo, and then invents download URLs for releases that do
not exist.

Measured facts this decision rests on:

- `GET <origin>/api/v1/packages/<pkg>` returns `{suggestedVersionCode, packages:[{versionName,
  versionCode}]}` — a few hundred bytes, newest first, capped at the ~12 most recent
  releases. It carries no file name and no ABI list.
- `GET <repo>/index-v1.jar` → member `index-v1.json`, whose top-level `packages` map (not
  `apps`, which holds only metadata) carries `apkName`, `versionName`, `versionCode`,
  `nativecode`, `hash`. `index.jar` is the legacy spelling with member `index.json`.
- `f-droid.org`'s own index-v1.jar is **15.8 MB compressed** (IzzyOnDroid's, at 1400 apps,
  is 3.77 MB) — far too heavy to fetch as part of building one app.
- Across 1400 apps / 2964 released entries: **no ABI-suffixed file names exist**, and only
  two names deviate from the `<pkg>_<code>.apk` grammar (`com.mgoogle.android.gms_22022001.apk`
  where the code is miscounted in the name, and `com.spynet.camtest_g2h_46.apk` with an
  extra token). F-Droid ships one universal APK per version code and declares the ABIs in
  `nativecode` instead. `armeabi-v7a` is the vendor spelling of the build's `arm-v7a`.

## Decision

`fdroid-dlurl` is accepted in two shapes, and each asks the repo rather than guessing:

- A **package page** (`<origin>/[<lang>/]packages/<pkg>`) queries the site JSON for the
  release list and builds the file name from the grammar, because that grammar holds and
  the index is too large to fetch. `pkg-name` may be omitted: the package is in the URL.
- A **bare repo root** (any third-party repo) is read through `index-v1.jar`, falling back
  to `index.jar`, and the release rows carry the **exact published file name** plus the
  declared ABIs. `pkg-name` is required, because the URL names no app.

Either way the parsed result is one table per run — version name, version code, file name,
arch tokens, tab-separated — newest release first, memoized by URL so one index fetch
serves every architecture.
`dl_fdroid` selects from that table: a pinned `version-code` selects the release outright;
otherwise the version name does, and where several releases share a name the newest code
wins. A release whose declared ABIs exclude the requested arch is refused **before any
transfer**; a blank ABI column (the site API) is not a refusal, and the artifact gate of
[0007](0007-requested-arch-is-a-hard-requirement.md) judges the bytes instead. Anything
unusable — no index, an empty release list, an unpublished version, a malformed URL —
returns non-zero so the caller drops this source and tries the next, rather than
fabricating a download.

## Rejected alternatives

- **Construct `<repo>/<pkg>_<code>.apk` from a version name with no listing at all.**
  Cheapest possible, and it produces 404s for versions the repo dropped, plus wrong names
  for the two author-quirk entries the index actually publishes. Rejected for the same
  reason [0012](0012-direct-source-identity-comes-from-its-artifact.md) rejects filename
  claims: the source must say what it has.
- **Fetch the repo index for every URL shape.** Uniform and precise, but 15.8 MB (about
  190 MB inflated) per app build on `f-droid.org`. The per-package JSON exists exactly to
  avoid it.
- **Reconstruct the file name even in the index form.** The index already names the file;
  reconstructing would reintroduce the two measured deviations for zero gain.
- **Split downloads per ABI, as APKPure does.** There is nothing to split: no ABI-suffixed
  name exists in the measured repo, and F-Droid declares ABIs on one universal file.
- **Put `fdroid` below the store scrapers.** It is first-party, un-walled and scriptable;
  APKMirror's anti-bot routing is the fragile path. The maintainer chose above-the-stores
  placement, so `fdroid` sits at #4, above `archive` and every store.

## Consequences

- Only the ~12 newest releases are reachable through a package page. Pinning an older
  version needs `cache_repo`, `archive`, or a repo-root URL whose index lists more.
- F-Droid re-signs the apps it builds, so an artifact's signer is the repo's key, not the
  upstream store key. A `sig.txt` pin written against a store signature will reject an
  F-Droid download; that is the pin doing its job, and the pin has to name the F-Droid
  identity if an app is meant to come from a repo.
- The watcher (`ci_fetch_app_versions.sh`) does not learn `fdroid-dlurl`. Its job is cheap
  version polling, which the per-package JSON supports for one package but not for the
  repo-root form at any price. An app that needs a watcher-recorded version should keep a
  store source beside the F-Droid one.
- Recovery if F-Droid ever ships per-ABI files: `_fdroid_split_url`/the index reader is the
  one place to teach it (`apkName` is already carried verbatim in the index form), not the
  arch gate.

## Verification

`bash .github/traces/test_fdroid_source.sh` (a step in `trace-verify.yml`) — offline
against `fixtures/fdroid/`: a page URL resolves origin/repo/package and its releases come
out newest-first from a deliberately unsorted fixture; the file name is built from the
grammar; a pinned code selects that build; an unpublished version, an arch the release
excludes, an empty release list, a repo with no index, a repo root naming no app, and a
malformed URL each drop the source without a transfer; the index form uses a deviating
`apkName` verbatim and maps `armeabi-v7a` to `arm-v7a`; the legacy `index.jar` /
`index.json` spelling is reached when `index-v1.jar` is absent; a memoized URL is not
fetched twice. Removing the newest-first sort, or the ABI filter, fails the suite — both
were checked by mutation. `bash .github/traces/trace_runner.sh verify` is unaffected (the
download loop is not in the golden surface).

Live confirmation, 2026-10-17, against the real endpoints (harness kept at
`temp/_fdroid_probe.sh`): the page form listed Aurora Store 4.8.4/76 and chose
`https://f-droid.org/repo/com.aurora.store_76.apk` (HEAD 200); a pinned code chose `_75`;
the repo-root form parsed IzzyOnDroid's 3.77 MB `index-v1.jar`, mapped its ABIs, chose
`https://apt.izzysoft.de/fdroid/repo/com.aurora.store_76.apk` (HEAD 200), refused `mips`
without transferring, and dropped an unpublished package, a non-repo URL and a repo root
with no `pkg-name`.
