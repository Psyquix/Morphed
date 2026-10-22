# 0004 — No download prewarm pass; fetching stays inside each build

**Status:** accepted (2026-09-22, after a rejection)
**Affects:** `scripts/build.sh` (job pool), `scripts/utils.sh` (`build_rv`,
`_get_prebuilts`, download flocking), `.github/workflows/build.yml` env

## Context

Stock APK downloads dominate a build run's wall clock, and the parallel pool can
start two jobs that want the same package version. A **prewarm pass** was
implemented for it: a first wave of download-only children, run in their own pool
ahead of the normal builds, so every stock file would already be on disk when the
real builds started. It was reverted without ever being measured
(`d033813f`, 2026-09-22).

## Decision

**There is no prewarm phase and there will not be one without a measured problem.**
A stock download happens inside the build that needs it. Cross-job duplication is
handled by two mechanisms that already existed:

- **Per `pkg+version` flock** — a second job wanting the same artifact waits on the
  lock and then finds the file in cache instead of fetching it again.
- **Universal promotion** — when a job fetches an all-arch/universal artifact, it is
  cached as `<pkg>-<version>-all.apk` so the sibling architecture's build is
  satisfied by the same download.

What the revert deliberately **kept**, because they are independent of prewarm:

- The `_req` transfer ceilings and low-speed stall guard (`RVB_DL_MAX_TIME`,
  `--connect-timeout`, `--retry`) — those protect every download.
- The cache architecture-satisfaction assertions in
  `.github/traces/test_cache_helpers.sh` — they pin pre-existing
  `_cache_probe_apk` / `_cache_all_archs_present` behaviour.

## Why it was rejected

The pass added, for an unquantified gain:

- a **second process pool** with its own lifecycle, next to the build pool;
- a **second concurrency knob** to tune and reason about;
- a **download-only mode flag inside `build_rv`**, which is the one function every
  other rule in the engine assumes runs a whole build;
- **per-label dedupe state** to stop the two phases racing each other.

And it changed *when* and *by whom* every stock APK gets fetched — the class of
change that produces a subtle cache or ordering bug at 3 a.m. in a run nobody is
watching. The flock already collapsed duplicate fetches, which was the only real
problem; the remaining benefit was theoretical.

## Rejected alternatives

- **Two-phase barrier (download everything, wait, then patch).** Same complexity
  budget as prewarm, plus it makes the slowest download a gate for the whole run
  instead of a delay for one app.
- **A global "one download per package per run" memo.** Cross-process correctness
  can't be memoised in a shell pool; the flock is the same idea done where the
  concurrency actually lives.
- **Raising `PARALLEL_JOBS` to hide download latency.** A knob change, not a
  structural one — and the right first move if a run is ever measurably
  download-bound. It costs memory and cache-quota pressure instead of correctness
  risk.

## Consequences

- Build time is bounded by download latency per app, and that is accepted. If it ever
  becomes a real problem, the escalation order is: raise `PARALLEL_JOBS`, then check
  the cache hit rate in `nullcpy/apks`, only then consider restructuring phases —
  with a measurement attached.
- `build_rv` has no mode flag. Anyone adding "download only" behaviour should treat
  this file as the reason to say no first.
- Do not re-propose prewarm or a two-phase download barrier unless the person asking
  is the maintainer, or a measured CI problem demands it.

## Verification

`.github/traces/test_cache_helpers.sh` pins the flock-adjacent cache behaviour
(architecture keys, `-all` promotion, `_cache_all_archs_present`); the golden traces
were recorded against the post-revert shape, so a reintroduced phase would show up
there immediately (`bash .github/traces/trace_runner.sh verify`).
