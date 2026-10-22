#!/bin/bash
# notify_render.sh — single owner of the event message body (workflow failure, issue,
# PR). Sourced, never executed: callers get one canonical rendering whether they send
# immediately (workflow_call) or queue it for a debounced batch (issues/PR).
#
# Written as Telegram HTML, not legacy Markdown, for two reasons.
#
# 1. Markdown cannot put a link inside a bold run — "*[a](url)*" renders literally — so
#    the headline had to choose between being bold and being clickable, and chose
#    clickable. HTML nests <a><b></b></a>, so the headline is both, and the detail lines
#    use the same ╰ grammar as the release notes, the build queue and the failure report:
#    every notice in the topic now reads as one family.
# 2. Legacy Markdown has no escape, so the old md() *deleted* the characters that would
#    corrupt a run. A pull request titled "Fix [rename] (v2)" arrived as "Fix rename v2".
#    HTML only needs & < > escaped, so titles and branch names arrive whole.
#
# Reads env describing the event and echoes the composed body. The caller supplies
# everything except what is optional per branch.
#
#   WF_NAME REPO ACTOR REF_NAME GITHUB_RUN_ID GITHUB_RUN_NUMBER GITHUB_SERVER_URL
#   EVENT_NAME ACTION PR_NUM PR_URL PR_TITLE PR_HEAD_REF PR_BASE_REF
#   PR_COMMITS PR_FILES PR_ADD PR_DEL ISSUE_NUM ISSUE_URL ISSUE_TITLE

# h <text> — escape the three characters Telegram HTML cannot carry raw. Nothing is
# dropped: user-authored text keeps every bracket and asterisk it was written with.
h() { printf '%s' "$1" | sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# hlink <url> <label> — a bold labelled anchor. The label is wrapped in <b> here so
# every headline in this file has exactly one shape, and the escaping is applied to the
# label, not to the URL, which is always built from GitHub's own fields.
hlink() { printf '<a href="%s"><b>%s</b></a>' "$(h "$1")" "$(h "$2")"; }

render_message() {
	local NL=$'\n' ACTOR_URL="https://github.com/${ACTOR}" REPO_URL="https://github.com/${REPO}"
	local REPO_MD ACTOR_MD MSG TITLE ICON CSTR

	REPO_MD="$(hlink "$REPO_URL" "${REPO#*/}")"
	ACTOR_MD="$(hlink "$ACTOR_URL" "${ACTOR}")"

	if [ -n "${WF_NAME:-}" ]; then
		local wf_url="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID}"
		MSG="$(hlink "$wf_url" "🔴 ${WF_NAME} #${GITHUB_RUN_NUMBER} failed") in ${REPO_MD}${NL}${NL}"
		MSG+="  ╰ 🌿 <code>$(h "${REF_NAME}")</code> · ${ACTOR_MD}"

	elif [ "${EVENT_NAME:-}" = "pull_request" ]; then
		TITLE="$(h "${PR_TITLE}")"
		case "${ACTION:-}" in
		opened) ICON="🟢" ;;
		closed) ICON="🔴" ;;
		*) ICON="🟡" ;;
		esac
		if [ "${PR_COMMITS:-}" = "1" ]; then
			CSTR="commit"
		else
			CSTR="commits"
		fi
		MSG="$(hlink "${PR_URL}" "${ICON} Pull request #${PR_NUM} ${ACTION}") in ${REPO_MD}${NL}${NL}"
		MSG+="  ╰ 📝 ${TITLE}${NL}"
		MSG+="  ╰ 👤 ${ACTOR_MD} · 📑 <code>$(h "${PR_HEAD_REF}")</code> → <code>$(h "${PR_BASE_REF}")</code> · ${PR_COMMITS} ${CSTR} · ${PR_FILES} files · +${PR_ADD}/-${PR_DEL}"

	else
		TITLE="$(h "${ISSUE_TITLE}")"
		case "${ACTION:-}" in
		closed) ICON="✅" ;;
		reopened) ICON="🔄" ;;
		*) ICON="🐛" ;;
		esac
		MSG="$(hlink "${ISSUE_URL}" "${ICON} Issue #${ISSUE_NUM} ${ACTION}") in ${REPO_MD}${NL}${NL}"
		MSG+="  ╰ 📝 ${TITLE}${NL}"
		MSG+="  ╰ 👤 ${ACTOR_MD}"
	fi

	printf '%s' "$MSG"
}
