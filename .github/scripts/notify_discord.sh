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

# The blank line that closes a mirrored message, so consecutive notices do not read as
# one wall of text. Discord trims trailing whitespace, so the closing line has to hold a
# character — a zero-width space, written as octal escapes because an invisible literal
# sitting in source is unreadable and survives every review.
#
# Measured in the channel, not assumed: text + "\n" shows no gap, text + "\n" + the
# character alone shows no gap either (the client collapses a single trailing line), and
# only text + blank line + the character renders as real space. Hence two newlines here.
#
# It closes every part of a split notice, not just the last one: the gap between two
# parts has to be created at the end of the earlier part, because a line padded to the
# START of a message is trimmed by the client exactly like a trailing bare newline was
# (measured — leading padding produced no seam at all, trailing padding did). The last
# part's pad is also the gap that ends the notice.
DISCORD_TAIL=$(printf '\n\n\342\200\213')
DISCORD_TAIL_UNITS=3   # what the packer must leave room for, once per part

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

# discord_invite_target — what an invite link becomes in the mirrored copy, echoed as a
# ready markdown link, or nothing when it cannot be answered.
# A discord.gg invite is the one unfurl neither mechanism stops: flags:4 covers link
# *embeds*, angle brackets cover ordinary unfurls, and Discord renders an invite as a
# server-invitation component with no sender-side switch (measured — the card survived
# both). The release footer's link is also useless to a reader already in the server, so
# it is pointed at the broadcast channel instead, which is the same thing the Telegram
# footer's 📣 Channel entry is. The target is emitted without a leading emoji: the
# footer's own mark is rewritten to match (see discord_replace_invite_links).
#
# The URL is derived from TG_CHAT_ID_BROADCAST rather than written out again here: that
# variable already names the channel, and a second copy of a handle is a second thing to
# forget when it is renamed. The wire forms differ on purpose (@handle for the Bot API,
# t.me/s/<handle> for a browser), which is why the derivation lives at the point of use.
discord_invite_target() {
	local handle=${TG_CHAT_ID_BROADCAST:-}
	if [ -z "$handle" ]; then
		return 0
	fi
	handle=${handle#@}
	printf '[Channel](<https://t.me/s/%s>)' "$handle"
}

# discord_replace_invite_links [replacement] — rewrite every invite link (wrapped or
# bare) to <replacement>; with no replacement given, keep the label and drop the target.
# The speech bubble the release footer hangs on its Discord entry is swapped for the
# megaphone that labels the channel everywhere else, because only the link itself is
# inside the match — leaving it would produce "💬 📣 Channel".
# Delimited with % because the pattern is full of | (host alternatives) and / (URL
# paths), either of which would end the s command early.
discord_replace_invite_links() {
	local rep=${1:-}
	if [ -z "$rep" ]; then
		LC_ALL=C sed -E \
			-e 's%\[([^]]*)\]\(<https?://(discord\.gg|discord\.com/invite|discordapp\.com/invite)/[^)]*>\)%\1%g' \
			-e 's%\[([^]]*)\]\(https?://(discord\.gg|discord\.com/invite|discordapp\.com/invite)/[^)]*\)%\1%g'
		return
	fi
	LC_ALL=C sed -E \
		-e "s%\[[^]]*\]\(<https?://(discord\.gg|discord\.com/invite|discordapp\.com/invite)/[^)]*>\)%$rep%g" \
		-e "s%\[[^]]*\]\(https?://(discord\.gg|discord\.com/invite|discordapp\.com/invite)/[^)]*\)%$rep%g" \
		-e 's%💬 \[Channel\]%📣 [Channel]%g'
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
# <code> gets two rules because an event title is a code span and a title may itself
# contain a backtick ("Fix `foo`"): a single-` fence would end early and leak the rest of
# the title as markup, so anything holding a backtick is fenced with `` and padded with
# spaces, which Discord reads as literal. A title carrying two consecutive backticks
# would need ``` — vanishingly rare, and it degrades to visible marks, not to broken
# layout.
#
# ORDER IS THE WHOLE POINT: innermost constructs are unwrapped first, because a
# release-note bundle heading is <b> around a link —
# <b>🧩 owner/repo (<a href="…">v1.57.0</a>)</b> — while an event headline is a link
# around bold — <a href="…"><b>Issue #312 opened</b></a> — and a rule that cannot cross
# a '<' matches nothing until whatever is inside it has already been unwound. So the
# tag rules run twice, link-then-bold each time, and either nesting direction collapses.
# Entities are decoded last so decoded text cannot re-enter the tag pass.
# Same LC_ALL=C reason as discord_from_tg_md.
discord_from_tg_html() {
	LC_ALL=C sed \
		-e 's|<code>\([^<]*`[^<]*\)</code>|`` \1 ``|g' \
		-e 's|<code>\([^<]*\)</code>|`\1`|g' \
		-e 's|<a href="\([^"]*\)">\([^<]*\)</a>|[\2](\1)|g' \
		-e 's|<b>\([^<]*\)</b>|**\1**|g' \
		-e 's|<i>\([^<]*\)</i>|_\1_|g' \
		-e 's|<a href="\([^"]*\)">\([^<]*\)</a>|[\2](\1)|g' \
		-e 's|<b>\([^<]*\)</b>|**\1**|g' \
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
	local rc=0 posts=0
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
	# repointed, which only changes the length by a few characters.
	local invite_target
	invite_target=$(discord_invite_target)
	text=$(discord_hide_link_targets <<<"$text" | discord_replace_invite_links "$invite_target")

	# Same packer the Telegram sites use, so the mirror's boundaries match theirs:
	# whole blocks only, and a heading travels with the block under it. The heading
	# pattern is post-conversion Discord Markdown — both the legacy-Markdown `*x*` and
	# the release-notes `<b>x</b>` forms have become **x** by now.
	# Collect the parts before sending any of them. Each one is closed with the invisible
	# blank line, which is what creates the gap at the seam that follows it — padding put
	# at the START of a part is trimmed and does nothing. The limit gives back the tail's
	# units so no part can cross 2000 once it is padded.
	local -a pieces=()
	local piece
	while IFS= read -r -d "$PACK_RS" piece; do
		if [ -n "$piece" ]; then
			pieces+=("$piece")
		fi
	done < <(printf '%s' "$text" | pack_message "$((DISCORD_LIMIT - DISCORD_TAIL_UNITS))" '^\*\*.*\*\*$' _pack_len_units)

	for piece in "${pieces[@]}"; do
		if [ "$posts" -gt 0 ]; then
			sleep "$DISCORD_PAUSE"
		fi
		_discord_post_once "$url" "${piece}${DISCORD_TAIL}" || rc=1
		posts=$((posts + 1))
	done

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
