#!/usr/bin/env bash
# Infrastructure Gate — blocks Bash infra commands unless INFRASTRUCTURE.md was read this session
# Non-immutable: chown root + chattr +i after creation
set -euo pipefail

SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
STATE_FILE="/tmp/sentinel-gate-${SESSION_ID}.json"
INFRA_DOC="${HOME}/INFRASTRUCTURE.md"
METRICS_FILE="${SENTINEL_HOME:-$HOME/.claude}/state/behavioral_metrics.json"

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || TOOL=""

# Only gate Bash tool
[ "$TOOL" = "Bash" ] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null) || COMMAND=""
[ -n "$COMMAND" ] || exit 0

# Stage A: Does command contain infra verbs?
INFRA_PATTERN='\b(ssh|scp|rsync|sudo|systemctl|service|journalctl|tailscale|ufw|iptables|nft|mount|umount)\b'
if ! echo "$COMMAND" | grep -qEi "$INFRA_PATTERN"; then
  exit 0
fi

# Stage B: Is it targeting a remote host or privileged op?
# Allow purely local commands (e.g. "systemctl status docker" on this machine)
REMOTE_PATTERN='(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|\.local\b|\.lab\b|@)'
if ! echo "$COMMAND" | grep -qEi "$REMOTE_PATTERN"; then
  exit 0
fi

# This is a remote infra command — check if INFRASTRUCTURE.md was read this session
INFRA_READ=0
if [ -f "$STATE_FILE" ]; then
  # Check reads in current cycle
  INFRA_READ=$(jq --arg doc "$INFRA_DOC" \
    '[.reads_this_cycle[]? | select(.file == $doc)] | length' \
    "$STATE_FILE" 2>/dev/null) || INFRA_READ=0

  # Check persistent flag (survives prompt resets)
  if [ "$INFRA_READ" -eq 0 ]; then
    INFRA_READ=$(jq \
      'if .infra_doc_read == true then 1 else 0 end' \
      "$STATE_FILE" 2>/dev/null) || INFRA_READ=0
  fi
fi

if [ "$INFRA_READ" -gt 0 ]; then
  # Track allowed infra command
  if [ -f "$METRICS_FILE" ]; then
    TMP=$(mktemp)
    jq --arg cmd "$COMMAND" --argjson now "$(date +%s)" \
      '.infra_allowed = ((.infra_allowed // 0) + 1) | .history = ([{"at": $now, "tool": "Bash", "action": "infra_allowed", "cmd": ($cmd[:80])}] + .history[:49])' \
      "$METRICS_FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$METRICS_FILE" || rm -f "$TMP"
  fi
  exit 0
fi

# BLOCKED — infra command without reading INFRASTRUCTURE.md
if [ -f "$METRICS_FILE" ]; then
  TMP=$(mktemp)
  jq --arg cmd "$COMMAND" --argjson now "$(date +%s)" \
    '.infra_blocked = ((.infra_blocked // 0) + 1) | .history = ([{"at": $now, "tool": "Bash", "action": "infra_blocked", "cmd": ($cmd[:80])}] + .history[:49])' \
    "$METRICS_FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$METRICS_FILE" || rm -f "$TMP"
fi

echo "BLOCKED by Infrastructure Gate: You must read ${HOME}/INFRASTRUCTURE.md before running remote infra commands." >&2
echo "" >&2
echo "Do this first:" >&2
echo "  1. Read ${HOME}/INFRASTRUCTURE.md (use the Read tool)" >&2
echo "  2. Find the correct host, user, and credentials FROM THE DOC" >&2
echo "  3. Then retry your command" >&2
echo "" >&2
echo "Attempted: ${COMMAND:0:120}" >&2
echo "" >&2
echo "This gate exists because the pre-action gate was ignored for infra tasks." >&2
echo "and guessed passwords from memory instead of reading the doc." >&2
exit 2
