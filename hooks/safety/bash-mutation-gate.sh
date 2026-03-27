#!/usr/bin/env bash
# Bash Mutation Gate — blocks file writes via Bash (cat >, tee, sed -i, cp, mv, etc.)
# unless behavioral gate state is VERIFIED.
#
# WHY THIS EXISTS:
# Claude bypassed the Write/Edit behavioral gate by using
# 'cat > file << HEREDOC' via Bash. The gate only covered Write/Edit tools,
# leaving Bash as a wide-open loophole for filesystem mutations.
# Codex ruling: "All mutation channels must be gated."
#
# IMMUTABLE: chown root:root + chattr +i after creation. Claude cannot modify.
set -euo pipefail

SESSION_ID="${CLAUDE_SESSION_ID:-unknown}"
STATE_FILE="/tmp/sentinel-gate-${SESSION_ID}.json"
CONFIG_FILE="${SENTINEL_HOME:-$HOME/.claude}/state/gate-config.json"
METRICS_FILE="${SENTINEL_HOME:-$HOME/.claude}/state/behavioral_metrics.json"

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null) || TOOL=""

# Only gate Bash tool
[ "$TOOL" = "Bash" ] || exit 0

COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null) || COMMAND=""
[ -n "$COMMAND" ] || exit 0

# === DETECT FILE MUTATION PATTERNS ===
# Redirects: > >> 2> &>
# Heredocs: cat > file << (or <<')
# Explicit writers: tee, sed -i, perl -pi, awk -i
# File ops targeting project paths: cp, mv into $HOME/ (excluding /tmp/)
# Script writers: python -c "open(...,'w')", node -e "fs.write"

MUTATION=0

# Pattern 1: Shell redirects writing to $HOME/ paths
if echo "$COMMAND" | grep -qE '>\s*$HOME/'; then
  MUTATION=1
fi

# Pattern 2: Heredoc to file
if echo "$COMMAND" | grep -qE 'cat\s.*>\s*$HOME/'; then
  MUTATION=1
fi

# Pattern 3: tee writing to $HOME/
if echo "$COMMAND" | grep -qE 'tee\s+(-a\s+)?$HOME/'; then
  MUTATION=1
fi

# Pattern 4: sed -i / perl -pi on $HOME/
if echo "$COMMAND" | grep -qE '(sed\s+-i|perl\s+-[p]?i).*($HOME/)'; then
  MUTATION=1
fi

# Pattern 5: cp/mv INTO $HOME/ (but not from /tmp/ scratch)
if echo "$COMMAND" | grep -qE '(cp|mv)\s+.*\s+$HOME/' | grep -qvE '/tmp/'; then
  MUTATION=1
fi

# Pattern 6: python/node inline file writes to $HOME/
if echo "$COMMAND" | grep -qE "(python3?\s+-c|node\s+-e).*($HOME/)"; then
  if echo "$COMMAND" | grep -qEi "(open\(|write|writeFile|fs\.)"; then
    MUTATION=1
  fi
fi

# Not a mutation — allow
[ "$MUTATION" -eq 1 ] || exit 0

# === ALLOW LIST — paths that don't need gate verification ===
# /tmp/, state files, memory files can be written freely
SAFE_PATTERNS="/tmp/|$HOME/.claude/state/|$HOME/.claude/projects/.*/memory/|$HOME/.engram/"
if echo "$COMMAND" | grep -qE ">\s*(${SAFE_PATTERNS})"; then
  exit 0
fi
# cp/mv to safe paths
if echo "$COMMAND" | grep -qE "(cp|mv)\s+.*\s+(${SAFE_PATTERNS})"; then
  exit 0
fi

# === CHECK GATE STATE ===
# No state file = no active gate session — allow (automated/GSD)
if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

# Read gate mode
MODE="warn"
if [ -f "$CONFIG_FILE" ]; then
  MODE=$(jq -r '.mode // "warn"' "$CONFIG_FILE" 2>/dev/null) || MODE="warn"
fi

STATE=$(jq -r '.state // "IDLE"' "$STATE_FILE" 2>/dev/null) || STATE="IDLE"

# IDLE or VERIFIED — allow
if [ "$STATE" = "IDLE" ] || [ "$STATE" = "VERIFIED" ]; then
  # Track allowed mutation
  if [ -f "$METRICS_FILE" ]; then
    TMP=$(mktemp)
    jq --arg cmd "$COMMAND" --argjson now "$(date +%s)" \
      '.bash_mutation_allowed = ((.bash_mutation_allowed // 0) + 1) | .history = ([{"at": $now, "tool": "Bash", "action": "bash_mutation_allowed", "cmd": ($cmd[:100])}] + .history[:49])' \
      "$METRICS_FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$METRICS_FILE" || rm -f "$TMP"
  fi
  exit 0
fi

# === BLOCKED — AWAIT_VERIFY state, mutation attempt ===
if [ -f "$METRICS_FILE" ]; then
  TMP=$(mktemp)
  jq --arg cmd "$COMMAND" --argjson now "$(date +%s)" \
    '.bash_mutation_blocked = ((.bash_mutation_blocked // 0) + 1) | .history = ([{"at": $now, "tool": "Bash", "action": "bash_mutation_blocked", "cmd": ($cmd[:100])}] + .history[:49])' \
    "$METRICS_FILE" > "$TMP" 2>/dev/null && mv "$TMP" "$METRICS_FILE" || rm -f "$TMP"
fi

if [ "$MODE" = "enforce" ]; then
  echo "BLOCKED by Bash Mutation Gate: File write via Bash detected without gate verification." >&2
  echo "" >&2
  echo "You attempted to write to $HOME/ via Bash instead of using Write/Edit tools." >&2
  echo "This is NOT a workaround — the gate covers ALL mutation channels." >&2
  echo "" >&2
  echo "Do this instead:" >&2
  echo "  1. Read the target files (Read tool)" >&2
  echo "  2. Run: gate-verify --files \"...\" --scope \"...\"" >&2
  echo "  3. Use Write/Edit tools (not Bash redirects)" >&2
  echo "" >&2
  echo "Attempted: ${COMMAND:0:150}" >&2
  echo "" >&2
  echo "This gate exists because you used 'cat > file << HEREDOC' to bypass" >&2
  echo "the Write tool gate via Bash heredoc. Codex ruling: all mutation channels gated." >&2
  exit 2
else
  exit 0
fi
