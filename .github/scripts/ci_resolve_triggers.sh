#!/bin/bash
set -euo pipefail

RAW_TRIGGER_STABLE=${RAW_TRIGGER_STABLE:-0}
RAW_TRIGGER_BETA=${RAW_TRIGGER_BETA:-0}
RAW_TRIGGER_APP_UPDATE=${RAW_TRIGGER_APP_UPDATE:-0}
RAW_TRIGGER_CONFIG_CHANGE=${RAW_TRIGGER_CONFIG_CHANGE:-0}

TRIGGER_STABLE=0
TRIGGER_BETA=0

# A pending new/retry item is a reason to build on its own: it reaches the
# ENABLED_COUNT check (which is now > 0 because ci_generate_configs force-enabled
# the pending keys) even when no source or app version moved.
if [ "$RAW_TRIGGER_STABLE" = "1" ] || [ "$RAW_TRIGGER_APP_UPDATE" = "1" ] || [ "$RAW_TRIGGER_CONFIG_CHANGE" = "1" ]; then
  CFG="configs/stable_build.json"
  if [ -f "$CFG" ]; then
    ENABLED_COUNT=$(jq '[.[] | objects | select(.enabled != false)] | length' "$CFG" || echo 0)
    if [ "${ENABLED_COUNT:-0}" -gt 0 ]; then
      TRIGGER_STABLE=1
    else
      echo "::notice::Skipping stable build trigger: no enabled apps in $CFG"
    fi
  fi
fi

if [ "$RAW_TRIGGER_BETA" = "1" ] || [ "$RAW_TRIGGER_APP_UPDATE" = "1" ] || [ "$RAW_TRIGGER_CONFIG_CHANGE" = "1" ]; then
  CFG="configs/beta_build.json"
  if [ -f "$CFG" ]; then
    ENABLED_COUNT=$(jq '[.[] | objects | select(.enabled != false)] | length' "$CFG" || echo 0)
    if [ "${ENABLED_COUNT:-0}" -gt 0 ]; then
      TRIGGER_BETA=1
    else
      echo "::notice::Skipping beta build trigger: no enabled apps in $CFG"
    fi
  fi
fi

echo "TRIGGER_STABLE=$TRIGGER_STABLE" >> "$GITHUB_OUTPUT"
echo "TRIGGER_BETA=$TRIGGER_BETA" >> "$GITHUB_OUTPUT"
