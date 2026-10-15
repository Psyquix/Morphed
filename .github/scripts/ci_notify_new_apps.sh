#!/bin/bash
# ci_notify_new_apps.sh — announce apps newly added to the config to the
# NullStore topic (TG_THREAD_NEWAPPS), separate from the CI update thread.
#
# Driven by new_apps.json, which ci_detect_config_changes.sh writes with the app
# keys it enqueued as reason "new" THIS run, per channel. Retries, prunes and the
# cold-start seed never appear there, so this fires once per genuinely-new app and
# not on every scheduled run. No-op when nothing new was added.
#
# Arch and channel are shown concretely (Option A): "both" fans out to the real
# ABIs, and an app new in both pools reads "stable, beta" - so the two fields use
# the same, expanded convention.
#
# Env: TG_TOKEN TG_CHAT_ID TG_THREAD_NEWAPPS WEBSITE_LINK (chat + topic come from
#      repo variables only, per notify_targets.sh; no hardcoded handle/topic).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=retry_lib.sh
source "$SCRIPT_DIR/retry_lib.sh"
# shellcheck source=notify_targets.sh
source "$SCRIPT_DIR/notify_targets.sh"

NA="new_apps.json"
[ -s "$NA" ] || exit 0
if [ -z "${TG_TOKEN:-}" ]; then
	echo "TG_TOKEN is not set. Skipping new-apps notification."
	exit 0
fi

keys=$(jqx -r '[.stable[], .beta[]] | unique | .[]' "$NA")
[ -n "$keys" ] || {
	echo "No new apps to announce."
	exit 0
}

tg_require_targets \
	"TG_CHAT_ID=${TG_CHAT_ID:-}" \
	"TG_THREAD_NEWAPPS=${TG_THREAD_NEWAPPS:-}" || exit 1

NL=$'\n'
WEB_LINK="${WEBSITE_LINK:-https://nullcpy.github.io/}"

# md_clean <text> — strip chars that would corrupt a [label](url) or *bold* run.
md_clean() { printf '%s' "$1" | tr -d '[]`'; }
# host_base <host> — forge web root, mirroring ci_notify_telegram.sh.
host_base() {
	case "${1:-github}" in
	gitlab) printf 'https://gitlab.com/' ;;
	codeberg) printf 'https://codeberg.org/' ;;
	*) printf 'https://github.com/' ;;
	esac
}

blocks=""
count=0
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

	# Read the app's metadata from whichever pool has it (stable first).
	cfg="config.stable.json"
	if ! { [ -f "$cfg" ] && jqx -e --arg k "$key" 'has($k)' "$cfg" >/dev/null 2>&1; }; then
		cfg="config.beta.json"
	fi
	name=$(jqx -r --arg k "$key" '.[$k]["app-name"] // $k' "$cfg")
	brand=$(jqx -r --arg k "$key" '.[$k].brand // empty' "$cfg")
	pkg=$(jqx -r --arg k "$key" '.[$k]["pkg-name"] // empty' "$cfg")
	psrc=$(jqx -r --arg k "$key" '.[$k]["patches-source"] // empty' "$cfg" | tr -d "\"'" | head -n1 | awk '{print $1}')
	phost=$(jqx -r --arg k "$key" '.[$k]["patches-source-host"] // "github"' "$cfg" | head -n1 | awk '{print $1}')
	arch=$(retry_effective_arch "$cfg" "$key" | tr -s '[:space:]' '\n' | LC_ALL=C sort -u | sed '/^$/d' | paste -sd ',' - | sed 's/,/, /g')

	block="📱 $(md_clean "$name")"
	[ -n "$brand" ] && block+=" ($(md_clean "$brand"))"
	[ -n "$psrc" ] && block+="${NL}  ╰ Patches: [$(md_clean "$psrc")]($(host_base "$phost")$(md_clean "$psrc"))"
	[ -n "$pkg" ] && block+="${NL}  ╰ Package: \`${pkg}\`"
	block+="${NL}  ╰ Arch: ${arch:-arm-v7a, arm64-v8a} · Channel: ${ch}"
	blocks+="${block}${NL}${NL}"
	count=$((count + 1))
done <<<"$keys"

MSG="*✨ New App(s) Added!*${NL}${NL}${blocks}"
while [ "${MSG%$'\n'}" != "$MSG" ]; do MSG="${MSG%$'\n'}"; done
MSG+="${NL}${NL}🆕 ${count} new app(s) added.${NL}🔗 [Download from NullStore](${WEB_LINK})."

curl -s -X POST \
	--data-urlencode "parse_mode=Markdown" \
	--data-urlencode "disable_web_page_preview=true" \
	--data-urlencode "text=${MSG}" \
	--data-urlencode "chat_id=${TG_CHAT_ID}" \
	--data-urlencode "message_thread_id=${TG_THREAD_NEWAPPS}" \
	"https://api.telegram.org/bot${TG_TOKEN}/sendMessage" >/dev/null || true

echo "New-apps notification sent (${count} app(s)) to topic ${TG_THREAD_NEWAPPS}."
