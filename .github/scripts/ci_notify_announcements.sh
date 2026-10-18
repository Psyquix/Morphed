#!/bin/bash
# ci_notify_announcements.sh — announce on the NullStore announcement topic what the
# watcher just did to the config: apps newly added, and apps woken because their own
# config moved (TG_THREAD_ANNOUNCE).
#
# Driven by the two payloads ci_detect_config_changes.sh writes:
#
#   new_apps.json     {stable:[key],beta:[key]}      apps enqueued reason "new"
#   changed_apps.json {stable:{key:[{field,from,to}]},...}  apps enqueued reason
#                                                    "config", with the field diff
#
# Both are THIS run's enqueue list, so a carried-over retry, a prune or the
# cold-start seed never appears here: this fires once per real event, not on every
# scheduled run. No-op when neither has anything.
#
# Why the second section exists: an app woken by a config edit shows up in the build
# with no obvious cause. Saying "build-mode: apk -> both" is the difference between a
# maintainer seeing their edit take effect and wondering whether it was ignored —
# which is exactly how a published `build-mode` change went unnoticed for a release
# cycle (why: [decisions/0014](../../docs/decisions/0014-config-changes-that-earn-a-rebuild.md)).
#
# One message, not two sends: this is the announcement topic, and splitting a run's
# additions from its edits would make two notifications chase one another for the
# same config commit.
#
# Arch and channel are shown concretely: "both" fans out to the real ABIs, and an app
# new in both pools reads "stable, beta" - so the two fields use the same expanded
# convention.
#
# Env: TG_TOKEN TG_CHAT_ID TG_THREAD_ANNOUNCE WEBSITE_LINK (chat + topic come from
#      repo variables only, per notify_targets.sh; no hardcoded handle/topic).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry_lib.sh
source "$SCRIPT_DIR/retry_lib.sh"
# shellcheck source=notify_targets.sh
source "$SCRIPT_DIR/notify_targets.sh"

NA="new_apps.json"
CA="changed_apps.json"
for f in "$NA" "$CA"; do
	if [ ! -s "$f" ]; then
		printf '%s\n' '{}' >"$f"
	fi
done
if [ -z "${TG_TOKEN:-}" ]; then
	echo "TG_TOKEN is not set. Skipping the announcement."
	exit 0
fi

new_count=$(jqx -r '[.stable[], .beta[]] | unique | length' "$NA")
chg_count=$(jqx -r '[.stable, .beta | to_entries[] | select(.value | length > 0)] | length' "$CA")
if [ "${new_count:-0}" -eq 0 ] && [ "${chg_count:-0}" -eq 0 ]; then
	echo "Nothing added and no config moved. No announcement."
	exit 0
fi

tg_require_targets \
	"TG_CHAT_ID=${TG_CHAT_ID:-}" \
	"TG_THREAD_ANNOUNCE=${TG_THREAD_ANNOUNCE:-}" || exit 1

NL=$'\n'
WEB_LINK="${WEBSITE_LINK:-https://nullcpy.github.io/}"

# md_clean <text> — strip chars that would corrupt a [label](url) or *bold* run.
md_clean() { printf '%s' "$1" | tr -d '[]`'; }
# md_val <json-scalar-or-null> — a config value rendered for a Markdown line: empty
# for null, and without the punctuation Telegram's legacy Markdown would eat. Patch
# names and theme colours arrive here verbatim from the config, so the guards are
# `*`, `_` and backtick rather than a hope that nobody writes them.
md_val() {
	local v
	v=$(jqx -r 'if . == null then "" else tostring end' <<<"$1")
	printf '%s' "$v" | tr -d '*_`'
}
# host_base <host> — forge web root, mirroring ci_notify_telegram.sh.
host_base() {
	case "${1:-github}" in
	gitlab) printf 'https://gitlab.com/' ;;
	codeberg) printf 'https://codeberg.org/' ;;
	*) printf 'https://github.com/' ;;
	esac
}
# app_cfg <app-key> — the pool file to read this app's metadata from (stable first).
app_cfg() {
	local key=$1 cfg="config.stable.json"
	if ! { [ -f "$cfg" ] && jqx -e --arg k "$key" 'has($k)' "$cfg" >/dev/null 2>&1; }; then
		cfg="config.beta.json"
	fi
	printf '%s' "$cfg"
}
# app_name <app-key> — display name, falling back to the key rather than inventing one.
app_name() {
	local cfg
	cfg=$(app_cfg "$1")
	[ -f "$cfg" ] || { printf '%s' "$1"; return 0; }
	jqx -r --arg k "$1" '.[$k]["app-name"] // $k' "$cfg"
}

new_blocks=""
if [ "${new_count:-0}" -gt 0 ]; then
	while IFS= read -r key; do
		[ -z "$key" ] && continue

		in_s=false
		in_b=false
		if jqx -e --arg k "$key" '.stable | index($k) != null' "$NA" >/dev/null 2>&1; then in_s=true; fi
		if jqx -e --arg k "$key" '.beta | index($k) != null' "$NA" >/dev/null 2>&1; then in_b=true; fi
		ch="stable"
		if [ "$in_s" = true ] && [ "$in_b" = true ]; then
			ch="stable, beta"
		elif [ "$in_b" = true ]; then
			ch="beta"
		fi

		cfg=$(app_cfg "$key")
		[ -f "$cfg" ] || cfg="config.stable.json"
		name=$(jqx -r --arg k "$key" '.[$k]["app-name"] // $k' "$cfg")
		brand=$(jqx -r --arg k "$key" '.[$k].brand // empty' "$cfg")
		variant=$(jqx -r --arg k "$key" '.[$k].variant // empty' "$cfg")
		subvariant=$(jqx -r --arg k "$key" '.[$k]["sub-variant"] // empty' "$cfg")
		pkg=$(jqx -r --arg k "$key" '.[$k]["pkg-name"] // empty' "$cfg")
		psrc=$(jqx -r --arg k "$key" '.[$k]["patches-source"] // empty' "$cfg" | tr -d "\"'" | head -n1 | awk '{print $1}')
		phost=$(jqx -r --arg k "$key" '.[$k]["patches-source-host"] // "github"' "$cfg" | head -n1 | awk '{print $1}')
		arch=$(retry_effective_arch "$cfg" "$key" | tr -s '[:space:]' '\n' | LC_ALL=C sort -u | sed '/^$/d' | paste -sd ',' - | sed 's/,/, /g')

		# Parenthetical = every identity part that exists, joined by " • ":
		# brand, variant, sub-variant (e.g. "Piko • NewX • Material You").
		label=""
		for part in "$brand" "$variant" "$subvariant"; do
			if [ -n "$part" ]; then
				label="${label:+${label} • }${part}"
			fi
		done
		block="📱 $(md_clean "$name")"
		if [ -n "$label" ]; then block+=" ($(md_clean "$label"))"; fi
		if [ -n "$psrc" ]; then block+="${NL}  ╰ Patches: [$(md_clean "$psrc")]($(host_base "$phost")$(md_clean "$psrc"))"; fi
		if [ -n "$pkg" ]; then block+="${NL}  ╰ Package: \`${pkg}\`"; fi
		block+="${NL}  ╰ Arch: ${arch:-arm-v7a, arm64-v8a} · Channel: ${ch}"
		new_blocks+="${block}${NL}${NL}"
	done <<<"$(jqx -r '[.stable[], .beta[]] | unique | .[]' "$NA")"
fi

chg_blocks=""
if [ "${chg_count:-0}" -gt 0 ]; then
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		ch=${line%%$'\t'*}
		key=${line#*$'\t'}
		name=$(app_name "$key")
		block="🔧 $(md_clean "$name")${NL}"
		while IFS= read -r frag; do
			[ -z "$frag" ] && continue
			field=$(printf '%s' "$frag" | jqx -r '.field')
			from=$(printf '%s' "$frag" | jqx -c '.from')
			to=$(printf '%s' "$frag" | jqx -c '.to')
			fv=$(md_val "$from")
			tv=$(md_val "$to")
			if [ -z "$fv" ]; then
				block+="  ╰ ${field}: +${tv}${NL}"
			elif [ -z "$tv" ]; then
				block+="  ╰ ${field}: -${fv}${NL}"
			else
				block+="  ╰ ${field}: ${fv} → ${tv}${NL}"
			fi
		done < <(jqx -c --arg c "$ch" --arg k "$key" '.[$c][$k] // [] | .[]' "$CA")
		if [ "$ch" = "beta" ]; then
			block+="  ╰ Channel: beta"
		fi
		block="${block%$'\n'}"
		chg_blocks+="${block}${NL}${NL}"
	done < <(jqx -r 'to_entries[] | .key as $c | .value | to_entries[] | select(.value | length > 0) | "\($c)\t\(.key)"' "$CA")
fi

MSG=""
if [ -n "$new_blocks" ]; then
	MSG+="*✨ New App(s) Added!*${NL}${NL}${new_blocks}"
fi
if [ -n "$chg_blocks" ]; then
	if [ -n "$MSG" ]; then
		MSG+="${NL}"
	fi
	MSG+="*🔧 Config Change(s)*${NL}${NL}${chg_blocks}"
fi
while [ "${MSG%$'\n'}" != "$MSG" ]; do MSG="${MSG%$'\n'}"; done
tail=""
if [ "${new_count:-0}" -gt 0 ]; then
	tail="${new_count} new app(s)"
fi
if [ "${chg_count:-0}" -gt 0 ]; then
	if [ -n "$tail" ]; then tail+=", "; fi
	tail+="${chg_count} config change(s)"
fi
# The leading mark follows what actually happened: a run that only woke an existing
# app is not a "new" thing, and greeting it with 🆕 would repeat the very conflation
# this section exists to remove.
mark="🔧"
if [ "${new_count:-0}" -gt 0 ]; then mark="🆕"; fi
MSG+="${NL}${NL}${mark} ${tail}.${NL}🔗 [Download from NullStore](${WEB_LINK})."

curl -s -X POST \
	--data-urlencode "parse_mode=Markdown" \
	--data-urlencode "disable_web_page_preview=true" \
	--data-urlencode "text=${MSG}" \
	--data-urlencode "chat_id=${TG_CHAT_ID}" \
	--data-urlencode "message_thread_id=${TG_THREAD_ANNOUNCE}" \
	"https://api.telegram.org/bot${TG_TOKEN}/sendMessage" >/dev/null || true

echo "Announcement sent (${new_count:-0} new, ${chg_count:-0} changed) to topic ${TG_THREAD_ANNOUNCE}."
