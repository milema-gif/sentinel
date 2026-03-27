#!/usr/bin/env bash
# Sentinel — Read Tracker (PostToolUse hook)
# Tracks which files have been read and calculates coverage percentage.
# Used by the gate to verify the agent read before editing.
# Install: PostToolUse hook matching "Read"
set -euo pipefail

SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
STATE_FILE="/tmp/sentinel-gate-${SESSION_ID}.json"

[ -f "$STATE_FILE" ] || exit 0

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || exit 0
[ "$TOOL" = "Read" ] || exit 0

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null) || FILE_PATH=""
[ -n "$FILE_PATH" ] || exit 0

LIMIT=$(echo "$INPUT" | jq -r '.tool_input.limit // 0' 2>/dev/null) || LIMIT=0
OFFSET=$(echo "$INPUT" | jq -r '.tool_input.offset // 0' 2>/dev/null) || OFFSET=0

TOTAL_LINES=0
if [ -f "$FILE_PATH" ]; then
  TOTAL_LINES=$(wc -l < "$FILE_PATH" 2>/dev/null) || TOTAL_LINES=0
fi

if [ "$LIMIT" -eq 0 ] && [ "$OFFSET" -eq 0 ]; then
  LINES_READ=$TOTAL_LINES
  [ "$LINES_READ" -gt 2000 ] && LINES_READ=2000
elif [ "$LIMIT" -gt 0 ]; then
  LINES_READ=$LIMIT
else
  LINES_READ=$((TOTAL_LINES - OFFSET))
  [ "$LINES_READ" -gt 2000 ] && LINES_READ=2000
fi

COVERAGE=0
if [ "$TOTAL_LINES" -gt 0 ]; then
  COVERAGE=$(( (LINES_READ * 100) / TOTAL_LINES ))
  [ "$COVERAGE" -gt 100 ] && COVERAGE=100
fi

TMP=$(mktemp)
jq --arg fp "$FILE_PATH" \
   --argjson lr "$LINES_READ" \
   --argjson tl "$TOTAL_LINES" \
   --argjson cov "$COVERAGE" \
   --argjson now "$(date +%s)" \
   '
   if (.reads_this_cycle | map(select(.file == $fp)) | length > 0) then
     .reads_this_cycle = [.reads_this_cycle[] |
       if .file == $fp then
         .lines_read = (.lines_read + $lr) |
         .coverage = (if ((.lines_read * 100) / (if $tl > 0 then $tl else 1 end)) > 100 then 100
                      else ((.lines_read * 100) / (if $tl > 0 then $tl else 1 end)) end) |
         .at = $now
       else . end]
   else
     .reads_this_cycle += [{"file": $fp, "lines_read": $lr, "total_lines": $tl, "coverage": $cov, "at": $now}]
   end
   ' "$STATE_FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$STATE_FILE" || rm -f "$TMP"

exit 0
