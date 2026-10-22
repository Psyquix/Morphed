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

rm -rf "$apk_cache_dir"
echo "CACHE HELPER TESTS: PASS"
