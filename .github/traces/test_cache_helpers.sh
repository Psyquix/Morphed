#!/usr/bin/env bash
# Functional regression test for the P3b cache helpers in utils.sh
# (_cache_target_vc/_cache_probe_apk/_cache_all_archs_present/_cache_touch_apks).
# The trace goldens don't exercise build_rv's cache section, so this covers it.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1
apk_cache_dir=$(mktemp -d)
pkg_name="com.test"
declare -A args=([version_code]="" [cli_source]="")
cli_jar=""; patches_jar=""; cli_lv_extra=""
arch_list=(all)
fail() { echo "FAIL: $*"; rm -rf "$apk_cache_dir"; exit 1; }
mkdir -p "$apk_cache_dir"

: > "$apk_cache_dir/com.test-1.2.3-all.apk"
_cache_probe_apk 1.2.3 all || true
[[ "$_CACHE_CHECK_APK" == *"-1.2.3-all.apk" ]] || fail "probe all-variant"
_cache_all_archs_present 1.2.3 || fail "all_present single"
rm "$apk_cache_dir/com.test-1.2.3-all.apk"

: > "$apk_cache_dir/com.test-1.2.3-arm64-v8a.apk"
_cache_probe_apk 1.2.3 arm64-v8a || true
[[ "$_CACHE_CHECK_APK" == *"-1.2.3-arm64-v8a.apk" ]] || fail "probe stock"
_cache_probe_apk 1.2.3 arm-v7a || true
[[ -z "$_CACHE_CHECK_APK" ]] || fail "probe miss"
arch_list=(arm64-v8a arm-v7a)
_cache_all_archs_present 1.2.3 && fail "all_present should miss v7a"
arch_list=(all)

: > "$apk_cache_dir/com.test-1.2.3-all.apk"
_cache_all_archs_present 1.2.3 validate || fail "validate without vc target"

# --- arch-satisfaction rules: a universal -all.apk (or a vendor bundle) must
# satisfy every arch, so a build whose sibling arch already fetched it
# short-circuits on the cache check and touches no mirror; a per-arch stock apk
# must not leak to the other arch.
rm -f "$apk_cache_dir/com.test-1.2.3-arm64-v8a.apk"
: > "$apk_cache_dir/com.test-1.2.3-all.apk"
arch_list=(arm-v7a); _cache_all_archs_present 1.2.3 || fail "universal must satisfy arm-v7a"
arch_list=(arm64-v8a); _cache_all_archs_present 1.2.3 || fail "universal must satisfy arm64-v8a"
arch_list=(arm64-v8a arm-v7a); _cache_all_archs_present 1.2.3 || fail "universal must satisfy both arches"
rm -f "$apk_cache_dir/com.test-1.2.3-all.apk"
: > "$apk_cache_dir/com.test-1.2.3-arm64-v8a.apk"
arch_list=(arm-v7a); _cache_all_archs_present 1.2.3 && fail "per-arch apk must not satisfy the other arch"

_CACHE_BUNDLE_OK=true
: > "$apk_cache_dir/com.test-4.0.0-all.xapk"
arch_list=(arm-v7a); _cache_all_archs_present 4.0.0 || fail "bundle must satisfy arm-v7a"
arch_list=(arm64-v8a arm-v7a); _cache_all_archs_present 4.0.0 || fail "bundle must satisfy both arches"
_CACHE_BUNDLE_OK=false
arch_list=(arm-v7a); _cache_all_archs_present 4.0.0 && fail "bundle must be ignored when passthrough is off"
rm -f "$apk_cache_dir/com.test-4.0.0-all.xapk" "$apk_cache_dir/com.test-1.2.3-arm64-v8a.apk"
arch_list=(all)

args[version_code]="123"
: > "$apk_cache_dir/com.test-1.2.3-123-all.apk"
_cache_probe_apk 1.2.3 all || true
[[ "$_CACHE_VC" == "123" ]] || fail "vc from mapping"
[[ "$_CACHE_CHECK_APK" == *"-1.2.3-123-all.apk" ]] || fail "vc filename preference"

args[version_code]=""
: > "$apk_cache_dir/com.test-2.0.0-all.apk"
_cache_probe_apk 2.0.0 all || true
[[ "$_CACHE_CHECK_APK" == *"-2.0.0-all.apk" ]] || fail "legacy fallback"

: > "$apk_cache_dir/com.test-3.0.0-all.apk"; touch -d "2020-01-01" "$apk_cache_dir/com.test-3.0.0-all.apk"
_cache_touch_apks 3.0.0 all
[[ $(find "$apk_cache_dir/com.test-3.0.0-all.apk" -newermt "2021-01-01") ]] || fail "touch refresh"

# --- usage key recorded for the apks repo cache tracker. cleanup-apks.py derives
# its key by stripping (-[0-9]+)?-(<arch>).(<ext>) off the stored asset name, so the
# target versionCode must NOT appear in the recorded key: a key carrying it matches
# nothing, the version silently loses its usage stamp and ages out by upload age,
# and the phantom key is pruned as a ghost entry. (The inverse mistake is commit
# 2549f146, reverted by ef1b405b; rule documented in docs/cache-repo.md.)
# The guard is asserted against a synthetic bad line first, so it cannot pass by
# matching nothing at all.
key_carries_vc() { case "$1" in *vc_infix*) return 0 ;; *) return 1 ;; esac; }
key_carries_vc 'echo "${pkg_name}-${version_f}${vc_infix}" >> used_versions.txt' \
	|| fail "vc-in-key guard is vacuous (it accepted a line that does carry it)"
key_carries_vc 'echo "${pkg_name}-${version_f}" >> used_versions.txt' \
	&& fail "vc-in-key guard misfires on the correct key"
usage_write=$(grep -E 'echo "\$\{pkg_name\}-\$\{version_f\}.*used_versions\.txt' scripts/utils.sh)
[ -n "$usage_write" ] || fail "used_versions.txt key write not found in utils.sh (moved or renamed?)"
key_carries_vc "$usage_write" && fail "cache usage key must not contain the target versionCode: $usage_write"

# --- publish: the name a stock artifact takes in the cache dir (and so in the apks
# store) is read off its bytes, not off the arch the build happened to ask for.
# Run 39985777497 put ONE vendor universal Telegram APK into the store twice — as
# <pkg>-13.1.0-72299-all.apk and again as <pkg>-13.1.0-72299-arm-v7a.apk — because a
# plain APK inherited the requested arch name, so the sibling arch that could not
# resolve a version code both took a different lock and kept its own copy.
# Real archives are used here, not placeholders: _cache_arch_key reads the lib/ and
# config.* members, so an empty file would make every case pass as "unreadable".
pub=$(mktemp -d) || fail "mktemp for publish fixtures"
mk_apk() { # $1=path, then the lib/<abi> dirs to carry
	python3 - "$1" "${@:2}" <<'PY' || fail "python3 zip fixture"
import sys, zipfile
path, abis = sys.argv[1], sys.argv[2:]
with zipfile.ZipFile(path, 'w') as z:
    z.writestr('AndroidManifest.xml', 'M')
    z.writestr('classes.dex', 'D')
    for a in abis:
        z.writestr('lib/%s/libso.so' % a, 'L')
PY
}
mk_xapk() { # $1=path, then the split members to carry
	python3 - "$1" "${@:2}" <<'PY' || fail "python3 zip fixture"
import sys, zipfile
path, splits = sys.argv[1], sys.argv[2:]
with zipfile.ZipFile(path, 'w') as z:
    z.writestr('manifest.json', '{}')
    for s in splits:
        z.writestr(s, 'S')
PY
}
# wpr() raises a CI annotation when GITHUB_REPOSITORY is set; the mismatch cases are
# expected to warn, so silence the annotation, not the check.
_gr_saved="${GITHUB_REPOSITORY:-}"
GITHUB_REPOSITORY=""

# 1. universal bytes fetched for arm-v7a land under the shared key, byte-identical.
mk_apk "$pub/stage-v7a.apk" arm64-v8a armeabi-v7a x86 x86_64
_PUB_APK="" _PUB_ALL="" _PUB_UPLOADED=""
_publish_stock_artifact "$pub/stage-v7a.apk" "$pub" com.pub 9.9.9 -72299 arm-v7a ||
	fail "publish of a universal apk returned failure"
[[ "$_PUB_APK" == "$pub/com.pub-9.9.9-72299-all.apk" ]] ||
	fail "universal bytes must publish under -all, got: $_PUB_APK"
[[ "$_PUB_ALL" == "$_PUB_APK" ]] || fail "a -all publish must report the shared key"
cmp -s "$pub/stage-v7a.apk" "$_PUB_APK" || fail "published bytes differ from the staged artifact"
[ -n "$_PUB_UPLOADED" ] || fail "a fresh publish owes the store an upload"
# Negative control beside the existence assert: the arch the build asked for must not
# have been written at all. Checked after the cmp above, so it cannot pass because
# nothing was written anywhere.
[ ! -e "$pub/com.pub-9.9.9-72299-arm-v7a.apk" ] ||
	fail "universal bytes were cached under the requested arch as well"
[ -z "$(find "$pub" -name '*.tmp.*' -print -quit)" ] || fail "a temp publish file was left behind"

# 2. single-ABI bytes keep their own arch key — never promoted to the shared name.
mk_apk "$pub/stage64.apk" arm64-v8a
_PUB_APK="" _PUB_ALL="" _PUB_UPLOADED=""
_publish_stock_artifact "$pub/stage64.apk" "$pub" com.pub 9.9.9 -72299 arm64-v8a ||
	fail "publish of a single-abi apk returned failure"
[[ "$_PUB_APK" == "$pub/com.pub-9.9.9-72299-arm64-v8a.apk" ]] ||
	fail "single-ABI bytes must keep their arch key, got: $_PUB_APK"
[ -z "$_PUB_ALL" ] || fail "an arch-specific artifact claimed the shared -all key"
[ ! -e "$pub/com.pub-9.9.9-72299-arm-v7a.apk" ] ||
	fail "an arm64-only apk was published for arm-v7a"

# 3. adoption: a readable archive already at the destination is left alone and is not
# uploaded a second time; the staged copy survives for this build to consume.
mk_apk "$pub/earlier.apk" arm64-v8a armeabi-v7a
mk_apk "$pub/newcomer.apk" arm64-v8a armeabi-v7a x86 x86_64
cp -f "$pub/earlier.apk" "$pub/com.adopt-1.0.0-all.apk"
_PUB_APK="" _PUB_ALL="" _PUB_UPLOADED=""
_publish_stock_artifact "$pub/newcomer.apk" "$pub" com.adopt 1.0.0 "" arm-v7a ||
	fail "adoption publish returned failure"
[[ "$_PUB_APK" == "$pub/com.adopt-1.0.0-all.apk" ]] ||
	fail "adoption reported the wrong path: $_PUB_APK"
cmp -s "$pub/earlier.apk" "$_PUB_APK" || fail "an existing readable archive was rewritten"
[ -z "$_PUB_UPLOADED" ] || fail "an adopted file must not be uploaded again"
[ -f "$pub/newcomer.apk" ] || fail "adoption deleted the staged copy"

# 4. a corrupt leftover at the destination is republished, never adopted.
: > "$pub/com.bad-1.0.0-all.apk"
_PUB_APK="" _PUB_ALL="" _PUB_UPLOADED=""
_publish_stock_artifact "$pub/newcomer.apk" "$pub" com.bad 1.0.0 "" arm64-v8a ||
	fail "publish over a corrupt destination returned failure"
unzip -l "$pub/com.bad-1.0.0-all.apk" >/dev/null 2>&1 ||
	fail "a non-archive leftover was adopted instead of republished"
[ -n "$_PUB_UPLOADED" ] || fail "republishing over a corrupt file must still upload"

# 5. a bundle keeps its extension and its own ABI key.
mk_xapk "$pub/only64.xapk" base.apk config.arm64_v8a.apk
_PUB_APK="" _PUB_ALL="" _PUB_UPLOADED=""
_publish_stock_artifact "$pub/only64.xapk" "$pub" com.bnd 2.0.0 -55 arm64-v8a ||
	fail "publish of a bundle returned failure"
[[ "$_PUB_APK" == "$pub/com.bnd-2.0.0-55-arm64-v8a.xapk" ]] ||
	fail "bundle must keep its extension and ABI key, got: $_PUB_APK"
[ -z "$_PUB_ALL" ] || fail "a single-ABI bundle claimed the shared -all key"
[ ! -e "$pub/com.bnd-2.0.0-55-all.xapk" ] || fail "a single-ABI bundle was published as -all"

# 6. a bundle that does not carry the requested arch is keyed by its own bytes, so it
# can never be mistaken for somebody else's artifact (the warning is the point).
mk_xapk "$pub/mismatch.xapk" base.apk config.arm64_v8a.apk
_PUB_APK="" _PUB_ALL="" _PUB_UPLOADED=""
_publish_stock_artifact "$pub/mismatch.xapk" "$pub" com.mis 3.0.0 -77 arm-v7a ||
	fail "publish of a mis-served bundle returned failure"
[[ "$_PUB_APK" == "$pub/com.mis-3.0.0-77-arm64-v8a.xapk" ]] ||
	fail "a mis-served bundle must be cached under its own ABI, got: $_PUB_APK"
[[ "$(ls "$pub" | grep -c 'com.mis-3.0.0-77-arm-v7a')" = 0 ]] ||
	fail "a mis-served bundle also landed under the requested arch name"

# --- version-code map parsing, under the caller's deliberate `unset IFS` ----------
# build_rv ends its bundle-list split with `unset IFS` (utils.sh), and the map form
# "arm64-v8a: 111 | arm-v7a: 222" is the only path of parse_arch_mapping that reads
# "$IFS" - to save it. Under set -u that is an unbound variable, and it killed
# MicrosoftWord-kveld9 with "IFS: unbound variable" in run 40476750624, the first
# config to use the map form. Saving and restoring is also wrong here: IFS was
# *unset*, an unset value means bash's default splitting, and setting it back to ""
# would leave the caller with no word splitting at all. So the function scopes it.
(
	set -u
	unset IFS
	[ "$(parse_arch_mapping "arm64-v8a: 111 | arm-v7a: 222" arm64-v8a)" = "111" ] || exit 1
	[ "$(parse_arch_mapping "arm64-v8a: 111 | arm-v7a: 222" arm-v7a)" = "222" ] || exit 1
	# Negative controls: the bare form passes through, an unmatched arch answers empty.
	[ "$(parse_arch_mapping "123" arm64-v8a)" = "123" ] || exit 1
	[ "$(parse_arch_mapping "arm64-v8a: 111" x86_64)" = "" ] || exit 1
	# And the caller's IFS comes back exactly as it went in: unset, not "".
	[ -z "${IFS+set}" ] || exit 1
) || fail "parse_arch_mapping needs unset IFS and a set value (run 40476750624)"

GITHUB_REPOSITORY="$_gr_saved"
rm -rf "$pub"
rm -rf "$apk_cache_dir"
echo "CACHE HELPER TESTS: PASS"
