#!/usr/bin/env bash
# Sentinel — PreCompact checkpoint hook
# Saves critical context before compaction destroys it.
# Reads stdin JSON with transcript_path, session_id, cwd
# Always exits 0 (never blocks compaction)
set -euo pipefail

# Read stdin JSON
INPUT="$(cat 2>/dev/null)" || INPUT="{}"

TRANSCRIPT_PATH="$(echo "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)" || true
SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)" || true
CWD="$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)" || true

# Bail if we don't have minimum required fields
if [[ -z "$TRANSCRIPT_PATH" || -z "$SESSION_ID" ]]; then
  exit 0
fi

# Default CWD
CWD="${CWD:-$HOME}"

CHECKPOINT_FILE="/tmp/claude-compact-checkpoint-${SESSION_ID}.json"

# Read last 100 lines of transcript JSONL
if [[ ! -f "$TRANSCRIPT_PATH" ]]; then
  exit 0
fi

TAIL_LINES="$(tail -n 100 "$TRANSCRIPT_PATH" 2>/dev/null)" || exit 0

# Extract files changed from Edit/Write tool calls
FILES_CHANGED="$(echo "$TAIL_LINES" | jq -r '
  select(.type == "tool_use" or .type == "tool_call") |
  select(.name == "Edit" or .name == "Write" or
         .tool == "Edit" or .tool == "Write") |
  (.input // .parameters // {}) |
  (.file_path // .path // empty)
' 2>/dev/null | sort -u | head -20)" || FILES_CHANGED=""

# Also try nested content array format
if [[ -z "$FILES_CHANGED" ]]; then
  FILES_CHANGED="$(echo "$TAIL_LINES" | jq -r '
    .content[]? // empty |
    select(.type == "tool_use") |
    select(.name == "Edit" or .name == "Write") |
    .input.file_path // empty
  ' 2>/dev/null | sort -u | head -20)" || FILES_CHANGED=""
fi

# Extract significant bash commands (git commit, npm test, etc.)
BASH_CMDS="$(echo "$TAIL_LINES" | jq -r '
  select(.type == "tool_use" or .type == "tool_call") |
  select(.name == "Bash" or .tool == "Bash") |
  (.input // .parameters // {}) |
  (.command // empty)
' 2>/dev/null | grep -iE '(git commit|git push|npm test|npm run|docker|systemctl|make |cargo |pytest)' | tail -5)" || BASH_CMDS=""

# Extract decision-like phrases from assistant messages
DECISION_PATTERN='decided|chose|going with|architecture|approach|strategy|because|trade-off|tradeoff|instead of|opted for|settled on'
DECISIONS="$(echo "$TAIL_LINES" | jq -r '
  select(.role == "assistant" and .type == "text") |
  .text // .content // empty
' 2>/dev/null | grep -oiE ".{0,80}(${DECISION_PATTERN}).{0,80}" | head -5 | sed 's/^[[:space:]]*//' | head -c 500)" || DECISIONS=""

# Also try nested content format
if [[ -z "$DECISIONS" ]]; then
  DECISIONS="$(echo "$TAIL_LINES" | jq -r '
    select(.role == "assistant") |
    .content[]? // empty |
    select(.type == "text") |
    .text // empty
  ' 2>/dev/null | grep -oiE ".{0,80}(${DECISION_PATTERN}).{0,80}" | head -5 | sed 's/^[[:space:]]*//' | head -c 500)" || DECISIONS=""
fi

# Extract last significant assistant message snippet
LAST_TASK="$(echo "$TAIL_LINES" | jq -r '
  select(.role == "assistant") |
  (.text // .content // empty) | if type == "array" then
    [.[] | select(.type == "text") | .text] | join(" ")
  elif type == "string" then . else empty end
' 2>/dev/null | tail -1 | head -c 200)" || LAST_TASK=""

# Build JSON arrays
FILES_JSON="$(echo "$FILES_CHANGED" | jq -R 'select(length > 0)' 2>/dev/null | jq -s '.' 2>/dev/null)" || FILES_JSON="[]"
DECISIONS_JSON="$(echo "$DECISIONS" | jq -R 'select(length > 0)' 2>/dev/null | jq -s '.' 2>/dev/null)" || DECISIONS_JSON="[]"
LAST_TASK_CLEAN="$(echo "$LAST_TASK" | head -c 200 | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g')"

TIMESTAMP="$(date +%s)"

# Write checkpoint file
jq -n \
  --arg sid "$SESSION_ID" \
  --argjson ts "$TIMESTAMP" \
  --argjson files "$FILES_JSON" \
  --argjson decisions "$DECISIONS_JSON" \
  --arg last_task "$LAST_TASK_CLEAN" \
  '{
    session_id: $sid,
    timestamp: $ts,
    files_changed: $files,
    decisions: $decisions,
    last_task: $last_task
  }' > "$CHECKPOINT_FILE" 2>/dev/null || true

exit 0
