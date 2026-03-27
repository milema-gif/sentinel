#!/usr/bin/env bash
# Sentinel — Behavioral Gate (PreToolUse hook)
# Blocks Edit/Write calls unless the agent has verified by reading target files first.
# Install: PreToolUse hook matching "Write|Edit"
set -euo pipefail

SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
STATE_FILE="/tmp/sentinel-gate-${SESSION_ID}.json"
CONFIG_FILE="${SENTINEL_HOME:-$HOME/.claude}/state/gate-config.json"
METRICS_FILE="${SENTINEL_HOME:-$HOME/.claude}/state/behavioral_metrics.json"

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || TOOL=""
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || FILE_PATH=""

# No state file = no active gate cycle — allow
if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

# Read gate mode (warn or enforce)
MODE="warn"
if [ -f "$CONFIG_FILE" ]; then
  MODE=$(jq -r '.mode // "warn"' "$CONFIG_FILE" 2>/dev/null) || MODE="warn"
fi

STATE=$(jq -r '.state // "IDLE"' "$STATE_FILE" 2>/dev/null) || STATE="IDLE"

# IDLE or VERIFIED = allow
if [ "$STATE" = "IDLE" ] || [ "$STATE" = "VERIFIED" ]; then
  if [ "$STATE" = "VERIFIED" ] && [ -f "$METRICS_FILE" ]; then
    TMP=$(mktemp)
    jq --arg fp "$FILE_PATH" --arg tool "$TOOL" --argjson now "$(date +%s)" \
      '.allowed = (.allowed + 1) | .history = ([{"at": $now, "tool": $tool, "file": $fp, "action": "allowed"}] + .history[:49])' \
      "$METRICS_FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$METRICS_FILE" || rm -f "$TMP"
  fi
  exit 0
fi

# AWAIT_VERIFY — block condition
# Allow edits to non-project files (state, config, tmp)
case "$FILE_PATH" in
  */state/*|*/memory/*|/tmp/*) exit 0 ;;
esac

# Track block/warn
if [ -f "$METRICS_FILE" ]; then
  ACTION="blocked"
  [ "$MODE" = "warn" ] && ACTION="warned"
  TMP=$(mktemp)
  jq --arg fp "$FILE_PATH" --arg tool "$TOOL" --argjson now "$(date +%s)" --arg action "$ACTION" \
    '.[$action] = (.[$action] + 1) | .history = ([{"at": $now, "tool": $tool, "file": $fp, "action": $action}] + .history[:49])' \
    "$METRICS_FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$METRICS_FILE" || rm -f "$TMP"
fi

if [ "$MODE" = "enforce" ]; then
  echo "BLOCKED by Sentinel: You must verify before editing." >&2
  echo "1. Read the target files first" >&2
  echo "2. Run: gate-verify --files \"file1,file2\" --scope \"what you're changing\"" >&2
  echo "Attempted: ${TOOL} on ${FILE_PATH}" >&2
  exit 2
else
  exit 0
fi
