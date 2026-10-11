#!/bin/bash
# notify_send_telegram.sh — the IMMEDIATE notify path: a workflow-failure alert
# raised through workflow_call. Issue/PR events no longer route here — they are
# enqueued and sent in a debounced batch (see notify_enqueue.sh / notify_drain.sh),
# which is why this script only handles the WF_NAME branch.
#
# Route B: a workflow-failure alert is skipped when ALREADY_REPORTED=true (the
# detailed per-app build report already covered that run).
#
# Env: TG_TOKEN TG_CHAT_ID TG_THREAD_ID WF_NAME ALREADY_REPORTED + render inputs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=notify_render.sh
source "$SCRIPT_DIR/notify_render.sh"
# shellcheck source=notify_targets.sh
source "$SCRIPT_DIR/notify_targets.sh"

if [ -z "${TG_TOKEN:-}" ]; then
	echo "TG_TOKEN is not set. Skipping Telegram notification."
	exit 0
fi

# Route B — the build step already reported this failure in detail.
if [ -n "${WF_NAME:-}" ] && [ "${ALREADY_REPORTED:-}" = "true" ]; then
	echo "Detailed failure report already sent; skipping generic alert."
	exit 0
fi

# The target is named by repo variables and nothing else: an unset chat or topic
# fails this step instead of posting to a handle hardcoded in the workflow (see
# notify_targets.sh).
tg_require_targets \
	"TG_CHAT_ID=${TG_CHAT_ID:-}" \
	"TG_THREAD_ID=${TG_THREAD_ID:-}" || exit 1

MSG="$(render_message)"

curl -s -X POST \
	--data-urlencode "parse_mode=Markdown" \
	--data-urlencode "disable_web_page_preview=true" \
	--data-urlencode "text=${MSG}" \
	--data-urlencode "chat_id=${TG_CHAT_ID}" \
	--data-urlencode "message_thread_id=${TG_THREAD_ID}" \
	"https://api.telegram.org/bot${TG_TOKEN}/sendMessage"
