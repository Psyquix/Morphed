#!/bin/bash
# notify_discord.sh — the Discord mirror of every Telegram notification. Sourced,
# never executed: each send site calls discord_send once next to the Telegram
# request it already makes and gets the whole transport from here — dialect
# conversion, the 2000-unit split, the rate-limit pause, the response check. The
# splitting itself is notify_pack.sh's, so a mirrored message breaks where the
# Telegram one breaks and not somewhere else with a different idea of a boundary.
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

DISCORD_LIMIT=2000       # UTF-16 code units per message; Telegram's 4096 is unusable
DISCORD_PAUSE=2          # seconds between posts: webhooks are capped per minute
DISCORD_RETRY_AFTER=2    # seconds to wait before one retry on HTTP 429
# Message flag 4 = SUPPRESS_EMBEDS: the webhook equivalent of the
# disable_web_page_preview=true every Telegram send already passes. It has to be set on
# the message, not inferred from the text - a [label](url) link unfurls into a full
# preview card on Discord even though the same markup shows nothing but the label in a
# Telegram topic, and one release note with six arch links becomes six stacked images.
# This suppresses previews only; an explicit embed would still need its own handling,
# and none is ever sent here.
DISCORD_FLAGS_NO_EMBEDS=4

# Own directory, not SCRIPT_DIR: every send site defines that already, and a sourced
# library overwriting it would move the caller's own sources to this directory.
DC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=notify_pack.sh
source "$DC_DIR/notify_pack.sh"

# discord_hide_link_targets — wrap every [label](url) target in angle brackets, stdin to
# stdout. flags:4 does not cover everything: a discord.gg invite is not a link embed but
# a server-invitation component, and it survived SUPPRESS_EMBEDS in the release footer
# while ordinary GitHub previews were suppressed. [label](<url>) is the documented text
# form that stops the unfurl and keeps the label clickable, and every link the notifiers
# emit is of that shape (no body writes a bare URL), so one pass here covers all sinks.
# Already-wrapped targets are left alone, so this is safe to run twice.
discord_hide_link_targets() {
	LC_ALL=C sed -e 's|\](\([^<)][^)]*\))|](<\1>)|g'
}

# discord_drop_invite_links — turn [label](invite-url) back into plain label text.
# Neither of the two suppression mechanisms reaches a server invite: flags:4 covers link
# *embeds* and angle brackets cover ordinary unfurls, but Discord renders an invite as an
# invitation **component** (verified — the DevSpace card survived both measures in the
# release footer), and there is no sender-side switch for it. Inside Discord the link is
# also worth nothing to a reader who is already in the server, so the mirror keeps the
# word and drops the target. Handles the wrapped and the bare form because it runs on
# already-wrapped text. Delimited with % because the pattern is full of | (host
# alternatives) and / (URL paths), either of which would end the s command early.
discord_drop_invite_links() {
	LC_ALL=C sed -E \
		-e 's%\[([^]]*)\]\(<https?://(discord\.gg|discord\.com/invite|discordapp\.com/invite)/[^)]*>\)%\1%g' \
		-e 's%\[([^]]*)\]\(https?://(discord\.gg|discord\.com/invite|discordapp\.com/invite)/[^)]*\)%\1%g'
}

# _pack_len_units <text> — set _PACK_LEN to the UTF-16 code-unit length of <text>, the
# currency Discord charges against its 2000-message limit. ${#var} counts a leading emoji
# as one character while the API counts it as two, so a char-budgeted message can be twice
# as long as it looks and get rejected; that is why the mirror passes its own measure to
# pack_message instead of using the default. jq takes no hex literals, so the plane-1
# boundary is spelled 65536, and its line ending is stripped because jq on Windows
# terminates output with CRLF — a trailing CR reaches arithmetic and fails the split.
_pack_len_units() {
	_PACK_LEN=$(printf '%s' "$1" | jq -Rs \
		'(length + ([explode[] | select(. >= 65536)] | length))' | tr -d '\r')
}

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
# <code>/`, and <a href> to a markdown link. Captures stop at '<' because that producer
# escapes every literal '<' to &lt;, so a tag's own text can never contain one.
#
# ORDER IS THE WHOLE POINT: innermost constructs are unwrapped first, because a
# release-note bundle heading is <b> around a link —
# <b>🧩 owner/repo (<a href="…">v1.57.0</a>)</b> — and a rule that cannot cross a '<'
# matches nothing until the <a> inside it has already become [text](url). Unwinding
# outside-in left every bundle heading in the channel as literal <b>…</b> text.
# Entities are decoded last so decoded text cannot re-enter the tag pass.
# Same LC_ALL=C reason as discord_from_tg_md.
discord_from_tg_html() {
	LC_ALL=C sed \
		-e 's|<a href="\([^"]*\)">\([^<]*\)</a>|[\2](\1)|g' \
		-e 's|<code>\([^<]*\)</code>|`\1`|g' \
		-e 's|<b>\([^<]*\)</b>|**\1**|g' \
		-e 's|<i>\([^<]*\)</i>|_\1_|g' \
		-e 's|&lt;|<|g; s|&gt;|>|g; s|&quot;|"|g; s|&amp;|\&|g'
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
		if ! code=$(jq -n --arg c "$content" --argjson f "$DISCORD_FLAGS_NO_EMBEDS" \
			'{content: $c, allowed_mentions: {parse: []}, flags: $f}' |
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

# discord_send <webhook-url> <text> [md|html] — mirror <text> to one Discord channel.
# <text> is the complete message body in Telegram's dialect; this splits it into
# Discord-sized messages itself, so callers pass the whole text once instead of their
# own Telegram chunks. mode selects the dialect of what is handed in and defaults to
# md. Returns 1 when any message was rejected; a channel with no webhook configured is
# a skip, not an error.
discord_send() {
	local url=${1:-} text=${2:-} mode=${3:-md}
	local chunk rc=0 posts=0
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
	# Angle-bracket the link targets after conversion: the converters create [label](url)
	# from <a href>, and the packer below counts the result, so the wrapping has to be
	# priced into the message length rather than added afterwards. Invites are then
	# unlinked, which only shortens the text.
	text=$(discord_hide_link_targets <<<"$text" | discord_drop_invite_links)

	# Same packer the Telegram sites use, so the mirror's boundaries match theirs:
	# whole blocks only, and a heading travels with the block under it. The heading
	# pattern is post-conversion Discord Markdown — both the legacy-Markdown `*x*` and
	# the release-notes `<b>x</b>` forms have become **x** by now.
	while IFS= read -r -d "$PACK_RS" chunk; do
		if [ -n "$chunk" ]; then
			if [ "$posts" -gt 0 ]; then
				sleep "$DISCORD_PAUSE"
			fi
			_discord_post_once "$url" "$chunk" || rc=1
			posts=$((posts + 1))
		fi
	done < <(printf '%s' "$text" | pack_message "$DISCORD_LIMIT" '^\*\*.*\*\*$' _pack_len_units)

	if [ "$posts" = 0 ]; then
		echo "Nothing to mirror to Discord."
		return 0
	fi
	# Say what actually happened: counting a rejected post as mirrored makes a failed
	# mirror look fine in a log nobody re-reads, which is how a broken converter sat
	# unnoticed in a channel for a whole build.
	if [ "$rc" = 0 ]; then
		echo "Mirrored ${posts} message(s) to Discord."
	else
		echo "Discord mirror incomplete: ${posts} message(s) attempted, at least one rejected." >&2
	fi
	return "$rc"
}
