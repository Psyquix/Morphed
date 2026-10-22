# The stock-APK cache repository (`nullcpy/apks`)

A separate repository that stores the **upstream, unpatched** APKs and bundles the
builder downloads, so a version is scraped from a store once rather than once per
build, per architecture, per fork. This file documents rvb's side of it — the
contract. The contributor workflow (getting write access, the three equivalent
`upload_apks.*` scripts, renaming APKMirror downloads) belongs to
[the repo's own README](https://github.com/nullcpy/apks/blob/main/README.md).

```
      store / forge                 nullcpy/apks                    rvb build
   (APKMirror, Uptodown, …)   →   release per package name    ←   download source #1
                                       ↑        │
                          upload after a        │ read as `cache_repo`
                          fresh fetch           ↓
                                   usage.json  ←  used_versions.txt
```

## Layout

| Thing | Shape |
|---|---|
| Releases | **one release per Android package name**, tag = `com.facebook.katana`, title = the same, empty notes |
| Assets | `<pkg>-<version>[-<versionCode>]-<arch>.<ext>` |
| `<arch>` | `all`, `universal`, `common`, `arm64-v8a`, `arm-v7a`, `armeabi-v7a`, `x86`, `x86_64` |
| `<ext>` | `apk`, `xapk`, `apkm`, `apks` |
| `usage.json` | `"<pkg>-<version>"` → epoch seconds of last use, keys sorted (no version code, on purpose — see below) |
| Uploaders | `upload_apks.ps1` / `.sh` / `.py` (human-contributed), the rvb engine (automated) |
| Retention | `.github/scripts/cleanup-apks.py`, monthly (1st, 00:00 UTC) |

The version-code infix is what lets one app version exist per ABI when a store
serves different `versionCode`s per architecture (split APKs), instead of one file
claiming a code that only matches another.

## How rvb reads it

There is **no `cache_repo-dlurl` in any config** — the source is wired in at build
time. When `UPLOAD_APKS_REPO` is set and the app has a package name, `build_rv`
synthesises:

```bash
args[cache_repo_dlurl]="https://github.com/${UPLOAD_APKS_REPO}/releases/tag/${pkg_name}"
```

so `cache_repo` becomes download source #1 in the fixed `DL_SRCS` order
(`cache_repo → direct → github → archive → apkmirror → uptodown → apkpure →
apkcombo`) without a single app asking for it. Forking is a variable change
(`vars.APKS_REPO`), not a config edit.

Reading is deliberately narrow:

- **`get_cache_repo_resp`** lists the release's `.apk/.apkm/.xapk/.apks` assets via
  `releases/tags/<tag>`, and the whole response is memoised per URL in
  `__DL_RESP_CACHE__` so several architectures of one app cost one API call.
- **Version listing is never asked of the cache** — `get_cache_repo_vers` just
  echoes the tag it was given. The cache answers "do you have version X?", never
  "what is the latest X?". That keeps it from becoming a shadow source of truth
  about upstream releases, which is the watcher's job.
- Selection inside the release is by filename match against the requested version
  and architecture; a version/arch that is absent logs
  `Version <v> with arch <a> not found in cache_repo` and the run falls through to
  the next source. A release that cannot be read at all logs
  `Could not get response for <app> in cache_repo`.
- `github-release-regex`-style filtering is skipped for this source, and
  `dl_cache_repo` reads `args[cache_repo_regex]` (per-arch `arch: regex | …` form
  supported) which **nothing currently populates** — an extension point, not a live
  feature. Treat it as unwired until a config key exists for it.

A single-ABI artifact is only ever stored and served under its own ABI key — never
promoted to the shared `-all` name, which only a verified universal bundle may use.
A companion on-disk **download-link index** (`temp/urlindex`, per-run, outside
`apk_cache_dir`) records what an arch-blind store link (APKPure/APKCombo/Uptodown)
actually contains after the first fetch, so a sibling architecture neither
re-downloads it nor adopts it under the wrong name
([decisions/0007](decisions/0007-requested-arch-is-a-hard-requirement.md)).

## How rvb writes it

After a *fresh* download succeeds (never one that came from the cache itself, and
never one from `archive` — otherwise archive.org copies would be laundered into the
cache as if they were store originals):

```bash
gh release view "$pkg" || gh release create "$pkg" --title "$pkg" --notes ""
gh release upload "$pkg" <file> --clobber
```

with three attempts, because parallel jobs can race on the same tag between the
`view` (404) and the `create` (422 already exists). Failures warn and continue: the
cache is an optimisation, and losing an upload must not lose the build.

Then, once per build run, `update_usage_tracker.py` clones the repo shallowly,
stamps every key from `temp/used_versions.txt` with the current time, dumps the file
with sorted keys (see **File ordering** below) and pushes
`chore: update cache usage tracker`. It exits quietly when `APKS_REPO_TOKEN` or the
file is missing, and when nothing changed — so a run that hit only cache entries
still counts as usage, while a run that built nothing writes nothing.

## Retention (the part that decides what survives)

`cleanup-apks.py` runs on the 1st of each month at 00:00 UTC and works on **versions**,
not files:

1. Group each release's assets by stripping the `[-vc]-<arch>.<ext>` suffix, giving
   the same key shape as `usage.json`.
2. Score each version `max(newest asset created_at, usage.json timestamp)`; an
   untracked version is indexed into `usage.json` at its upload time.
3. Keep the **10** best-scoring versions per package unconditionally
   (`KEEP_COUNT`).
4. Beyond those ten, delete a version (all its assets) only when it has been
   inactive for more than **30 days** (`KEEP_DAYS`).
5. Drop `usage.json` keys whose assets no longer exist, so the file cannot grow
   without bound or resurrect a deleted version's score.
6. Rewrite `usage.json` with sorted keys and commit it back to `main` — but only when
   something actually changed.
7. On success only, the workflow's last step deletes its own oldest Actions runs and
   keeps the **10** newest. GitHub exposes nothing but day-based retention in settings,
   so a run-count cap has to be enforced from inside the workflow; a failed prune leaves
   the history untouched, which keeps the failing run's logs reachable.

The monthly cadence costs precision: the 30-day inactivity window is sampled once a
month, so a version is really evicted somewhere between 30 and ~61 days after its last
use — never earlier than the window, and the `KEEP_COUNT` floor covers the gap for
anything still in rotation.

Net effect: a version CI keeps consuming never ages out, recent versions are
protected even if unused, and the repo's storage cost tracks *live* demand instead
of how long the project has existed. This is a different, much more forgiving policy
than the archive releases' "2 newest versions per app+arch" — those hold patched
output for users, this holds stock input for builds.

## The usage key is `<pkg>-<version>` — never the version code

Retention only protects what it can recognise, so both sides must agree on one key,
and the shape is **`<pkg>-<version>` with the version code stripped**.
`cleanup-apks.py` derives it by removing `(-[0-9]+)?-(<arch>).(<ext>)` from the asset
filename — that optional numeric group exists precisely to drop a version code — and
`build_rv` writes `used_versions.txt` as `${pkg_name}-${version_f}`.

So all of these assets are **one version** to the retention pass:

```text
com.facebook.katana-573.0.0.37.74-473623755-arm64-v8a.apk ─┐
com.facebook.katana-573.0.0.37.74-arm64-v8a.apk            ├→ com.facebook.katana-573.0.0.37.74
com.facebook.katana-573.0.0.37.74-arm-v7a.apk              ─┘
```

That is what makes the per-ABI version-code split harmless to track: one app version,
one usage stamp, one keep-or-delete decision covering every artifact of it.

The trap, documented because it was walked into on 2026-09-29: appending the version
code to the usage key "so it matches the filename" looks like an obvious consistency
fix and silently untracks the version instead — cleanup never derives such a key, so
the version is scored by `upload time` alone and starts expiring after 30 days no
matter how often CI pulls it, while the phantom key is deleted as a ghost entry at the
next monthly run. Verified against the live repo: every asset under
`com.facebook.katana`, including its version-code-named ones, resolves to a
bare-version key that exists in `usage.json` with a current stamp.

What genuinely must stay in step is the **other** end of the name: change the
`-<arch>.<ext>` suffix pattern, or the arch/extension vocabulary, and the strip stops
matching — those assets then never group at all, which is both unprunable and
invisible. The version code is the one component the key intentionally ignores.

## File ordering: both writers sort

`usage.json` is machine-managed state that **two** workflows rewrite and push to the
cache repo's `main` — `update_usage_tracker.py` here after every build run, and
`cleanup-apks.py` on the monthly prune. Both dump with `sort_keys=True`, so a commit
contains only the versions whose stamp actually moved.

Without sorting, JSON order is insertion order: a key that already exists keeps its
old line wherever it happens to sit, while every newly indexed version lands at the
bottom. The files then drift apart between the two writers, and one of them eventually
re-scrambles the whole file into a reorder commit that hides the handful of meaningful
lines — and a build push racing the monthly prune conflicts on a difference that is not
a difference. Sorting also keeps the file legible when you read it after a cache miss:
every version of one package sits on consecutive lines.

The convention only holds while both sides agree: drop `sort_keys` in either writer and
the other's next run produces the reorder again. Keys are ASCII package names, so the
order is by Unicode code point and identical on every runner; neither writer adds a
trailing newline. Do not hand-edit the file to add an entry — an untracked version is
indexed automatically at its upload time, and a key whose asset does not exist is
pruned as a ghost entry at the next monthly run.

## Debugging checklist

```bash
# is the package cached at all, and under what names?
gh api --paginate repos/nullcpy/apks/releases/tags/<pkg> -q '.assets[].name'
# does cleanup think it is used? (from a clone of the cache repo)
jq -r '.["<pkg>-<version>"] | if type=="number" then todate else "untracked" end' usage.json
# what did the last build actually consume?
#   temp/used_versions.txt on the runner, and the "Uploading newly downloaded APKs
#   to nullcpy/apks" line in the Build step log
# which source served the app?
#   "Downloading '<app>' from '<source>'" in that app's ::group:: block
```

Missing cache entries are never an error — they cost a scrape. A *wrong* entry is:
`verify_downloaded_apk` and the version-code check reject a mismatched payload and
the source falls through, so a corrupt asset degrades to a fresh download rather
than poisoning the build.
