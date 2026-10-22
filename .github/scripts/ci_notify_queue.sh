#!/bin/bash
# ci_notify_queue.sh — announce on the CI log topic the exact pool the watcher has
# just committed to building (TG_THREAD_NOTIFY): every enabled app, grouped under the
# patch source and the concrete release tag that group will actually be built from.
#
# Why a notice of its own: the run's other CI message answers "what moved" (a new patch
# release, a new app version); nothing answers "so what is being built", and the
# watcher is the last place where both pools are visible together — each build job sees
# only its own config. Reading the trigger and the resulting queue back to back is what
# tells a maintainer that the edit they made is the build that is about to happen.
#
# Why the EFFECTIVE triggers and not the raw ones: ci_resolve_triggers.sh downgrades a
# channel to 0 when the regenerated pool has no enabled apps, so a raw flag can be 1
# for a pool that builds nothing. Announcing that pool would name apps nobody is
# building, which is the one thing a queue notice must never do.
#
# Why groups are (patch source, resolved tag) and not just source: the same source
# queued in both pools builds from two different bundles (stable v1.47.0 and beta
# v1.48.0-dev.17, say), and one header cannot honestly state two versions. An app
# enabled in both pools under one tag stays one block, labelled `Channel: stable, beta`
# — the expanded convention ci_notify_announcements.sh already uses.
#
# Version resolution is the same read the build itself makes, never a second decision:
# the app's `patches-version` if it carries one, else the pool's top-level value; the
# `both` routing word resolves to its own pool as build.sh does; a `stable`/`beta`
# keyword is answered from state/patch_sources.json exactly as _patch_source_state_tag
# answers it; anything else is already a concrete pin. No answer means no invented tag:
# the keyword is then printed as written and left unlinked.
#
# Env: TG_TOKEN TG_CHAT_ID TG_THREAD_NOTIFY EFFECTIVE_STABLE EFFECTIVE_BETA
#      RVB_PATCH_SOURCES_JSON (snapshot path override, as the engine's helper has)
#      GITHUB_SERVER_URL GITHUB_REPOSITORY GITHUB_RUN_ID
# TG_CHAT_ID and TG_THREAD_NOTIFY come from repository variables only: with no built-in
# handle or topic, an unset one fails this step instead of posting somewhere stale (see
# notify_targets.sh).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry_lib.sh
source "$SCRIPT_DIR/retry_lib.sh"
# shellcheck source=notify_targets.sh
source "$SCRIPT_DIR/notify_targets.sh"

NL=$'\n'
# \x1f (unit separator) is the record delimiter, never a tab: tab is IFS *whitespace*,
# so `IFS=$'\t' read` collapses runs of tabs and an app without a variant or
# sub-variant would shift every later field left onto the wrong column. A non-whitespace
# delimiter keeps empty fields empty (build_report_failures.sh delimits with | for the
# same reason).
SEP=$'\x1f'
TG_LIMIT=4096
DEF_PATCHES_SRC="MorpheApp/morphe-patches"

if [ -z "${TG_TOKEN:-}" ]; then
	echo "TG_TOKEN is not set. Skipping the build-queue notification."
	exit 0
fi

# md_clean <text> — drop the marks Telegram's legacy Markdown would eat (brackets and
# backticks as in ci_notify_announcements.sh, plus the bold/italic marks a title can
# carry). App names and tags arrive verbatim from the config, so nobody has to write a
# name without punctuation for this to render.
md_clean() { printf '%s' "$1" | tr -d '*_[]`'; }

# host_base <host> — forge web root, mirroring ci_notify_telegram.sh.
host_base() {
	case "${1:-github}" in
	gitlab) printf 'https://gitlab.com/' ;;
	codeberg) printf 'https://codeberg.org/' ;;
	*) printf 'https://github.com/' ;;
	esac
}

# release_web_url <host> <owner/repo> <tag> — the release page of one tag. This mirrors
# source_release_web_url in scripts/utils.sh (the single owner of that shape): GitLab
# puts a tag under /-/releases/, GitHub and Forgejo under /releases/tag/.
release_web_url() {
	local host=${1:-github} src=$2 tag=$3
	if [ "$host" = "gitlab" ]; then
		printf 'https://gitlab.com/%s/-/releases/%s' "$src" "$tag"
	else
		printf '%s%s/releases/tag/%s' "$(host_base "$host")" "$src" "$tag"
	fi
}

# state_tag <owner/repo> <host> <channel> — the concrete tag the watcher recorded, or
# nothing. Mirrors _patch_source_state_tag in scripts/utils.sh, blocked answer included:
# a blocked source reports "no tag" even though the snapshot keeps its last known one.
# utils.sh is not sourced here (it is the engine and expects the build sandbox), so this
# is the same projection ci_notify_telegram.sh already makes of that file.
state_tag() {
	local file="${RVB_PATCH_SOURCES_JSON:-state/patch_sources.json}"
	if [ ! -f "$file" ]; then
		return 0
	fi
	jqx -r --arg repo "${1,,}" --arg host "${2:-github}" --arg ch "$3" '
		to_entries
		| map(select(.value | type == "object"))
		| map(select(((.value.repo // .key) | ascii_downcase) == $repo))
		| map(select(((.value.host // "github") | ascii_downcase) == $host))
		| (.[0].value // {}) as $e
		| if $e.blocked == true then "" else ($e[$ch] // "") end
	' "$file"
}

# state_blocked <owner/repo> <host> — success when the snapshot marks the repository
# blocked (404/451/403 from the forge), the same read as _patch_source_state_blocked.
# The engine skips those apps outright, so the notice has to say so rather than call
# them quietly queued.
state_blocked() {
	local file="${RVB_PATCH_SOURCES_JSON:-state/patch_sources.json}"
	if [ ! -f "$file" ]; then
		return 1
	fi
	jqx -e --arg repo "${1,,}" --arg host "${2:-github}" '
		to_entries
		| map(select(.value | type == "object"))
		| map(select(((.value.repo // .key) | ascii_downcase) == $repo))
		| map(select(((.value.host // "github") | ascii_downcase) == $host))
		| (.[0].value // {}).blocked == true
	' "$file" >/dev/null 2>&1
}

# arch_list <config-file> <app-key> — the effective arch set as `arm-v7a, arm64-v8a`.
# retry_effective_arch is the shared normaliser, so an absent arch prints the "both"
# fan-out instead of the raw keyword: routing keywords are expanded, never shown.
arch_list() {
	retry_effective_arch "$1" "$2" |
		tr -s '[:space:]' '\n' | LC_ALL=C sort -u | sed '/^$/d' | paste -sd ',' - | sed 's/,/, /g'
}

# app_head <name> <key> <brand> <variant> <sub-variant> — the identity line every
# notification uses: "📱 Name (brand • variant • sub-variant)", the parenthetical
# carrying only the parts that exist, and the config key as the name of last resort.
app_head() {
	local name=$1 key=$2 part label="" out
	if [ -z "$name" ]; then
		name=$key
	fi
	for part in "$3" "$4" "$5"; do
		if [ -n "$part" ]; then
			label="${label:+${label} • }${part}"
		fi
	done
	out="📱 $(md_clean "$name")"
	if [ -n "$label" ]; then
		out+=" ($(md_clean "$label"))"
	fi
	printf '%s' "$out"
}

# ---- Collect one TSV record per enabled app per triggered pool ----
# channel, key, app-name, brand, variant, sub-variant, pkg, source, host, version, arch
EFF_STABLE=${EFFECTIVE_STABLE:-0}
EFF_BETA=${EFFECTIVE_BETA:-0}
records=""
for ch in stable beta; do
	on=$EFF_STABLE
	if [ "$ch" = "beta" ]; then
		on=$EFF_BETA
	fi
	if [ "$on" != "1" ]; then
		echo "Queue: $ch pool is not triggered for this run; not listed."
		continue
	fi
	cfg="configs/${ch}_build.json"
	if [ ! -f "$cfg" ]; then
		echo "Queue: $cfg not present; not listed."
		continue
	fi
	pool_ver=$(jqx -r '."patches-version" // empty' "$cfg") || pool_ver=""
	rec=$(jqx -r --arg ch "$ch" --arg pv "$pool_ver" --arg dsrc "$DEF_PATCHES_SRC" --arg sep "$SEP" '
		to_entries[]
		| select(.value | type == "object")
		| select(.value.enabled != false)
		| .key as $k | .value as $v
		| [ $ch, $k,
			($v["app-name"] // ""),
			($v.brand // ""),
			($v.variant // ""),
			($v["sub-variant"] // ""),
			($v["pkg-name"] // ""),
			($v["patches-source"] // $dsrc),
			($v["patches-source-host"] // "github"),
			($v["patches-version"] // $pv),
			($v.arch // "") ]
		| join($sep)
	' "$cfg")
	if [ -n "$rec" ]; then
		records+="${rec}${NL}"
	fi
done

if [ -z "${records//[[:space:]]/}" ]; then
	echo "No apps are queued in any triggered pool; no build-queue notification."
	exit 0
fi

tg_require_targets \
	"TG_CHAT_ID=${TG_CHAT_ID:-}" \
	"TG_THREAD_NOTIFY=${TG_THREAD_NOTIFY:-}" || exit 1

# ---- Group by (patch source, resolved release tag) ----
declare -A GROUP_ID GROUP_LABEL GROUP_URL GROUP_BLOCKED GROUP_COUNT GROUP_KEYS
declare -A APP_SEEN APP_CH APP_HEAD_TXT APP_ARCH
ngrp=0

while IFS=$'\x1f' read -r ch key name brand variant subvariant pkg src host ver archraw; do
	if [ -z "$key" ]; then
		continue
	fi
	if [ -z "$ver" ]; then
		# A pool always carries its own channel at the top level; if it somehow does
		# not, the pool being handled is the only honest answer.
		ver=$ch
	fi
	# `both` is pool routing, not a channel: it resolves to the pool being handled,
	# which is what build.sh does before a build ever looks at the value.
	if [ "${ver,,}" = "both" ]; then
		ver=$ch
	fi
	tag=""
	# Blocked is checked whatever the version value is, exactly as the engine does: a
	# pinned tag of a dead repository is just as undownloadable as a keyword.
	blocked=0
	if state_blocked "$src" "$host"; then
		blocked=1
	fi
	case "${ver,,}" in
	stable | beta)
		tag=$(state_tag "$src" "$host" "${ver,,}")
		;;
	*)
		tag=$ver # already a concrete pin — the config named this release
		;;
	esac
	# The label always names a version: the concrete tag when there is one, otherwise
	# the value as written (a keyword nobody has answered yet). An unanswered keyword is
	# never dressed up as a tag.
	label="${src}/${tag:-$ver}"
	url=""
	if [ -n "$tag" ]; then
		url=$(release_web_url "$host" "$src" "$tag")
	fi

	# Two apps of the same source and host but different channels can land in
	# different groups (different tags); the lookup key is the rendered pair, plus the
	# blocked flag, so a blocked source never shares a header with a live one.
	glookup="${label}|${url}|${blocked}"
	if [ -z "${GROUP_ID[$glookup]:-}" ]; then
		ngrp=$((ngrp + 1))
		GROUP_ID[$glookup]=$ngrp
		GROUP_LABEL[$ngrp]=$label
		GROUP_URL[$ngrp]=$url
		GROUP_BLOCKED[$ngrp]=$blocked
		GROUP_COUNT[$ngrp]=0
		GROUP_KEYS[$ngrp]=""
	fi
	gid=${GROUP_ID[$glookup]}

	akey="${gid}|${key}"
	if [ -z "${APP_SEEN[$akey]:-}" ]; then
		APP_SEEN[$akey]=1
		APP_CH[$akey]=$ch
		APP_HEAD_TXT[$akey]="$(app_head "$name" "$key" "$brand" "$variant" "$subvariant")"
		if [ -n "$pkg" ]; then
			APP_HEAD_TXT[$akey]+="${NL}  ╰ Package: \`${pkg}\`"
		fi
		APP_ARCH[$akey]=$(arch_list "configs/${ch}_build.json" "$key")
		GROUP_COUNT[$gid]=$((GROUP_COUNT[$gid] + 1))
		GROUP_KEYS[$gid]+="${key}${NL}"
	else
		# Same app, other pool, same tag: one block that names both channels.
		case ", ${APP_CH[$akey]}," in
		*", ${ch},") : ;;
		*) APP_CH[$akey]+=", ${ch}" ;;
		esac
	fi
done <<<"$records"

# ---- Assemble the message: group header, then its app blocks sorted by key ----
CHUNK=""
SENT=0

send_chunk() {
	local text=${1:-} resp
	if [ -z "$text" ]; then
		return 0
	fi
	resp=$(curl -s -X POST \
		--data-urlencode "parse_mode=Markdown" \
		--data-urlencode "disable_web_page_preview=true" \
		--data-urlencode "text=${text}" \
		--data-urlencode "chat_id=${TG_CHAT_ID}" \
		--data-urlencode "message_thread_id=${TG_THREAD_NOTIFY}" \
		"https://api.telegram.org/bot${TG_TOKEN}/sendMessage")
	# Telegram answers HTTP 200 with {"ok":false} for some errors; the body decides.
	if ! grep -q '"ok":true' <<<"$resp"; then
		echo "::error::Telegram rejected a build-queue chunk: ${resp}" >&2
		return 1
	fi
	SENT=1
}

flush_chunk() {
	# A chunk holding only the title is never sent: it would strand a message that says
	# nothing. The next unit simply appends to it.
	if [ -z "$CHUNK" ] || [ "$CHUNK" = "$TITLE" ]; then
		return 0
	fi
	send_chunk "$CHUNK"
	CHUNK=""
}

# put <text> — append a unit that is known to fit a message, starting a new buffer when
# this one is empty. Units are joined by a blank line, never glued.
put() {
	if [ -z "$CHUNK" ]; then
		CHUNK=$1
	else
		CHUNK+="${NL}${NL}$1"
	fi
}

TITLE="*🛠️ Apps Queued for Build!*"
put "$TITLE"

# Groups are ordered by the lowercased label, so a owner who capitalises their repo
# differently from another still gets a stable, readable order.
ordered_gids=$(
	for ((gid = 1; gid <= ngrp; gid++)); do
		printf '%s\t%s\n' "$(printf '%s' "${GROUP_LABEL[$gid]}" | tr 'A-Z' 'a-z')" "$gid"
	done | LC_ALL=C sort | cut -f2-
)

declare -a GROUP_BLOCKS

for gid in $ordered_gids; do
	n=${GROUP_COUNT[$gid]}
	plural=$([ "$n" = 1 ] && printf 'app' || printf 'apps')
	if [ -n "${GROUP_URL[$gid]}" ]; then
		header="🧩 [$(md_clean "${GROUP_LABEL[$gid]}")](${GROUP_URL[$gid]}) · ${n} ${plural}"
	else
		header="🧩 $(md_clean "${GROUP_LABEL[$gid]}") · ${n} ${plural}"
	fi
	if [ "${GROUP_BLOCKED[$gid]}" = 1 ]; then
		header+="${NL}  ╰ 🚫 Repository access blocked."
	fi

	GROUP_BLOCKS=()
	while IFS= read -r key; do
		if [ -z "$key" ]; then
			continue
		fi
		akey="${gid}|${key}"
		GROUP_BLOCKS+=("${APP_HEAD_TXT[$akey]}${NL}  ╰ Arch: ${APP_ARCH[$akey]:-arm-v7a, arm64-v8a} · Channel: ${APP_CH[$akey]}")
	done <<<"$(printf '%s' "${GROUP_KEYS[$gid]}" | sed '/^$/d' | LC_ALL=C sort -u)"

	# The whole group travels together when it fits: a send must not open mid-group, and
	# a header must not sit alone at the end of one. Two tries, then a split: fit it in
	# the current message, else start a fresh one, else (a group bigger than any single
	# message) break it on app boundaries and repeat the header so every part still names
	# the bundle its apps come from.
	body="$header"
	for blk in "${GROUP_BLOCKS[@]}"; do
		body+="${NL}${NL}${blk}"
	done
	if [ $((${#CHUNK} + 2 + ${#body})) -gt "$TG_LIMIT" ]; then
		flush_chunk
	fi
	if [ $((${#CHUNK} + 2 + ${#body})) -gt "$TG_LIMIT" ]; then
		put "$header"
		for blk in "${GROUP_BLOCKS[@]}"; do
			if [ $((${#CHUNK} + 2 + ${#blk})) -gt "$TG_LIMIT" ]; then
				flush_chunk
				put "$header"
			fi
			put "$blk"
		done
	else
		put "$body"
	fi
done

# The action link only appears when the run identity is actually known — never a
# guessed URL. It goes in the last message it still fits into.
if [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_RUN_ID:-}" ]; then
	run_url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
	foot="⚙️ [View Build in Action](${run_url})"
	if [ $((${#CHUNK} + 2 + ${#foot})) -gt "$TG_LIMIT" ]; then
		flush_chunk
	fi
	put "$foot"
fi

flush_chunk

if [ "$SENT" = 1 ]; then
	echo "Build-queue notification sent (${ngrp} patch group(s), topic ${TG_THREAD_NOTIFY})."
fi
