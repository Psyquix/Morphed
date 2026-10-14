#!/usr/bin/env bash
# Fixture regression tests for the APKMirror variant picker:
#   scripts/apkmirror_search.py         (the primary implementation)
#   apkmirror_search() in scripts/utils.sh  (the no-python mirror)
# plus the two helpers they share the ranking with (_amk_minapi_rank,
# _amk_arch_class) and the bundle-before-APK order (_apkmirror_type_order).
#
# Why this exists: manual run 38589077939 asked for Truecaller-heval99 arm-v7a, the Heval
# bundle pins versionCode 2639006, and the picker returned the FIRST row carrying that
# number - which is the arm64-v8a-only upload, because three of the release's bundles
# share one versionCode and differ only in Architecture / Minimum Version / Screen DPI.
# The arch-honesty gate (docs/decisions/0007) then refused the bytes and the arch was
# never published. A pinned versionCode is a predicate on a row, not a licence to stop
# reading the row.
#
# Offline: one HTML fixture, no network, no htmlq requirement (the mirror half is
# skipped, loudly, where bin/htmlq cannot run).
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1
CWD=$(pwd)
export CWD

FIX=".github/traces/fixtures/apkmirror/truecaller-26.39.6-variants.html"
[ -f "$FIX" ] || { echo "FAIL: fixture missing: $FIX"; exit 1; }

fail() { echo "FAIL: $*"; exit 1; }
PY=python3
command -v "$PY" >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || fail "no python interpreter to run scripts/apkmirror_search.py"

# $1=arch token (APKMirror spelling) $2=badge $3=pinned versionCode ("" = none)
# $4=dpi list ("" = the engine default)
am_py() {
	"$PY" scripts/apkmirror_search.py "${4:-nodpi anydpi auto}" "$1" "$2" "26-39-6" "26.39.6" "$3" <"$FIX" 2>/dev/null
}

# The mirror is only reached when no interpreter is on PATH, so the stubs below shadow
# the two names the probe in apkmirror_search() looks for: they print nothing, which
# sends the function down its own branch. The subshell keeps the shadow off the rest of
# the suite.
SH_OK=false
if set_prebuilts >/dev/null 2>&1 && [ -n "${HTMLQ:-}" ] \
	&& [[ "$("$HTMLQ" "div.probe" --text <<<'<div class="probe">yes</div>' 2>/dev/null)" == *yes* ]]; then
	SH_OK=true
fi
am_sh() (
	python3() { :; }
	python() { :; }
	apkmirror_search "$(cat "$FIX")" "${4:-nodpi anydpi auto}" "$1" "$2" "26-39-6" "26.39.6" "$3" 2>/dev/null
)

# One case, run through whichever implementations are available, both must agree.
# $1=label $2=arch $3=badge $4=expected href suffix or NONE $5=pinned vc $6=dpi
case_() {
	local label=$1 arch=$2 badge=$3 want=$4 vc=$5 dpi=${6:-} got sh
	if [ "$want" = NONE ]; then
		got=$(am_py "$arch" "$badge" "$vc" "$dpi")
		[ -z "$got" ] || fail "$label: expected no row, got '$got'"
		if [ "$SH_OK" = true ]; then
			sh=$(am_sh "$arch" "$badge" "$vc" "$dpi")
			[ -z "$sh" ] || fail "$label (mirror): expected no row, got '$sh'"
		fi
	else
		got=$(am_py "$arch" "$badge" "$vc" "$dpi") || fail "$label: python picker returned nothing"
		[[ "$got" == *"$want"* ]] || fail "$label: want '$want', got '$got'"
		if [ "$SH_OK" = true ]; then
			sh=$(am_sh "$arch" "$badge" "$vc" "$dpi") || fail "$label: mirror returned nothing"
			[[ "$sh" == *"$want"* ]] || fail "$label (mirror): want '$want', got '$sh'"
			[ "$sh" = "$got" ] || fail "$label: mirror and python disagree: '$sh' vs '$got'"
		fi
	fi
	printf 'ok  %-46s %s\n' "$label" "$want"
}

# --- the reported failure: arm-v7a with a pinned versionCode shared by several variants
# must land on the arm64+v7a bundle, not on the arm64-only row the bottom-up walk sees
# first. The arm64 case below is the negative control that keeps it non-vacuous: the
# rejected row IS reachable, it just is not reachable for arm-v7a.
case_ "v7a + pinned vc -> fat, oldest Android" armeabi-v7a BUNDLE "-4-android-apk-download" 2639006
case_ "arm64 + pinned vc -> oldest Android wins" arm64-v8a BUNDLE "-2-android-apk-download" 2639006
# No pin at all: the lowest Minimum Version on the table, whatever versionCode it carries.
case_ "v7a unpinned -> absolute oldest" armeabi-v7a BUNDLE "-7-android-apk-download" ""
# The pin still filters: only the 2639005 row is eligible, and it is v7a-capable.
case_ "v7a + other vc -> vc predicate holds" armeabi-v7a BUNDLE "-7-android-apk-download" 2639005
# Badge kind is a hard filter per pass, so the caller's order decides bundle vs APK.
case_ "APK pass takes the apk badge" armeabi-v7a APK "-5-android-apk-download" 2639006
# A catch-all build may not take a row that omits an ABI: no BUNDLE row here is
# universal, so nothing is eligible. (Negative control: every case above DID resolve.)
case_ "arch=all refuses a partial bundle" all BUNDLE NONE 2639006
# Four-ABI label: matched by membership now, invisible to the old spelling list.
case_ "x86 inside a 4-ABI label" x86 BUNDLE "-3-android-apk-download" 2639006
# DPI still constrains: only the 120-480dpi row is allowed, newer Android and all.
case_ "dpi narrows the field, no auto" armeabi-v7a BUNDLE "-1-android-apk-download" 2639006 "120-480dpi"

# --- shared ranking helpers, asserted directly so the table cases stay readable
py_rank() { "$PY" -c "import sys;sys.path.insert(0,'scripts');import apkmirror_search as a;print(a.minapi_rank(sys.argv[1]))" "$1"; }
want_rank() {
	local in=$1 want=$2 got
	got=$(py_rank "$in") || fail "minapi_rank python raised on '$in'"
	[ "$got" = "$want" ] || fail "python minapi_rank('$in') = $got, want $want"
	got=$(_amk_minapi_rank "$in")
	[ "$got" = "$want" ] || fail "bash _amk_minapi_rank('$in') = $got, want $want"
	printf 'ok  %-46s %s\n' "minapi_rank('$in')" "$want"
}
want_rank "Android 8.0+" 800
want_rank "Android 12L+" 1200
want_rank "Android 4.0.3+" 400
want_rank "Android 10+" 1000
# An unreadable column must rank LAST, never claim a version it does not state.
want_rank "varies with Android" 999999

py_cls() {
	"$PY" -c "import sys;sys.path.insert(0,'scripts');import apkmirror_search as a;r=a.arch_class(sys.argv[1],sys.argv[2]);print('NONE' if r is None else r)" "$1" "$2"
}
want_cls() {
	local col=$1 arch=$2 want=$3 got
	got=$(py_cls "$col" "$arch") || fail "arch_class python raised on '$col'"
	[ "$got" = "$want" ] || fail "python arch_class('$col','$arch') = $got, want $want"
	if _amk_arch_class "$col" "$arch" >/dev/null 2>&1; then
		got=$(_amk_arch_class "$col" "$arch")
	else
		got=NONE
	fi
	[ "$got" = "$want" ] || fail "bash _amk_arch_class('$col','$arch') = $got, want $want"
	printf 'ok  %-46s %s\n' "arch_class('$col','$arch')" "$want"
}
want_cls "universal" arm64-v8a 0
want_cls "noarch" armeabi-v7a 0
want_cls "arm64-v8a + armeabi-v7a" armeabi-v7a 0
want_cls "arm64-v8a + armeabi-v7a + x86 + x86_64" armeabi-v7a 0
want_cls "arm64-v8a" arm64-v8a 1
want_cls "arm64-v8a" armeabi-v7a NONE
want_cls "armeabi-v7a" arm64-v8a NONE
want_cls "arm64-v8a + armeabi-v7a" all NONE
want_cls "" arm64-v8a NONE

# --- bundle before APK (the caller's pass order)
order=$(_apkmirror_type_order | tr '\n' ' ')
[ "$order" = "BUNDLE APK " ] || fail "variant pass order must be 'BUNDLE APK', got '$order'"
printf 'ok  %-46s %s\n' "apkmirror type pass order" "$order"

if [ "$SH_OK" != true ]; then
	echo "SKIP: the no-python mirror in utils.sh was not exercised - $HTMLQ is not"
	echo "      executable here. The mirror half of every case above runs on the"
	echo "      trace-verify job, where bin/htmlq/htmlq-x86_64 is a Linux ELF."
fi
echo "APKMIRROR VARIANT TESTS: PASS"
