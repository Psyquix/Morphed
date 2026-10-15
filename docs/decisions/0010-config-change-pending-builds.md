# 0010 — Config changes and build failures drive a pending-build list

**Status:** accepted (2026-10-15)
**Affects:** `.github/scripts/ci_generate_configs.sh`, `ci_trigger_flags.sh`,
`ci_resolve_triggers.sh`, a new `ci_detect_config_changes.sh`, a new
`build_update_retry_list.sh`, `state/built_shape.json`,
`state/pending_builds.json`, the watcher's trigger flags, and the build job's
data-commit steps. Counterpart to [0003](0003-blocked-patch-sources-are-skipped.md)
(a blocked source is *skipped*; this record is about what gets *re-queued*).

## Context

The watcher decides which apps to build from three signals: a patch source
published a release (`TRIGGER_STABLE`/`TRIGGER_BETA`), an app's own version moved
(`TRIGGER_APP_UPDATE`), or a source was blocked/unblocked (`TRIGGER_BLOCKED`).
Two real gaps fall through that net:

1. **A brand-new app is never built.** `state/app_versions.json` runs with
   `_check_only_listed = true`, so `ci_fetch_app_versions.sh` only re-checks apps
   already tracked there. A freshly added app has no tracked version, is never
   fetched, never raises `TRIGGER_APP_UPDATE`, and sits unbuilt until its patch
   source happens to publish again — which may be never for a source already at
   its latest tag.

2. **A failed build is not retried, and a stale failure is retried forever.**
   A download that fails on a transient cause (Cloudflare, scraper, a slug the
   engine has since learned to resolve) produces no artifact and no follow-up:
   the next run only rebuilds the app if some unrelated trigger happens to fire.
   Conversely, a failure that will never succeed — e.g. an app requesting an
   architecture no store publishes (MacroDroid `arm-v7a`) — is noise if it is
   re-attempted on every scheduled run.

Both are, at bottom, the same question: **has the config changed relative to what
we last actually built, and did the last build of it fail?**

## Decision

Introduce two regenerable files on `data` and one reconciliation step on each
side of the pipeline.

- **`state/built_shape.json`** — per channel, `app key → sorted effective-arch
  list`: the shape of the config the last *successful* build of each app was
  produced from. This is the memory that makes "new" and "arch removed"
  computable, and it is what keeps a new app from being re-flagged every run.
- **`state/pending_builds.json`** — per channel, `app key → {reason, arches,
  attempts, parked, run, ts}`, `reason ∈ {new, retry}`: the union of "build this
  because the config changed" and "build this again because it failed".

**Watcher** (`ci_detect_config_changes.sh`, after base configs compile and before
trigger classification) diffs the compiled config's effective `(app → arch set)`
against `built_shape`:

- an app key absent from `built_shape`, or an arch newly requested for an app →
  enqueue `reason: new` (force-enable);
- an app removed from the config, or a **failed arch no longer requested** →
  prune that pending entry (MacroDroid switched `both → arm64-v8a` drops its
  `arm-v7a` retry);
- a pending `retry` entry whose `attempts` reached the cap is **parked** and not
  force-enabled, but is **re-armed** (attempts reset) when a natural trigger or a
  config change touches that app again.

The pending set is a trigger of its own (`TRIGGER_CONFIG_CHANGE`): it feeds
`ANYTHING_CHANGED`, forces the affected pool to regenerate, and — because
`ci_resolve_triggers.sh` counts enabled apps — makes the build job run even when
nothing else moved. `ci_generate_configs.sh` force-enables pending keys, but never
one the human set `enabled = false` in the TOML.

**Build job** (`build_update_retry_list.sh`, after the failure report) reconciles
the two files from what just happened: attempted `(app, arch)` pairs with no
failure record move into `built_shape` and drop out of `pending`; failed pairs are
upserted into `pending` with `reason: retry` and `attempts + 1`. It commits them
to `data` alongside the artifact hashes.

Effective arch is resolved with the same precedence the build uses —
`app.arch // file-level default // "both"` — and normalised to a set
(`both → {arm64-v8a, arm-v7a}`, `all`/`auto` → universal), because the compiled
config only carries `arch` when it is explicitly set (an inherited `both` shows
as `null`).

## Rejected alternatives

- **Flip `enabled = true` in the human TOML to retry.** `configs/**/*.toml` is the
  sole copy of human intent and is never machine-written to `data`; a bot must not
  edit it. The generated `*_build.json` pool is the machine's surface.
- **Rely on `patches-version` re-resolution instead of a new trigger.** A new app
  on an already-current source has nothing to re-resolve; this is exactly the gap.
- **Retry every failure unconditionally, forever.** Six scheduled runs a day
  re-attempting an architecture that no store carries is churn and notification
  noise; hence the cap, the park, and the arch-removal prune.
- **Store the pending list in the generated `*_build.json`.** That file is
  regenerated from scratch each run and is not the right home for cross-run memory;
  `state/` is the designated place for regenerable CI state.

## Consequences

- `built_shape.json` and `pending_builds.json` are **regenerable** like the rest of
  `state/`: deleting them only loses the new/retry memory, and the next successful
  build of each app rebuilds `built_shape`. They are committed by the existing
  `commit_data_branch.sh` glob (`state/*.json`) with no change to that script.
- `commit_data_branch.sh` can add files but never deletes them, so pruning a
  pending entry means rewriting the JSON, not removing a file — handled inside the
  two state files, never as separate per-app files.
- The build job becomes a second writer to `data` for these files; the `ci` and
  `build` concurrency groups plus the existing push-retry loop keep the two
  writers serialised.
- A parked entry is invisible in the pool but still on `data` for audit; "why isn't
  my app rebuilding" is answered by `pending_builds.json`, not by a build log.

## Verification

A stubbed-binary harness in `temp/` drives `ci_detect_config_changes.sh` and
`build_update_retry_list.sh` over fixture configs and `temp/failures` records,
covering: new app → enabled then cleared after success; failed arch removed →
pruned; cap → parked; re-arm on config change. A **negative control** asserts an
unchanged config with no failures leaves both files byte-identical, and that an
empty pending set makes the generated pool identical to today's. See
`.github/traces/README.md` and [ci-pipelines](../ci-pipelines.md).
