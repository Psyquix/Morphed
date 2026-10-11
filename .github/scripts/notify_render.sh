#!/bin/bash
# notify_render.sh — single owner of the Telegram Markdown body for a notify
# event (workflow failure, issue, or PR). Sourced, never executed: callers get
# one canonical rendering whether they send immediately (workflow_call) or queue
# it for a debounced batch (issues/PR). The shape matches the build/patch
# notifications: a linked header followed by emoji-led sub-lines. Telegram's
# legacy Markdown cannot bold a link (`*[..](..)*` renders literally), so the
# header link stays unbolded and each sub-line stands on its own.
#
# Reads env describing the event and echoes the composed Markdown. The caller
# supplies everything except what is optional per branch.
#
#   WF_NAME REPO ACTOR REF_NAME GITHUB_RUN_ID GITHUB_RUN_NUMBER GITHUB_SERVER_URL
#   EVENT_NAME ACTION PR_NUM PR_URL PR_TITLE PR_HEAD_REF PR_BASE_REF
#   PR_COMMITS PR_FILES PR_ADD PR_DEL ISSUE_NUM ISSUE_URL ISSUE_TITLE

# Markdown (legacy) has no escape-all helper; drop the few characters in
# user-authored titles that would otherwise start a bold/italic/link run.
md() { printf '%s' "$1" | tr -d '*_[]`'; }

render_message() {
	local NL=$'\n' ACTOR_URL="https://github.com/${ACTOR}" REPO_URL="https://github.com/${REPO}"
	local REPO_MD="[$(md "${REPO#*/}")](${REPO_URL})" ACTOR_MD="[$(md "${ACTOR}")](${ACTOR_URL})"
	local MSG TITLE ICON

	if [ -n "${WF_NAME:-}" ]; then
		local wf_url="${GITHUB_SERVER_URL:-https://github.com}/${REPO}/actions/runs/${GITHUB_RUN_ID}"
		MSG="🔴 [$(md "${WF_NAME}") #${GITHUB_RUN_NUMBER} failed](${wf_url}) in ${REPO_MD}${NL}${NL}"
		MSG+="🌿 \`$(md "${REF_NAME}")\` • ${ACTOR_MD}"

	elif [ "${EVENT_NAME:-}" = "pull_request" ]; then
		TITLE="$(md "${PR_TITLE}")"
		case "${ACTION:-}" in
		opened) ICON="🟢" ;;
		closed) ICON="🔴" ;;
		*) ICON="🟡" ;;
		esac
		[ "${PR_COMMITS:-}" = "1" ] && CSTR="commit" || CSTR="commits"
		MSG="${ICON} [Pull request #${PR_NUM} ${ACTION}](${PR_URL}) in ${REPO_MD}${NL}${NL}"
		MSG+="📝 ${TITLE}${NL}"
		MSG+="👤 ${ACTOR_MD}${NL}"
		MSG+="📑 \`$(md "${PR_HEAD_REF}")\` → \`$(md "${PR_BASE_REF}")\` • ${PR_COMMITS} ${CSTR} • ${PR_FILES} files • +${PR_ADD}/-${PR_DEL}"

	else
		TITLE="$(md "${ISSUE_TITLE}")"
		case "${ACTION:-}" in
		closed) ICON="✅" ;;
		reopened) ICON="🔄" ;;
		*) ICON="🐛" ;;
		esac
		MSG="${ICON} [Issue #${ISSUE_NUM} ${ACTION}](${ISSUE_URL}) in ${REPO_MD}${NL}${NL}"
		MSG+="📝 ${TITLE}${NL}"
		MSG+="👤 ${ACTOR_MD}"
	fi

	printf '%s' "$MSG"
}
