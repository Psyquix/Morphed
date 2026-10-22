#!/bin/bash
# notify_pack.sh — the single owner of where a notification message ends. Sourced,
# never executed: every site that has to split a body longer than one message calls
# pack_message instead of carrying its own loop.
#
# Why it exists: the chunkers it replaced packed whole *lines* up to the limit, and a
# notification body is not written in lines — it is written in blocks. A release-note
# app entry is three lines (`• App vX`, `  ╰ APK: …`, `  ╰ Module: …`) that mean nothing
# apart, and a bundle heading (`<b>🧩 owner/repo (vX)</b>`) means nothing without the
# first block under it. Line packing therefore produced messages that opened with an
# orphan `╰ APK:` under no app name at all — which is what a long release looked like in
# the group. Packing blocks fixes that class of cut everywhere at once.
#
# Grammar: a block is a paragraph — consecutive lines with no blank line between them.
# Every notify body here is already written that way (the release-notes pipeline inserts
# a blank line around each heading precisely so blocks are separable), so no site has to
# describe its structure; it only names what a heading looks like in its own dialect,
# and that pattern keeps a heading glued to the block that follows it.
#
# What it cannot do: a single block bigger than the limit has no internal boundary left
# to respect, so it is still split — on line boundaries, then at spaces, then hard. That
# is the only case where a continuation can appear without its heading, and it is
# unreachable in practice for these bodies (the largest block is one app with two arch
# links, a few hundred characters against a 4096 limit).
#
# Globals written by design, because a shell function cannot return a number: _PACK_LEN
# (set by the measure in use) and _PACK_REMAINDER (set by _pack_split).

PACK_RS=$'\x1e'      # record separator between packed messages
_PACK_LEN=0
_PACK_REMAINDER=""

# Default size measure: shell characters. A caller whose API charges a different
# currency passes its own (notify_discord.sh measures UTF-16 code units).
_pack_len_chars() { _PACK_LEN=${#1}; }

# pack_message <limit> [heading-regex] [measure-fn] — read a body on stdin, write
# messages separated by $PACK_RS on stdout, each at most <limit> as measured by
# <measure-fn>. The regex, when given, matches a single-line block that introduces the
# block after it.
#
# Consume the records with:
#   while IFS= read -r -d "$PACK_RS" chunk; do send "$chunk"; done < <(printf '%s' "$MSG" | pack_message …)
pack_message() {
	local limit=${1:-4096} hre=${2:-} measure=${3:-_pack_len_chars}
	local NL=$'\n'
	local -a paras=()
	local buf="" line

	# Pass 1: paragraphs. Blank lines are separators and are not preserved; blocks are
	# re-joined with exactly one blank line, which is how every body here is written.
	# The `|| [ -n "$line" ]` is not decoration: a body built by command substitution
	# has no trailing newline, and plain `read` reports EOF *and* fills the variable on
	# that last partial line - without the guard the final block of every notification
	# would be dropped before packing ever saw it.
	while IFS= read -r line || [ -n "$line" ]; do
		if [ -z "$line" ]; then
			if [ -n "$buf" ]; then
				paras+=("$buf")
				buf=""
			fi
			continue
		fi
		buf="${buf:+${buf}${NL}}${line}"
	done
	if [ -n "$buf" ]; then
		paras+=("$buf")
	fi

	# Pass 2: glue each heading block to the block that follows it, so a boundary can
	# never fall between a section title and its content. Two headings in a row are not
	# glued — the second belongs to whatever comes after it. The index is advanced by
	# hand because the word list of `for i in "${!arr[@]}"` is built before the loop
	# runs, so skipping inside it does nothing but duplicate the next block.
	local -a units=()
	local i=0 p
	while [ "$i" -lt "${#paras[@]}" ]; do
		p=${paras[$i]}
		if [ -n "$hre" ] && [[ $p != *"$NL"* ]] && [[ $p =~ $hre ]] &&
			[ "$((i + 1))" -lt "${#paras[@]}" ] &&
			! [[ ${paras[$((i + 1))]} =~ $hre ]]; then
			units+=("${p}${NL}${NL}${paras[$((i + 1))]}")
			i=$((i + 2))
		else
			units+=("$p")
			i=$((i + 1))
		fi
	done

	# Pass 3: pack whole blocks; flush before a block that will not fit.
	local chunk="" clen=0 ulen unit before
	for unit in "${units[@]}"; do
		$measure "$unit"
		ulen=${_PACK_LEN}
		if [ -z "$chunk" ]; then
			chunk=$unit
			clen=$ulen
		elif [ $((clen + 2 + ulen)) -le "$limit" ]; then
			chunk="${chunk}${NL}${NL}${unit}"
			clen=$((clen + 2 + ulen))
		else
			printf '%s%s' "$chunk" "$PACK_RS"
			chunk=$unit
			clen=$ulen
		fi
		# A block too large for any message: give up on block boundaries inside it and
		# cut lines, then spaces. The first piece keeps the block's own first line, so
		# an oversized app entry still names its app.
		while [ "$clen" -gt "$limit" ]; do
			before=$chunk
			_pack_split "$limit" "$measure" "$chunk"
			chunk=$_PACK_REMAINDER
			if [ -z "$chunk" ]; then
				clen=0
				break
			fi
			# no progress means the split found nothing to emit; stop rather than spin
			if [ "$chunk" = "$before" ]; then
				printf '%s%s' "$chunk" "$PACK_RS"
				chunk=""
				clen=0
				break
			fi
			$measure "$chunk"
			clen=${_PACK_LEN}
		done
	done
	if [ -n "$chunk" ]; then
		printf '%s%s' "$chunk" "$PACK_RS"
	fi
}

# _pack_split <limit> <measure> <text> — emit the leading part of <text> that fits,
# terminated by $PACK_RS, and leave the rest in _PACK_REMAINDER. Breaks on a line
# boundary when one exists inside the limit, else at the last space, else mid-token.
_pack_split() {
	local limit=$1 measure=$2 text=$3
	local NL=$'\n' acc="" acclen=0 line len cut head sp

	# as many whole lines as fit (same last-partial-line guard as pack_message)
	while IFS= read -r line || [ -n "$line" ]; do
		$measure "$line"
		len=${_PACK_LEN}
		if [ -z "$acc" ]; then
			# the first line alone is too big: fall through to the space/hard cut
			if [ "$len" -gt "$limit" ]; then
				break
			fi
			acc=$line
			acclen=$len
			continue
		fi
		if [ $((acclen + 1 + len)) -gt "$limit" ]; then
			break
		fi
		acc="${acc}${NL}${line}"
		acclen=$((acclen + 1 + len))
	done <<<"$text"

	if [ -n "$acc" ]; then
		printf '%s%s' "$acc" "$PACK_RS"
		_PACK_REMAINDER=${text:${#acc}}
		_PACK_REMAINDER=${_PACK_REMAINDER#$'\n'}
		return 0
	fi

	# no line boundary fits: cut at the last space inside the limit, else hard
	cut=$limit
	head=${text:0:$cut}
	case "$head" in
	*" "*)
		sp=${head% *}
		# only take the space break when the piece is still worth its size
		if [ "${#sp}" -ge "$((limit / 2))" ]; then
			head=$sp
		fi
		;;
	esac
	printf '%s%s' "$head" "$PACK_RS"
	_PACK_REMAINDER=${text:${#head}}
	_PACK_REMAINDER=${_PACK_REMAINDER#" "}
	return 0
}
