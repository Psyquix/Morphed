# CI pipelines

Six workflows in [.github/workflows](../.github/workflows). One watcher decides
*whether* to build; the reusable build job does the building; cleanup keeps
GitHub's limits; notify reports failures.

| File | Name | Triggered by | Concurrency group |
|---|---|---|---|
| [ci.yml](../.github/workflows/ci.yml) | CI | `schedule` (6 UTC crons: ~4 h windows with randomized minutes), `workflow_dispatch` | `ci` |
| [build.yml](../.github/workflows/build.yml) | Build | `workflow_call` only — from `ci.yml` (per pool) or `manual-ci.yml` | `build` |
| [cleanup.yml](../.github/workflows/cleanup.yml) | Cleanup | `workflow_call`, `workflow_dispatch` | `clean` |
| [manual-ci.yml](../.github/workflows/manual-ci.yml) | Manual CI | `workflow_dispatch` (config choice, optional `remove_apks`, `disable_dedup` checkbox) | `ci` |
| [notify.yml](../.github/workflows/notify.yml) | Notify | `issues`/`pull_request` (debounced batch), `workflow_call` (immediate, when a needed job of the caller ended in `failure`) | drain: `notify-debounce` |
| [trace-verify.yml](../.github/workflows/trace-verify.yml) | Trace Verify | `push` touching `scripts/build.sh`, `scripts/utils.sh`, `scripts/apkmirror_search.py`, `scripts/uptodown.py` or `.github/traces/**` | `trace-verify` |

Nothing here runs on `push` to `main` except Trace Verify: a push changes
behaviour for the *next* scheduled run, it does not start a build.

The watcher's schedule is a set of 6 UTC crons, one per 4 h window (`0,4,8,12,16,20`),
each with its own randomized minute. GitHub's `schedule` trigger is best-effort —
under load a due run is enqueued late, and a tick that was missed is dropped rather
than back-filled (measured here at 3-4 runs a day against a 4 h cron, each 40 min to
3.5 h late) — so widening the window to 4 h trades redundancy away: a dropped tick
can now leave a gap of up to ~4 h instead of the ~2 h the earlier grid tolerated. The
watcher is idempotent, so an extra tick costs only the check steps unless something
actually moved. Spreading the minutes across each window takes ticks off the
contended :00 and keeps every run off the website's `23 */6` rebuild (no window
shares minute 23). Cadence is still not a guarantee — when a check must happen now,
`manual-ci.yml` is the path.

## The watcher (`ci.yml`)

One job, `check_patch`, decides everything downstream. Order matters because each
step's output is the next step's input:

| Step | Script | What it decides |
|---|---|---|
| Fetch configs & state | `fetch_data_branch.sh` | hard-fails if `data` is missing — no silent fallback to stale state |
| Compile Base Configs | `compile_patch_configs.py` | every app's pool membership from `configs/patches/*.toml` |
| Sync Patch Sources | `sync_patch_sources.py` | discovers all `(patches-source, host)` pairs, lists releases on GitHub/GitLab/Codeberg, rewrites `state/patch_sources.json`, prunes sources no config uses, emits `TRIGGER_STABLE`/`TRIGGER_BETA`/`TRIGGER_BLOCKED` and writes `changed_sources.json` |
| Fetch App Versions | `ci_fetch_app_versions.sh` | scrapes current store versions (honours `"_check_only_listed"` in `state/app_versions.json`) |
| Compare App Versions | `compare` step | `TRIGGER_APP_UPDATE` when a tracked app moved |
| Detect config changes | `ci_detect_config_changes.sh` | always runs: diffs the compiled config against `state/built_shape.json` — its arch set **and** each app's tracked config map — enqueues new apps/arches (`reason: new`), apps whose tracked config moved (`reason: config`, with the field diff written to `changed_apps.json`) and carried-over retries into `state/pending_builds.json`, prunes queue entries whose app/arch left the config (the `built_shape` memory is kept, so re-enabling an app is not a new build request), **re-arms** an entry whose app config changed since it was written (`cfg` fingerprint: attempts reset, park lifted), and emits `TRIGGER_CONFIG_CHANGE` — which means "the watcher's state moved", not "build this": it is the only signal that gets `state/*.json` committed to `data`, and whether a run starts is decided downstream by the enabled-app count in the pool (why: [decisions/0010](decisions/0010-config-change-pending-builds.md), [0014](decisions/0014-config-changes-that-earn-a-rebuild.md)) |
| Classify triggers | `ci_trigger_flags.sh` | the two questions everyone else asks: `SOURCES_CHANGED`, `ANYTHING_CHANGED` (config change counts toward the latter, never the former) |
| Check Patch App Updates | `ci_check_app_patches.py` | only when `SOURCES_CHANGED`: downloads the changed bundles and hashes them (`state/patch_file_hashes.json`) to find which apps the new patches actually cover |
| Generate configs (JSON) | `ci_generate_configs.sh` | only when `ANYTHING_CHANGED`: writes the pool config each channel will build |
| Resolve effective triggers | `ci_resolve_triggers.sh` | per-channel `TRIGGER_*` **after** generation, and downgrades a trigger to 0 when the resulting pool has no enabled apps |
| Notify telegram | `ci_notify_telegram.sh` | raw vs effective triggers, so a suppressed trigger is visible |
| Notify build queue | `ci_notify_queue.sh` | ONE message on the log topic (`TG_THREAD_NOTIFY`) naming every app this run will actually build: the enabled keys of the regenerated pools, as `📱 Name (brand • variant)` blocks grouped under `[owner/repo/tag](release page)` headers. It reads the **effective** triggers, not the raw ones, so a channel `ci_resolve_triggers.sh` downgraded for want of enabled apps contributes nothing (the watcher is also the last place both pools are visible together — each build job sees only its own config). The tag is the one the build would resolve: the app's own `patches-version`, else the pool's channel, answered from `state/patch_sources.json` the same way `_patch_source_state_tag` answers it. An app with nothing to build from is **not queued and not listed** — a source the snapshot marks `blocked` is skipped by the engine before it resolves any version, and a channel with no tag recorded for that source has no bundle to patch (a stable-only repository therefore contributes no beta line) — each skip is written to the step log so a missing app is explainable. A pool whose every app is filtered out sends nothing |
| Notify announcements | `ci_notify_announcements.sh` | ONE message on the NullStore announcement topic (`TG_THREAD_ANNOUNCE`) covering both things the watcher can cause: apps added to the config (`new_apps.json`) and apps it woke because their tracked config moved (`changed_apps.json`, printed as the field diff, e.g. `build-mode: apk → both`). No-op when neither has anything; one send per run, not two notices chasing each other |
| Commit updated state | `commit_data_branch.sh` | pushes **only** `*.json` under `configs/` + `state/` to `data` |

Two design rules worth preserving:

- **`changed_sources.json` is written once**, by the sync step
  (`derive_source_changes.py`). Config generation, the patch-relevance scan and
  the trigger flags all project from that one record, so three steps can never
  disagree about what moved.
- **Generation is membership-only.** `ci_generate_configs.sh` sets
  `enabled = false` for apps outside this run's change set and never rewrites a
  version: an app whose `patches-version` is a channel keyword keeps the keyword,
  resolved at build time against `state/patch_sources.json`. Stamping a concrete
  tag into the pool config used to create a second artifact that had to agree
  with the state snapshot about what "stable" meant.
- The beta pool keeps one extra gate: an app-version bump alone pulls an app into
  beta only when one of its sources genuinely has `beta_date > stable_date`,
  otherwise the stable pool already covers it.

### What causes a build

| Event | Flags | Effect |
|---|---|---|
| A patch source publishes a release on the stable channel | `TRIGGER_STABLE` | stable pool regenerates and builds |
| …on the beta channel | `TRIGGER_BETA` | beta pool only |
| An app's own version changed in a tracked store | `TRIGGER_APP_UPDATE` | both pools reconsider membership (beta gated as above) |
| A source is blocked or unblocked (`404`/`451`/`403` from the forge) | `TRIGGER_BLOCKED` | regenerates membership, so frozen sources drop out and recovered ones return |
| The config gained a new app or a new architecture, **or** a previously-failed build is still owed a retry, **or** an app's own config changed under a parked entry (re-arm) | `TRIGGER_CONFIG_CHANGE` (non-parked pending list) | pool regenerates with the pending apps force-enabled, and the build runs even though no source or version moved (why: [decisions/0010](decisions/0010-config-change-pending-builds.md)) |
| Nothing moved | all `0` | no config write, no notification, no build |

A blocked source is **skipped**, not retried: neither a retry nor a live listing
recovers a repository that is gone, and the app reappears by itself once the
forge answers again. The deliberate fail-open inside that check is recorded in
[decisions/0003](decisions/0003-blocked-patch-sources-are-skipped.md).

### Ordering and safety rails

- `build_beta` runs first; `build_stable` `needs` it and additionally requires the
  watcher to have succeeded and beta not to have been cancelled. The single
  `build` concurrency group therefore serialises every manifest merge against the
  `website` branch — two builders never merge at once.
- `trigger_cleanup` runs on `always()` if either build succeeded.
- `trigger_notify_failure` runs on `always()` plus an explicit `== 'failure'` test on
  each of `check_patch`, `build_beta` and `build_stable`. Two separate traps shaped
  that line:
  - `always()` is load-bearing, not stylistic. GitHub skips a job whose needed job was
    **skipped** unless the condition begins with `always()`, and a `check_patch` failure
    leaves both build jobs skipped. Under a bare `failure()` the one failure that gates
    every build was the one that announced nothing (run 39261459573, killed by a typo'd
    config key in "Compile Base Configs").
  - The results are named one by one because `contains(needs.*.result, 'failure')` at
    JOB level is unreliable — a runner bug open since 2021
    ([actions/runner#1540](https://github.com/actions/runner/issues/1540)): a job-level
    condition does not evaluate the wildcard from the same values the identical
    expression shows at step level. Run 39263204435 carried that form and still skipped
    the job while `check_patch` was in `failure`. `trigger_cleanup` two entries above
    is the working precedent for the named form.

  Comparing to `'failure'` rather than `!= 'success'` keeps the ordinary quiet night
  silent: with nothing to build, `build_beta` ends `skipped`, which is not a failure —
  and a `cancelled` run is not news either.
- `ci_trigger_flags.sh` writes outputs with explicit `if` blocks rather than
  `[ … ] || [ … ] && var=` lists on purpose: under `set -e` a short-circuit list
  whose final command never runs exits non-zero and would kill the step *before*
  it wrote its outputs, silently turning every dependent step into a no-op.

## The build job (`build.yml`)

Called once per pool with `config_file` (and optional `remove_apks`, plus
`disable_dedup` from Manual CI). Everything it needs to be reproducible lives in
that one file, including the tuning knobs —
`PARALLEL_JOBS: "6"` and `UPLOAD_CONCURRENCY: "12"` are workflow env values, not
repo variables, so they are visible in PRs, survive forks, and carry git history
(why: [decisions/0005](decisions/0005-tuning-knobs-live-in-the-workflow.md)).

Step order, with the reason each is where it is:

1. Java 21 (Temurin) → checkout `main` with `fetch-depth: 0` and submodules (full
   history is needed to enumerate existing tags and to commit to other branches) →
   `fetch_data_branch.sh`.
2. `build_resolve_context.sh` maps the config file to `ARCHIVE_TAG`,
   `IS_PRERELEASE`, `TITLE_SUFFIX` and the Telegram thread — the single owner of
   "which channel is this run".
3. Install Bouncy Castle **only if** `patchers.py needs-bks` says an app in this
   config is patched with NPatch — the only tool that asks the **JVM** for a BKS
   keystore type (single-argument `KeyStore.getInstance("BKS")`). ReVanced CLI and
   Morphe also work in BKS but carry their own provider inside their jar, and
   LSPatch uses `getDefaultType()`, so none of them trigger this step. A stock
   Temurin has no BKS type, so getting the gate wrong either way is visible: skip
   it for an NPatch config and patching dies on `KeyStoreException: BKS not found`.
4. `install_keystore.sh` writes the signing identity from the four `KEYSTORE_*`
   secrets and **fails the run** if any of them is absent: there is no keystore in
   the repository to fall back on (the template's shipped a public private key), and
   silently signing with it would make every build here updatable by anyone holding
   the same template. It also checks the BKS magic and that `KEY_ALIAS` is readable
   with `KEYSTORE_PASSWORD`, so a wrong secret stops the job here rather than at the
   first patch. `build.sh` then re-checks the identity before any download.
5. `build_resolve_version.sh` computes `NEXT_VER_CODE` (`YY` + the next 4-digit
   sequence above the highest existing tag/release, e.g. `260141`).
6. Restore the Actions APK cache (`temp/apks`), optionally drop named APKs, then
   `pip install curl_cffi` for the store scrapers. The Cloudflare-bypass sidecar
   runs as a job `service` on `:8000`.
7. `scripts/build.sh <config>` — the engine ([build-engine.md](build-engine.md)).
   `UPLOAD_APKS_REPO` + `APKS_REPO_TOKEN` turn on the shared cache repo;
   `RVB_MORPHE_PASSTHROUGH`, `RVB_DEDUP_MODE` and the `RELEASE_NOTES_*_LINK`
   vars are passed here. On any per-app failure the engine writes a record to
   `temp/failures/` (kept across the run's end, wiped at start), which the next
   step consumes. An app whose freshly patched APK matches its published
   fingerprint (`state/build_content_hashes.json`, `RVB_DEDUP_MODE=enforce`) is
   skipped before module packaging and recorded under `temp/unchanged/` — a
   skip, not a failure; it never reaches the failure report. The job env derives
   that knob from `inputs.disable_dedup`: ticked, a Manual CI run demotes to
   `log`, so a match is still reported but nothing is withheld and the app
   publishes anyway; every other caller gets `enforce`. The match only
   suppresses when every artifact kind the build was asked to publish is already
   live on the record, and a bare-md5 entry (kinds unknown) never suppresses at
   all — see [build-engine.md](build-engine.md).
7b. **Report build failures** (`build_report_failures.sh`, `if: always()`,
   `continue-on-error`): reads `temp/failures/`, uploads each build log to
   `xi.pe`, and posts ONE batched Markdown message to the failure topic
   (`TG_THREAD_NOTIFY`) in up to three sections — apps that failed to **build**
   (`<slug>.json`, with the log link and patch source), apps where **the patcher
   itself aborted** (`<slug>_pf.json` + `<slug>_pf.log`: the engine skips with rc 0,
   so the plain descriptor is wiped as a clean return and only this survivor pair
   reaches the report; rendered in the same Build Failed section), apps the patch set
   **refused for every supported version** (`<slug>_np.json`: the tried versions and
   the bundle link, and deliberately no APK search links, since nothing was ever
   fetched), and apps whose **download sources were all exhausted**
   (`<slug>_dl.json`, a request to upload the APK to the cache repo manually), plus a
   link to the run. A slug that has a build record has its `_dl`/`_np`/`_pf` twins
   dropped, so an app is reported once. When it sends, it sets the job output
   `reported_failures=true`, which
   `trigger_notify_failure` forwards as `already_reported` so
   `notify_send_telegram.sh` skips the generic "🔴 CI #N failed" alert for that
   run (Route B) — non-build failures still notify normally.
7b2. **Reconcile pending-build state** (`build_update_retry_list.sh`,
   `if: !cancelled()`): reads the same `temp/failures/` records and updates
   `state/built_shape.json` + `state/pending_builds.json` for this channel. **Only
   download exhaustion (`_dl`) is retried**: a `_dl` arch still requested is re-queued
   as a retry and parked once it hits `RVB_RETRY_MAX`. Every other failure class — a
   build abort (`<slug>.json`), a patcher abort (`_pf`) and a patch-set rejection
   (`_np`) — is **settled, not retried**: re-running the same engine over the same
   inputs reproduces the same abort, so it spends a build slot to learn nothing. The
   fix for those is a patch-bundle release or a config edit, and both already
   re-trigger the app independently (`TRIGGER_STABLE` / the watcher's re-arm), so the
   retry queue has nothing to add. A settled arch is merged into `built_shape` (its
   tracked config map stamped from the pool it just built) so neither the retry queue
   nor the watcher's "arch never built → reason new" path re-nags it every run; the
   baseline is held back only for an arch that still owes a download retry, or the
   pending retry would forgive the very edit it is re-queuing (decisions/0014). The
   entry is merged, not
   replaced, so the watcher's `cfg` fingerprint survives the attempt — dropping it
   would make every run look like a config change and re-arm the app forever. A
   dedicated commit step
   pushes the two files to `data`. The watcher reads them next run to force-enable
   the queue (step 7c of `check_patch`, [above](#the-watcher-ciyml)).
7c. **Check whether anything needs publishing** (`build_check_no_change.sh`):
   `build/` empty plus `temp/unchanged/all.txt` (every artifact this pool built
   was an unchanged duplicate) → `HAS_NEW_FILES=false`, and steps 9–16 are all
   skipped — no numbered release, no manifest, no pointers, no archive upload,
   no website merge, no notification. The build number reserved in step 5 is
   simply unused: the counter reads existing releases/tags, so a no-change run
   leaves no gap. Anything else (including a failed build, which aborts before
   this step) keeps the chain enabled — the guard fails toward publishing,
   never toward silence. A no-change run also publishes no fingerprints: the
   already-live files match the state entries that suppressed them.
8. `update_usage_tracker.py` (`|| true`), `build_cache_cleanup.sh`, then the cache
   manifest (`size name` pairs) is hashed into the save key so a run that changed
   nothing does not re-upload 8 GB.
9. `build_get_output.sh` lifts `build.md` into a step output (and `build.tmp`,
   which the changelog step prefers as the source so the next build's `build.md`
   append does not corrupt it).
10. `build_make_manifest.py` → `temp/manifest/build.json`.
11. **Upload to release** (numbered): title `Build No. <code>`, body from
    `build.md`, `--prerelease` for beta.
12. **Update changelog and module update files**: `build_update_changelog.sh`
    checks out `update`, writes `changelogs/<code>.md` plus one JSON pointer per
    module zip, and lists the exact paths it created in `.updated_pointers`. The
    next step stages *those* paths explicitly — a `git add -A` on that branch
    would sweep in unrelated dirt. Runs only when modules were built.
13. `git checkout -f main` (dropping the `update` checkout) →
    `build_exclude_from_archive.sh` removes opted-out apps from `build/`.
14. **Upload to release (Archive)**: `continue-on-error: true`, assets only. It
    names no metadata at all, which is deliberate —
    [decisions/0001-release-metadata-ownership.md](decisions/0001-release-metadata-ownership.md).
15. `merge_archive_branch.sh` merges this build's manifest into the `website`
    branch. Must run **after** the archive upload so its live-asset filter sees the
    new files. Why manifests live on a branch at all:
    [decisions/0002](decisions/0002-manifests-live-on-a-branch.md).
16. **Merge published content hashes into state** (`build_merge_hashes.sh`):
    folds the fingerprints the engine recorded in `temp/hashes/append.*.tsv`
    into `state/build_content_hashes.json` — but only when the upload chain
    got through (the step also requires the archive upload not to have failed),
    and **per line**: a stem is adopted only when the artifact it stands for
    actually shipped (`build/` holds its `.apk` or module-`.zip` spelling) or it
    already has a state entry. The engine hashes at patch time, and a per-app
    stage after it (module packing, stock merge) can still fail while the run
    overall succeeds — without this filter a failed build would seed a
    fingerprint for a file nobody published. A hash becomes authoritative
    exactly when its artifact is live, per app, not per run. Kinds are credited
    the same way and **per spelling**: the entry keeps the kinds it already
    recorded plus `apk`/`module` for whichever of the two filenames reached
    `build/` this run, so a run whose module zip failed to pack cannot mint the
    evidence that would suppress a module later.
    `commit_data_branch.sh` then pushes the state file to `data` (only when the
    merge changed it; a failed data push is a warning, not a failure — the next
    run's fetch converges and the worst case is one redundant republish).
17. `build_notify_telegram.sh` posts the release to the channel's thread and to the
    broadcast channel. `continue-on-error`: the chat, the channel and the topic come
    from variables only (no built-in handle), so an unset one fails this step — but
    the step runs last, after publishing, and a notification-config error must not
    turn a run whose files are already live into a failed build.

## Cleanup (`cleanup.yml`)

1. `ophub/delete-releases-workflows` deletes releases and tags, keeping the newest
   **98** and anything matching the keyword `stable`/`beta` — that keyword list is
   the only thing protecting the archive releases from deletion.
2. `cleanup-archive-assets.py` prunes each archive to the **2 newest versions per
   app + architecture** (grouping by `<app>-<arch>.<ext>`, newest by `created_at`).
3. `cleanup_update_branch.sh` drops update pointers and changelogs whose release is
   gone; `cleanup_website_branch.sh` drops `manifests/<tag>.json` for deleted
   releases.
3b. `cleanup_artifact_hashes.sh` prunes `state/build_content_hashes.json` against
   what actually lives on the releases (matching the `<stem>.apk` and
   `<…>-module-v<…>.zip` spellings, case-insensitively) — per spelling, so each one
   proves its own kind: an entry keeps exactly the kinds still downloadable and is
   dropped entirely when none survives. Being the only reader of real liveness, it
   is also the only place a lost kind can be re-proved, and it upgrades a bare-md5
   entry to `{hash, kinds}` from the asset names rather than leaving it unknown.
   This is a guard on the duplicate-build check, not tidying: an entry is the
   evidence that lets a rebuild be suppressed, so evidence for a deleted file must
   go with the file —
   otherwise a pinned rebuild would be "skipped" as identical to something
   nobody can download. It runs **after** the asset deleters so entries pruned
   in the same pass lose their guard in that pass; a failed releases listing
   aborts it loudly rather than pruning against an empty set. When it changed
   the file, `commit_data_branch.sh` pushes the pruned state to `data`.
4. A `catalog-updated` `repository_dispatch` to `vars.WEBSITE_REPO`
   (default `nullcpy/nullcpy.github.io`), authenticated with
   `WEBSITE_DISPATCH_TOKEN` falling back to `APKS_REPO_TOKEN`. `continue-on-error`,
   because the site also rebuilds on its own schedule — a lost dispatch delays the
   catalogue, it does not break it.

## Notify (`notify.yml`)

Two delivery models sharing one renderer (`notify_render.sh`) and one target guard
(`notify_targets.sh`):

- **`workflow_call` — immediate.** A caller (`ci.yml`/`manual-ci.yml`) invokes it on
  `failure()`; the `notify` job renders the generic "🔴 CI #N failed" alert via
  `notify_send_telegram.sh` and posts it at once. When the caller passes
  `already_reported=true` (Route B — the build's own Report-build-failures step
  already sent a per-app report) the script exits without posting, so a build
  failure is never double-messaged. Non-build failures (checkout, `check_patch`)
  never set the flag and still alert.
- **`issues` / `pull_request` — debounced batch.** GitHub fires one run per event and
  runs cannot share memory, so a burst (several issues closing at once) would
  otherwise post one message each. The `enqueue` job instead renders the event and
  appends it to `queue.jsonl` on the orphan `notify-queue` branch (self-created on
  the first append; the push-retry loop merges concurrent appends and never
  force-pushes), and the `drain` job — under concurrency `notify-debounce`,
  `cancel-in-progress: false` — sleeps `NOTIFY_DEBOUNCE_SECONDS` (60) then posts
  ONE batched message and prunes exactly the drained prefix. Later queued drains
  find the queue empty and no-op.

The log topic (`TG_THREAD_NOTIFY`) carries two independent messages, not one combined
report: the build job's per-app failure report and the watcher's build-queue notice are
sent by different steps, in different runs of the pipeline, and folding them together
would make a clean build that is about to happen announce nothing.

**No notification script names a chat.** Every `TG_*` target arrives from a
repository variable, and `tg_require_targets` refuses to send when one is unset:
the step fails with an `::error::` listing the missing names and no message goes
out. It used to be `${TG_CHAT_ID:-@handle}` / `${TG_THREAD_*:-<number>}` defaults at
each send site, which meant a renamed group or a misspelled variable kept posting to
the stale chat instead of saying so. A missing topic ID is an error too, not "no
thread" — in a forum group Telegram routes a threadless message to General, which
looks like a delivered notification. The guard runs after the `TG_TOKEN` skip (a
fork with no token still exits 0 quietly) and after each script's own "nothing to
send" early exit, so a clean run never fails over config nobody needed; a failed
drain leaves its queue lines on the branch for the next attempt.

The queue is append-only and every plumbing call pins `core.autocrlf=false` /
`core.eol=lf`, so the JSONL bytes (and the drain's prefix prune) do not depend on
the runner's git config.

## Required secrets and variables

| Kind | Name | Used by | Notes |
|---|---|---|---|
| secret | `GITHUB_TOKEN` (auto) | all | `contents: write` on the jobs that push branches |
| secret | `KEYSTORE_B64`, `KEYSTORE_P12_B64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS` | build | signing identity; **all four required** — `install_keystore.sh` fails the run when any is missing and no keystore ships in the repo ([decisions/0008](decisions/0008-signing-identity-is-secret-only.md)) |
| secret | `APKS_REPO_TOKEN` | build, cleanup | cross-repo write to `nullcpy/apks`, doubles as dispatch token |
| secret | `CODEBERG_TOKEN` | watcher | raises Codeberg/Forgejo rate limits |
| secret | `TG_TOKEN`, `WEBSITE_DISPATCH_TOKEN` (optional) | notify steps | |
| var | `APKS_REPO`, `WEBSITE_REPO` | build, cleanup | alternate cache/site repos for forks |
| var | `TG_CHAT_ID`, `TG_CHAT_ID_BROADCAST`, `TG_THREAD_CI`, `TG_THREAD_STABLE`, `TG_THREAD_BETA`, `TG_THREAD_NOTIFY`, `TG_THREAD_ANNOUNCE` | notifications | the chat handle and every topic ID come from here only, and an unset one fails its notify step (see the target guard above) instead of falling back to a written-in chat; `TG_THREAD_NOTIFY` is the log topic and receives two separate kinds of message — the per-app build/download failure report, and the watcher's build-queue notice listing what the run resolved to build; `TG_THREAD_ANNOUNCE` is the announcement topic — config additions and config-change rebuild notices together (that step is `continue-on-error`, so an unset one only skips the notice). It replaced `TG_THREAD_NEWAPPS`, which pointed at the same topic under the narrower name |
| var | `RELEASE_NOTES_DISCORD_LINK`, `RELEASE_NOTES_DONATE_LINK`, `RELEASE_NOTES_WEBSITE_LINK` | build | footer links in the generated release body; the Discord link is omitted when its var is unset, never invented |
| var | `RVB_MORPHE_PASSTHROUGH` | build | bundle handling escape hatch |
| var | `RVB_MORPHE_STRIPLIBS` | build | bisect switch for morphe's own `--striplibs`, passed on top of the engine's trim/`zip -d`; `false` patches with the engine strip alone ([build-engine.md](build-engine.md)) |

## Log conventions

The Actions log is a product surface here: 60+ apps × several arches in parallel,
and a maintainer reads it on failure.

- `::group::` / `::endgroup::` wrap each build (in pooled mode the parent emits
  them while replaying a child's log, in completion order).
- Engine messages go through `pr` / `wpr` / `epr` (green `+`, `!`, red `-`) and
  `abort` for fatal ones.
- The asset uploader marks each file's progress with `⬆️` (start) and `✅`
  (uploaded), and reports a failed attempt as `::warning::Attempt n/3 failed for
  <file>` before the final `::error::` — so a scan of the log locates the failing
  file.
- `::warning::` and `::error::` are reserved for annotatable problems, and a
  validation rejection that must stop the job writes `::error::` **and** exits
  non-zero (see `IS_PRERELEASE` handling in the uploader).

## Testing a pipeline change

| Change | Cheapest honest verification |
|---|---|
| Engine functions (`utils.sh`) | `bash .github/traces/trace_runner.sh verify` — offline, no network |
| A shell script CI calls | a stubbed-binary harness in `temp/` (see [contributing.md](contributing.md)) |
| Release/upload behaviour | the metadata matrix harness + a `workflow_dispatch` of Manual CI against `configs/config.manual.toml` |
| Watcher gating | Manual CI with a chosen config, or read the previous run's flags in the Actions UI |
| Website-facing formats | rebuild the site catalogue with `dry_run: true` on `rebuild-catalog.yml` |
