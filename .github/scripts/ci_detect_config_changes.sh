#!/bin/bash
# ci_detect_config_changes.sh — the watcher's reconciliation for ADR 0010.
#
# Runs in check_patch after the base configs compile and the app-version compare,
# before ci_trigger_flags.sh. It answers one question per channel: "has the config
# changed relative to what we last built, and is anything still owed a build?" and
# turns that into an actionable pending list the pool generator force-enables.
#
#   * a brand-new app, or a newly requested arch for a known app (arch not in
#     built_shape) -> enqueue reason "new" so the next build picks it up even
#     though no patch source or app version moved (the _check_only_listed throttle
#     means a new app would otherwise never be fetched or triggered).
#   * an app removed from the config, or a failed arch no longer requested ->
#     prune it from the pending list (MacroDroid both -> arm64-v8a drops its
#     arm-v7a retry).
#   * a pending entry already recorded by the build job (reason "retry") is left
#     alone - attempts/parked belong to the build job - except for arch pruning.
#
# Cold start: built_shape is empty the first time this runs after the feature
# lands. Without a guard every app would look "new" and the whole pool would be
# force-built, so the first run per channel SEEDS built_shape to the current
# config and enqueues nothing; only apps/arches added afterwards are treated as
# new. The seed is persisted by flagging TRIGGER_CONFIG_CHANGE so the watcher's
# commit step runs.
#
# Env: GITHUB_OUTPUT (writes TRIGGER_CONFIG_CHANGE=0/1).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry_lib.sh
source "$SCRIPT_DIR/retry_lib.sh"

BS_FILE="state/built_shape.json"
PB_FILE="state/pending_builds.json"

bs=$(retry_load "$BS_FILE")
pb=$(retry_load "$PB_FILE")
bs_orig="$bs"
pb_orig="$pb"
trigger=0

# to_arr <space-separated tokens> -> sorted, unique JSON array. LC_ALL=C keeps the
# order byte-stable ("arm-v7a" before "arm64-v8a") regardless of the runner locale.
to_arr() {
	if [ -z "${1:-}" ]; then
		printf '[]'
	else
		# shellcheck disable=SC2086
		printf '%s\n' $1 | LC_ALL=C sort -u | jqx -R . | jqx -sc .
	fi
}

process_channel() { # $1=channel $2=config-file
	local ch=$1 cfg=$2
	[ -f "$cfg" ] || return 0

	local apps cfg_count bs_count first_run key want want_arr bs_arr pend_json pend_arches kept need added
	apps=$(retry_list_apps "$cfg")
	cfg_count=$(printf '%s\n' "$apps" | grep -c . || true)
	bs_count=$(jqx -r --arg c "$ch" '(.[$c] // {}) | length' <<<"$bs")

	# Cold start for this channel: nothing built yet but the config has apps.
	if [ "${bs_count:-0}" -eq 0 ] && [ "${cfg_count:-0}" -gt 0 ]; then
		first_run=1
	else
		first_run=0
	fi

	if [ "$first_run" = 1 ]; then
		# Seed built_shape to the current config shape and enqueue nothing.
		local seed="{}"
		while IFS= read -r key; do
			[ -z "$key" ] && continue
			want=$(retry_effective_arch "$cfg" "$key")
			want_arr=$(to_arr "$want")
			seed=$(jqx -c --arg k "$key" --argjson a "$want_arr" '.[$k] = $a' <<<"$seed")
		done <<<"$apps"
		bs=$(jqx -c --arg c "$ch" --argjson s "$seed" '.[$c] = $s' <<<"$bs")
		return 0
	fi

	while IFS= read -r key; do
		[ -z "$key" ] && continue
		want=$(retry_effective_arch "$cfg" "$key")
		want_arr=$(to_arr "$want")
		bs_arr=$(jqx -c --arg c "$ch" --arg k "$key" '(.[$c][$k] // [])' <<<"$bs")

		pend_json=$(jqx -c --arg c "$ch" --arg k "$key" '.[$c][$k]' <<<"$pb")
		if [ "$pend_json" = "null" ]; then
			# Not already queued: enqueue only genuinely-new arches (never built).
			need=$(jqx -cn --argjson want "$want_arr" --argjson have "$bs_arr" '$want - $have')
			added=$(jqx -r 'length' <<<"$need")
			if [ "${added:-0}" -gt 0 ]; then
				pb=$(jqx -c --arg c "$ch" --arg k "$key" --argjson a "$need" \
					'.[$c][$k] = {reason:"new", arches:$a, attempts:0, parked:false}' <<<"$pb")
				trigger=1
			fi
		else
			# Already queued: prune arches the config no longer requests.
			pend_arches=$(jqx -c '.arches' <<<"$pend_json")
			kept=$(jqx -cn --argjson pa "$pend_arches" --argjson want "$want_arr" '$pa - ($pa - $want)')
			if [ "$(jqx -r 'length' <<<"$kept")" -eq 0 ]; then
				pb=$(jqx -c --arg c "$ch" --arg k "$key" 'del(.[$c][$k])' <<<"$pb")
				trigger=1
			elif [ "$kept" != "$pend_arches" ]; then
				pb=$(jqx -c --arg c "$ch" --arg k "$key" --argjson a "$kept" '.[$c][$k].arches = $a' <<<"$pb")
				trigger=1
			fi
		fi
	done <<<"$apps"
}

process_channel stable config.stable.json
process_channel beta config.beta.json

# A build must run whenever anything non-parked is still pending, even if this
# run changed nothing (a retry carried over from a previous run).
if [ "$(jqx -r '[.stable, .beta | to_entries[] | select(.value.parked != true)] | length' <<<"$pb")" -gt 0 ]; then
	trigger=1
fi

# Persist the seed/reconciliation even when nothing is pending: if the files
# changed this run, the commit step must fire so the baseline survives.
if [ "$bs" != "$bs_orig" ] || [ "$pb" != "$pb_orig" ]; then
	mkdir -p state
	printf '%s\n' "$bs" >"$BS_FILE"
	printf '%s\n' "$pb" >"$PB_FILE"
	[ "$bs" != "$bs_orig" ] && trigger=1
fi

# Pre-extract the non-parked pending keys per channel for the pool generator.
jqx -c '[.stable | to_entries[] | select(.value.parked != true) | .key]' <<<"$pb" >pending.stable.json
jqx -c '[.beta | to_entries[] | select(.value.parked != true) | .key]' <<<"$pb" >pending.beta.json

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "TRIGGER_CONFIG_CHANGE=$trigger" >>"$GITHUB_OUTPUT"
fi
echo "Config-change reconciliation: TRIGGER_CONFIG_CHANGE=$trigger; pending stable=$(jqx -c '.stable | length' <<<"$pb"), beta=$(jqx -c '.beta | length' <<<"$pb")"
