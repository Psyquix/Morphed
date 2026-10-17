#!/usr/bin/env bash
# Functional regression tests for the ADR 0010 re-arm in ci_detect_config_changes.sh
# (and the fingerprint-preserving merge in build_update_retry_list.sh).
#
# The rule: a pending entry is an order placed under a particular config. When that
# app's own compiled entry changes, the failed build no longer describes the build
# being asked for, so attempts reset and a parked entry is queued again. Each
# acceptance here is paired with the refusal that makes it mean something: an
# unchanged config must NOT re-arm, a reordered-but-identical block must NOT re-arm,
# a re-armed entry must NOT re-arm again on the next run, and an app that left the
# config must be left alone.
#
# Drives the real watcher script (no stubs): it reads config.stable.json /
# config.beta.json and state/*.json from its cwd, so each case runs in its own
# sandbox tree. Nothing here touches the repo's own configs/ or state/.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=../scripts/retry_lib.sh
source "$REPO/.github/scripts/retry_lib.sh"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# run_case <name> <config.stable.json> <pending_builds.json> <built_shape.json>
# leaves: CASE=<dir>, OUT_TRIGGER, OUT_PENDING, OUT_LOG, OUT_STATE, OUT_STATE2
run_case() {
	local name=$1 cfg=$2 pb=$3 bs=$4
	CASE="$t/$name"
	mkdir -p "$CASE/state"
	printf '%s\n' "$cfg" >"$CASE/config.stable.json"
	printf '%s\n' '{"patches-version":"stable"}' >"$CASE/config.beta.json"
	printf '%s\n' "$pb" >"$CASE/state/pending_builds.json"
	printf '%s\n' "$bs" >"$CASE/state/built_shape.json"
	(
		cd "$CASE" || exit 1
		GITHUB_OUTPUT="$CASE/gho" bash "$REPO/.github/scripts/ci_detect_config_changes.sh" \
			>"$CASE/log" 2>&1
	) || fail "$name: ci_detect_config_changes.sh exited non-zero"
	OUT_TRIGGER=$(sed -n 's/^TRIGGER_CONFIG_CHANGE=//p' "$CASE/gho" | tail -1)
	OUT_PENDING=$(cat "$CASE/pending.stable.json" 2>/dev/null || echo '[]')
	OUT_NEWAPPS=$(cat "$CASE/new_apps.json" 2>/dev/null || echo '{}')
	OUT_STATE=$(cat "$CASE/state/pending_builds.json")
	OUT_STATE2=$(cat "$CASE/state/built_shape.json")
	OUT_LOG=$(cat "$CASE/log")
}

APP='"App-x": {"pkg-name":"com.x","app-name":"App","apkmirror-dlurl":"https://apkmirror.com/a"}'
# built_shape with a different app present (and fully built for its requested arches),
# so no case trips the cold-start seed and no unrelated app joins the pending list.
SHAPE='{"stable":{"Other-y":["arm-v7a","arm64-v8a"]},"beta":{}}'
STABLE_CFG="{\"patches-version\":\"stable\",$APP}"
FP=$(cd "$t" && printf '%s\n' "$STABLE_CFG" >probe.json && retry_fingerprint probe.json "App-x")
[ -n "$FP" ] || fail "fingerprint helper returned nothing"

# --- 1. a parked app whose config gained a source is re-armed and re-queued ------
run_case rearm_on_change \
	"{\"patches-version\":\"stable\",\"App-x\":{\"pkg-name\":\"com.x\",\"app-name\":\"App\",\"apkmirror-dlurl\":\"https://apkmirror.com/a\",\"direct-dlurl\":\"https://vendor.example/dl/apk\"}}" \
	'{"stable":{"App-x":{"reason":"retry","arches":["arm-v7a","arm64-v8a"],"attempts":3,"parked":true,"cfg":"deadbeef"}},"beta":{}}' \
	"$SHAPE"
[[ "$OUT_TRIGGER" == "1" ]] || fail "case1 trigger: $OUT_TRIGGER"
grep -q "Re-armed 'App-x'" <<<"$OUT_LOG" || fail "case1: no re-arm logged: $OUT_LOG"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "0" ]] || fail "case1 attempts not reset"
[[ "$(jqx -r '.stable["App-x"].parked' <<<"$OUT_STATE")" == "false" ]] || fail "case1 still parked"
[[ "$OUT_PENDING" == '["App-x"]' ]] || fail "case1 not queued for the pool: $OUT_PENDING"
[[ "$(jqx -r '.stable["App-x"].cfg' <<<"$OUT_STATE")" != "deadbeef" ]] || fail "case1 cfg not refreshed"

# --- 2. negative control: the same config must not re-arm, must not write --------
run_case no_change_no_rearm "$STABLE_CFG" \
	"{\"stable\":{\"App-x\":{\"reason\":\"retry\",\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"attempts\":3,\"parked\":true,\"cfg\":\"$FP\"}},\"beta\":{}}" \
	"$SHAPE"
[[ "$OUT_TRIGGER" == "0" ]] || fail "case2 fired a build for an unchanged config"
grep -q "Re-armed" <<<"$OUT_LOG" && fail "case2 re-armed without a config change"
[[ "$OUT_PENDING" == "[]" ]] || fail "case2 un-parked a still-valid retry: $OUT_PENDING"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "3" ]] || fail "case2 budget reset"
[[ "$OUT_STATE" == "$(printf '%s\n' "{\"stable\":{\"App-x\":{\"reason\":\"retry\",\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"attempts\":3,\"parked\":true,\"cfg\":\"$FP\"}},\"beta\":{}}" | jqx -c .)" ]] ||
	fail "case2 rewrote the state file (churn): $OUT_STATE"

# --- 3. negative control: reordered keys are not a config change ----------------
run_case reorder_not_a_change \
	'{"patches-version":"stable","App-x":{"app-name":"App","apkmirror-dlurl":"https://apkmirror.com/a","pkg-name":"com.x"}}' \
	"{\"stable\":{\"App-x\":{\"reason\":\"retry\",\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"attempts\":3,\"parked\":true,\"cfg\":\"$FP\"}},\"beta\":{}}" \
	"$SHAPE"
[[ "$OUT_TRIGGER" == "0" ]] || fail "case3: key order re-armed the app"

# --- 4. a legacy entry with no baseline re-arms once, then never again ----------
run_case legacy_once \
	"$STABLE_CFG" \
	'{"stable":{"App-x":{"reason":"retry","arches":["arm-v7a","arm64-v8a"],"attempts":3,"parked":true}},"beta":{}}' \
	"$SHAPE"
[[ "$(jqx -r '.stable["App-x"].parked' <<<"$OUT_STATE")" == "false" ]] || fail "case4 legacy entry not re-armed"
[[ -n "$(jqx -r '.stable["App-x"].cfg // ""' <<<"$OUT_STATE")" ]] || fail "case4 baseline not recorded"
seeded=$(jqx -r '.stable["App-x"].cfg' <<<"$OUT_STATE")
# Second run on the identical config must be a no-op - the guard against an entry
# that re-arms every run because its fingerprint never sticks.
run_case legacy_second \
	"$STABLE_CFG" \
	"{\"stable\":{\"App-x\":{\"reason\":\"retry\",\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"attempts\":3,\"parked\":true,\"cfg\":\"$seeded\"}},\"beta\":{}}" \
	"$SHAPE"
[[ "$OUT_TRIGGER" == "0" ]] || fail "case5 re-armed on the second run too"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "3" ]] || fail "case5 budget reset again"

# --- 5b. loop guard: a LIVE entry with no baseline keeps its count ---------------
# Resetting attempts whenever `cfg` is missing would hand every naturally-triggered
# failure (whose first entry is written by the build job, which hashes no config) a
# fresh budget each run, so RVB_RETRY_MAX could never be reached and the app would
# retry forever. Only the park is lifted by a missing baseline, never the count.
run_case live_no_baseline_keeps_count \
	"$STABLE_CFG" \
	'{"stable":{"App-x":{"reason":"retry","arches":["arm-v7a","arm64-v8a"],"attempts":2,"parked":false}},"beta":{}}' \
	"$SHAPE"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "2" ]] ||
	fail "case5b a baseline-less live retry lost its attempts: $OUT_STATE"
[[ -n "$(jqx -r '.stable["App-x"].cfg // ""' <<<"$OUT_STATE")" ]] || fail "case5b baseline not recorded"
grep -q "Re-armed" <<<"$OUT_LOG" && fail "case5b logged a re-arm it must not have made"

# --- 6. a brand-new app still enqueues reason "new" and now carries a baseline --
run_case new_app_cfg \
	"$STABLE_CFG" '{"stable":{},"beta":{}}' "$SHAPE"
[[ "$OUT_PENDING" == '["App-x"]' ]] || fail "case6 new app not queued: $OUT_PENDING"
[[ "$(jqx -r '.stable["App-x"].reason' <<<"$OUT_STATE")" == "new" ]] || fail "case6 reason"
[[ "$(jqx -r '.stable["App-x"].cfg' <<<"$OUT_STATE")" == "$FP" ]] || fail "case6 new entry lacks the fingerprint"
[[ "$OUT_NEWAPPS" == '{"stable":["App-x"],"beta":[]}' ]] || fail "case6 notification list: $OUT_NEWAPPS"

# --- 7. arch pruning and re-arm coexist: both -> arm64 keeps the retry alive ----
run_case arch_prune_then_rearm \
	'{"patches-version":"stable","App-x":{"pkg-name":"com.x","arch":"arm64-v8a","apkmirror-dlurl":"https://apkmirror.com/a"}}' \
	'{"stable":{"App-x":{"reason":"retry","arches":["arm-v7a","arm64-v8a"],"attempts":1,"parked":false,"cfg":"old"}},"beta":{}}' \
	"$SHAPE"
[[ "$(jqx -c '.stable["App-x"].arches' <<<"$OUT_STATE")" == '["arm64-v8a"]' ]] || fail "case7 arch not pruned: $OUT_STATE"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "0" ]] || fail "case7 arch edit did not re-arm"

# --- 8. an arch the config no longer requests at all drops the entry ------------
run_case arch_gone_deletes \
	'{"patches-version":"stable","App-x":{"pkg-name":"com.x","arch":"x86_64","apkmirror-dlurl":"https://apkmirror.com/a"}}' \
	'{"stable":{"App-x":{"reason":"retry","arches":["arm-v7a","arm64-v8a"],"attempts":2,"parked":false,"cfg":"old"}},"beta":{}}' \
	"$SHAPE"
[[ "$(jqx -r '.stable | has("App-x")' <<<"$OUT_STATE")" == "false" ]] || fail "case8 disjoint arch kept: $OUT_STATE"

# --- 10. an attempt must not lose the fingerprint (the re-arm-forever guard) -----
# build_update_retry_list.sh rewrites the pending entry when a build fails. If that
# rewrite dropped `cfg`, the watcher would see a baseline-less entry on its next run
# and re-arm it again, buying an infinite retry loop - exactly what parking exists to
# stop. So the merge is tested where it is written, then fed back to the watcher.
run_build_case() { # <name> <pending-json>
	local name=$1 pb=$2
	CASE="$t/$name"
	mkdir -p "$CASE/state" "$CASE/temp/failures"
	printf '%s\n' '{"patches-version":"stable","App-x":{"enabled":true,"pkg-name":"com.x"}}' >"$CASE/pool.stable.json"
	printf '%s\n' '{"app":"App-x","arch":"arm64-v8a"}' >"$CASE/temp/failures/appx.json"
	printf '%s\n' '{"stable":{"Other-y":["arm-v7a","arm64-v8a"]},"beta":{}}' >"$CASE/state/built_shape.json"
	printf '%s\n' "$pb" >"$CASE/state/pending_builds.json"
	(
		cd "$CASE" || exit 1
		CONFIG_FILE=pool.stable.json RVB_RETRY_MAX=3 GITHUB_OUTPUT="$CASE/gho" \
			bash "$REPO/.github/scripts/build_update_retry_list.sh" >"$CASE/log" 2>&1
	) || fail "$name: build_update_retry_list.sh exited non-zero"
	OUT_STATE=$(cat "$CASE/state/pending_builds.json")
}

run_build_case build_preserves_cfg \
	"{\"stable\":{\"App-x\":{\"reason\":\"retry\",\"arches\":[\"arm-v7a\",\"arm64-v8a\"],\"attempts\":0,\"parked\":false,\"cfg\":\"$FP\"}},\"beta\":{}}"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "1" ]] || fail "case10 attempts not counted"
[[ "$(jqx -r '.stable["App-x"].cfg // "MISSING"' <<<"$OUT_STATE")" == "$FP" ]] ||
	fail "case10 the attempt dropped the fingerprint: $OUT_STATE"

# --- 11. and the watcher, after that attempt, still does not re-arm --------------
# The entry is a live (non-parked) retry, so the trigger stays high on its own
# account; what must NOT happen is the budget being reset behind the build's back.
run_case after_attempt_no_rearm "$STABLE_CFG" "$OUT_STATE" "$SHAPE"
grep -q "Re-armed" <<<"$OUT_LOG" && fail "case11 re-armed an app whose config never changed: $OUT_LOG"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "1" ]] ||
	fail "case11 the watcher reset an attempt it had no reason to reset: $OUT_STATE"

# --- 12. an app that left the config is not touched by any of this -------------
run_case app_absent_untouched \
	'{"patches-version":"stable","Other-y":{"pkg-name":"com.o","app-name":"Other","apkmirror-dlurl":"https://apkmirror.com/o"}}' \
	'{"stable":{"App-x":{"reason":"retry","arches":["arm-v7a"],"attempts":3,"parked":true,"cfg":"old"}},"beta":{}}' \
	"$SHAPE"
[[ "$(jqx -r '.stable["App-x"].attempts' <<<"$OUT_STATE")" == "3" ]] || fail "case9 touched an app not in the config"
[[ "$OUT_PENDING" == "[]" ]] || fail "case9 queued a removed app: $OUT_PENDING"

echo "CONFIG RE-ARM TESTS: PASS"
