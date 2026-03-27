#!/usr/bin/env bash
# PostCompact reinject hook — recovers checkpoint context after compaction
# Reads stdin JSON with session_id, source
# Outputs recovered context to stdout for Claude to consume
# Always exits 0
set -euo pipefail

# Read stdin JSON
INPUT="$(cat 2>/dev/null)" || INPUT="{}"

SESSION_ID="$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)" || true

if [[ -z "$SESSION_ID" ]]; then
  exit 0
fi

CHECKPOINT_FILE="/tmp/claude-compact-checkpoint-${SESSION_ID}.json"

# If no checkpoint exists, exit silently
if [[ ! -f "$CHECKPOINT_FILE" ]]; then
  exit 0
fi

# Read checkpoint
CHECKPOINT="$(cat "$CHECKPOINT_FILE" 2>/dev/null)" || exit 0

# Validate it's real JSON
echo "$CHECKPOINT" | jq empty 2>/dev/null || exit 0

# Extract fields
FILES="$(echo "$CHECKPOINT" | jq -r '.files_changed // [] | join(", ")' 2>/dev/null)" || FILES=""
DECISIONS="$(echo "$CHECKPOINT" | jq -r '.decisions // [] | join("; ")' 2>/dev/null)" || DECISIONS=""
LAST_TASK="$(echo "$CHECKPOINT" | jq -r '.last_task // empty' 2>/dev/null)" || LAST_TASK=""
TS="$(echo "$CHECKPOINT" | jq -r '.timestamp // empty' 2>/dev/null)" || TS=""

# Format timestamp
if [[ -n "$TS" ]]; then
  TS_HUMAN="$(date -d "@$TS" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" || TS_HUMAN="$TS"
else
  TS_HUMAN="unknown"
fi

# Only output if we have something useful
if [[ -z "$FILES" && -z "$DECISIONS" && -z "$LAST_TASK" ]]; then
  exit 0
fi

# Output recovered context
cat <<CONTEXT

─── RECOVERED CONTEXT (from before compaction at ${TS_HUMAN}) ───
CONTEXT

if [[ -n "$FILES" ]]; then
  echo "Files changed this session: ${FILES}"
fi

if [[ -n "$DECISIONS" ]]; then
  echo "Key decisions: ${DECISIONS}"
fi

if [[ -n "$LAST_TASK" ]]; then
  echo "Last task: ${LAST_TASK}"
fi

cat <<CONTEXT
─── Continue from where you left off ───

CONTEXT

exit 0
