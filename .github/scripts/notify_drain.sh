#!/bin/bash
# notify_drain.sh — batch the queued issue/PR alerts into ONE Telegram message,
# then remove exactly the lines it sent. Paired with notify_enqueue.sh behind the
# `notify-debounce` concurrency group (cancel-in-progress: false), so a burst of
# events produces one send and the later queued drains find nothing to do.
#
# Ordering (send-then-clear): the queue is only pruned after every chunk posts
# successfully. If a send fails the lines stay, and the next drain retries them —
# a duplicate is preferred over a silent loss. Pruning removes precisely the lines
# this run drained, so an event appended DURING the send window survives for the
# next drain instead of being wiped.
#
# Env: TG_TOKEN TG_CHAT_ID TG_THREAD_NOTIFY
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=notify_queue.sh
source "$SCRIPT_DIR/notify_queue.sh"
# shellcheck source=notify_targets.sh
source "$SCRIPT_DIR/notify_targets.sh"

TG_LIMIT=4096
NL=$'\n'

if [ -z "${TG_TOKEN:-}" ]; then
	echo "TG_TOKEN is not set. Skipping drain."
	exit 0
fi

# Snapshot the queue we are draining (through the lib so line endings are pinned).
base=$(nq_base_sha)
content=$(nq_read "$base")
if [ -z "$content" ]; then
	echo "Notify queue empty; nothing to drain."
	exit 0
fi

# Failing here leaves the queue untouched, so the batch is retried by the next
# drain once the variables are set (see notify_targets.sh for the no-default rule).
tg_require_targets \
	"TG_CHAT_ID=${TG_CHAT_ID:-}" \
	"TG_THREAD_NOTIFY=${TG_THREAD_NOTIFY:-}" || exit 1

# Collect the event texts (one JSON object per line).
count=0
BODY=""
while IFS= read -r line; do
	[ -z "$line" ] && continue
	text="$(jq -r '.text // empty' <<<"$line")"
	[ -z "$text" ] && continue
	count=$((count + 1))
	if [ -n "$BODY" ]; then
		# Each event already carries its own header + sub-lines; one blank line is
		# enough separation, no divider or batch count.
		BODY+="${NL}${NL}"
	fi
	BODY+="$text"
done <<< "$content"

if [ "$count" = 0 ]; then
	echo "Notify queue had no renderable entries."
	exit 0
fi

MSG="$BODY"

send_chunk() {
	local text="${1:-}"
	[ -z "$text" ] && return 0
	local resp
	resp="$(curl -s -X POST \
		--data-urlencode "parse_mode=Markdown" \
		--data-urlencode "disable_web_page_preview=true" \
		--data-urlencode "text=${text}" \
		--data-urlencode "chat_id=${TG_CHAT_ID}" \
		--data-urlencode "message_thread_id=${TG_THREAD_NOTIFY}" \
		"https://api.telegram.org/bot${TG_TOKEN}/sendMessage")"
	# Telegram returns {"ok":false} with HTTP 200 on some errors; check the body.
	if ! grep -q '"ok":true' <<<"$resp"; then
		echo "::error::Telegram rejected a chunk: ${resp}" >&2
		return 1
	fi
}

# Chunk on line boundaries, mirroring build_notify_telegram.sh.
CHUNK=""
while IFS= read -r LINE; do
	CANDIDATE="${CHUNK:+${CHUNK}${NL}}${LINE}"
	if [ "${#CANDIDATE}" -le "$TG_LIMIT" ]; then
		CHUNK="$CANDIDATE"
	else
		send_chunk "$CHUNK" || exit 1
		CHUNK="$LINE"
	fi
done <<< "$MSG"
if [ -n "$CHUNK" ]; then
	send_chunk "$CHUNK" || exit 1
fi

# Sends succeeded → prune the drained lines. The queue is append-only (FIFO), so
# the lines just drained are always a prefix of the current file; drop exactly
# their count with tail rather than a byte-match grep (robust to multibyte JSON,
# and to events appended during the send, which survive as the tail).
sent_lines=$(printf '%s\n' "$content" | grep -c .)
kept=$(nq_read | tail -n "+$((sent_lines + 1))" || true)
if [ -n "$kept" ]; then
	kept="${kept}${NL}"
fi
if ! nq_write "$kept"; then
	echo "::warning::sent the batch but could not prune the queue; a later drain may resend" >&2
fi
