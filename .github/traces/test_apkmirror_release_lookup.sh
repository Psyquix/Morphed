#!/usr/bin/env bash
# Fixture regression tests for the APKMirror RELEASE-PAGE lookup inside dl_apkmirror:
# which page a version request ends up on when the store answers for a whole site instead
# of for one app.
#
# Why this exists: run 40175646917 built Truecaller-bufferk arm-v7a (and arm64) at the one
# version its patch bundle advertises, 26.10.6 (March 2026). That release IS on APKMirror, at
#   /apk/true-software-scandinavia-ab/truecaller-caller-id-block/truecaller-trusted-caller-id-26-10-6-release/
# published under the app's FORMER name, so neither slug guess reached it; the app's own
# listing page shows ten recent releases and /page/N/ re-renders the same ten, so the page
# walk never saw it either; and the version-only "?s=26.10.6" query is answered SITE-WIDE,
# where the old 'grep -F "26-10-6-release" | head -1' landed on another developer's 26.10.6
# (ru.vkusvill). The package guard then rejected the page and dl_apkmirror returned —
# abandoning the whole source while the correct link sat further down the same result list.
# The last-resort site search could not have rescued it either: queried by listing slug it
# answers "No results found", while the same query by app name returns the release.
#
# The assertions read the stub's request log, because that IS the decision under test —
# which release page the lookup settled on, and which it fetched and refused. Everything
# past the resolved page needs bin/htmlq, so those assertions run only where htmlq is
# executable, exactly as in test_apkmirror_variants.sh; the skip is printed, never silent.
#
# Offline: `_cf_get` is replaced by a URL→fixture table that records every request, and
# `_cf_cffi_download` writes bytes instead of fetching. The candidate ordering, the package
# reader, the variant picker and the download chain stay the real ones.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
# shellcheck disable=SC1091
source scripts/utils.sh >/dev/null 2>&1
CWD=$(pwd)
export CWD
FIX="$CWD/.github/traces/fixtures/apkmirror"
t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
# Stay in the repository: set_prebuilts hands out bin/htmlq, bin/aapt2 and bin/toml as paths
# relative to CWD, so a test that moved into its scratch dir could not resolve them even
# where those binaries are runnable.
TEMP_DIR="$t/temp"
mkdir -p "$TEMP_DIR"
fail() { echo "FAIL: $*"; exit 1; }

for f in lookup-category lookup-search-versiononly lookup-search-renamedlisting \
	lookup-search-wrongthenright lookup-search-allwrong lookup-release-truecaller \
	lookup-release-vkusvill lookup-noresults lookup-download; do
	[ -s "$FIX/$f.html" ] || fail "fixture missing: $FIX/$f.html"
done

CF_LOG="$t/cf.log"
RUN_LOG="$t/run.log"
SCENE=collision
RUN_RC=0

# Which result field this scene's search pages show.
scene_field() {
	case "$SCENE" in
		collision) body="$FIX/lookup-search-versiononly.html" ;;
		renamed) body="$FIX/lookup-search-renamedlisting.html" ;;
		wrongthenright) body="$FIX/lookup-search-wrongthenright.html" ;;
		allwrong) body="$FIX/lookup-search-allwrong.html" ;;
		noresults) body="$FIX/lookup-noresults.html" ;;
		*) fail "unknown scene '$SCENE'" ;;
	esac
}

# The stubbed store. Order matters: the release pages are matched before the listing pages,
# and the two slug guesses the live site answers with a 404 are refused here, so a test
# cannot pass by the guess happening to hit a fixture.
_cf_get() {
	local url=$1 body=""
	printf '%s\n' "$url" >> "$CF_LOG"
	case "$url" in
		*"-android-apk-download"*) body="$FIX/lookup-download.html" ;;
		*"/download/?key="*) body="$FIX/lookup-download.html" ;;
		*apkmirror.com/d/*) body="$FIX/lookup-download.html" ;;
		*truecaller-spam-call-blocker-26-10-6-release*) return 1 ;;
		*truecaller-caller-id-block-26-10-6-release*) return 1 ;;
		*truecaller-trusted-caller-id-26-10-6-release*) body="$FIX/lookup-release-truecaller.html" ;;
		*"-26-10-6-release"*) body="$FIX/lookup-release-vkusvill.html" ;;
		*"/?s=26.10.6") scene_field ;;
		# The site search is asked with the app's title, so it answers with the field a
		# lookup in this scene would see. Only 'noresults' differs: there the version-only
		# query is empty while the name query returns the collision field — that difference
		# is the whole point of case 7.
		*"searchtype=apk&s=truecaller-spam-call-blocker+26.10.6")
			if [ "$SCENE" = noresults ]; then
				body="$FIX/lookup-search-versiononly.html"
			else
				scene_field
			fi
			;;
		*"searchtype=apk&s=vkusvill-delivery+26.10.6") scene_field ;;
		*"searchtype=apk&s=truecaller-caller-id-block+26.10.6") body="$FIX/lookup-noresults.html" ;;
		*"/apk/true-software-scandinavia-ab/truecaller-caller-id-block/"*) body="$FIX/lookup-category.html" ;;
		*"/apk/vkusvill/vkusvill-delivery/"*) body="$FIX/lookup-category.html" ;;
		*) return 1 ;;
	esac
	html=$(cat "$body")
	return 0
}
# The store's own file endpoint: land bytes, do not fetch.
_cf_cffi_download() { printf 'FAKE-TRUECALLER-APK\n' > "$2"; return 0; }

# Does bin/htmlq run here? Everything past the resolved release page needs it; on a Windows
# checkout it is a Linux ELF and those assertions are skipped, loudly. set_prebuilts runs
# either way, because dl_apkmirror reads $HTMLQ the way the engine leaves it.
set_prebuilts >/dev/null 2>&1 || true
HQ_OK=false
if [ -n "${HTMLQ:-}" ] \
	&& [[ "$("$HTMLQ" "div.probe" --text <<<'<div class="probe">yes</div>' 2>/dev/null)" == *yes* ]]; then
	HQ_OK=true
fi

# $1=scene  $2=pkg_name  $3=apkmirror-dlurl  $4=version
run_lookup() {
	SCENE=$1
	pkg_name=$2
	local url=$3 ver=$4
	: > "$CF_LOG"
	rm -f "$t/out.apk" "$t/out.apkm"
	__APKMIRROR_RESP__=$(cat "$FIX/lookup-category.html")
	__APKMIRROR_CAT__="${url%/}"
	__APKMIRROR_CAT__="${__APKMIRROR_CAT__##*/}"
	__APKMIRROR_EXAMPLE_URL__=""
	dl_apkmirror "$url" "$ver" "$t/out.apk" arm-v7a "nodpi anydpi auto" false "" >"$RUN_LOG" 2>&1
	RUN_RC=$?
}

req_count() { # $1=substring of the requested URLs
	local n
	n=$(grep -cF -- "$1" "$CF_LOG" 2>/dev/null) || true
	printf '%s' "${n:-0}"
}
log_has() {
	grep -qF -- "$1" "$RUN_LOG" || fail "$2: log lacks '$1' — $(tr '\n' '|' <"$RUN_LOG")"
}
log_hasnt() {
	if grep -qF -- "$1" "$RUN_LOG"; then fail "$2: log must not contain '$1'"; fi
}
say() { printf 'ok  %-52s %s\n' "$1" "$2"; }
# What the lookup settled on: the release page it accepted must have been fetched, and the
# version must not have been reported missing. Past this point the run belongs to the
# picker, which is test_apkmirror_variants.sh's surface.
settled_on() { # $1=label  $2=release slug that must be fetched  [$3=exact fetch count]
	if [ -z "${3:-}" ]; then
		[ "$(req_count "$2")" -ge 1 ] || fail "$1: '$2' was never fetched — $(tr '\n' ' ' <"$CF_LOG")"
	else
		[ "$(req_count "$2")" = "$3" ] ||
			fail "$1: '$2' fetched $(req_count "$2") times, want $3 — $(tr '\n' ' ' <"$CF_LOG")"
	fi
	log_hasnt "Could not find version 26.10.6 on APKMirror" "$1"
	log_hasnt "Resolved APKMirror page is for" "$1"
}

TC_URL="https://www.apkmirror.com/apk/true-software-scandinavia-ab/truecaller-caller-id-block/"
TC_REL="truecaller-trusted-caller-id-26-10-6-release"
UD_REL="vkusvill-delivery-26-10-6-release"

# --- 1. the reported failure: a version-only search field whose first hit is another app
# must still settle on this app's release page, published under its FORMER slug. The links
# outside this app's listing are not fetched at all: the listing path puts the answer first.
run_lookup collision com.truecaller "$TC_URL" 26.10.6
settled_on "collision" "$TC_REL"
[ "$(req_count "$UD_REL")" = 0 ] || fail "collision: a link outside the listing was fetched anyway"
[ "$(req_count "pulsepoint")" = 0 ] || fail "collision: a 26.10.6892 near miss was taken for 26.10.6"
[ "$(req_count "instabridge")" = 0 ] || fail "collision: a 26.10.6.1 near miss was taken for 26.10.6"
[ "$(req_count "google-play-services-26-10-65")" = 0 ] || fail "collision: a 26.10.65 near miss was taken"
if [ "$HQ_OK" = true ]; then
	[ "$RUN_RC" = 0 ] || fail "collision: rc=$RUN_RC; log: $(tr '\n' '|' <"$RUN_LOG")"
	[ -s "$t/out.apk" ] || fail "collision: no artifact written"
fi
say "collision: in-listing link wins, neighbours untouched" "rc=$RUN_RC"

# --- 2. negative control for the ordering above: the same field, building the OTHER app.
# The lookup must follow pkg_name rather than the fixture's most-mentioned link; a stub that
# simply took the last link of the field would fail here.
run_lookup collision ru.vkusvill "https://www.apkmirror.com/apk/vkusvill/vkusvill-delivery/" 26.10.6
settled_on "other-app control" "$UD_REL"
[ "$(req_count "$TC_REL")" = 0 ] || fail "other-app control: Truecaller's page fetched for ru.vkusvill"
if [ "$HQ_OK" = true ]; then
	[ "$RUN_RC" = 0 ] || fail "other-app control: rc=$RUN_RC"
	[ -s "$t/out.apk" ] || fail "other-app control: no artifact written"
fi
say "same field, other package: that package wins" "rc=$RUN_RC"

# --- 3. the field holds the answer, but outside this app's listing path. Ordering by that
# path must never become a filter: a renamed or relocated app is invisible to a path
# comparison while its own page still states the right package.
run_lookup renamed com.truecaller "$TC_URL" 26.10.6
settled_on "relocated" "$TC_REL"
log_hasnt "instead of 'com.truecaller'" "relocated"
if [ "$HQ_OK" = true ]; then
	[ "$RUN_RC" = 0 ] || fail "relocated: rc=$RUN_RC"
fi
say "candidate outside the listing path still accepted" "rc=$RUN_RC"

# --- 4. collisions FIRST and nothing under the listing path: each wrong page is fetched,
# named and skipped, and the right page behind them is still reached. This is the case the
# old code lost when the guard returned instead of taking the next result.
run_lookup wrongthenright com.truecaller "$TC_URL" 26.10.6
[ "$(req_count "vkusvill")" = 2 ] ||
	fail "skip-then-win: expected 2 collision pages, saw $(req_count "vkusvill")"
settled_on "skip-then-win" "$TC_REL"
log_has "instead of 'com.truecaller'; trying the next result" "skip-then-win"
if [ "$HQ_OK" = true ]; then
	[ "$RUN_RC" = 0 ] || fail "skip-then-win: rc=$RUN_RC; log: $(tr '\n' '|' <"$RUN_LOG")"
	[ -s "$t/out.apk" ] || fail "skip-then-win: no artifact written"
fi
say "collision skipped, later candidate wins" "rc=$RUN_RC"

# --- 5. a field that is all collision and no answer: the candidate budget bounds the
# requests to that one field, the version is reported as not found, and no other app's bytes
# are written. One field is one budget — the listing and the site search ask the store
# different questions, so each gets its own look; what must not happen is walking an
# unlimited number of pages, or downloading any of them.
run_lookup allwrong com.truecaller "$TC_URL" 26.10.6
sl=$(grep -nF "searchtype=apk&s=" "$CF_LOG" | head -1 | cut -d: -f1)
[ -n "$sl" ] || fail "all-collision: the walk never reached the site search — $(tr '\n' ' ' <"$CF_LOG")"
[ "$(head -n $((sl - 1)) "$CF_LOG" | grep -cF vkusvill)" = "$_APKMIRROR_CANDIDATE_LIMIT" ] ||
	fail "all-collision: the first field was walked past the budget of $_APKMIRROR_CANDIDATE_LIMIT"
if [ "$HQ_OK" = true ]; then
	# The title query re-offers the same field, and the one link the budget had not reached
	# is tried — and refused — before the version is reported missing.
	[ "$(req_count vkusvill)" = "$((_APKMIRROR_CANDIDATE_LIMIT + 1))" ] ||
		fail "all-collision: $(req_count vkusvill) collision pages fetched, want the budget plus the site search's one new link"
else
	echo "      note: without htmlq the site search is asked with the listing slug, which the"
	echo "      live site answers 'No results found', so this run stops at the budget exactly"
	echo "      and the field's sixth link is never offered — case 7 covers the title query."
fi
log_has "Could not find version 26.10.6 on APKMirror" "all-collision"
[ ! -e "$t/out.apk" ] || fail "all-collision: a rejected app's artifact was written"
[ "$RUN_RC" != 0 ] || fail "all-collision: a field with no answer reported success"
say "all-collision field: budget honoured, nothing downloaded" "rc=$RUN_RC"

# --- 6. a package with no release in the field at all: every candidate is refused by its own
# page, so the miss is reported as a miss rather than resolved to a neighbour — which also
# proves cases 1 and 3 were decided by the package and not by a link's text. One candidate
# (the 26.10.6.1 near miss) is a dead link here, exactly as a stale search hit is on the
# live site: it must be named and skipped, not end the walk.
run_lookup collision com.example.absent "$TC_URL" 26.10.6
log_has "did not answer for version 26.10.6" "absent: a dead candidate must be reported"
[ "$(req_count "$TC_REL")" = 1 ] || fail "absent: Truecaller's page fetched $(req_count "$TC_REL") times, want 1"
[ "$(req_count "$UD_REL")" = 1 ] || fail "absent: the collision page was not tried and refused"
log_has "Could not find version 26.10.6 on APKMirror" "absent"
[ ! -e "$t/out.apk" ] || fail "absent: an artifact was written for a package the store does not have"
[ "$RUN_RC" != 0 ] || fail "absent: reported success"
say "no page for the package: miss, not a neighbour" "rc=$RUN_RC"

# --- 7. when the version-only query answers nothing, the walk has to reach the site search,
# and the site search has to be asked with the app's NAME — the listing slug is measured dead
# on the live site. The 'Apps related to' trap inside the listing page is the negative
# control on the request budget: it matches the version, belongs to another package, and is
# repeated on all ten pages, so it must be fetched once and then remembered.
run_lookup noresults com.truecaller "$TC_URL" 26.10.6
[ "$(req_count "$UD_REL")" = 1 ] ||
	fail "related-apps trap: fetched $(req_count "$UD_REL") times, want 1 (a rejection must be remembered)"
if [ "$HQ_OK" = true ]; then
	if ! grep -qF "s=truecaller-spam-call-blocker+26.10.6" "$CF_LOG"; then
		fail "site search by name: APKMirror was never asked the app title — $(tr '\n' ' ' <"$CF_LOG")"
	fi
	settled_on "site search by name" "$TC_REL"
	[ "$RUN_RC" = 0 ] || fail "site search by name: rc=$RUN_RC; log: $(tr '\n' '|' <"$RUN_LOG")"
	[ -s "$t/out.apk" ] || fail "site search by name: no artifact written"
	say "listing dead, site search by name finds it" "rc=$RUN_RC"
else
	echo "SKIP: case 7 past the resolved page needs a runnable bin/htmlq - $HTMLQ is not"
	echo "      executable here. It runs on the trace-verify job, where htmlq-x86_64 is a"
	echo "      Linux ELF. Without htmlq the site-search links cannot be read at all, so"
	echo "      the lookup legitimately stops at 'Could not find version', asserted below."
	log_has "Could not find version 26.10.6 on APKMirror" "no-htmlq"
	[ "$RUN_RC" != 0 ] || fail "no-htmlq: rc must be non-zero when the site search cannot be parsed"
	say "no htmlq: one rejection per page, then a clean miss" "rc=$RUN_RC"
fi

echo "APKMIRROR RELEASE LOOKUP TESTS: PASS"
