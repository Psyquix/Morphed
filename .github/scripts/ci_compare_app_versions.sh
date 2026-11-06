#!/bin/bash
set -euo pipefail

# The comparator is the engine's own: scripts/utils.sh get_highest_ver is the single
# implementation of "which of these versions is higher", so the watcher cannot decide
# a different ordering than build_rv would apply to the same list (it also tolerates a
# store's free-text suffix - "349.9 - Stable" - which a plain string compare cannot).
# Convert utils.sh to Unix line endings if needed
dos2unix scripts/utils.sh 2>/dev/null || true
source scripts/utils.sh

CURRENT_VERSIONS="state/app_versions.json"
ACTIVE_APPS="active_apps.json"

[ -f "$CURRENT_VERSIONS" ] || echo '{}' > "$CURRENT_VERSIONS"

if [ -f fetched_app_versions.json ]; then
    FETCHED_APP_VERSIONS=$(cat fetched_app_versions.json)
else
    FETCHED_APP_VERSIONS="{}"
fi
[ -f "$ACTIVE_APPS" ] || echo '[]' > "$ACTIVE_APPS"

APP_UPDATES_FILE="app_updates.json"
echo '{}' > "$APP_UPDATES_FILE"

TRIGGER_APP_UPDATE=0

# Compare fetched versions with current versions
while IFS= read -r group; do
    if [ -z "$group" ]; then continue; fi
    new_ver=$(echo "$FETCHED_APP_VERSIONS" | jq -r ".\"$group\"")
    old_ver=$(jq -r ".\"$group\".version // empty" "$CURRENT_VERSIONS")

    if [ "$new_ver" = "null" ]; then new_ver=""; fi
    if [ -z "$new_ver" ] || [ "$new_ver" = "$old_ver" ]; then continue; fi

    # A move is only an update when it moves UP. The recorded value is what build_rv
    # is told to patch when a bundle advertises no version, so treating a difference as
    # an update let a group whose stores disagree bounce forever: Uptodown lags
    # APKMirror, whichever answered was recorded, and the next run's other answer was
    # then "newer" again - re-waking, re-patching and re-releasing the same two APKs on
    # every schedule tick. A genuine pull-back stays visible as a warning instead of
    # silently re-recording a version the pool has already moved past.
    if [ -n "$old_ver" ]; then
        # Compare the release, not the way a store prints it. APKMirror and Uptodown
        # both append the channel ("349.9 - Stable") while other stores answer bare,
        # and "349.9" versus "349.9 - Stable" is not a version difference - yet left
        # to the sorter the padded one wins, so a store that started suffixing its
        # numbers would re-key the cache name and rebuild an app that had not moved.
        old_key="${old_ver%% *}"
        new_key="${new_ver%% *}"
        if [ "$old_key" = "$new_key" ]; then
            echo "::warning::Not an update for $group: $new_ver is $old_key, printed differently than the recorded $old_ver. Keeping $old_ver."
            continue
        fi
        higher=$(printf '%s\n%s\n' "$old_key" "$new_key" | get_highest_ver)
        if [ "$higher" != "$new_key" ]; then
            echo "::warning::Not an update for $group: store says $new_ver, recorded $old_ver is higher. Keeping $old_ver (the stores disagree; check which one answered)."
            continue
        fi
    fi

    echo "::notice::Update detected for $group: ${old_ver:-unset} -> $new_ver"
    TRIGGER_APP_UPDATE=1

    # Add all constituent keys to active_apps.json
    keys=$(jq -r ".\"$group\".keys[]? // \"$group\"" "$CURRENT_VERSIONS")
    for key in $keys; do
        jq --arg k "$key" '. + [$k] | unique' "$ACTIVE_APPS" > tmp.json && mv tmp.json "$ACTIVE_APPS"
    done

    # Add to app_updates.json for Telegram notification (using Group name)
    jq --arg grp "$group" --arg old "${old_ver:-unknown}" --arg new "$new_ver" '.[$grp] = {old: $old, new: $new}' "$APP_UPDATES_FILE" > tmp.json && mv tmp.json "$APP_UPDATES_FILE"

    # Update current versions
    jq --arg grp "$group" --arg ver "$new_ver" '
        if .[$grp] | type == "object" then
            .[$grp].version = $ver
        else
            .[$grp] = { keys: [$grp], version: $ver }
        end
    ' "$CURRENT_VERSIONS" > tmp.json && mv tmp.json "$CURRENT_VERSIONS"
done < <(echo "$FETCHED_APP_VERSIONS" | jq -r 'keys[]')

if [ -n "${GITHUB_OUTPUT:-}" ]; then
    echo "TRIGGER_APP_UPDATE=$TRIGGER_APP_UPDATE" >> "$GITHUB_OUTPUT"
fi
