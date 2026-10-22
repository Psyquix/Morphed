#!/bin/bash
# notify_queue.sh — a durable, cross-run queue for debounced issue/PR alerts,
# stored as one append-only JSONL file (`queue.jsonl`) on a dedicated orphan
# branch (`notify-queue`). Sourced, not executed; used by notify_enqueue.sh and
# notify_drain.sh.
#
# Why a branch: GitHub fires one workflow run per event and runs cannot share
# memory, so a batch needs a store every run can append to and one run can drain
# — exactly the pattern `commit_data_branch.sh` already uses for generated state.
# Plumbing-only (temp index + commit-tree), so it never touches the checked-out
# worktree or the real index.
#
# Concurrency: several runs append at once; the push-retry loop re-fetches and
# re-appends on a race, so no event is dropped and the branch stays linear
# (fast-forward only, never forced — see the repo's no-force-push rule).
#
# Every git call is pinned to core.autocrlf=false / core.eol=lf: the queue is a
# byte-exact JSONL that other tooling greps by whole line, so a stray CRLF from a
# runner's git config would break both storage and the drain's line matching.

NQ_BRANCH="${NQ_BRANCH:-notify-queue}"
NQ_FILE="${NQ_FILE:-queue.jsonl}"
# The well-known empty tree; read-tree seeds a from-scratch commit with it.
NQ_EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
NL=$'\n'

export GIT_AUTHOR_NAME="${GIT_AUTHOR_NAME:-github-actions[bot]}"
export GIT_AUTHOR_EMAIL="${GIT_AUTHOR_EMAIL:-41898282+github-actions[bot]@users.noreply.github.com}"
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME"
export GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

# _git — git with line endings pinned, so the JSONL bytes are host-independent.
_git() {
	git -c core.autocrlf=false -c core.eol=lf -c core.safecrlf=false "$@"
}

# nq_base_sha — echo the tip COMMIT of NQ_BRANCH, or empty when the branch does
# not exist yet (the caller then writes a root commit instead of a child).
nq_base_sha() {
	if _git fetch -q origin "$NQ_BRANCH" 2> /dev/null; then
		_git rev-parse FETCH_HEAD
	fi
}

# nq_read [base] — echo the current queue file contents (empty when absent).
nq_read() {
	local base=${1-}
	[ -n "$base" ] || base=$(nq_base_sha)
	[ -n "$base" ] || return 0
	_git cat-file -p "$base:$NQ_FILE" 2> /dev/null || true
}

# nq_commit <base> <content> — build a commit whose NQ_FILE is exactly <content>.
# <base> empty ⇒ root commit (no parent); otherwise a child of <base>. Echoes the
# new sha, or returns 1 when <content> is already what the branch holds.
nq_commit() {
	local base=${1:-} content=$2 idx tree blob old commit
	if [ -n "$base" ]; then
		old=$(_git cat-file -p "$base:$NQ_FILE" 2> /dev/null || true)
		[ "$old" = "$content" ] && return 1
	fi
	idx=$(mktemp)
	GIT_INDEX_FILE=$idx _git read-tree "${base:-$NQ_EMPTY_TREE}"
	blob=$(printf '%s' "$content" | _git hash-object -w --stdin)
	GIT_INDEX_FILE=$idx _git update-index --add --cacheinfo "100644,$blob,$NQ_FILE"
	tree=$(GIT_INDEX_FILE=$idx _git write-tree)
	rm -f "$idx"
	if [ -n "$base" ]; then
		commit=$(_git commit-tree "$tree" -p "$base" -m "notify: queue update")
	else
		commit=$(_git commit-tree "$tree" -m "notify: create queue")
	fi
	echo "$commit"
}

# nq_write <content> — commit <content> as NQ_FILE over the current tip, retrying
# on a non-fast-forward push. The caller passes already-merged content, so a
# retry just re-parents onto the moved tip and re-pushes.
nq_write() {
	local content=$1 attempt base new
	for attempt in 1 2 3; do
		base=$(nq_base_sha)
		if ! new=$(nq_commit "$base" "$content"); then
			return 0
		fi
		if _git push -q origin "$new:refs/heads/$NQ_BRANCH" 2> /dev/null; then
			return 0
		fi
		sleep 2
	done
	return 1
}

# nq_append <line> — append one JSONL <line> under push-retry, re-reading the
# remote content on every attempt so concurrent appends merge rather than clobber.
nq_append() {
	local line=$1 attempt base current merged new
	for attempt in 1 2 3; do
		base=$(nq_base_sha)
		current=$(nq_read "$base")
		# Command substitution strips trailing newlines, so re-add the separator
		# explicitly; without it two entries would land on one JSONL line.
		if [ -n "$current" ]; then
			merged="${current}${NL}${line}${NL}"
		else
			merged="${line}${NL}"
		fi
		new=$(nq_commit "$base" "$merged")
		if _git push -q origin "$new:refs/heads/$NQ_BRANCH" 2> /dev/null; then
			return 0
		fi
		sleep 2
	done
	return 1
}
