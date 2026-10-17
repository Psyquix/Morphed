#!/usr/bin/env bash
# Functional regression tests for the `fdroid` download source in scripts/utils.sh
# (get_fdroid_resp / get_fdroid_vers / get_fdroid_pkg_name / dl_fdroid).
#
# The contract being guarded: an F-Droid repo is read through the site API (package-page
# URL) or through its index jar (bare repo URL), and the release the build downloads is
# the one the repo names for the requested version, code and arch. Every acceptance has
# a matching refusal in the same suite, because a resolver that answered for any input
# would pass the positive cases too: an unknown version, an arch the release does not
# carry, an empty package list, a repo with no index, and a repo root naming no app all
# have to drop the source instead of inventing a URL.
#
# Offline: `req` is stubbed onto fixture files, so no F-Droid host is contacted. Only
# unzip + jq are real (they parse the index jar), matching how the engine reads it.
set -u
FIX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/fixtures/fdroid" && pwd)"
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
cd "$t" || exit 1

TEMP_DIR="$t/temp"
mkdir -p "$TEMP_DIR"
JAR_V1="$t/index-v1.jar"
JAR_LEGACY="$t/index-legacy.jar"
python3 - "$FIX_DIR" "$JAR_V1" "$JAR_LEGACY" <<'PY'
import sys, zipfile
fix, v1, legacy = sys.argv[1], sys.argv[2], sys.argv[3]
with zipfile.ZipFile(v1, 'w') as z:
    z.write(fix + '/index-v1.json', 'index-v1.json')
with zipfile.ZipFile(legacy, 'w') as z:
    z.write(fix + '/index-legacy.json', 'index.json')
PY

declare -a APK_URLS=()
REQ_CALLS=0
REQ_FAIL=""
fail() { echo "FAIL: $*"; exit 1; }
reset_fd() {
	__FDROID_URL__="" __FDROID_ORIGIN__="" __FDROID_REPO__="" __FDROID_PKG__="" __FDROID_TABLE__=""
	APK_URLS=()
	REQ_CALLS=0
	REQ_FAIL=""
	pkg_name=""
}
req() {
	local url=$1 out=$2
	REQ_CALLS=$((REQ_CALLS + 1))
	if [ -n "$REQ_FAIL" ] && [[ "$url" == *"$REQ_FAIL"* ]]; then return 1; fi
	case "$url" in
		# `-` means stdout here too: the engine reads the API through `req <url> -`,
		# which is curl's `-o -`, so the stub has to honour it the same way.
		*/api/v1/packages/com.example.app)
			if [ "$out" = "-" ]; then cat "$FIX_DIR/api-com.example.app.json"; else cat "$FIX_DIR/api-com.example.app.json" > "$out"; fi
			return 0
			;;
		*/api/v1/packages/com.example.empty)
			if [ "$out" = "-" ]; then printf '{"packageName":"x","packages":[]}'; else printf '{"packageName":"x","packages":[]}' > "$out"; fi
			return 0
			;;
		*/index-v1.jar) cp -f "$JAR_V1" "$out" 2>/dev/null || return 1; return 0 ;;
		*/index.jar) cp -f "$JAR_LEGACY" "$out" 2>/dev/null || return 1; return 0 ;;
	esac
	case "$url" in
		*.apk) APK_URLS+=("$url"); printf 'FAKE-APK' > "$out"; return 0 ;;
	esac
	return 1
}
row() { sed -n "${1}p" <<<"$__FDROID_TABLE__"; }
# field <row> <column> - the table is tab-separated, and comparing one field at a time
# beats string-building tabs inside a [[ ]] test.
field() { sed -n "${1}p" <<<"$__FDROID_TABLE__" | cut -f"$2"; }

# --- 1. package-page URL: split, parse, newest first ------------------------------
reset_fd
get_fdroid_resp "https://example.net/fdroid/en/packages/com.example.app/" || fail "page form parse"
[[ "$__FDROID_ORIGIN__" == "https://example.net" ]] || fail "origin: $__FDROID_ORIGIN__"
[[ "$__FDROID_REPO__" == "https://example.net/repo" ]] || fail "repo: $__FDROID_REPO__"
[[ "$__FDROID_PKG__" == "com.example.app" ]] || fail "pkg: $__FDROID_PKG__"
[ "$(wc -l <<<"$__FDROID_TABLE__")" = 4 ] || fail "row count: $(wc -l <<<"$__FDROID_TABLE__")"
# The fixture lists codes 200,212,210,211; the table must come out newest-first.
[[ "$(field 1 1)" == "2.1.2" ]] || fail "newest name: [$(row 1)]"
[[ "$(field 1 2)" == "212" ]] || fail "newest code: [$(row 1)]"
[[ "$(field 1 3)" == "com.example.app_212.apk" ]] || fail "constructed apk name: [$(row 1)]"
[[ -z "$(field 1 4)" ]] || fail "site API declares no ABIs, column must stay empty"
[[ "$(field 2 1)" == "2.1.1" && "$(field 2 2)" == "211" ]] || fail "second row: [$(row 2)]"
[ "$(get_fdroid_vers | get_highest_ver)" = "2.1.2" ] || fail "get_highest_ver over the parsed list"
[[ "$(get_fdroid_pkg_name)" == "com.example.app" ]] || fail "pkg_name getter"

# --- 2. release selection by name, by pinned code, and by latest ------------------
dl_fdroid "https://example.net/fdroid/en/packages/com.example.app/" "2.1.1" out.apk arm64-v8a nodpi false "" || fail "by name"
[[ "${APK_URLS[0]}" == "https://example.net/repo/com.example.app_211.apk" ]] || fail "name pick: ${APK_URLS[*]}"
APK_URLS=()
dl_fdroid "https://example.net/fdroid/en/packages/com.example.app/" "2.1.1" out.apk arm64-v8a nodpi false "200" || fail "by code"
[[ "${APK_URLS[0]}" == "https://example.net/repo/com.example.app_200.apk" ]] || fail "pinned code ignored: ${APK_URLS[*]}"
APK_URLS=()
dl_fdroid "https://example.net/fdroid/en/packages/com.example.app/" "" out.apk arm64-v8a nodpi true "" || fail "by latest"
[[ "${APK_URLS[0]}" == "https://example.net/repo/com.example.app_212.apk" ]] || fail "latest pick: ${APK_URLS[*]}"

# --- 3. negative control: a version the repo does not have ------------------------
APK_URLS=()
dl_fdroid "https://example.net/fdroid/en/packages/com.example.app/" "9.9.9" out.apk arm64-v8a nodpi false "" &&
	fail "invented a URL for an unpublished version"
[ "${#APK_URLS[@]}" = 0 ] || fail "refused version still transferred"

# --- 3b. build.sh strips a trailing slash (and a trailing 'download') from every
# dlurl before it reaches a source, so the package must also resolve without the slash
# - otherwise every config author would silently get a wrong package name.
reset_fd
get_fdroid_resp "https://example.net/fdroid/en/packages/com.example.app" || fail "slash-less page URL"
[[ "$__FDROID_PKG__" == "com.example.app" ]] || fail "package from a slash-less URL: $__FDROID_PKG__"
[[ "$__FDROID_REPO__" == "https://example.net/repo" ]] || fail "repo from a slash-less URL: $__FDROID_REPO__"

# --- 4. bare repo URL: index-v1.jar, names verbatim, nativecode mapped ------------
reset_fd
pkg_name="com.example.app"
get_fdroid_resp "https://example.net/fdroid/repo" || fail "repo form parse"
[[ "$__FDROID_REPO__" == "https://example.net/fdroid/repo" ]] || fail "repo kept: $__FDROID_REPO__"
[[ "$(row 2)" == *"com.example.app_quirk_211.apk"* ]] || fail "apkName must come from the index verbatim: [$(row 2)]"
grep -q "arm-v7a" <<<"$__FDROID_TABLE__" || fail "armeabi-v7a not mapped to the build token"
[[ -z "$(field 3 4)" ]] || fail "entry without nativecode must have an empty column"

# --- 5. declared ABIs gate the download; a blank column does not ------------------
APK_URLS=()
dl_fdroid "https://example.net/fdroid/repo" "2.1.1" out.apk arm-v7a nodpi false "" &&
	fail "arm64-only release satisfied an arm-v7a build"
[ "${#APK_URLS[@]}" = 0 ] || fail "refused arch still transferred"
APK_URLS=()
dl_fdroid "https://example.net/fdroid/repo" "2.1.1" out.apk arm64-v8a nodpi false "" || fail "matching arch refused"
[[ "${APK_URLS[0]}" == *"/com.example.app_quirk_211.apk" ]] || fail "verbatim name not used: ${APK_URLS[*]}"
APK_URLS=()
dl_fdroid "https://example.net/fdroid/repo" "2.0.0" out.apk anything-goes nodpi false "" ||
	fail "an undeclared ABI list should defer to the artifact gate"

# --- 6. legacy index fallback (no index-v1.jar, member index.json) ----------------
reset_fd
pkg_name="com.example.legacy"
REQ_FAIL="index-v1.jar"
get_fdroid_resp "https://example.net/legacy/repo" || fail "legacy index fallback"
[[ "$(field 1 1)" == "1.5" && "$(field 1 2)" == "15" ]] || fail "legacy row: [$(row 1)]"
[[ "$(field 1 3)" == "com.example.legacy_15.apk" ]] || fail "legacy apk name: [$(row 1)]"
[[ "$(field 1 4)" == "arm-v7a" ]] || fail "legacy abis: [$(row 1)]"
APK_URLS=()
dl_fdroid "https://example.net/legacy/repo" "1.5" out.apk arm-v7a nodpi false "" || fail "legacy download"
[[ "${APK_URLS[0]}" == *"/com.example.legacy_15.apk" ]] || fail "legacy pick: ${APK_URLS[*]}"
APK_URLS=()
dl_fdroid "https://example.net/legacy/repo" "1.5" out.apk arm64-v8a nodpi false "" && fail "x86-era arm64 accepted"

# --- 7. negative controls: every unusable repo drops the source -------------------
reset_fd
pkg_name="com.example.app"
REQ_FAIL="/index"
get_fdroid_resp "https://example.net/dead/repo" 2>/dev/null && fail "repo with no index accepted"

reset_fd
get_fdroid_resp "https://example.net/fdroid/en/packages/com.example.empty/" 2>/dev/null &&
	fail "empty package list accepted"
reset_fd
get_fdroid_resp "https://example.net/fdroid/repo" 2>/dev/null && fail "bare repo accepted with no pkg-name"
reset_fd
pkg_name="com.example.app"
get_fdroid_resp "not-a-url" 2>/dev/null && fail "a non-URL accepted as a repo"

# --- 8. the parsed repo is memoized: one index fetch per run ----------------------
reset_fd
pkg_name="com.example.app"
get_fdroid_resp "https://example.net/fdroid/repo" >/dev/null 2>&1 || fail "first parse"
local_calls=$REQ_CALLS
get_fdroid_resp "https://example.net/fdroid/repo" >/dev/null 2>&1 || fail "memoized call rc"
[ "$REQ_CALLS" = "$local_calls" ] || fail "memoized URL re-fetched ($REQ_CALLS vs $local_calls)"

echo "F-DROID SOURCE TESTS: PASS"
