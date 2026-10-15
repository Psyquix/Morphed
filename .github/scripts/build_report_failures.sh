#!/bin/bash
# build_report_failures.sh — turn the per-app failure records the engine left in
# temp/failures into ONE batched Telegram message on the failure-notification
# topic, uploading each build log to xi.pe and linking it inline.
#
# Why a separate CI step instead of notifying from the engine: the engine stays
# free of network/notification code (and of Telegram credentials in its env);
# this step owns the whole report and is fail-soft like every other notify path,
# so one bad xi.pe upload never fails the build step.
#
# Records (written by scripts/utils.sh + scripts/build.sh), one per app+arch:
#   <slug>.json    a build that aborted (has <slug>.log alongside)
#   <slug>_dl.json a build whose download sources were all exhausted
#   <slug>_np.json a build the patch set refused for every supported version, so no
#                  APK was ever fetched (the dl record must not cover it: asking for a
#                  manual upload of a file nobody wanted is noise)
# Records are regrouped by app base name and rendered in three parts: a Build
# Failed section (per-arch versionCode + the log link), a Download Failures section
# (per-arch versionCode + search-engine links for the APK) and a Patch Compatibility
# section (the versions the bundle refused + the bundle link to complain to). Each arch
# carries its own version so an app that resolved a different version per arch
# never renders a wrong shared version.
#
# Route B: when this step actually sends, it writes reported_failures=true so
# ci.yml can skip the generic "🔴 CI #N failed" alert for the same run.
#
# Env: TG_TOKEN TG_CHAT_ID TG_THREAD_NOTIFY APKS_REPO
#      GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_OUTPUT
# TG_CHAT_ID and TG_THREAD_NOTIFY come from repository variables only: with no
# built-in handle, an unset one fails this step (reported_failures stays unset,
# so ci.yml still raises its generic alert) rather than posting to a stale chat.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=notify_targets.sh
source "$SCRIPT_DIR/notify_targets.sh"

NL=$'\n'
FAILURES_DIR="temp/failures"
TG_LIMIT=4096
XIPE_URL_BASE="https://xi.pe"

if [ -z "${TG_TOKEN:-}" ]; then
	echo "TG_TOKEN is not set. Skipping failure report."
	exit 0
fi
if [ ! -d "$FAILURES_DIR" ] || ! find "$FAILURES_DIR" -maxdepth 1 -name '*.json' -print -quit | grep -q .; then
	echo "No failure records in $FAILURES_DIR; nothing to report."
	exit 0
fi
# Checked after the "nothing to report" exit so a clean build never fails this
# step over routing config it did not need.
tg_require_targets \
	"TG_CHAT_ID=${TG_CHAT_ID:-}" \
	"TG_THREAD_NOTIFY=${TG_THREAD_NOTIFY:-}" || exit 1

# Markdown (legacy) has no escape-all helper; strip the few characters that
# would corrupt a [label](url) or a *bold* run in app-authored text.
md_clean() { printf '%s' "$1" | tr -d '[]`'; }

version_label() { # $1=version — hide the unhelpful placeholder values
	local v="${1:-}"
	case "$v" in
	'' | auto | latest | beta | exp) printf '' ;;
	*) printf 'v%s' "${v#v}" ;;
	esac
}

# app_base <app-label> <arch> — the app name with the engine's " (<arch>)" build
# suffix removed, so per-arch records regroup under one name. Only the exact
# " (<arch>)" suffix is stripped, so a legitimate table name like "YouTube
# (Experimental)" keeps its parenthetical.
app_base() {
	local app=$1 arch=$2
	[ -n "$arch" ] && app="${app% ($arch)}"
	printf '%s' "$app"
}

# uniq_col <n> <blob> — first-seen unique values of pipe-column n, empties dropped.
uniq_col() { printf '%s\n' "$2" | cut -d'|' -f"$1" | sed '/^$/d' | awk '!s[$0]++'; }

# ---- Collect records, grouped by app base name (ordered by first sighting) ----
# Per record the blob is:  arch | version | versionCode | logurl | patches | pkg
declare -A BREC DREC BORDERSET DORDERSET VCFB
BORDER=""; DORDER=""
shopt -s nullglob
for json in "$FAILURES_DIR"/*.json; do
	case "$json" in *_dl.json | *_np.json) continue ;; esac
	slug="$(basename "${json%.json}")"
	# A cascaded case (download exhausted, or the patch set refused, then the build
	# itself failed) is reported once, as the build failure; drop its twins.
	[ -f "$FAILURES_DIR/${slug}_dl.json" ] && rm -f "$FAILURES_DIR/${slug}_dl.json"
	[ -f "$FAILURES_DIR/${slug}_np.json" ] && rm -f "$FAILURES_DIR/${slug}_np.json"

	app="$(jq -r '.app // empty' "$json")"
	arch="$(jq -r '.arch // empty' "$json")"
	ver="$(version_label "$(jq -r '.version // empty' "$json")")"
	vc="$(jq -r '.vc // empty' "$json")"
	patches="$(jq -r '.patches_src // empty' "$json")"

	# Upload the log; a non-URL response means no link (the app is still listed).
	logurl=""
	if [ -f "$FAILURES_DIR/$slug.log" ]; then
		link="$(curl -sS --data-binary "@$FAILURES_DIR/$slug.log" "$XIPE_URL_BASE/" 2> /dev/null || true)"
		case "$link" in "$XIPE_URL_BASE/"*) logurl="$link" ;; esac
	fi

	base="$(app_base "$app" "$arch")"
	# A build that failed even after the engine's version-code arch fallback is a
	# genuine incompatibility, not a transient miss - flag it for the note below.
	[ "$(jq -r '.vc_fallback // false' "$json")" = "true" ] && VCFB[$base]=1
	BREC[$base]+="${arch}|${ver}|${vc}|${logurl}|${patches}|${NL}"
	[ -z "${BORDERSET[$base]:-}" ] && { BORDER+="${base}${NL}"; BORDERSET[$base]=1; }
done

for json in "$FAILURES_DIR"/*_dl.json; do
	app="$(jq -r '.app // empty' "$json")"
	arch="$(jq -r '.arch // empty' "$json")"
	ver="$(version_label "$(jq -r '.version // empty' "$json")")"
	vc="$(jq -r '.vc // empty' "$json")"
	pkg="$(jq -r '.pkg // empty' "$json")"
	base="$(app_base "$app" "$arch")"
	# No log and no patches for a download failure; blob must still be 6 fields
	# (arch|ver|vc|log|patches|pkg) so the reader's columns line up.
	DREC[$base]+="${arch}|${ver}|${vc}|||${pkg}${NL}"
	[ -z "${DORDERSET[$base]:-}" ] && { DORDER+="${base}${NL}"; DORDERSET[$base]=1; }
done

# Patch-compatibility rejections: no APK was fetched, so the "version" slot carries the
# versions the bundle refused and the patches slot names the bundle to fix.
declare -A NREC NORDERSET
NORDER=""
for json in "$FAILURES_DIR"/*_np.json; do
	app="$(jq -r '.app // empty' "$json")"
	arch="$(jq -r '.arch // empty' "$json")"
	patches="$(jq -r '.patches_src // empty' "$json")"
	pkg="$(jq -r '.pkg // empty' "$json")"
	# ".tried" is a comma list of version names; render each with its v prefix.
	tried="$(jq -r '.tried // empty' "$json")"
	ver="$(printf '%s' "$tried" | tr ',' '\n' | sed -e 's/^v//' -e '/^$/d' -e 's/^/v/' | paste -sd ' ' -)"
	vc="$(jq -r '.vc // empty' "$json")"
	patch_url="$(jq -r '.patch_url // empty' "$json")"
	base="$(app_base "$app" "$arch")"
	# Columns: arch|ver|vc|log|patches|pkg|patch_url; the log is absent because
	# build_rv returned clean, and patch_url names the bundle release that refused.
	NREC[$base]+="${arch}|${ver}|${vc}||${patches}|${pkg}|${patch_url}${NL}"
	[ -z "${NORDERSET[$base]:-}" ] && { NORDER+="${base}${NL}"; NORDERSET[$base]=1; }
done
shopt -u nullglob

# arch_token <ver> <vc> — the `v<version> (<versionCode>)` code span for one arch
# line, collapsing to whatever pieces are actually known.
arch_token() { # $1=ver $2=vc
	local ver=$1 vc=$2
	[ -z "$ver" ] && { [ -n "$vc" ] && printf '(%s)' "$vc"; return 0; }
	printf '`%s%s`' "$ver" "${vc:+ ($vc)}"
}

# search_links <pkg> <base> <ver> — three engine links to locate the missing APK.
search_links() { # $1=pkg $2=base $3=ver(label, maybe 'vX')
	local enc q
	q="${1:-$2}${3:+ ${3#v}} android apk"
	enc="$(jq -rn --arg q "$q" '$q|@uri')"
	printf 'Search [Google](https://www.google.com/search?q=%s) / [DuckDuckGo](https://duckduckgo.com/?q=%s) / [Brave](https://search.brave.com/search?q=%s)' "$enc" "$enc" "$enc"
}

# render_app_group <base> <blob> <mode build|dl|np> — one grouped app block. All
# modes list each arch as "arch `vX (vc)`: <link>"; build links the log, download links
# the search engines, np links the patch bundle that refused the versions. Build adds a
# Patches line naming the failing bundle.
render_app_group() { # $1=base $2=blob $3=mode
	local base=$1 blob=$2 mode=$3 out arch ver vc log patches pkg patch_url tok links
	out="📱 $(md_clean "$base")"
	if [ "$mode" = build ]; then
		patches=$(uniq_col 5 "$blob" | head -1)
		[ -n "$patches" ] && out+="${NL}  ╰ Patches: [$(md_clean "$patches")](https://github.com/$patches)"
		[ -n "${VCFB[$base]:-}" ] && out+="${NL}  ╰ version-code arch fallback already tried; genuine incompatibility (not retried)"
	fi
	while IFS='|' read -r arch ver vc log patches pkg patch_url; do
		[ -z "$arch" ] && continue
		tok="$(arch_token "$ver" "$vc")"
		if [ "$mode" = build ]; then
			[ -z "$log" ] && { out+="${NL}  ╰ ${arch}${tok:+ ${tok}}"; continue; }
			links="[Log](${log})"
		elif [ "$mode" = np ]; then
			# No log, no APK to hunt for: the bundle is the thing that has to change.
			[ -z "$patches" ] && { out+="${NL}  ╰ ${arch}${tok:+ ${tok}}"; continue; }
			if [ -n "$patch_url" ]; then
				# Deep-link the exact release that refused, labelled with its tag.
				links="[$(md_clean "$patches/${patch_url##*/}")](${patch_url})"
			else
				links="[Patch bundle](https://github.com/$patches)"
			fi
		else
			links="$(search_links "$pkg" "$base" "$ver")"
		fi
		out+="${NL}  ╰ ${arch}${tok:+ ${tok}}: ${links}"
	done <<< "$blob"
	printf '%s' "$out"
}

# ---- Assemble the three parts ----
# Render each app block first and count only the ones that produce output, so a
# part never prints its "(N apps)" header over an empty body.
build_body=""; dl_body=""; np_body=""; cbuild=0; cdl=0; cnp=0
while IFS= read -r base; do
	[ -z "$base" ] && continue
	blk="$(render_app_group "$base" "${BREC[$base]}" build)"
	[ -z "${blk//[[:space:]]/}" ] && continue
	build_body+="${blk}${NL}${NL}"; cbuild=$((cbuild + 1))
done <<< "$BORDER"
while IFS= read -r base; do
	[ -z "$base" ] && continue
	blk="$(render_app_group "$base" "${NREC[$base]:-}" np)"
	[ -z "${blk//[[:space:]]/}" ] && continue
	np_body+="${blk}${NL}${NL}"; cnp=$((cnp + 1))
done <<< "$NORDER"
while IFS= read -r base; do
	[ -z "$base" ] && continue
	blk="$(render_app_group "$base" "${DREC[$base]}" dl)"
	[ -z "${blk//[[:space:]]/}" ] && continue
	dl_body+="${blk}${NL}${NL}"; cdl=$((cdl + 1))
done <<< "$DORDER"

if [ "$cbuild" = 0 ] && [ "$cdl" = 0 ] && [ "$cnp" = 0 ]; then
	echo "Failure records present but nothing renderable; no report sent."
	exit 0
fi

MSG=""
# Each section carries its own hint directly beneath it, so the guidance sits next
# to the failures it refers to instead of in a block at the very end. Section
# bodies end in a trailing blank line; $(printf '%s' …) drops it so the hint lands
# one line under the last app, and sections are joined by a single blank line.
if [ "$cbuild" -gt 0 ]; then
	MSG+="*🚨 Build Failed (${cbuild} app$([ "$cbuild" = 1 ] && echo '' || echo 's'))*${NL}${NL}$(printf '%s' "$build_body")${NL}${NL}⚠️ Report the issue to the patch author with the log link."
fi
if [ "$cnp" -gt 0 ]; then
	[ -n "$MSG" ] && MSG+="${NL}${NL}"
	MSG+="*🧩 Patch Compatibility (${cnp} app$([ "$cnp" = 1 ] && echo '' || echo 's'))*${NL}${NL}$(printf '%s' "$np_body")${NL}${NL}⚠️ These versions have no patch to apply or no patch for that arch."
fi
if [ "$cdl" -gt 0 ]; then
	[ -n "$MSG" ] && MSG+="${NL}${NL}"
	MSG+="*📡 Download Failures (${cdl} app$([ "$cdl" = 1 ] && echo '' || echo 's'))*${NL}${NL}$(printf '%s' "$dl_body")${NL}${NL}ℹ️ Upload the APK to the [cache repo](https://github.com/${APKS_REPO:-nullcpy/apks}) manually."
fi

if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
	run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
	MSG+="${NL}${NL}⚙️ [View Run]($run_url)"
fi

# ---- Chunk on line boundaries and send ----
send_chunk() {
	local text="${1:-}"
	[ -z "$text" ] && return 0
	curl -s -X POST \
		--data-urlencode "parse_mode=Markdown" \
		--data-urlencode "disable_web_page_preview=true" \
		--data-urlencode "text=${text}" \
		--data-urlencode "chat_id=${TG_CHAT_ID}" \
		--data-urlencode "message_thread_id=${TG_THREAD_NOTIFY}" \
		"https://api.telegram.org/bot${TG_TOKEN}/sendMessage" > /dev/null || true
}

CHUNK=""
sent=0
while IFS= read -r LINE; do
	CANDIDATE="${CHUNK:+${CHUNK}${NL}}${LINE}"
	if [ "${#CANDIDATE}" -le "$TG_LIMIT" ]; then
		CHUNK="$CANDIDATE"
	else
		if [ -n "$CHUNK" ]; then
			send_chunk "$CHUNK"
			sent=1
		fi
		CHUNK="$LINE"
	fi
done <<< "$MSG"
if [ -n "$CHUNK" ]; then
	send_chunk "$CHUNK"
	sent=1
fi

if [ "$sent" = 1 ] && [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "reported_failures=true" >> "$GITHUB_OUTPUT"
fi
