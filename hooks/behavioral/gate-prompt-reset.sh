#!/usr/bin/env bash
# Sentinel — Gate Reset (UserPromptSubmit hook)
# Resets behavioral gate state at the start of each new prompt cycle.
# Install: UserPromptSubmit hook
set -euo pipefail

STATE_DIR="/tmp"
INPUT=$(cat)
SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
STATE_FILE="${STATE_DIR}/sentinel-gate-${SESSION_ID}.json"
METRICS_FILE="${SENTINEL_HOME:-$HOME/.claude}/state/behavioral_metrics.json"

PROMPT=$(echo "$INPUT" | jq -r '.prompt // ""' 2>/dev/null) || PROMPT=""

# Get current cycle count
CYCLE=0
if [ -f "$STATE_FILE" ]; then
  CYCLE=$(jq -r '.cycle // 0' "$STATE_FILE" 2>/dev/null) || CYCLE=0
fi
CYCLE=$((CYCLE + 1))

# Reset state
cat > "$STATE_FILE" <<EOJSON
{
  "cycle": ${CYCLE},
  "state": "AWAIT_VERIFY",
  "instruction": $(echo "$PROMPT" | head -c 200 | jq -Rs .),
  "reads_this_cycle": [],
  "verified_files": [],
  "scope": "",
  "updated_at": $(date +%s)
}
EOJSON

# Update metrics
mkdir -p "${SENTINEL_HOME:-$HOME/.claude}/state"
if [ ! -f "$METRICS_FILE" ]; then
  echo '{"blocked":0,"warned":0,"allowed":0,"verified":0,"cycles":0,"history":[]}' > "$METRICS_FILE"
fi
TMP=$(mktemp)
jq '.cycles = (.cycles + 1)' "$METRICS_FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$METRICS_FILE" || rm -f "$TMP"

exit 0
