#!/bin/bash
# build_update_retry_list.sh — the build job's half of ADR 0010.
#
# Runs in build.yml right after build_report_failures.sh, from the same
# temp/failures records the notification is built from. It reconciles the two
# pending-build state files against what actually happened this run:
#
#   * an attempted (enabled) app/arch not owed a download retry (a clean build, a
#     dedup-suppressed already-good artifact, or one of the settled failures in the
#     third bullet): merge its arches into built_shape so the watcher stops treating
#     it as "new", stamp the tracked config it built from, and drop those arches from
#     its pending entry (deleting the entry once nothing is left to build).
#   * an attempted app/arch whose ONLY outstanding failure is a download exhaustion
#     (`_dl`) and is still requested: record it in pending_builds as reason "retry"
#     with attempts + 1, parking it once it has hit RVB_RETRY_MAX so a genuinely-
#     unbuildable arch stops being retried every run instead of looping forever.
#   * every OTHER failure — build abort (`<slug>.json`), patcher abort (`_pf`),
#     patch-set rejection (`_np`) and bundle-unreadable (`_lb`) — is deliberately NOT
#     retried. A retry re-runs the same engine over the same inputs and reproduces the
#     same abort, so it spends a build slot to learn nothing; the fix is a patch-bundle
#     release or a config edit, and BOTH already force-enable the app through their own
#     trigger (TRIGGER_STABLE / the watcher's re-arm). Their attempted arches therefore
#     fall into the success side below: settled into built_shape so neither this queue nor
#     the watcher's "arch never built -> reason new" path re-nags them every run (ADR
#     0010). This is the same settle the `_np` case already relies on.
#
# Only pool builds (a *.json config) reconcile; a manual TOML run must not mutate
# the scheduled retry state. A whole-job crash that leaves an attempted app with no
# record would mark it built - rare, and self-correcting because that app's own
# source/version trigger rebuilds it; the far worse failure (mass force-rebuild) is
# prevented by the watcher's cold-start seed.
#
# Env: CONFIG_FILE, RVB_RETRY_MAX (default 3), GITHUB_RUN_ID, GITHUB_OUTPUT
#      (writes RETRY_STATE_UPDATED=true/false).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry_lib.sh
source "$SCRIPT_DIR/retry_lib.sh"

CFG="${CONFIG_FILE:-}"
updated() {
	if [ -n "${GITHUB_OUTPUT:-}" ]; then
		echo "RETRY_STATE_UPDATED=$1" >>"$GITHUB_OUTPUT"
	fi
}

if [ -z "$CFG" ] || [ ! -f "$CFG" ] || [[ "$CFG" != *.json ]]; then
	echo "Not a pool build config ($CFG); leaving retry state untouched."
	updated false
	exit 0
fi

CH=$(retry_channel_of_config "$CFG")
FAILDIR="temp/failures"
BS_FILE="state/built_shape.json"
PB_FILE="state/pending_builds.json"
RVB_RETRY_MAX="${RVB_RETRY_MAX:-3}"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN="${GITHUB_RUN_ID:-0}"

bs=$(retry_load "$BS_FILE")
pb=$(retry_load "$PB_FILE")
bs0="$bs"
pb0="$pb"

# ---- collect retry-eligible arches per app: download-exhaustion records only ----
# Only `_dl` wakes a retry. Build aborts (`<slug>.json`), patcher aborts (`_pf`),
# patch-set rejections (`_np`) and bundle-unreadable aborts (`_lb`) are skipped here, so
# their arches land in the success side of the reconcile below and settle into built_shape
# instead of re-queueing.
declare -A FAILED
shopt -s nullglob
for j in "$FAILDIR"/*.json; do
	case "$j" in *_dl.json) ;; *) continue ;; esac
	app=$(jqx -r '.app // empty' "$j")
	arch=$(jqx -r '.arch // empty' "$j")
	[ -n "$app" ] || continue
	base=$(retry_app_base "$app" "$arch")
	[ -n "$arch" ] && FAILED[$base]+="$arch "
done
shopt -u nullglob

# ---- reconcile every app this build attempted ----
while IFS= read -r key; do
	[ -z "$key" ] && continue
	enabled=$(jqx -r --arg k "$key" '(.[$k].enabled // true)' "$CFG")
	[ "$enabled" = "false" ] && continue

	want=$(retry_effective_arch "$CFG" "$key")
	want_arr=$(retry_to_arr "$want")

	fset="[]"
	if [ -n "${FAILED[$key]:-}" ]; then
		fset=$(retry_to_arr "${FAILED[$key]}")
		# keep only arches the config still requests
		fset=$(jqx -cn --argjson f "$fset" --argjson want "$want_arr" '$f - ($f - $want)')
	fi
	# succeeded = requested arches minus failed arches
	succ=$(jqx -cn --argjson want "$want_arr" --argjson f "$fset" '$want - $f')

	# remember attempts before we touch the entry
	prev_att=$(jqx -r --arg c "$CH" --arg k "$key" '(.[$c][$k].attempts // 0)' <<<"$pb")

	# Merge the non-`_dl` arches (successes AND the settled build/patch/np failures)
	# into built_shape, then drop them from pending. The entry is {arches, cfg}: the
	# tracked fields of the config this build was produced from, recorded whenever
	# nothing further is owed a retry. An arch still owed a download retry must NOT
	# advance the baseline — that would forgive the very edit the maintainer made and
	# let the watcher stop asking for it, while the pending retry already keeps the app
	# queued (why: decisions/0014). A non-retry failure advancing it is the intended
	# settle: the arch is done until a patch-bundle trigger or a config edit revisits it.
	if [ "$(jqx -r 'length' <<<"$succ")" -gt 0 ]; then
		wmap=$(retry_effective_cfg "$CFG" "$key")
		bs=$(jqx -c --arg c "$CH" --arg k "$key" --argjson s "$succ" --argjson m "$wmap" '
			(.[$c][$k] // []) as $old
			| ($old | if type == "object" then (.arches // []) else . end) as $had
			| .[$c][$k] = ((($had + $s) | unique) as $a | {arches: $a, cfg: $m})' <<<"$bs")
	fi
	pb=$(jqx -c --arg c "$CH" --arg k "$key" --argjson s "$succ" '
		if .[$c][$k] then
			.[$c][$k].arches = ((.[$c][$k].arches // []) - $s)
			| (if (.[$c][$k].arches | length) == 0 then del(.[$c][$k]) else . end)
		else . end' <<<"$pb")

	# re-queue whatever download-exhausted (the only retry class)
	if [ "$(jqx -r 'length' <<<"$fset")" -gt 0 ]; then
		new_att=$(( ${prev_att:-0} + 1 ))
		parked=false
		[ "$new_att" -ge "$RVB_RETRY_MAX" ] && parked=true
		# Merge, never replace: the watcher's `cfg` fingerprint has to survive an
		# attempt, because it is the baseline the next run compares against. Rebuilding
		# the object here would drop it, the watcher would read the entry as one that
		# predates the field, and every run would re-arm it - the exact churn the park
		# exists to prevent.
		pb=$(jqx -c --arg c "$CH" --arg k "$key" --argjson a "$fset" \
			--argjson att "$new_att" --argjson pk "$parked" --argjson run "$RUN" --arg ts "$NOW" \
			'.[$c][$k] = ((.[$c][$k] // {}) + {reason:"retry", arches:$a, attempts:$att, parked:$pk, run:$run, ts:$ts})' <<<"$pb")
	fi
done < <(retry_list_apps "$CFG")

if [ "$bs" != "$bs0" ] || [ "$pb" != "$pb0" ]; then
	mkdir -p state
	# Same split as the watcher: compact in the variables (the comparisons above
	# read those), canonical document layout in the files - see jsonfmt.py.
	jqx . <<<"$bs" >"$BS_FILE"
	jqx . <<<"$pb" >"$PB_FILE"
	echo "Retry state updated for channel $CH (built_shape + pending_builds)."
	updated true
else
	echo "Retry state unchanged for channel $CH."
	updated false
fi
