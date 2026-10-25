#!/usr/bin/env bash
# Functional regression tests for the two halves of the version watcher:
# .github/scripts/ci_fetch_app_versions.sh (which store it asks, in which order, and
# what it says when a store answers nothing) and
# .github/scripts/ci_compare_app_versions.sh (what is allowed to move the recorded
# version and so wake a build).
#
# The defect they hold the door against: a group whose stores are a release apart -
# Uptodown lags APKMirror for Discord - was re-recorded on every run that lost a
# scraping race, because ANY difference counted as an update. The recorded value then
# bounced 349.9 -> 350.8 -> 349.9 forever, re-patching and re-releasing the same two
# APKs on each tick, and the log never said which store had answered. So every
# acceptance here sits beside the refusal that makes it mean something: a lower or
# equal version must NOT fire, an identical version must NOT rewrite state, the first
# source that answers must end the search, and a store that names no version must say
# so out loud instead of quietly handing the app to the next one.
#
# Offline: the fetch cases run against a stub scripts/utils.sh in their own sandbox
# that records which sources were asked, in order, and returns canned lists (its
# DL_SRCS line is copied from the real utils.sh, so reordering the engine's sources
# reorders what these assertions expect rather than silently disagreeing). The compare
# cases run against the REAL utils.sh, because the comparator they guard is the
# engine's own get_highest_ver - the watcher must not invent a second one.
# Nothing here touches the repo's own configs/ or state/.
set -u
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
fail() { echo "FAIL: $*"; exit 1; }
jqx() { jq -c "$@"; }

# ============================================================ compare: only UP fires
# run_cmp <name> <state/app_versions.json> <fetched_app_versions.json>
# leaves: CMP_TRIGGER CMP_STATE CMP_ACTIVE CMP_UPDATES CMP_LOG
run_cmp() {
	local name=$1 state=$2 fetched=$3
	CMP_CASE="$t/cmp-$name"
	mkdir -p "$CMP_CASE/state" "$CMP_CASE/scripts"
	printf '%s\n' "$state" >"$CMP_CASE/state/app_versions.json"
	printf '%s\n' "$fetched" >"$CMP_CASE/fetched_app_versions.json"
	cp "$REPO/scripts/utils.sh" "$CMP_CASE/scripts/utils.sh"
	(
		cd "$CMP_CASE" || exit 1
		# utils.sh aborts at source time unless it can find its patcher registry; the
		# sandbox has no .github/ of its own, so point it at the repo's (same escape
		# hatch trace_runner.sh uses).
		RVB_PATCHERS_SH="$REPO/.github/scripts/patchers.sh" \
			GITHUB_OUTPUT="$CMP_CASE/gho" bash "$REPO/.github/scripts/ci_compare_app_versions.sh" \
				>"$CMP_CASE/log" 2>&1
	) || fail "cmp/$name: ci_compare_app_versions.sh exited non-zero"
	CMP_TRIGGER=$(sed -n 's/^TRIGGER_APP_UPDATE=//p' "$CMP_CASE/gho" | tail -1)
	CMP_STATE=$(cat "$CMP_CASE/state/app_versions.json")
	CMP_ACTIVE=$(cat "$CMP_CASE/active_apps.json" 2>/dev/null || echo '[]')
	CMP_UPDATES=$(cat "$CMP_CASE/app_updates.json" 2>/dev/null || echo '{}')
	CMP_LOG=$(cat "$CMP_CASE/log")
}

REC_349='{"_check_only_listed":true,"Discord":{"keys":["Discord-revenge","Discord-rain"],"version":"349.9 - Stable"}}'
REC_350='{"_check_only_listed":true,"Discord":{"keys":["Discord-revenge","Discord-rain"],"version":"350.8 - Stable"}}'

# --- 1. a genuinely newer version wakes the group and advances the baseline --------
run_cmp newer "$REC_349" '{"Discord":"350.8 - Stable"}'
[[ "$CMP_TRIGGER" == "1" ]] || fail "case1 a real update did not fire (got '$CMP_TRIGGER')"
[[ "$(jqx -r '.Discord.version' <<<"$CMP_STATE")" == "350.8 - Stable" ]] ||
	fail "case1 baseline not advanced: $CMP_STATE"
[[ "$(jqx -c '. | sort' <<<"$CMP_ACTIVE")" == '["Discord-rain","Discord-revenge"]' ]] ||
	fail "case1 constituent keys not queued: $CMP_ACTIVE"
[[ "$(jqx -r '.Discord.old + ">" + .Discord.new' <<<"$CMP_UPDATES")" == "349.9 - Stable>350.8 - Stable" ]] ||
	fail "case1 notification payload: $CMP_UPDATES"

# --- 2. THE BUG: a store that is one release BEHIND must not fire ------------------
# This is 349.9 arriving after 350.8 was recorded - the exact bounce that rebuilt
# Discord on alternate schedule ticks. Equal-and-lower must be a no-op.
run_cmp older "$REC_350" '{"Discord":"349.9 - Stable"}'
[[ "$CMP_TRIGGER" == "0" ]] || fail "case2 a downgrade fired a build"
[[ "$(jqx -r '.Discord.version' <<<"$CMP_STATE")" == "350.8 - Stable" ]] ||
	fail "case2 the baseline was dragged backwards: $CMP_STATE"
[[ "$(jqx -c . <<<"$CMP_ACTIVE")" == "[]" ]] || fail "case2 an app was queued for a downgrade: $CMP_ACTIVE"
[[ "$CMP_UPDATES" == "{}" ]] || fail "case2 a downgrade was announced: $CMP_UPDATES"
grep -q "Not an update for Discord" <<<"$CMP_LOG" ||
	fail "case2 the refusal is silent in the log: $CMP_LOG"

# --- 3. negative control: the same version is not an update and rewrites nothing ----
run_cmp same "$REC_349" '{"Discord":"349.9 - Stable"}'
[[ "$CMP_TRIGGER" == "0" ]] || fail "case3 the identical version fired"
[[ "$(jqx -c . <<<"$CMP_STATE")" == "$(jqx -c . <<<"$REC_349")" ]] ||
	fail "case3 state churned on a no-op: $CMP_STATE"

# --- 4. stores name the same release differently, and that is not an update --------
# APKMirror's titles carry the channel ("349.9 - Stable"), other stores answer bare.
# A format change must neither fire nor re-record: the suffix is part of the build's
# cache key, so rewriting it would re-patch an APK that has not moved.
run_cmp resuffix "$REC_350" '{"Discord":"350.8"}'
[[ "$CMP_TRIGGER" == "0" ]] || fail "case4a a store's formatting fired a build"
run_cmp reformat "$REC_349" '{"Discord":"349.9"}'
[[ "$CMP_TRIGGER" == "0" ]] || fail "case4b a store's formatting fired a build"
# ... in either direction, since the two stores print the same release differently.
run_cmp resuffix_in '{"_check_only_listed":true,"Discord":{"keys":["Discord-revenge"],"version":"349.9"}}' \
	'{"Discord":"349.9 - Stable"}'
[[ "$CMP_TRIGGER" == "0" ]] || fail "case4e a store's formatting fired a build"
[[ "$(jqx -r '.Discord.version' <<<"$CMP_STATE")" == "349.9" ]] ||
	fail "case4e the recorded format was replaced: $CMP_STATE"
# ... while the same two formats, genuinely apart, still compare correctly.
run_cmp crossform_up "$REC_349" '{"Discord":"350.8"}'
[[ "$CMP_TRIGGER" == "1" ]] || fail "case4c a cross-format upgrade was refused: $CMP_LOG"
run_cmp crossform_down "$REC_350" '{"Discord":"349.9"}'
[[ "$CMP_TRIGGER" == "0" ]] || fail "case4d a cross-format downgrade fired a build"

# --- 5. first-ever record of a group still fires, keyed by the group name ----------
run_cmp cold '{}' '{"Discord":"350.8 - Stable"}'
[[ "$CMP_TRIGGER" == "1" ]] || fail "case5 an unrecorded group did not fire"
[[ "$(jqx -c '.Discord.keys' <<<"$CMP_STATE")" == '["Discord"]' ]] ||
	fail "case5 no keys recorded for the new group: $CMP_STATE"
[[ "$(jqx -c . <<<"$CMP_ACTIVE")" == '["Discord"]' ]] || fail "case5 queue: $CMP_ACTIVE"

# --- 6. a group the fetch could not answer for must not fire or corrupt state ------
run_cmp noanswer "$REC_349" '{"Discord":null,"Other":""}'
[[ "$CMP_TRIGGER" == "0" ]] || fail "case6 an empty answer fired a build"
[[ "$(jqx -r '.Discord.version' <<<"$CMP_STATE")" == "349.9 - Stable" ]] ||
	fail "case6 an empty answer overwrote the baseline: $CMP_STATE"

# ================================================================ fetch: order + voice
# The stub replays scripts/utils.sh's own source list, and answers per source from the
# env the case sets: RC_<src> = the page-fetch status, RV_<src> = the listing status,
# V_<src> = the version lines it names. ASKED collects "<src> <url>" per call, so the
# order the watcher asks in is a fact the test reads rather than infers.
eval "$(grep -m1 '^DL_SRCS=' "$REPO/scripts/utils.sh")"
[ -n "${DL_SRCS[*]:-}" ] || fail "could not read DL_SRCS from scripts/utils.sh"

stub_utils() { # <dir>
	{
		cat <<STUB
# Test stub of utils.sh for the version watcher: it IS the real utils.sh - so the
# comparator the watcher uses is the real get_highest_ver, not a copy that could drift -
# with every store scrape replaced by a recorder. No network, no tools: sleep is
# neutralised so the watcher's rate-limit pause costs the suite nothing (the real call
# is still made). Each source answers from the env the case sets: RC_<src> = the page
# fetch status, RV_<src> = the listing status, V_<src> = the version lines it names.
source "$REPO/scripts/utils.sh"
set_prebuilts() { :; }
sleep() { :; }
STUB
		local s
		for s in "${DL_SRCS[@]}"; do
			cat <<STUB
get_${s}_resp() { printf '%s %s\n' "${s}" "\$1" >> "\$ASKED"; return "\${RC_${s}:-0}"; }
get_${s}_vers() {
	if [ -n "\${V_${s}:-}" ]; then printf '%s\n' "\${V_${s}}"; fi
	return "\${RV_${s}:-0}"
}
STUB
		done
	} >"$1/scripts/utils.sh"
}

# run_fetch <name> <app-json-for-config.stable.json> [ENV=VAL ...]
# leaves: OUT_ASKED OUT_JSON OUT_LOG OUT_RC
run_fetch() {
	local name=$1 appcfg=$2
	shift 2
	FX="$t/fetch-$name"
	mkdir -p "$FX/state" "$FX/scripts"
	printf '%s\n' '{"_check_only_listed":true,"Discord":{"keys":["Discord-revenge"],"version":"349.9 - Stable"}}' \
		>"$FX/state/app_versions.json"
	printf '{"patches-version":"stable","Discord-revenge":%s}\n' "$appcfg" >"$FX/config.stable.json"
	printf '%s\n' '{"patches-version":"beta"}' >"$FX/config.beta.json"
	stub_utils "$FX"
	: >"$FX/asked.txt"
	(
		cd "$FX" || exit 1
		env ASKED="$FX/asked.txt" RVB_PATCHERS_SH="$REPO/.github/scripts/patchers.sh" "$@" \
			bash "$REPO/.github/scripts/ci_fetch_app_versions.sh" >"$FX/log" 2>&1
	)
	OUT_RC=$?
	OUT_ASKED=$(cut -d' ' -f1 "$FX/asked.txt")
	OUT_JSON=$(cat "$FX/fetched_app_versions.json" 2>/dev/null || echo '{}')
	OUT_LOG=$(cat "$FX/log")
}

ALL_URLS='{"enabled":true,"pkg-name":"com.discord","app-name":"Discord",'\
'"github-dlurl":"https://github.example/releases",'\
'"fdroid-dlurl":"https://f-droid.org/x",'\
'"archive-dlurl":"https://archive.org/x",'\
'"direct-dlurl":"https://vendor.example/a.apk",'\
'"cache_repo-dlurl":"https://github.example/apks",'\
'"apkmirror-dlurl":"https://www.apkmirror.com/apk/discord/discord-chat-for-gamers",'\
'"uptodown-dlurl":"https://discord-chat-for-gamers.en.uptodown.com/android",'\
'"apkpure-dlurl":"https://apkpure.com/discord/com.discord",'\
'"apkcombo-dlurl":"https://apkcombo.com/discord/com.discord"}'

# Discord's real shape: three stores, no F-Droid or GitHub release feed. Uptodown is
# the one that lags a release behind, so it is the trap in every case below.
DISC_URLS='{"enabled":true,"pkg-name":"com.discord","app-name":"Discord",'\
'"apkmirror-dlurl":"https://www.apkmirror.com/apk/discord/discord-chat-for-gamers",'\
'"uptodown-dlurl":"https://discord-chat-for-gamers.en.uptodown.com/android",'\
'"apkcombo-dlurl":"https://apkcombo.com/discord/com.discord"}'

# The names the watcher must never ask for a version listing. Spelled out here rather
# than read from the script on purpose: a change to either side has to be looked at.
SKIPPED="cache_repo direct archive"
expected=""
for s in "${DL_SRCS[@]}"; do
	case " $SKIPPED " in
		*" $s "*) continue ;;
	esac
	expected+="$s"$'\n'
done
EXPECTED_ORDER="${expected%$'\n'}"

# --- 10. the order is the engine's download order, and never asked of a mirror ----
# Every page fetch fails, so all of them get asked and the log shows the sequence.
# Uptodown-first was the defect: it ranked a lagging store above the one the build
# would have downloaded from. cache_repo, direct and archive are skipped for the same
# reasons build_rv skips them - the cache and the mirror answer "do you have X?", not
# "what is the latest X?", and a direct URL would have to be downloaded to know.
run_fetch order "$ALL_URLS" \
	RC_github=1 RC_fdroid=1 RC_apkmirror=1 RC_uptodown=1 RC_apkpure=1 RC_apkcombo=1
[[ "$OUT_RC" == "0" ]] || fail "case10 the fetch step aborted instead of failing soft (rc=$OUT_RC)"
got_order=$(printf '%s\n' "$OUT_ASKED")
[[ "$got_order" == "$EXPECTED_ORDER" ]] ||
	fail "case10 asked in the wrong order: got [$got_order] expected [$EXPECTED_ORDER]"
[[ "$(head -1 <<<"$got_order")" != "uptodown" ]] || fail "case10 uptodown is still first"
for skipped in $SKIPPED; do
	if grep -qx "$skipped" <<<"$got_order"; then
		fail "case10 asked $skipped for a version listing"
	fi
done
grep -q "Could not read the github page for Discord-revenge" <<<"$OUT_LOG" ||
	fail "case10 a failed page fetch is not attributed to github: $OUT_LOG"
grep -q "sources tried: ${EXPECTED_ORDER//$'\n'/ }" <<<"$OUT_LOG" ||
	fail "case10 the exhaustion line names no sources: $OUT_LOG"

# --- 11. the first store that answers ends the search ------------------------------
# Negative control for 12: with APKMirror answering, Uptodown - which is a release
# behind - must not be consulted at all, so its lag can never be recorded.
run_fetch first_answer "$DISC_URLS" \
	V_apkmirror=$'350.8 - Stable\n349.9 - Stable' V_uptodown='349.9 - Stable'
[[ "$(jqx -r .Discord <<<"$OUT_JSON")" == "350.8 - Stable" ]] ||
	fail "case11 did not keep the first answer: $OUT_JSON"
if grep -qx uptodown <<<"$(printf '%s\n' "$OUT_ASKED")"; then
	fail "case11 kept asking after a store answered"
fi
grep -q "Latest version for Discord is 350.8 - Stable (from apkmirror)" <<<"$OUT_LOG" ||
	fail "case11 the answer is not attributed to a source: $OUT_LOG"

# --- 12. a store that answers with NOTHING says so, then the search continues ------
# This is the Discord shape: the page loaded, the listing came back empty (the
# scrape broke), and the group moved to the next store in silence. The version it
# recorded was then whatever the other store had.
run_fetch empty_voice "$DISC_URLS" \
	V_apkmirror='' V_uptodown='349.9 - Stable'
grep -q "apkmirror listed no version for Discord-revenge" <<<"$OUT_LOG" ||
	fail "case12 an empty version list stayed silent: $OUT_LOG"
[[ "$(jqx -r .Discord <<<"$OUT_JSON")" == "349.9 - Stable" ]] ||
	fail "case12 did not fall through to the store that answered: $OUT_JSON"
grep -q "(from uptodown)" <<<"$OUT_LOG" ||
	fail "case12 the fall-through target is not named: $OUT_LOG"

# --- 13. a listing that FAILS is distinguished from a listing that is empty --------
run_fetch vers_fails "$DISC_URLS" RC_apkmirror=0 RV_apkmirror=1 V_uptodown='349.9 - Stable'
grep -q "apkmirror failed to list versions for Discord-revenge" <<<"$OUT_LOG" ||
	fail "case13 a failing listing is not reported as a failure: $OUT_LOG"
if grep -q "apkmirror listed no version" <<<"$OUT_LOG"; then
	fail "case13 called a failure an empty listing: $OUT_LOG"
fi

# --- 14. two groups sharing one store URL are scraped once, and both say who -------
BOTH='"Discord":{"keys":["Discord-revenge"],"version":"349.9 - Stable"},'\
'"Instagram":{"keys":["Instagram-InstaFel"],"version":"1.0"}'
DEDUP="$t/fetch-dedup"
mkdir -p "$DEDUP/state" "$DEDUP/scripts"
printf '{"_check_only_listed":true,%s}\n' "$BOTH" >"$DEDUP/state/app_versions.json"
stub_utils "$DEDUP"
printf '{"patches-version":"stable","Discord-revenge":%s,"Instagram-InstaFel":%s}\n' \
	'{"enabled":true,"pkg-name":"com.discord","apkmirror-dlurl":"https://shared.example/x"}' \
	'{"enabled":true,"pkg-name":"com.instagram","apkmirror-dlurl":"https://shared.example/x"}' \
	>"$DEDUP/config.stable.json"
printf '%s\n' '{"patches-version":"beta"}' >"$DEDUP/config.beta.json"
: >"$DEDUP/asked.txt"
(
	cd "$DEDUP" || exit 1
	env ASKED="$DEDUP/asked.txt" RVB_PATCHERS_SH="$REPO/.github/scripts/patchers.sh" \
		V_apkmirror='9.9 - Stable' \
		bash "$REPO/.github/scripts/ci_fetch_app_versions.sh" >"$DEDUP/log" 2>&1
) || fail "case14 the fetch step aborted"
OUT_ASKED=$(cat "$DEDUP/asked.txt")
[[ "$(wc -l <<<"$OUT_ASKED")" == "1" ]] ||
	fail "case14 scraped the same URL twice: $OUT_ASKED"
grep -q "Reusing cached version for Instagram-InstaFel: 9.9 - Stable (apkmirror)" "$DEDUP/log" ||
	fail "case14 the cached answer lost its source: $(cat "$DEDUP/log")"

echo "VERSION WATCH TESTS: PASS"
