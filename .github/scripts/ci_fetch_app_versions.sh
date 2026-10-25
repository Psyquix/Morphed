#!/bin/bash
set -euo pipefail

# Convert utils.sh to Unix line endings if needed
dos2unix scripts/utils.sh 2>/dev/null || true

source scripts/utils.sh
set_prebuilts

# Use pre-compiled configs if available, or compile as fallback
CONFIG_INPUTS=()
[ -f config.stable.json ] && CONFIG_INPUTS+=(config.stable.json)
[ -f config.beta.json ] && CONFIG_INPUTS+=(config.beta.json)

if [ ${#CONFIG_INPUTS[@]} -eq 0 ]; then
    python3 .github/scripts/compile_patch_configs.py
    [ -f config.stable.json ] && CONFIG_INPUTS+=(config.stable.json)
    [ -f config.beta.json ] && CONFIG_INPUTS+=(config.beta.json)
fi

mkdir -p state
[ -f state/app_versions.json ] || echo '{}' > state/app_versions.json
> fetched_app_versions.jsonl
CHECK_ONLY_LISTED=$(jq -r '."_check_only_listed" // false' state/app_versions.json)

if [ "$CHECK_ONLY_LISTED" = "true" ]; then
    jq -r 'to_entries | map(select(.key | startswith("_") | not)) | .[] | "\(.key)|\(.value.keys[0])"' state/app_versions.json > check_list.txt
else
    # All enabled apps across stable and dev configs
    ENABLED_APPS=$(jq -r -s 'add | to_entries | map(select((.value | type == "object") and .value.enabled == true)) | .[].key' "${CONFIG_INPUTS[@]}")
    
    # Get all grouped apps to exclude them
    GROUPED_APPS=$(jq -r 'to_entries | map(select(.key | startswith("_") | not)) | .[].value.keys[]?' state/app_versions.json 2>/dev/null || echo "")
    
    > check_list.txt
    
    # Add groups first
    jq -r 'to_entries | map(select(.key | startswith("_") | not)) | .[] | "\(.key)|\(.value.keys[0])"' state/app_versions.json >> check_list.txt
    
    # Add non-grouped enabled apps
    for app in $ENABLED_APPS; do
        if ! echo "$GROUPED_APPS" | grep -qx "$app"; then
            echo "$app|$app" >> check_list.txt
        fi
    done
fi

# The order the watcher asks its stores in is the order the engine downloads in:
# DL_SRCS in scripts/utils.sh is the single implementation of source priority, so the
# version the watcher records is the version the build is handed first - and a group
# whose stores are a release apart stops answering differently per run because the
# scraping happened to reach a different one. Three members are skipped, for the same
# reasons build_rv skips them:
#   cache_repo - the cache answers "do you have version X?", never "what is the latest
#                X?" (docs/cache-repo.md), so it must not become a shadow source of truth
#   archive    - a mirror of what was already published, never a source of truth
#   direct     - a bare file URL: its version can only be read off the artifact, which
#                means downloading it (docs/decisions/0012)
WATCH_SKIP=("cache_repo" "direct" "archive")

declare -A cached_versions  # dlurl -> "<source>|<version>", so a reused answer says who gave it

while IFS='|' read -r group app; do
    if [ -z "$group" ] || [ -z "$app" ]; then continue; fi
    echo "::group::Fetching version for $group ($app)..."

    dlurls=()
    sources=()
    for src in "${DL_SRCS[@]}"; do
        if printf '%s\n' "${WATCH_SKIP[@]}" | grep -qx "$src"; then continue; fi
        if ! declare -F "get_${src}_resp" >/dev/null; then
            echo "::warning::$src is in DL_SRCS but lists no versions; skipping it for $app."
            continue
        fi
        url=$(jq -r -s --arg app "$app" --arg k "${src}-dlurl" 'add | .[$app][$k] // ""' "${CONFIG_INPUTS[@]}")
        if [ -z "$url" ] || [ "$url" = "null" ]; then continue; fi
        dlurls+=("$url")
        sources+=("$src")
    done

    if [ ${#dlurls[@]} -eq 0 ]; then
        echo "::warning::No dlurl for $app, skipping"
        echo "::endgroup::"
        continue
    fi
    
    latest_ver=""
    answered_by=""
    for i in "${!dlurls[@]}"; do
        dlurl="${dlurls[$i]}"
        src_name="${sources[$i]}"
        
        if [ -n "${cached_versions[$dlurl]:-}" ]; then
            answered_by="${cached_versions[$dlurl]%%|*}"
            latest_ver="${cached_versions[$dlurl]#*|}"
            echo "::notice::Reusing cached version for $app: $latest_ver ($answered_by)"
            break
        fi

        if ! get_${src_name}_resp "$dlurl"; then
            echo "::warning::Could not read the $src_name page for $app ($dlurl); trying the next source."
            continue
        fi
        if ! vers=$(get_${src_name}_vers); then
            echo "::warning::$src_name failed to list versions for $app ($dlurl); trying the next source."
            continue
        fi
        latest_ver=$(printf '%s\n' "$vers" | get_highest_ver)
        if [ -z "$latest_ver" ]; then
            # The page answered and named no version at all. This branch used to be
            # silent, and the silence was the bug: an empty list looked exactly like a
            # store with nothing to say, so the group quietly moved to the next source,
            # whose number was a different release - and every run that lost the race
            # re-recorded, re-woken and re-rebuilt the app against it.
            echo "::warning::$src_name listed no version for $app ($dlurl); trying the next source."
            continue
        fi

        cached_versions[$dlurl]="${src_name}|${latest_ver}"
        answered_by="$src_name"
        # Sleep to avoid rate limiting only if we actually fetched
        sleep $((RANDOM % 5 + 3))
        break
    done
    
    if [ -n "$latest_ver" ]; then
        echo "Latest version for $group is $latest_ver (from $answered_by)"
        jq -n --arg grp "$group" --arg ver "$latest_ver" '{($grp): $ver}' >> fetched_app_versions.jsonl
    else
        echo "::error::Could not find latest version for $group; sources tried: ${sources[*]}"
    fi
    echo "::endgroup::"
done < check_list.txt

if [ -s fetched_app_versions.jsonl ]; then
    FETCHED_JSON=$(jq -s 'reduce .[] as $item ({}; . * $item)' fetched_app_versions.jsonl)
else
    FETCHED_JSON="{}"
fi

echo "$FETCHED_JSON" > fetched_app_versions.json

rm -f fetched_app_versions.jsonl check_list.txt
