#!/usr/bin/env bash
# Functional regression tests for the plain-APK ABI strip: _strip_apk_abis and the
# keep-list it shares with --striplibs (_striplibs_keep_of_arch). The trace goldens do
# not cover this — they drive patch_apk directly and never reach build_rv's strip
# section.
#
# Every case asserts what must SURVIVE beside what must go, and the per-arch verdicts are
# a literal table rather than something recomputed from the function under test (a derived
# expectation would still pass if the keep-list were wrong). The surviving assertions are
# not decoration: the pattern this replaces, "lib/x86/*", could satisfy a delete-only test
# while deleting nothing at all, because zip matches the stored name and reports a miss as
# rc 12 — which the old code threw away with `|| :`.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
cd "$t" || exit 1
fail() { echo "FAIL: $*"; exit 1; }

python3 - <<'PY'
import zipfile

with zipfile.ZipFile('shapes.apk', 'w') as z:
    z.writestr('AndroidManifest.xml', 'M')
    z.writestr('classes.dex', 'D')
    z.writestr('lib/arm64-v8a/libso.so', 'A')
    z.writestr('lib/armeabi-v7a/libso.so', 'B')
    z.writestr('lib/x86/libso.so', 'C')
    z.writestr('lib/x86/sub/deep.so', 'C2')            # zip's * crosses '/'
    z.writestr('lib/x86_64/libso.so', 'D')
    z.writestr('lib/armeabi/libso.so', 'E')            # legacy ABI name
    z.writestr('lib/mips/libso.so', 'F')
    z.writestr('./lib/arm64-v8a/libroot.so', 'G')      # ./-rooted entry
    z.writestr('assets/engine/lib/x86/libso.so', 'H')  # not a native-lib dir
    z.writestr('lib/whatever/libso.so', 'I')           # an app's own lib dir

# The two controls: an artifact with nothing foreign, and one whose only foreign entries
# are ./-rooted — the exact shape the old wildcard matched nothing on.
with zipfile.ZipFile('arm64only.apk', 'w') as z:
    z.writestr('AndroidManifest.xml', 'M')
    z.writestr('lib/arm64-v8a/libso.so', 'A')
with zipfile.ZipFile('dotslash.apk', 'w') as z:
    z.writestr('AndroidManifest.xml', 'M')
    z.writestr('lib/arm64-v8a/libso.so', 'A')
    z.writestr('./lib/x86/libso.so', 'C')
    z.writestr('./lib/armeabi/libso.so', 'E')
PY

listing() { unzip -Z1 "$1" | tr -d '\r'; }
keep() { grep -qxF -- "$2" <<<"$3" || fail "$1: lost $2"; }
drop() { grep -qxF -- "$2" <<<"$3" && fail "$1: still carries $2"; }

# --- the keep-list both sides of the strip read ---
[ "$(_striplibs_keep_of_arch arm64-v8a)" = "arm64-v8a" ] || fail "keep arm64-v8a"
[ "$(_striplibs_keep_of_arch arm-v7a)" = "armeabi-v7a" ] || fail "keep arm-v7a spelling"
[ "$(_striplibs_keep_of_arch x86)" = "x86" ] || fail "keep x86"
[ "$(_striplibs_keep_of_arch x86_64)" = "x86_64" ] || fail "keep x86_64"
[ "$(_striplibs_keep_of_arch all)" = "arm64-v8a,armeabi-v7a" ] || fail "keep all = arm pair"
[ "$(_striplibs_keep_of_arch universal)" = "arm64-v8a,armeabi-v7a" ] || fail "keep universal"
[ "$(_striplibs_keep_of_arch ARM64)" = "arm64-v8a" ] || fail "keep arch alias"

# --- per-arch verdicts, pinned literally ---
LIBS='lib/arm64-v8a/libso.so ./lib/arm64-v8a/libroot.so lib/armeabi-v7a/libso.so lib/armeabi/libso.so lib/x86/libso.so lib/x86/sub/deep.so lib/x86_64/libso.so lib/mips/libso.so'
declare -A KEEPS=([arm64-v8a]='lib/arm64-v8a/libso.so ./lib/arm64-v8a/libroot.so'
	[arm-v7a]='lib/armeabi-v7a/libso.so'
	[x86]='lib/x86/libso.so lib/x86/sub/deep.so'
	[x86_64]='lib/x86_64/libso.so'
	[all]='lib/arm64-v8a/libso.so ./lib/arm64-v8a/libroot.so lib/armeabi-v7a/libso.so')

for arch in arm64-v8a arm-v7a x86 x86_64 all; do
	out="out_$arch.apk"
	_strip_apk_abis shapes.apk "$out" "$arch" || fail "strip rc ($arch)"
	[ -f "${out}.strip.tmp" ] && fail "$arch: temp archive left behind"
	L=$(listing "$out")
	for n in $LIBS; do
		if [[ " ${KEEPS[$arch]} " == *" $n "* ]]; then
			keep "$arch" "$n" "$L"
		else
			drop "$arch" "$n" "$L"
		fi
	done
	# None of these is a native-lib directory, so no arch may delete it: the last one is
	# the collateral the widened "*lib/x86/*" pattern caused when it was measured.
	keep "$arch" 'AndroidManifest.xml' "$L"
	keep "$arch" 'classes.dex' "$L"
	keep "$arch" 'lib/whatever/libso.so' "$L"
	keep "$arch" 'assets/engine/lib/x86/libso.so' "$L"
done

# --- control: nothing foreign means a plain copy, no rewrite, no temp ---
_strip_apk_abis arm64only.apk out_clean.apk arm64-v8a || fail "clean strip rc"
cmp -s arm64only.apk out_clean.apk || fail "clean artifact was rewritten"
[ -f out_clean.apk.strip.tmp ] && fail "clean run left a temp"

# --- control: ./-rooted entries follow the same verdict, not the name's shape ---
listing dotslash.apk | grep -qxF './lib/x86/libso.so' || fail "fixture lost its ./ entry"
_strip_apk_abis dotslash.apk out_dot.apk arm64-v8a || fail "dotslash strip rc"
L=$(listing out_dot.apk)
drop dotslash './lib/x86/libso.so' "$L"
drop dotslash './lib/armeabi/libso.so' "$L"
keep dotslash 'lib/arm64-v8a/libso.so' "$L"
keep dotslash 'AndroidManifest.xml' "$L"

echo "PASS: arch strip"
