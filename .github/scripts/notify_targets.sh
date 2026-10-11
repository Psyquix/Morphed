#!/bin/bash
# notify_targets.sh — the single owner of "may this Telegram send run?". Sourced,
# never executed: every send site (build release notes, CI patch/app report,
# build-failure report, queued issue/PR batch, workflow_call failure alert) asks
# the same question and refuses the same way.
#
# Why it exists: the chat handles and topic IDs used to be spelled out at each
# send site with an inline default — a handle and a topic number written into the
# script. A variable that was missing or misspelled therefore failed nothing: the
# send went to the hardcoded chat, which is the wrong chat after a group rename.
# The targets now come from repository variables only, and an unset one is a
# configuration error: report it and send nothing rather than guess.
#
# A topic ID is required, not optional: the notification group is a forum, and
# Telegram routes a message without message_thread_id into the General topic.
# That looks like a successful delivery, so a missing thread ID must not be
# treated as "no thread".
#
# Placement rule for callers: run this AFTER the TG_TOKEN guard (a fork with no
# token skips quietly) and AFTER the script's own "nothing to send" early exit
# (a clean build must not fail a notify step over config nobody needed). On
# failure the step exits non-zero and no message is sent — the step goes red, the
# build/publish result is unchanged (notify steps are fail-soft).

# tg_require_targets NAME=VALUE [NAME=VALUE ...]
# Lists every NAME whose VALUE is empty in one ::error:: annotation and returns
# 1 so the caller can exit; returns 0 when all are set.
tg_require_targets() {
	local missing="" pair name value
	for pair in "$@"; do
		name=${pair%%=*}
		value=${pair#*=}
		[ -n "$value" ] || missing="${missing:+${missing}, }${name}"
	done
	if [ -n "$missing" ]; then
		echo "::error::Telegram target not configured: ${missing} unset. Set it under Settings -> Secrets and variables -> Actions -> Variables; nothing was sent." >&2
		return 1
	fi
	return 0
}
