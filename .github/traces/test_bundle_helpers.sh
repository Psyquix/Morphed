#!/usr/bin/env bash
# Functional regression tests for the morphe bundle-passthrough helpers in
# scripts/utils.sh (_bundle_ext_of/_bundle_extract_base/_trim_bundle_for_arch/
# bundle cache probe+touch). The trace goldens don't cover this section.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
cd "$t" || exit 1

python3 - <<'PY'
import zipfile
parts=['base.apk','config.arm64_v8a.apk','config.armeabi_v7a.apk',
       'config.x86.apk','config.x86_64.apk','config.hdpi.apk','config.en.apk']
for n in parts:
    with zipfile.ZipFile(n,'w') as z: z.writestr('x','y')
with zipfile.ZipFile('vendor.xapk','w') as z:
    for n in parts: z.write(n,n)
    z.writestr('manifest.json','{}')
PY

fail() { echo "FAIL: $*"; exit 1; }
trim() { _trim_bundle_for_arch vendor.xapk "$1" "$2" || fail "trim rc $2"; unzip -Z1 "$1" | grep -E '\.apk$' | sort | tr '\n' ' '; }

L=$(trim t64.xapk arm64-v8a)
[[ "$L" == "base.apk config.arm64_v8a.apk config.en.apk config.hdpi.apk " ]] || fail "arm64 members: $L"
L=$(trim tar.xapk arm-v7a)
[[ "$L" == "base.apk config.armeabi_v7a.apk config.en.apk config.hdpi.apk " ]] || fail "arm-v7a members: $L"
L=$(trim tx8.xapk x86)
[[ "$L" == "base.apk config.en.apk config.hdpi.apk config.x86.apk " ]] || fail "x86 members: $L"
L=$(trim tx6.xapk x86_64)
[[ "$L" == "base.apk config.en.apk config.hdpi.apk config.x86_64.apk " ]] || fail "x86_64 members: $L"

_bundle_ext_of vendor.xapk >/dev/null || fail "ext detect"
_bundle_extract_base vendor.xapk extracted_base.apk && [ -s extracted_base.apk ] || fail "base extract"
_bundle_ext_of foo.apk >/dev/null 2>&1 && fail "false bundle"

# cache probe prefers the bundle only when _CACHE_BUNDLE_OK
apk_cache_dir="$t/cache"; mkdir -p "$apk_cache_dir"
declare -A args=([version_code]="" [cli_source]="")
cli_jar=""; patches_jar=""; cli_lv_extra=""; pkg_name="com.test"
cp vendor.xapk "$apk_cache_dir/com.test-1.0-all.xapk"
_CACHE_BUNDLE_OK=true
_cache_probe_apk 1.0 all || true
[[ "$_CACHE_CHECK_APK" == *.xapk ]] || fail "probe bundle: [$_CACHE_CHECK_APK]"
_CACHE_BUNDLE_OK=false
_cache_probe_apk 1.0 all || true
[[ -z "$_CACHE_CHECK_APK" ]] || fail "bundle leaked into disabled probe"

# touch refreshes bundle names too
touch -d "2020-01-01" "$apk_cache_dir/com.test-1.0-all.xapk"
_cache_touch_apks 1.0 all
[[ $(find "$apk_cache_dir/com.test-1.0-all.xapk" -newermt "2021-01-01") ]] || fail "touch bundle"

# --- arch-honesty predicate + learned download-link index (docs/decisions/0007) ---
python3 - <<'PY'
import zipfile
with zipfile.ZipFile('arm64only.xapk','w') as z:
    z.writestr('base.apk','x'); z.writestr('config.arm64_v8a.apk','y'); z.writestr('config.hdpi.apk','z')
with zipfile.ZipFile('noarch.apk','w') as z:
    z.writestr('AndroidManifest.xml','x')
PY

# _artifact_abis reads config splits (a bundle has no top-level lib/ entry).
_artifact_abis vendor.xapk | grep -qxF arm64-v8a || fail "vendor.xapk should read arm64-v8a"
_abis_satisfies "arm64-v8a arm-v7a" arm-v7a || fail "abis_satisfies: list contains arch"
_abis_satisfies "arm64-v8a" arm-v7a && fail "abis_satisfies: other single ABI must NOT satisfy"
_abis_satisfies "" arm-v7a || fail "abis_satisfies: empty ABIs satisfy any arch (arch-agnostic)"
_abis_satisfies "arm64-v8a" all || fail "abis_satisfies: catch-all arch satisfied by anything"

_artifact_satisfies_arch arm64only.xapk arm64-v8a || fail "arm64 artifact satisfies arm64"
_artifact_satisfies_arch arm64only.xapk arm-v7a && fail "arm64-only must NOT satisfy arm-v7a (this is the mislabel)"
_artifact_satisfies_arch vendor.xapk arm-v7a || fail "universal must keep the 32-bit build"
_artifact_satisfies_arch noarch.apk arm-v7a || fail "arch-agnostic apk satisfies any arch"

# Learned link index: fetch-once-then-adopt, refuse-without-refetch only on evidence.
export TEMP_DIR="$t/tmpidx"
_dlurl_index_record "https://store/x?vc=20" arm64only.xapk
[[ "$(_dlurl_index_lookup "https://store/x?vc=20" arm64-v8a)" == *.xapk ]] || fail "index adopts the right arch (no refetch)"
[[ "$(_dlurl_index_lookup "https://store/x?vc=20" arm-v7a)" == "REJECT" ]] || fail "index rejects a wrong single ABI"
# Negative control: an unknown link is fetched, never refused without evidence.
[[ -z "$(_dlurl_index_lookup "https://store/never-fetched" arm-v7a)" ]] || fail "unknown link must NOT be refused"
# A key whose blob vanished reads as unknown, not as a stale hit.
_b=$(cut -f2 "${TEMP_DIR}/urlindex/keys/$(_dlurl_sha "https://store/x?vc=20")")
rm -f "$_b"
[[ -z "$(_dlurl_index_lookup "https://store/x?vc=20" arm64-v8a)" ]] || fail "stale blob must read as unknown"
# A universal blob is adopted for either arch.
_dlurl_index_record "https://store/uni?vc=20" vendor.xapk
[[ "$(_dlurl_index_lookup "https://store/uni?vc=20" arm-v7a)" == *.xapk ]] || fail "universal adopt for arm-v7a"
[[ "$(_dlurl_index_lookup "https://store/uni?vc=20" arm64-v8a)" == *.xapk ]] || fail "universal adopt for arm64"

echo "BUNDLE HELPER TESTS: PASS"
