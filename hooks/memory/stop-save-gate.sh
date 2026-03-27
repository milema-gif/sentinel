#!/usr/bin/env bash
# Sentinel — Stop hook that blocks session end without memory saves
# Fail-silent: any error -> allow stop (exit 0, no output)

METRICS_FILE="${SENTINEL_HOME:-$HOME/.claude}/state/memory_metrics.json"

# --- Helpers ---

update_metrics() {
  local field="$1"
  local ts_field="${2:-}"

  # Ensure metrics file exists
  if [ ! -f "$METRICS_FILE" ]; then
    mkdir -p "$(dirname "$METRICS_FILE")"
    cat > "$METRICS_FILE" <<'INIT'
{
  "stop_blocks": 0,
  "stop_allows": 0,
  "sessions_with_saves": 0,
  "sessions_without_saves": 0,
  "last_blocked_at": null,
  "last_save_check": null
}
INIT
  fi

  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [ -n "$ts_field" ]; then
    jq --arg f "$field" --arg tf "$ts_field" --arg now "$now" \
      '.[$f] += 1 | .[$tf] = $now | .last_save_check = $now' \
      "$METRICS_FILE" > "${METRICS_FILE}.tmp" && mv "${METRICS_FILE}.tmp" "$METRICS_FILE"
  else
    jq --arg f "$field" --arg now "$now" \
      '.[$f] += 1 | .last_save_check = $now' \
      "$METRICS_FILE" > "${METRICS_FILE}.tmp" && mv "${METRICS_FILE}.tmp" "$METRICS_FILE"
  fi
}

allow_stop() {
  update_metrics "${1:-stop_allows}" "${2:-}" 2>/dev/null || true
  exit 0
}

block_stop() {
  update_metrics "stop_blocks" "last_blocked_at" 2>/dev/null || true
  cat <<'EOF'
{
  "decision": "block",
  "reason": "Session has significant work but no memory saves. Before finishing:\n1. Call mem_save for key decisions/discoveries\n2. Call mem_session_summary with Goal/Accomplished/Next Steps\nThen you can finish."
}
EOF
  exit 0
}

# --- Main ---

# Read stdin JSON (with timeout)
INPUT="$(timeout 3 cat 2>/dev/null)" || allow_stop

# If empty input, allow
[ -z "$INPUT" ] && allow_stop

# Check stop_hook_active — prevent infinite loop
HOOK_ACTIVE="$(echo "$INPUT" | jq -r '.stop_hook_active // "false"' 2>/dev/null)" || allow_stop
[ "$HOOK_ACTIVE" = "true" ] && exit 0

# Get transcript path
TRANSCRIPT="$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)" || allow_stop

# If no transcript or file doesn't exist or is empty, allow
[ -z "$TRANSCRIPT" ] && allow_stop
[ ! -f "$TRANSCRIPT" ] && allow_stop
[ ! -s "$TRANSCRIPT" ] && allow_stop

# Count work actions: assistant lines with tool_use of Edit, Write, Bash, Agent
WORK_ACTIONS=$(grep -c '"role":"assistant"' "$TRANSCRIPT" 2>/dev/null | head -1) || WORK_ACTIONS=0

# More precise: count lines that have both assistant role and tool-use patterns
if [ "$WORK_ACTIONS" -gt 0 ]; then
  WORK_ACTIONS=$(grep '"role":"assistant"' "$TRANSCRIPT" 2>/dev/null \
    | grep -cE '(Edit|Write|Bash|Agent|tool_use)' 2>/dev/null) || WORK_ACTIONS=0
fi

# Trivial session — allow
if [ "$WORK_ACTIONS" -lt 3 ]; then
  allow_stop
fi

# Check for memory saves in transcript (MCP-prefixed or plain names)
HAS_SAVES=false
if grep -qE '(mem_save|mem_session_summary)' "$TRANSCRIPT" 2>/dev/null; then
  HAS_SAVES=true
fi

if [ "$HAS_SAVES" = true ]; then
  allow_stop "sessions_with_saves"
else
  update_metrics "sessions_without_saves" 2>/dev/null || true
  block_stop
fi
