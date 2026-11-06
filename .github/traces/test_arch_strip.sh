#!/usr/bin/env bash
# Functional regression tests for the plain-APK ABI strip: _strip_apk_abis, the keep-list it
# shares with --striplibs (_striplibs_keep_of_arch), and the one decision that says which of
# the two does the job for a build (_patcher_strips_libs). The trace goldens do not cover
# this — they drive patch_apk directly and never reach build_rv's strip section.
#
# Every case asserts what must SURVIVE beside what must go, and the per-arch verdicts are
# a literal table rather than something recomputed from the function under test (a derived
# expectation would still pass if the keep-list were wrong). The surviving assertions are
# not decoration: the pattern this replaces, "lib/x86/*", could satisfy a delete-only test
# while deleting nothing at all, because zip matches the stored name and reports a miss as
# rc 12 — which the old code threw away with `|| :`.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
UTILS_SH="$PWD/scripts/utils.sh"
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

# --- who strips: one decision, and the patcher's half must not be paid for with the block ---
# Rewriting a signed archive deletes the APK Signing Block along with the entries, because
# the block is not an entry — it sits between the local file data and the central directory.
# An engine-rewritten plain APK therefore reaches morphe-desktop as "not signed", and the
# patches that read the STOCK certificate (spoof-signature family, universal microG
# metadata) abort. So when the patcher is handed --striplibs, the input must not be touched.
deleg() { # $1=PATCHER_KIND $2=RVB_MORPHE_STRIPLIBS $3=yes|no  — the verdict must be literal,
	# not derived from the function: a permissive rewrite of the predicate passes its own test.
	local rc=0
	PATCHER_KIND=$1
	RVB_MORPHE_STRIPLIBS=$2
	_patcher_strips_libs || rc=$?
	[ "$rc" = 0 ] && rc=yes || rc=no
	[ "$rc" = "$3" ] || fail "delegation $1/striplibs=$2: got $rc want $3"
}
deleg morphe true yes
deleg morphe false no
deleg revanced true no
deleg xposed true no
deleg instafel true no
deleg generic true no
deleg "" true no

python3 - <<'PY'
import struct, zipfile

with zipfile.ZipFile('signed.apk', 'w') as z:
    z.writestr('AndroidManifest.xml', 'M')
    z.writestr('META-INF/MANIFEST.MF', 'Manifest-Version: 1.0\n')
    z.writestr('lib/arm64-v8a/libso.so', 'A')
    z.writestr('lib/x86/libso.so', 'C')

# A structurally valid APK Signing Block, inserted where the real one lives: immediately
# before the central directory, so local-header offsets stay as they are and only the EOCD's
# cd-offset field moves. Layout: size, key-value pairs, size, 16-byte magic.
raw = open('signed.apk', 'rb').read()
eocd = raw.rfind(b'PK\x05\x06')
cd_off = struct.unpack('<I', raw[eocd + 16:eocd + 20])[0]
value = b'signed'
pair = struct.pack('<I', 8 + len(value)) + b'\x71\xba\xec\xbf\x61\x68\xe1\xae' + value
size = struct.pack('<Q', len(pair) + 8 + 16)
block = size + pair + size + b'APK Sig Block 42'
eocd_new = (raw[eocd:eocd + 16] + struct.pack('<I', cd_off + len(block)) + raw[eocd + 20:])
open('signed.apk', 'wb').write(raw[:cd_off] + block + raw[cd_off:eocd] + eocd_new)
PY

has_block() { python3 -c "
import struct, sys
raw = open(sys.argv[1], 'rb').read()
e = raw.rfind(b'PK\\x05\\x06')
o = struct.unpack('<I', raw[e + 16:e + 20])[0]
sys.exit(0 if raw[o - 16:o] == b'APK Sig Block 42' else 1)" "$1"; }

# The fixture is a readable archive with a block to lose — without this, every assertion
# below about the block would be vacuous.
listing signed.apk | grep -qxF 'lib/x86/libso.so' || fail "signed fixture lost its entries"
has_block signed.apk || fail "signed fixture has no signing block"

# The delegated path: the reuse guard still wants a file at the stripped name, and that file
# has to be the stock archive, unchanged.
cp -f signed.apk out_delegated.apk || fail "delegated copy"
cmp -s signed.apk out_delegated.apk || fail "delegated input was rewritten"
has_block out_delegated.apk || fail "delegated input lost the signing block"
listing out_delegated.apk | grep -qxF 'lib/x86/libso.so' || fail "delegated input dropped a lib"

# Negative control, and the reason the delegation exists at all: the engine's own rewrite
# really does destroy the block while doing its job correctly.
_strip_apk_abis signed.apk out_rewritten.apk arm64-v8a || fail "signed strip rc"
L=$(listing out_rewritten.apk)
keep rewritten 'lib/arm64-v8a/libso.so' "$L"
drop rewritten 'lib/x86/libso.so' "$L"
has_block out_rewritten.apk && fail "rewrite kept the signing block — the control is void"

# Wiring: the call site must ask this one predicate on both halves, or the flag and the
# input rewrite drift apart again — the strip running twice, or neither running.
W=$(sed -n '/\.stripped\.apk"$/,/patcher_args+=("--striplibs"/p' "$UTILS_SH")
[ -n "$W" ] || fail "could not read build_rv's strip section of scripts/utils.sh"
grep -q 'cp -f "$stock_apk" "$stock_apk_to_patch"' <<<"$W" || fail "delegated path no longer copies the stock apk"
grep -q 'elif ! _strip_apk_abis "$stock_apk" "$stock_apk_to_patch" "$arch_f"' <<<"$W" || fail "engine strip no longer the fallback branch"
# Exactly two gates in that window: the copy/rewrite choice and the flag. One means a half
# stopped asking; three would mean a second spelling of the condition crept in.
[ "$(grep -c 'if _patcher_strips_libs; then' <<<"$W")" = 2 ] || fail "the two strip decisions are no longer one predicate"

echo "PASS: arch strip"
