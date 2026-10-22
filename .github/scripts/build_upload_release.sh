#!/bin/bash
set -euo pipefail

# Unified release uploader using native gh CLI with per-file retry and clobber.
#
# Rule: a metadata field the caller did not name is not written - absence means
# "leave it be", never "write empty". Rationale, incident history and rejected
# alternatives: docs/decisions/0001-release-metadata-ownership.md
#
# Inputs (via env vars):
#   RELEASE_TAG / TAG     : Release tag name (required)
#   RELEASE_TITLE / TITLE : Release title. Unset leaves an existing name alone and
#                           lets gh name a new release after the tag.
#   RELEASE_BODY_FILE     : Path to a markdown notes file (e.g. build.md). Missing,
#                           empty or unset all count as "not named".
#   RELEASE_NOTES         : Inline notes string; consulted only if no body file was
#                           named. Empty means "not named", not "clear the body".
#   IS_PRERELEASE         : "true" marks a pre-release, "false" a full release,
#                           unset/empty leaves the state as it is. Any other value
#                           is rejected with exit 2 instead of being guessed at.
#   RELEASE_TARGET        : Target branch/commit for a NEW release (optional).
#                           Ignored when the release already exists.
#   UPLOAD_FILES          : Space-separated files/glob patterns (default: "./build/*")
#   GITHUB_REPOSITORY     : owner/repo (required)
#   GH_TOKEN              : GitHub token (required)
#
# Assets are the exception: the file list IS the named intent and gh refuses a
# duplicate asset name, so --clobber stays unconditional (retries must be idempotent).

TAG="${RELEASE_TAG:-${TAG:?RELEASE_TAG or TAG not set}}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
TITLE="${RELEASE_TITLE:-${TITLE:-}}"
BODY_FILE="${RELEASE_BODY_FILE:-${BODY_FILE:-}}"
RELEASE_NOTES="${RELEASE_NOTES:-}"
IS_PRERELEASE="${IS_PRERELEASE:-}"
TARGET="${RELEASE_TARGET:-${TARGET:-}}"
FILES_PATTERN="${UPLOAD_FILES:-${FILES:-./build/*}}"

echo "=== Uploading release assets for tag: $TAG ==="

# 1. Turn each named field into flags; an empty array means "the caller did not
# name this", so it never reaches gh.
TARGET_ARG=()
[ -n "$TARGET" ] && TARGET_ARG=(--target "$TARGET")

TITLE_ARG=()
[ -n "$TITLE" ] && TITLE_ARG=(-t "$TITLE")

NOTES_ARG=()
if [ -n "$BODY_FILE" ] && [ -s "$BODY_FILE" ]; then
    NOTES_ARG=(-F "$BODY_FILE")
elif [ -n "$RELEASE_NOTES" ]; then
    NOTES_ARG=(-n "$RELEASE_NOTES")
fi

PRERELEASE_CREATE_ARG=()
PRERELEASE_EDIT_ARG=()
# Three states, because "the caller said nothing" is not the same claim as "the
# caller said false" - the latter used to demote a hand-flagged release silently.
case ${IS_PRERELEASE,,} in
    true)
        PRERELEASE_CREATE_ARG=(--prerelease)
        PRERELEASE_EDIT_ARG=(--prerelease)
        ;;
    false)
        PRERELEASE_EDIT_ARG=(--prerelease=false)
        ;;
    "") ;;
    *)
        echo "::error::IS_PRERELEASE must be true, false or unset (got: '$IS_PRERELEASE')" >&2
        exit 2
        ;;
esac

# 2. Ensure release exists or create it
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    # gh release edit replaces the whole body, so send only the named fields in one
    # call - and when nothing was named, there is no call to make.
    EDIT_ARG=("${TITLE_ARG[@]}" "${NOTES_ARG[@]}" "${PRERELEASE_EDIT_ARG[@]}")
    if [ ${#EDIT_ARG[@]} -gt 0 ]; then
        echo "Release $TAG already exists, updating metadata: ${EDIT_ARG[*]}"
        gh release edit "$TAG" "${EDIT_ARG[@]}" -R "$REPO" || true
    else
        echo "Release $TAG already exists and no metadata was named - leaving it as-is."
    fi
else
    CREATE_ARG=("${TITLE_ARG[@]}" "${NOTES_ARG[@]}" "${PRERELEASE_CREATE_ARG[@]}" "${TARGET_ARG[@]}")
    if [ ${#CREATE_ARG[@]} -gt 0 ]; then
        echo "Creating release $TAG with: ${CREATE_ARG[*]}"
    else
        echo "Creating release $TAG with gh's defaults (name = tag, empty body)."
    fi
    gh release create "$TAG" "${CREATE_ARG[@]}" -R "$REPO"
fi

# 3. Collect files to upload
shopt -s nullglob
FILES=()
for pattern in $FILES_PATTERN; do
    for f in $pattern; do
        [ -f "$f" ] && FILES+=("$f")
    done
done
shopt -u nullglob

if [ ${#FILES[@]} -eq 0 ]; then
    echo "No files matched '$FILES_PATTERN' to upload"
    exit 0
fi

PARALLEL_JOBS="${UPLOAD_CONCURRENCY:-4}"
echo "Uploading ${#FILES[@]} file(s) to release $TAG (concurrency: $PARALLEL_JOBS)..."

# 4. Upload files in parallel with per-file retry
FAILED_LOG=$(mktemp)
trap 'rm -f "$FAILED_LOG"' EXIT

upload_file() {
    local file="$1"
    local filename
    filename=$(basename "$file")
    echo "⬆️ $filename..."
    for attempt in 1 2 3; do
        if gh release upload "$TAG" "$file" --clobber -R "$REPO"; then
            echo "✅ $filename"
            return 0
        fi
        echo "::warning::Attempt $attempt/3 failed for $filename, retrying in 5s..."
        sleep 5
    done
    echo "::error::Failed to upload $filename after 3 attempts"
    echo "$filename" >> "$FAILED_LOG"
    return 1
}

job_count=0

for file in "${FILES[@]}"; do
    upload_file "$file" &
    ((job_count++)) || true
    if [ "$job_count" -ge "$PARALLEL_JOBS" ]; then
        wait -n || true
        ((job_count--)) || true
    fi
done
wait

if [ -s "$FAILED_LOG" ]; then
    echo "::error::The following file(s) failed to upload:"
    cat "$FAILED_LOG"
    exit 1
fi

echo "=== All release assets uploaded successfully ==="
