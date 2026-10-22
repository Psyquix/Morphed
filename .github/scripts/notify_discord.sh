#!/bin/bash
# notify_discord.sh — the Discord mirror of every Telegram notification. Sourced,
# never executed: each send site calls discord_send once next to the Telegram
# request it already makes and gets the whole transport from here — dialect
# conversion, the 2000-character split, the rate-limit pause, the response check.
#
# Why one webhook per Discord channel: the URL is both the destination and the
# credential, so there is no chat-handle-plus-topic pair to keep in sync, and a
# stale or wrong URL cannot move a message to some other channel the way a stale
# TG_CHAT_ID can. The sinks wired today mirror the Telegram topics like this:
#
#   DISCORD_WEBHOOK_PATCH_ALERT  patch/version notices   (ci_notify_telegram.sh)
#   DISCORD_WEBHOOK_GITHUB_LOG   the log sink: build-queue notice, per-app failure
#                                report, queued issue/PR batch, workflow-failure
#                                alert (ci_notify_queue.sh, build_report_failures.sh,
#                                notify_drain.sh, notify_send_telegram.sh) plus
#                                config announcements (ci_notify_announcements.sh)
#   DISCORD_WEBHOOK_BUILDER_LOG  release notes           (build_notify_telegram.sh)
#
# Why these live in secrets and not in variables: a webhook URL carries its token,
# so anyone holding one posts as the project. Never write a URL into a file in this
# repo, and never echo one — not even in an error, because Actions logs are public.
#
# Unset means "this sink is not mirrored", not "configuration error": the call
# returns 0 without posting, exactly like the TG_TOKEN guard every caller already
# runs, so a fork holding neither credential stays silent. Placing the mirror after
# that guard is deliberate — every site still exits early when TG_TOKEN is missing,
# so Discord mirrors Telegram rather than replacing it.
#
# Telegram stays the primary sink and the author of the text: the bodies are written
# in Telegram's dialect (notify_render.sh owns the shape, per the single-owner rule),
# and only the emphasis marks differ, so the conversion below is mechanical rather
# than a second message builder. The ╰ / • / emoji skeleton is plain Unicode and
# passes through unchanged.
#
# Failure level is the CALLER's choice, because the resend contracts differ:
# notify_drain.sh must not fail on a mirror error (a non-zero there leaves the queue
# unpruned and double-posts Telegram), while a fire-and-forget site should show red.
# discord_send returns 1 on rejection and the caller decides whether that matters.
#
# Depends on: jq, curl, mktemp. Requires bash 4+ for ${var:offset:length}.

DISCORD_LIMIT=2000       # content characters per message; Telegram's 4096 is unusable
DISCORD_PAUSE=2          # seconds between posts: webhooks are capped per minute
DISCORD_RETRY_AFTER=2    # seconds to wait before one retry on HTTP 429

# discord_from_tg_md — Telegram legacy Markdown to Discord Markdown, stdin to stdout.
# A paired *run* becomes **run**, because on Discord a single pair means italics and
# leaving it would quietly render every section header in italics. Unpaired
# asterisks are left alone: guessing at them is how a name loses a character. What
# reaches this filter is markup the sites themselves wrote — user-authored text is
# already stripped of emphasis marks by md()/md_clean() at the call sites.
#
# LC_ALL=C is load-bearing, not a style choice: under a UTF-8 locale this system's
# sed matches [^*] character-wise and silently mis-handles the emoji that leads every
# one of these headers, so '*🚨 New Patch(es) Detected!*' comes back unchanged (or,
# worse, half-converted across the line). Under C the class is byte-wise, the marks
# are ASCII, and a multibyte character inside a bold run is carried through untouched.
discord_from_tg_md() {
	LC_ALL=C sed -e 's/\*\([^*]\{1,\}\)\*/**\1**/g'
}

# discord_from_tg_html — Telegram HTML to Discord Markdown, the inverse of the sed
# that builds the release-notes body in build_notify_telegram.sh: <b>/**, <i>/_,
# <code>/`, and <a href> to a markdown link. Captures stop at '<' because that
# producer escapes every literal '<' to &lt;, so a tag's content can never contain
# one. Entities are decoded last so decoded text cannot re-enter the tag pass.
# Same LC_ALL=C reason as discord_from_tg_md.
discord_from_tg_html() {
	LC_ALL=C sed \
		-e 's|<b>\([^<]*\)</b>|**\1**|g' \
		-e 's|<i>\([^<]*\)</i>|_\1_|g' \
		-e 's|<code>\([^<]*\)</code>|`\1`|g' \
		-e 's|<a href="\([^"]*\)">\([^<]*\)</a>|[\2](\1)|g' \
		-e 's|&lt;|<|g; s|&gt;|>|g; s|&quot;|"|g; s|&amp;|\&|g'
}

# discord_wrap — stdin to stdout, with every emitted line at most DISCORD_LIMIT
# characters. The mirror packs whole lines (below), so this step exists only for a
# line that is itself too long — a signed CDN link. Such a line breaks at its last
# space inside the limit so words stay glued, and only hard-cuts when there is no
# space to break at; dropping a notice to keep one URL intact is the worse failure.
discord_wrap() {
	local line cut rest sp
	while IFS= read -r line; do
		while [ "${#line}" -gt "$DISCORD_LIMIT" ]; do
			cut=${line:0:$DISCORD_LIMIT}
			rest=${line:$DISCORD_LIMIT}
			case "$cut" in
			*" "*)
				sp=${cut% *}
				# Only take the space break when the piece is still worth its size;
				# a 40-character message is not worth splitting a 2000-character line for.
				if [ "${#sp}" -ge "$((DISCORD_LIMIT / 2))" ]; then
					cut=$sp
					rest=${line:${#sp}}
					rest=${rest# }
				fi
				;;
			esac
			printf '%s\n' "$cut"
			line=$rest
		done
		printf '%s\n' "$line"
	done
}

# _discord_post_once <url> <content> — post one message. Discord answers 204 with no
# body on success and {"code":…,"message":…} on failure, so the status code decides
# and the body only explains. HTTP 429 is the rate limit rather than a rejection:
# wait and retry once before reporting anything. The URL is never echoed.
_discord_post_once() {
	local url=$1 content=$2 tmp code body attempt rc reason
	tmp=$(mktemp)
	rc=1
	for attempt in 1 2; do
		if ! code=$(jq -n --arg c "$content" \
			'{content: $c, allowed_mentions: {parse: []}}' |
			curl -sS -o "$tmp" -w '%{http_code}' -X POST \
				-H 'Content-Type: application/json' \
				--data-binary @- "$url"); then
			echo "::error::Discord webhook request failed at transport level; nothing mirrored." >&2
			code=000
			rc=1
			break
		fi
		case "$code" in
		2??)
			rc=0
			break
			;;
		esac
		if [ "$code" = "429" ] && [ "$attempt" = 1 ]; then
			sleep "$DISCORD_RETRY_AFTER"
			continue
		fi
		rc=1
		break
	done
	if [ "$rc" != 0 ]; then
		# Trim the reply to one short line and keep the endpoint out of it.
		body=$(tr -d '\r\n' <"$tmp" 2>/dev/null | cut -c1-200)
		echo "::error::Discord webhook rejected the message (HTTP ${code}): ${body:-no body}" >&2
	fi
	rm -f "$tmp"
	return "$rc"
}

# _discord_units — stdin lines to stdout numbers: the UTF-16 code-unit length of each
# line, which is what Discord counts against its 2000-message limit. ${#var} cannot
# answer it: every header here leads with a non-BMP emoji, and one of those is a single
# shell character but two charged units, so a char-counted budget can be up to twice
# too generous and the post is rejected. One jq pass prices the whole message. jq
# takes no hex literals, so the plane-1 boundary is spelled 65536, and its line ending
# is stripped because jq on Windows terminates every line with CRLF - a trailing CR
# reaches the packer's arithmetic and fails the whole split rather than one message.
_discord_units() {
	jq -Rr '(length + ([explode[] | select(. >= 65536)] | length)) | tostring' | tr -d '\r'
}

# discord_send <webhook-url> <text> [md|html] — mirror <text> to one Discord channel.
# <text> is the complete message body in Telegram's dialect; this splits it into
# Discord-sized messages on line boundaries itself, so callers pass the whole text
# once instead of their own Telegram chunks. mode selects the dialect of what is
# handed in and defaults to md. Returns 1 when any message was rejected; a channel
# with no webhook configured is a skip, not an error.
discord_send() {
	local url=${1:-} text=${2:-} mode=${3:-md}
	local nl=$'\n' chunk="" line rc=0 posts=0 used=0 w i
	local -a lines weights
	if [ -z "$url" ]; then
		echo "Discord webhook not set for this sink; skipping the mirror."
		return 0
	fi
	if [ -z "${text//[[:space:]]/}" ]; then
		echo "Nothing to mirror to Discord."
		return 0
	fi
	case "$url" in
	https://discord.com/api/webhooks/* | https://discordapp.com/api/webhooks/*) ;;
	*)
		echo "::error::Discord webhook URL is not a webhook endpoint; nothing mirrored." >&2
		return 1
		;;
	esac
	if [ "$mode" = "html" ]; then
		text=$(discord_from_tg_html <<<"$text")
	else
		text=$(discord_from_tg_md <<<"$text")
	fi

	# Wrapped lines first, then their price: packing needs the unit count of each line
	# before it decides, not after the message is built.
	mapfile -t lines < <(printf '%s\n' "$text" | discord_wrap)
	mapfile -t weights < <(printf '%s\n' "${lines[@]}" | _discord_units)

	# Pack whole lines up to the limit; a line that does not fit the current message
	# starts a new one, so a line is never broken to make it fit. The buffer is tracked
	# by a counter, not by [ -z "$chunk" ]: a blank line is a real first line of a
	# message here (the notices separate sections with one), and testing the buffer
	# would quietly drop it every time a message happened to start on one.
	local started=0
	chunk=""
	used=0
	for i in "${!lines[@]}"; do
		line=${lines[$i]}
		w=${weights[$i]:-0}
		if [ "$started" = 0 ]; then
			chunk=$line
			used=$w
			started=1
			continue
		fi
		# +1 for the newline joining them
		if [ $((used + 1 + w)) -gt "$DISCORD_LIMIT" ]; then
			if [ "$posts" -gt 0 ]; then
				sleep "$DISCORD_PAUSE"
			fi
			_discord_post_once "$url" "$chunk" || rc=1
			posts=$((posts + 1))
			chunk=$line
			used=$w
			started=1
		else
			chunk="${chunk}${nl}${line}"
			used=$((used + 1 + w))
		fi
	done
	if [ "$started" = 1 ] && [ -n "$chunk" ]; then
		if [ "$posts" -gt 0 ]; then
			sleep "$DISCORD_PAUSE"
		fi
		_discord_post_once "$url" "$chunk" || rc=1
		posts=$((posts + 1))
	fi
	# A message whose only content is blank carries nothing; posting it would be noise.
	if [ "$posts" = 0 ] && [ -z "${chunk//[[:space:]]/}" ]; then
		echo "Nothing to mirror to Discord."
		return 0
	fi
	echo "Mirrored ${posts} message(s) to Discord."
	return "$rc"
}
