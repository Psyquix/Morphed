#!/usr/bin/env bash
# Offline regression tests for the preferred-format chain: the compile validator,
# the two order helpers (_pref_class_order, _pref_ext_order), the Archive extension
# picker (dl_archive), the APKPure link picker (_apkpure_pick_link) and the class
# parity of scripts/uptodown.py's resolver.
#
# The contract: the chain is an ordered PREFIX of each source's variant order,
# never a filter - a source without the preferred shape still serves the next one,
# and an unset key must leave every source's historical order byte-for-byte intact.
# The universal-over-per-ABI axis is NOT part of the chain (IP-quota policy) and the
# cases below pin both halves of that separation.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1
CWD=$(pwd)
export CWD

fail() { echo "FAIL: $*"; exit 1; }
pass() { printf 'ok  %-52s %s\n' "$1" "$2"; }

# A caller-side view of the chain, exactly as build.sh writes it into app_args.
declare -A args=()

# --- _pref_ext_order: chain first, unnamed entries keep the given default order
ext_case() { # $1=label $2=chain(rest: default list is fixed here) $3=expected
	local label=$1 chain=$2 want=$3 got
	got=$(_pref_ext_order "$chain" apk apkm xapk apks | tr '\n' ' ')
	[ "$got" = "$want" ] || fail "$label: want '$want', got '$got'"
	pass "$label" "$want"
}
ext_case "ext: unset names nothing (caller keeps its default)" "" ""
ext_case "ext: xapk first" "xapk" "xapk apk apkm apks "
ext_case "ext: chain order is the order" "apks apk" "apks apk apkm xapk "
ext_case "ext: token not in defaults is skipped" "apk.apkm" "apk apkm xapk apks "

# --- class collapse (the axis APKMirror and Uptodown share)
cls_case() { # $1=chain $2=expected class order
	local got
	got=$(_pref_class_order "$1" BUNDLE APK | tr '\n' ' ')
	[ "$got" = "$2" ] || fail "class order for '$1': want '$2', got '$got'"
	pass "class: chain '$1'" "$2"
}
cls_case "" "BUNDLE APK "
cls_case "apk" "APK BUNDLE "
cls_case "apkm" "BUNDLE APK "
cls_case "apkm apk xapk" "BUNDLE APK "
cls_case "apk apk" "APK BUNDLE "

# --- compile validator: unset stays unset, unknown aborts, duplicate warns+dedupes
v=""
_pref_format_validate "" App && v=$__PREF_CHAIN || fail "unset chain must validate cleanly"
[ -z "$v" ] || fail "unset chain produced '$v'"
pass "validate: unset stays unset" ""

v=""
_pref_format_validate "APK xapk xapk" App && v=$__PREF_CHAIN || fail "valid chain rejected: $v"
[ "$v" = "apk xapk" ] || fail "case/dedup: want 'apk xapk', got '$v'"
pass "validate: lowercase + dedupe" "$v"

out=$( ( _pref_format_validate "apk aab" App ) 2>&1 ) && rc=0 || rc=$?
[ "$rc" != 0 ] || fail "unknown token 'aab' did not abort"
grep -q "unknown token 'aab'" <<<"$out" || fail "abort message missing the token: $out"
pass "validate: unknown token aborts" "rc=$rc"

out=$( ( _pref_format_validate "apk apk" App ) 2>&1 ); rc=$?
[ "$rc" = 0 ] || fail "duplicate token aborted (rc=$rc) - it must only warn"
grep -q "duplicate token 'apk'" <<<"$out" || fail "duplicate produced no warning: $out"
pass "validate: duplicate warns, keeps compiling" "rc=0"

# --- Archive: chain reorders the extension scan, composites stay in the tail
# The merge of a fake bundle is not what these cases assert (the chosen URL is),
# so _bundle_to_apk is stubbed - a real one would read a real zip. It also writes
# what the caller passes it to produce (base.apk under a passthrough shape).
_bundle_to_apk() { cp -f "$1" "$2"; : >"${2%/*}/base.apk" 2>/dev/null || true; }
ARCHIVE_LIST=$'pkg-1.2.3-arm64-v8a.apk\npkg-1.2.3-arm64-v8a.xapk\npkg-1.2.3-all.apk\npkg-1.2.3-arm64-v8a.apkm'
dl_ext_case() { # $1=chain $2=version_code $3=list $4=expected suffix
	local _reqlog req rc got chain=$1 vc=$2 list=$3 want=$4
	_reqlog=$(mktemp)
	req() { echo "$1" >>"$_reqlog"; : >"$2"; }
	__ARCHIVE_RESP__=$list
	args[preferred_format]=$chain
	dl_archive "https://arch.example/pkg" "1.2.3" "out.pkg.apk" "arm64-v8a" false false "$vc" >/dev/null 2>&1; rc=$?
	got=$(head -1 "$_reqlog" 2>/dev/null); got=${got##*/}
	[ "$rc" = 0 ] || { rm -f "$_reqlog"; fail "dl_archive failed (rc=$rc) chain='$chain' vc='$vc'"; }
	[[ "$got" == *"$want" ]] || fail "archive chain '$chain': want '$want', got '$got'"
	pass "archive: chain '$chain' vc '$vc'" "$want"
	rm -f "$_reqlog" out.pkg.apk out.pkg out.pkg.xapk out.pkg.apkm out.pkg.apks
}
dl_ext_case "" "" "$ARCHIVE_LIST" "-arm64-v8a.apk"
dl_ext_case "xapk" "" "$ARCHIVE_LIST" "-arm64-v8a.xapk"
dl_ext_case "apkm xapk" "" "$ARCHIVE_LIST" "-arm64-v8a.apkm"
# Only a composite exists: the named plain spellings miss, the tail still finds it.
dl_ext_case "apk" "" "pkg-1.2.3-arm64-v8a.apk.apkm" "-arm64-v8a.apk.apkm"
# The versionCode pass honours the chain too.
dl_ext_case "xapk" "77" $'pkg-1.2.3-77-arm64-v8a.apk\npkg-1.2.3-77-arm64-v8a.xapk' "-77-arm64-v8a.xapk"

# --- APKPure: chain outranks the featured kind; unset keeps the historical pick
apkpure_case() { # $1=label $2=chain $3=featured $4=page html $5=arch $6=want ("" = no link)
	local got
	args[preferred_format]=$2
	got=$(_apkpure_pick_link "$4" "$5" "$3" "" 2>/dev/null) || got=""
	if [ -z "$6" ]; then
		[ -z "$got" ] || { echo "FAIL: $label: expected no link, got '$got'"; exit 1; }
	else
		[[ "$got" == *"$6"* ]] || { echo "FAIL: $1: want '$6', got '$got'"; exit 1; }
	fi
	pass "$1" "${6:-<none>}"
}
PAGE_A_ONLY='<a href="https://d.apkpure.com/b/APK/com.x?versionCode=10&amp;nc=arm64-v8a"></a>'
PAGE_BOTH='<a href="https://d.apkpure.com/b/APK/com.x?versionCode=10&amp;nc=arm64-v8a"></a><a href="https://d.apkpure.com/b/XAPK/com.x?versionCode=10&amp;nc=arm64-v8a"></a>'
FEATURED='<a id="download_link" href="https://d.apkpure.com/b/APK/com.x?versionCode=10&amp;nc=arm64-v8a">'
feat_x=${FEATURED//b\/APK\?/b\/XAPK\?}
# Featured link missing entirely + universal rows of both kinds: the historical order
# picks arch across BOTH kinds first (universal), then filters the kind - the chain is
# what may change the kind, nothing else.
PAGE_UNIV='<a href="https://d.apkpure.com/b/XAPK/com.x?versionCode=9&amp;nc=arm64-v8a%2Carmeabi-v7a"></a><a href="https://d.apkpure.com/b/APK/com.x?versionCode=9&amp;nc=arm64-v8a%2Carmeabi-v7a"></a>'

apkpure_case "apkpure: unset + featured APK keeps APK" "" "$FEATURED" "$PAGE_BOTH" arm64-v8a "/b/APK/"
apkpure_case "apkpure: chain apk outranks featured XAPK" "apk" "$feat_x" "$PAGE_BOTH" arm64-v8a "/b/APK/"
apkpure_case "apkpure: chain xapk outranks featured APK" "xapk" "$FEATURED" "$PAGE_BOTH" arm64-v8a "/b/XAPK/"
apkpure_case "apkpure: chain falls through when shape absent" "xapk" "$feat_x" "$PAGE_A_ONLY" arm64-v8a "/b/APK/"
# Negative control for the line above: the same featured-XAPK page WITHOUT an XAPK
# row must still land on the APK row - the chain never hard-fails a source.
apkpure_case "apkpure: featured kind missing, plain kept" "" "$feat_x" "$PAGE_A_ONLY" arm64-v8a "/b/APK/"
apkpure_case "apkpure: no featured, no chain -> universal" "" "" "$PAGE_UNIV" arm64-v8a "nc=arm64-v8a%2Carmeabi-v7a"
apkpure_case "apkpure: no featured, chain xapk -> universal XAPK" "xapk" "" "$PAGE_UNIV" arm64-v8a "/b/XAPK/"
args[preferred_format]=""

# --- Uptodown resolver parity: rows carry only an xapk flag, so the chain must
# collapse to the same two classes there as here (no network: pure functions).
PY=python3
command -v "$PY" >/dev/null 2>&1 || PY=python
if command -v "$PY" >/dev/null 2>&1; then
	"$PY" - <<'PYEOF'
import sys
sys.path.insert(0, "scripts")
import uptodown as u

assert u._preferred_class("") is None
assert u._preferred_class("apk xapk") == "apk"
assert u._preferred_class("xapk") == "bundle"
assert u._preferred_class("apks") == "bundle"
assert u._fmt_class("apk") == "apk" and u._fmt_class("apkm") == "bundle"
PYEOF
	[ $? -eq 0 ] || fail "uptodown.py class parity"
	pass "uptodown.py: class parity with utils.sh" "ok"
else
	echo "SKIP: no python interpreter; uptodown.py class parity was not exercised"
fi

echo "PREFERRED-FORMAT TESTS: PASS"
