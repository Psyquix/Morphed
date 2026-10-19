# 0014 — Only a config change that earns an artifact may force a rebuild

**Status:** accepted (2026-10-19)
**Affects:** `.github/scripts/retry_lib.sh` (`retry_tracked_keys`,
`retry_effective_cfg`, `retry_effective_kinds`, `retry_shape_*`),
`ci_detect_config_changes.sh`, `build_update_retry_list.sh`,
`state/built_shape.json` (now `channel → app → {arches, cfg}`), the new
`changed_apps.json`, the duplicate-build gate in `scripts/utils.sh`,
`state/build_content_hashes.json` (now `{hash, kinds}`),
`build_merge_hashes.sh`, `cleanup_artifact_hashes.sh`, and the announcement topic.
Extends [0010](0010-config-change-pending-builds.md); counterpart to
[0003](0003-blocked-patch-sources-are-skipped.md).

## Context

Run [39152256939](https://github.com/nullcpy/rvb/actions/runs/39152256939)
(2026-10-18, `data@855a4bee` → `4da3616d`) is the report this record answers. The
maintainer published `build-mode = "both"` for Google Maps. The watcher fired
`TRIGGER_CONFIG_CHANGE=1`, the stable pool regenerated, and the run built
`aCalendar-hxreborn` (a genuinely new app) and `Threads-HushThreads` (its patch
source moved). Google Maps came out as `enabled: false` and nothing was said about
it.

Nothing was broken in the machinery. `built_shape.json` remembers an app as a
**list of arches**, and `build-mode` moves no arch, so the diff was empty and the
queue stayed silent. The knob was published, read correctly, carried into the pool,
and then never used.

Two facts made it worse than a missing trigger:

- **A rebuild would not have been enough.** Google Maps' patched APK is unchanged,
  so `check_duplicate_build` matched its published fingerprint and returned "skip
  the whole table build" *before* the module stage ran. Suppressing on a
  same-arch hash is correct for a source that re-published nothing; it is wrong when
  the maintainer asked for a second artifact from the same bytes.
- **The retry state would have sealed it.** A skip writes no failure record, so
  `build_update_retry_list.sh` credits the arch as built. Fix only the trigger and
  every later run reads "already built" for an artifact that has never existed.

And the general shape of the bug was bigger than `build-mode`: **arch equality is
not config equality.** Re-pointing `patches-source` at a source that is already at
its latest tag, editing a pin, changing the patch selection — all invisible, for the
same reason. 0010 already noticed this class for *new* apps ("a new app on an
already-current source has nothing to re-resolve"); the same hole applies to an
already-built app.

## Decision

`built_shape.json` records, per app, **the config its last successful build was
produced from** — not just its arches:

```json
{ "stable": { "GoogleMaps-bearinmindcat": {
    "arches": ["arm-v7a", "arm64-v8a"],
    "cfg": { "app-name": "Google Maps", "pkg-name": "com.google.android.apps.maps",
             "arch": "both", "build-mode": "apk" } } } }
```

`cfg` holds only the **tracked** keys — the ones whose value changes what an
artifact is built from, or whether it is built at all. The list lives once in
`retry_tracked_keys()`; nothing else re-implements it.

### What earns a rebuild

| edit | rebuild? | why |
|---|---|---|
| patch source publishes a release; app version moves | ✅ as before | untouched by this record |
| `patches-source`, `patches-version` (pin), `cli-source`, `patch-folder`, `included`/`excluded`/`exclusive`/`inclusive-patches`, `patcher-args`, `brand`/`variant`/`sub-variant`, `app-name`, `pkg-name`, `arch`, `build-mode`, `version`, `version-code`, `dpi`, `include-stock`, `compression-level`, `module-prop-name`, `enable-module-update` | ✅ new | the tracked map differs |
| `both → apk` (a narrowing of `build-mode` or `arch`) | ❌ | no rebuild can un-publish; see below |
| any `*-dlurl` | ❌ | transport: the same version/versionCode/arch artifact arrives from another store. If a store ever serves different bytes, the build's own content fingerprint says so on the next real build |
| `enabled = false → true` | ❌ unless a tracked field also moved | see [0010](0010-config-change-pending-builds.md)'s prune: the queue entry is retired, the memory is kept, so a pure toggle describes an order that is already satisfied |
| `author`, `author-page` | ❌ | read from a config's file-level defaults only, never from an app block |

A **shape** change is judged by widening, not by difference: an `(arch, kind)` pair
the config asks for that no recorded build produced. `apk → both` adds
`arm-v7a:module`; `both → apk` adds nothing, so it queues nothing. Every other
tracked key is a difference in kind rather than in size, so any change counts.

### Two state files, two deliberate polarities

Both files carry values written before this record existed, and the readers must
guess in opposite directions:

- `built_shape` — an entry with **no `cfg`** is *no evidence*. The watcher records
  the current map and enqueues nothing. Guessing "unbuilt" would force-rebuild the
  whole pool the moment this deploys; guessing from the current config would forgive
  every edit published before the migration lands. This is 0010's per-channel
  cold-start guard, applied per app.
- `build_content_hashes` — a bare md5 string is *kinds unknown*, and unknown kinds
  **cannot justify a skip**. One extra publish is noise; a wrong skip is silent,
  terminal, and state-corrupting. `cleanup_artifact_hashes.sh`, being the only
  reader of real release liveness, is the only place a kind is removed — and the
  only place one can be re-proved, so a bare entry with live files is upgraded to
  `{hash, kinds}` there.

The polarity of `built_shape` makes the deploy order safe in both directions, but
the *truthful* baseline comes from reading what is actually published: the
`website` branch's `archive/<channel>.json` is existence-filtered by
`merge_archive_branch.sh` and every entry already carries `arch` and
`fileType` (`APK`/`Module`), so a one-off migration seeds `cfg` from live artifacts
rather than from the config's current wishes.

### The watcher never advances the baseline

Only `build_update_retry_list.sh` writes `cfg`, and only for an app that shipped
something. If the watcher advanced it, a failed rebuild would forgive the edit and
the change would be forgotten — the precise failure mode that made this bug
permanent rather than transient.

### The announcement says what changed

`changed_apps.json` carries the field diff (`{field, from, to}`) for the run that
first notices the change, on the same announcement topic as new apps — because a
maintainer who edited a config and sees a build appear with no word about why cannot
tell "my edit worked" from "my edit was ignored", which is how this went unnoticed.
An app woken by a config change is announced as a change, never as "New App(s)
Added". That distinction now runs one level deeper: `reason: "new"` means the app had
no `built_shape` record at all, where before it also covered an existing app that
newly asked for one more arch — so an app in the catalogue for a year could be
announced as an addition. Widening is a config change like any other, reported as
`Arch: arm64-v8a → arm-v7a, arm64-v8a` with the ABIs expanded per the existing rule
that routing keywords are never shown raw. The announcement fires once: a queue entry
that already carries the new
fingerprint keeps the app in the pool but stays quiet, or every scheduled run until
the build succeeded would re-announce one edit and the topic would stop meaning
"something changed just now".

## Rejected alternatives

- **Give `built_shape` arch×kind tokens and stop there.** It fixes `build-mode`
  specifically and leaves `patches-source`, pins and the patch selection in the same
  silent class — one bug per config key instead of one rule.
- **Store a hash of the whole compiled entry and rebuild when it moves.** A hash
  cannot be diffed, so the announcement could only say "config edited"; and hashing
  everything over-triggers, rebuilding apps over a dlurl typo. Both objections point
  at the same answer: store the values, and store only the tracked ones.
- **Store the entire compiled entry** (~445 B/app, 90 KB) to make every field
  diffable. The fields that would be missing from the narrower map cannot change an
  artifact, so the extra 55 KB buys noise.
- **Hash the module zip too, so its dedup can be per-artifact.** Zip packing has no
  measured cross-run hash stability, and `PATCHER_HASH_DEDUP_ELIGIBLE` exists
  precisely to withhold suppression power from a tool whose hashes wobble. One
  patched-APK fingerprint still stands for the app+arch's artifact set — the
  question is only whether every *requested kind* of that set is live.
- **Let partial publishing happen** (publish the module, suppress the unchanged
  APK). A release would then carry half an artifact set, and the manifest, notes and
  update pointers all assume the pair.
- **Add a `force-build` config flag.** The maintainer already has one: edit the
  config the build depends on. A second override for a broken signal hides the
  broken signal.

## Consequences

- `state/built_shape.json` grows from 15 KB to roughly 55 KB, and `cfg` maps appear
  for apps as they build even with no migration. Both files stay regenerable in the
  0010 sense: losing them costs the *precision*, never the artifacts, and the worst
  case one run is an extra publish, not a lost one.
- `build_content_hashes.json` values change type. The value **is** the version
  marker; there is deliberately no top-level `"schema"` key, because
  `[.[] | length]` aggregations in two CI steps would trip over a string. Nothing
  outside these three scripts and the engine reads the file — no website, manifest
  or asset-name impact.
- `cleanup_artifact_hashes.sh` must compare parsed documents, not entry counts: a
  kind trim changes content while leaving the count untouched, and a count-only test
  throws its own rewrite away silently. The harness caught exactly this before
  landing.
- A tracked key added to a config is only noticed by the diff if
  `retry_tracked_keys()` lists it. Trace case 19 closes that loop by requiring every
  key CONFIG.md documents to be either tracked or explicitly ignored, so a new key
  fails a test rather than silently landing in the "edits that look like they should
  rebuild but do not" class — which is the class this record is about.
- Known limits, deliberately left open: a narrowing does not republish anything;
  a tracked-field change that reproduces byte-identical artifacts is suppressed by
  the content fingerprint and the baseline advances — the release already holds what
  the config asks for, so nothing is lost, but the run is silent rather than
  confirming; and if cleanup prunes an app's artifacts while its `built_shape` entry
  stands, nothing re-triggers until a natural cause does. Publication correctness
  does not rest on `built_shape`: the kinds record, which cleanup does prune, is the
  gate.

## Verification

`.github/traces/test_config_rearm.sh` drives the real watcher over sandbox trees and
now covers, each with its paired negative control: `build-mode` widening enqueues
`reason: "config"` with the exact field diff and does **not** appear in
`new_apps.json`; narrowing enqueues nothing; a dlurl edit enqueues nothing; a
patch-source move enqueues and names the field; the same edit is not announced twice
by the next run; an entry with no baseline records
one, enqueues nothing and still gets committed; the watcher never advances a baseline
it just asked to rebuild; and every documented config key is classified.
`bash .github/traces/trace_runner.sh verify` guards the engine half. The dedup half
is a stubbed-binary harness in `temp/`: legacy bare md5 + requested `both` publishes;
`kinds:["apk","module"]` + identical hash skips; `kinds:["apk"]` + identical hash
publishes; `log`/`off` modes keep their current behaviour; the merge credits a kind
only for the spelling that reached `build/`; and cleanup trims, keeps and drops
entries according to live release assets.
