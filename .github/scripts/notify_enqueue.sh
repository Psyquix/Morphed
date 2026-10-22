#!/bin/bash
# notify_enqueue.sh — render the current issue/PR event and append it to the
# debounced queue on the notify-queue branch. Runs first in every event-triggered
# notify.yml run; the paired drain job then batches whatever has accumulated.
#
# The event is fully rendered here (not at drain time) because the drain run does
# not have this run's event payload in its env. Storing finished Markdown keeps
# notify_render.sh the single owner of the shape.
#
# Env (from notify.yml): the render inputs + nothing Telegram-specific.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=notify_render.sh
source "$SCRIPT_DIR/notify_render.sh"
# shellcheck source=notify_queue.sh
source "$SCRIPT_DIR/notify_queue.sh"

MSG="$(render_message)"
LINE="$(jq -c -n --arg ts "$(date -u +%FT%TZ)" --arg text "$MSG" '{ts:$ts, text:$text}')"

if ! nq_append "$LINE"; then
	echo "::error::could not append to the notify queue" >&2
	exit 1
fi
