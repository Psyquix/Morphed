#!/bin/bash
# build_update_retry_list.sh — the build job's half of ADR 0010.
#
# Runs in build.yml right after build_report_failures.sh, from the same
# temp/failures records the notification is built from. It reconciles the two
# pending-build state files against what actually happened this run:
#
#   * an attempted (enabled) app/arch with NO failure record succeeded (or was
#     dedup-suppressed as already-good): merge its arches into built_shape so the
#     watcher stops treating it as "new", and drop those arches from its pending
#     entry (deleting the entry once nothing is left to build).
#   * an attempted app/arch that DID fail and is still requested: record it in
#     pending_builds as reason "retry" with attempts + 1, parking it once it has
#     hit RVB_RETRY_MAX so a genuinely-unbuildable arch stops being retried every
#     run instead of looping forever.
#   * no-compatible-patch (_np) records are deliberately NOT retried: they heal on
#     their own when the patch bundle updates (a real TRIGGER_STABLE), so queueing
#     them would be permanent noise.
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

# ---- collect failed arches per app (excluding _np no-patch records) ----
declare -A FAILED TERM
shopt -s nullglob
for j in "$FAILDIR"/*.json; do
	case "$j" in *_np.json) continue ;; esac
	app=$(jqx -r '.app // empty' "$j")
	arch=$(jqx -r '.arch // empty' "$j")
	[ -n "$app" ] || continue
	base=$(retry_app_base "$app" "$arch")
	[ -n "$arch" ] && FAILED[$base]+="$arch "
	# A failure that already exhausted the engine's version-code arch fallback is
	# terminal (a real incompatibility), so park it instead of retrying every run.
	[ -n "$arch" ] && [ "$(jqx -r '.vc_fallback // false' "$j")" = "true" ] && TERM[$base]+="$arch "
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

	# merge successes into built_shape, then drop them from pending
	bs=$(jqx -c --arg c "$CH" --arg k "$key" --argjson s "$succ" \
		'.[$c][$k] = (((.[$c][$k] // []) + $s) | unique)' <<<"$bs")
	pb=$(jqx -c --arg c "$CH" --arg k "$key" --argjson s "$succ" '
		if .[$c][$k] then
			.[$c][$k].arches = ((.[$c][$k].arches // []) - $s)
			| (if (.[$c][$k].arches | length) == 0 then del(.[$c][$k]) else . end)
		else . end' <<<"$pb")

	# re-queue whatever failed
	if [ "$(jqx -r 'length' <<<"$fset")" -gt 0 ]; then
		new_att=$(( ${prev_att:-0} + 1 ))
		parked=false
		[ "$new_att" -ge "$RVB_RETRY_MAX" ] && parked=true
		# terminal (version-code fallback already tried): park now and pin attempts to
		# the cap, so only a config change or a natural rebuild can bring it back.
		if [ -n "${TERM[$key]:-}" ]; then
			parked=true
			new_att="$RVB_RETRY_MAX"
		fi
		pb=$(jqx -c --arg c "$CH" --arg k "$key" --argjson a "$fset" \
			--argjson att "$new_att" --argjson pk "$parked" --argjson run "$RUN" --arg ts "$NOW" \
			'.[$c][$k] = {reason:"retry", arches:$a, attempts:$att, parked:$pk, run:$run, ts:$ts}' <<<"$pb")
	fi
done < <(retry_list_apps "$CFG")

if [ "$bs" != "$bs0" ] || [ "$pb" != "$pb0" ]; then
	mkdir -p state
	printf '%s\n' "$bs" >"$BS_FILE"
	printf '%s\n' "$pb" >"$PB_FILE"
	echo "Retry state updated for channel $CH (built_shape + pending_builds)."
	updated true
else
	echo "Retry state unchanged for channel $CH."
	updated false
fi
