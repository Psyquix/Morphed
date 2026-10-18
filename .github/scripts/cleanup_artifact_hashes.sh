#!/bin/bash
set -euo pipefail

# Prune state/build_content_hashes.json entries whose artifact no longer lives
# on ANY release of this repository.
#
# Why this is correctness, not tidying: a duplicate verdict suppresses
# publishing on the strength of the state entry. If cleanup's asset pruning
# later deletes that very file (keep-2-newest-per-app+arch, archive exclusions,
# or a whole app being dropped), a pinned rebuild of the same version would be
# "skipped" as identical to a file nobody can download — the suppression would
# silently eat the release. The entry may only suppress a build while its file
# is actually published somewhere.
#
# Ordering: run AFTER cleanup-archive-assets.py and the release deleter, so
# entries whose assets were legitimately pruned this pass are removed here in
# the same run (an entry that still has a live asset is never touched).
#
# A stem counts as live through either published spelling it can produce, and each
# spelling proves its own kind — which is the whole point here:
#   <stem>.apk                      -> kind "apk"   (apk / both builds)
#   <pre>-module-v<rest>-<arch>.zip -> kind "module" (module / both builds)
# An entry keeps exactly the kinds it can still prove, so a pruned module zip stops
# suppressing the module the next build was asked to publish. A bare-md5 entry (written
# before kinds were tracked) that still has live files is upgraded to the object form
# with the kinds the releases prove: this step is the only reader of real liveness, so
# it is the only place that can state it. An entry with no live spelling is dropped.
#
# The fetch is fail-loud on a broken paginated call (empty output with
# --paginate would otherwise read as "everything is gone" and wipe all
# entries). A repo with genuinely no releases cannot hold live assets, so
# clearing then converges at the cost of one rebuild per app.
#
# Env: GITHUB_TOKEN (gh default), GH_OUTPUT_FILE optional
#      (default "temp/gh_outputs/cleanup_hashes.env", written for the
#      follow-up commit step), GITHUB_REPOSITORY required.
# Writes: state/build_content_hashes.json (pruned in place when changed)

REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY not set}"
STATE_FILE="state/build_content_hashes.json"
ASSETS="temp/gh_outputs/release-assets.txt"
OUT_ENV="${GH_OUTPUT_FILE:-temp/gh_outputs/cleanup_hashes.env}"

if [ ! -f "$STATE_FILE" ]; then
	echo "No $STATE_FILE yet; nothing to prune."
	mkdir -p "$(dirname "$OUT_ENV")"
	echo "STATE_PRUNED=false" >"$OUT_ENV"
	exit 0
fi
if ! jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
	echo "::error::$STATE_FILE is not a JSON object — refusing to prune a malformed state file" >&2
	exit 1
fi

mkdir -p "$(dirname "$ASSETS")" "$(dirname "$OUT_ENV")"
if ! gh api --paginate "repos/$REPO/releases" -q '.[].assets[].name' >"$ASSETS"; then
	echo "::error::Could not list release assets — refusing to prune (a partial list could delete live guards)" >&2
	exit 1
fi
echo "Comparing against $(grep -c . "$ASSETS" || true) live asset name(s)."

jq --rawfile rel "$ASSETS" '
  def apk_name: (. | ascii_downcase) + ".apk";
  def module_name:
    ((. | sub("^(?<pre>.+?)-v(?<d>[0-9])"; .pre + "-module-v" + .d) | ascii_downcase) + ".zip");
  def live_kinds($names):
    . as $s
    | [ (if ($names | has($s | apk_name)) then "apk" else empty end),
        (if ($names | has($s | module_name)) then "module" else empty end) ];
  ([$rel | splits("\n") | select(length > 0) | ascii_downcase] | INDEX(.)) as $live
  | with_entries(.value |= with_entries(
      (.key | live_kinds($live)) as $k
      | if ($k | length) == 0 then empty
      elif (.value | type) == "object" then .value.kinds = $k
      else .value = { hash: .value, kinds: $k } end))
  | with_entries(select(.value | length > 0))
' "$STATE_FILE" >"${STATE_FILE}.tmp"

before=$(jq '[.[] | length] | add // 0' "$STATE_FILE")
after=$(jq '[.[] | length] | add // 0' "$STATE_FILE.tmp")
# The DOCUMENT decides whether the rewrite is kept, not the key count: trimming one
# kind off an entry (its module zip pruned from the archive release) leaves the count
# exactly as it was, so a count-only test would discard the one edit that matters —
# the entry would go on suppressing an artifact nobody can download, and it would do
# so silently on every run. Comparing parsed JSON rather than bytes keeps the test
# honest whatever indentation the writer used.
if [ "$(jq -cS . "$STATE_FILE")" = "$(jq -cS . "$STATE_FILE.tmp")" ]; then
	rm -f "${STATE_FILE}.tmp"
	echo "All $after fingerprints have live release assets; state unchanged."
	echo "STATE_PRUNED=false" >"$OUT_ENV"
else
	mv -f "${STATE_FILE}.tmp" "$STATE_FILE"
	if [ "$before" != "$after" ]; then
		echo "Pruned $((before - after)) stale fingerprint(s) from $STATE_FILE ($before -> $after)."
	else
		echo "No fingerprint removed; trimmed the kinds that lost their live asset."
	fi
	echo "STATE_PRUNED=true" >"$OUT_ENV"
fi
