#!/usr/bin/env bash
# Functional regression tests for the `direct` download source in scripts/utils.sh.
#
# The contract being guarded: a bare file URL carries no metadata in its text, so the
# package name, version and versionCode of a direct build come from the fetched
# artifact, never from the URL's filename. Every case that used to be satisfied by
# parsing the filename is asserted here against an artifact that DISAGREES with it, so
# a re-introduced shortcut fails loudly. The absence checks each carry a negative
# control (an unset memo, a non-zip body, a mismatching package), because a predicate
# that returns nothing for every input would otherwise pass them all.
#
# Stubs: `req` (serves a fixed local body instead of the network, and in case 10 a
# transfer that dies twice before answering), `sleep` (so the retry backoff costs no
# test time) and `_meta_field_of` (reads the identity from a sidecar next to that
# body). `unzip`, `_artifact_abis` and the learned download-link index stay real.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
cd "$t" || exit 1

TEMP_DIR="$t/temp"
mkdir -p "$TEMP_DIR"
REQ_CALLS=0
FAKE_BODY=""
fail() { echo "FAIL: $*"; exit 1; }

# Build a zip shaped like an APK carrying the given vendor ABI directories.
mk_apk() { # $1=path  $2=space separated lib/<abi> names
	python3 - "$1" "$2" <<'PY'
import sys, zipfile
path, abis = sys.argv[1], [a for a in sys.argv[2].split() if a]
with zipfile.ZipFile(path, 'w') as z:
    z.writestr('AndroidManifest.xml', 'stub')
    for a in abis:
        z.writestr('lib/%s/libstub.so' % a, 'stub')
PY
}
# Identity aapt would read off the current body; empty values mean "unreadable".
set_meta() { # $1=package  $2=versionName  $3=versionCode
	printf 'package=%s\nversionName=%s\nversionCode=%s\n' "$1" "$2" "$3" > "$FAKE_BODY.meta"
}
serve() { # $1=file to serve, "" to fail the transfer outright
	FAKE_BODY="$1"
}
req() {
	REQ_CALLS=$((REQ_CALLS + 1))
	[ -n "$FAKE_BODY" ] && [ -f "$FAKE_BODY" ] || return 1
	cp -f "$FAKE_BODY" "$2" 2>/dev/null || return 1
	# The identity belongs to the bytes, so it travels with the copy.
	[ -f "$FAKE_BODY.meta" ] && cp -f "$FAKE_BODY.meta" "$2.meta"
	return 0
}
_meta_field_of() { # $1=file  $2=field
	[ -f "$1.meta" ] || return 0
	awk -F= -v k="$2" '$1 == k { sub(/^[^=]*=/, ""); print }' "$1.meta"
}

reset_direct() { # forget the probe memo between cases
	unset __DIRECT_URL__ __DIRECT_VERS__ __DIRECT_PKG_NAME__
	rm -rf "$TEMP_DIR/urlindex" "$TEMP_DIR/apks_dl"
	REQ_CALLS=0
	pkg_name=""
}

# --- 1. nothing is reported before a probe ----------------------------------------
# Negative control for the removed filename parsing: with no artifact read yet, both
# getters must fail rather than invent a value out of the URL.
reset_direct
mk_apk body.apk "arm64-v8a armeabi-v7a x86 x86_64"
get_direct_vers >/dev/null 2>&1 && fail "get_direct_vers must not answer before a probe"
get_direct_pkg_name >/dev/null 2>&1 && fail "get_direct_pkg_name must not answer before a probe"

# --- 2. a nameless URL reports the artifact's identity, not the URL's --------------
# The URL's last segment is "apk", which the old parser turned into an empty version.
reset_direct
serve body.apk
set_meta org.telegram.messenger.web 13.0.3 71839
get_direct_resp "https://telegram.org/dl/android/apk" 2>/dev/null || fail "probe of a nameless URL failed"
[[ "$(get_direct_vers)" == "13.0.3" ]] || fail "vers from bytes: got '$(get_direct_vers)'"
[[ "$(get_direct_pkg_name)" == "org.telegram.messenger.web" ]] || fail "pkg from bytes: got '$(get_direct_pkg_name)'"
[ "$REQ_CALLS" = 1 ] || fail "probe should fetch exactly once, saw $REQ_CALLS"

# --- 3. a versioned filename is ignored when the bytes disagree --------------------
# This is the case the removal is really about: the name says one app at 1.0, the
# served APK is another app at 9.9.9, and the build must follow the bytes.
reset_direct
serve body.apk
set_meta com.example.other 9.9.9 999
get_direct_resp "https://host/com.example.app-1.0-all.apk" 2>/dev/null || fail "probe failed"
[[ "$(get_direct_vers)" == "9.9.9" ]] || fail "filename leaked into vers: got '$(get_direct_vers)'"
[[ "$(get_direct_pkg_name)" == "com.example.other" ]] || fail "filename leaked into pkg: got '$(get_direct_pkg_name)'"

# --- 4. a body that is not a zip drops the source ----------------------------------
# Negative control: an HTML error page saved under an .apk name must not probe into a
# version, it must fail so the caller falls through to the next source.
reset_direct
printf '<html>not an apk</html>' > junk.apk
serve junk.apk
set_meta com.example.app 1.0 100
get_direct_resp "https://host/nameless" >/dev/null 2>&1 && fail "non-zip body accepted as an APK"
[ -z "${__DIRECT_VERS__:-}" ] || fail "memo written for a rejected body"

# --- 5. an APK whose identity aapt cannot read drops the source ---------------------
reset_direct
serve body.apk
set_meta "" "" ""
get_direct_resp "https://host/nameless" >/dev/null 2>&1 && fail "unreadable identity accepted"

# --- 6. an artifact for a different package drops the source ------------------------
reset_direct
serve body.apk
set_meta com.example.wrong 1.0 100
pkg_name="com.example.app"
get_direct_resp "https://host/nameless" >/dev/null 2>&1 && fail "package mismatch accepted"

# --- 7. the probe is reused: per-arch downloads adopt the recorded blob ------------
reset_direct
serve body.apk
set_meta com.example.app 1.0 100
pkg_name="com.example.app"
get_direct_resp "https://host/nameless" 2>/dev/null || fail "probe failed"
[ "$REQ_CALLS" = 1 ] || fail "probe fetch count: $REQ_CALLS"
get_direct_resp "https://host/nameless" 2>/dev/null || fail "memoized probe rc"
[ "$REQ_CALLS" = 1 ] || fail "memoized probe re-fetched ($REQ_CALLS)"
dl_direct "https://host/nameless" 1.0 "$t/out-arm64.apk" arm64-v8a 2>/dev/null || fail "adopt arm64"
dl_direct "https://host/nameless" 1.0 "$t/out-v7a.apk" arm-v7a 2>/dev/null || fail "adopt arm-v7a"
[ -s "$t/out-arm64.apk" ] || fail "adopted artifact is empty"
[ "$REQ_CALLS" = 1 ] || fail "dl_direct re-downloaded what the probe already had ($REQ_CALLS)"

# --- 8. a recorded single-ABI blob is refused for another arch, without a fetch -----
# Negative control for the adoption path above: the same lookup must not hand out a
# file that cannot run on the requested arch.
reset_direct
mk_apk arm64only.apk "arm64-v8a"
serve arm64only.apk
set_meta com.example.app 1.0 100
pkg_name="com.example.app"
get_direct_resp "https://host/arm64only.apk" 2>/dev/null || fail "probe of arm64-only failed"
dl_direct "https://host/arm64only.apk" 1.0 "$t/should_not_exist.apk" arm-v7a >/dev/null 2>&1 &&
	fail "arm64-only direct link satisfied an arm-v7a build"
[ ! -e "$t/should_not_exist.apk" ] || fail "rejected arch still wrote an artifact"

# --- 9. without a probe, dl_direct still fetches and records ------------------------
# Guards the fallback branch: a source that was never identified (e.g. dl_direct
# reached straight away) downloads once and records what it got.
reset_direct
serve body.apk
set_meta com.example.app 1.0 100
dl_direct "https://host/cold.apk" 1.0 "$t/cold.apk" arm64-v8a 2>/dev/null || fail "cold dl_direct"
[ -s "$t/cold.apk" ] || fail "cold download wrote nothing"
[ "$REQ_CALLS" = 1 ] || fail "cold fetch count: $REQ_CALLS"
dl_direct "https://host/cold.apk" 1.0 "$t/warm.apk" x86 2>/dev/null || fail "warm dl_direct"
[ "$REQ_CALLS" = 1 ] || fail "second arch re-fetched a recorded link ($REQ_CALLS)"

# --- 10. a transfer that dies part-way is re-requested, never resumed ---------------
# A vendor CDN that closes the socket mid-file makes curl fail with (18) "transfer
# closed with N bytes remaining", which --retry does not treat as transient and which
# -C - cannot resume through a per-request signed redirect. req_artifact must therefore
# start a fresh request; run 39985777497 lost Telegram's 70 MB universal APK on the
# first arch and its sibling's attempt twelve seconds later completed.
# Negative control: every successful case above asserts REQ_CALLS = 1, so a stub that
# always succeeds cannot be what makes these counts reach 3.
sleep() { :; }                      # keep the backoff out of the test clock
_gr_saved="${GITHUB_REPOSITORY:-}"  # the retry warning is expected, not an annotation
GITHUB_REPOSITORY=""
_req_orig=$(declare -f req)
_n_flaky=0
_n_limit=3                     # how many attempts die before the URL answers
req() {                            # dies twice, then serves the body
	REQ_CALLS=$((REQ_CALLS + 1))
	_n_flaky=$((_n_flaky + 1))
	if [ "$_n_flaky" -lt "$_n_limit" ]; then rm -f "$2" 2>/dev/null; return 1; fi
	cp -f "$FAKE_BODY" "$2" || return 1
}
reset_direct
serve body.apk
set_meta com.example.app 1.0 100
REQ_CALLS=0
req_artifact "https://host/flaky" "$t/recovered.apk" >/dev/null 2>&1 ||
	fail "a truncated transfer was not retried to success"
[ "$REQ_CALLS" = 3 ] || fail "flaky URL: expected 3 attempts, saw $REQ_CALLS"
[ -s "$t/recovered.apk" ] || fail "the successful attempt did not land the artifact"

_n_limit=9999                      # now the URL never answers
REQ_CALLS=0
req_artifact "https://host/dead" "$t/dead.apk" >/dev/null 2>&1 &&
	fail "a URL that never answered reported success"
[ "$REQ_CALLS" = 3 ] || fail "dead URL: expected 3 attempts, saw $REQ_CALLS"
[ ! -e "$t/dead.apk" ] || fail "a failed download left an artifact behind"

eval "$_req_orig"                      # the harness stub, not the real _req
GITHUB_REPOSITORY="$_gr_saved"
unset -f sleep

echo "direct source: all cases passed"
