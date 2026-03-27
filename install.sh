#!/usr/bin/env bash
# Sentinel Installer
# Installs hooks, rules, and state config into your Claude Code setup.
# Default: enforce mode (locked). Use --warn for warn mode (no enforcement).
set -euo pipefail

SENTINEL_HOME="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${HOME}/.claude"

# --- Flag parsing ---
MODE="enforce"
FORCE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --warn) MODE="warn"; shift ;;
    --force) FORCE=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

echo "━━━ Sentinel Installer ━━━━━━━━━━━━━━━━━━━━━"
echo "Source: ${SENTINEL_HOME}"
echo "Target: ${CLAUDE_DIR}"
echo ""

# Create directories
mkdir -p "${CLAUDE_DIR}/state"
mkdir -p "${CLAUDE_DIR}/rules"

# Copy rules
echo "Installing rules..."
cp "${SENTINEL_HOME}/rules/"*.md "${CLAUDE_DIR}/rules/" 2>/dev/null && echo "  Rules copied" || echo "  No rules found"

# --- Config installation ---
CONFIG_PATH="${CLAUDE_DIR}/state/gate-config.json"

if [ ! -f "$CONFIG_PATH" ]; then
  # Fresh install: write config with selected mode
  cat > "$CONFIG_PATH" <<EOJSON
{"mode": "${MODE}", "created_at": "$(date +%Y-%m-%d)", "min_read_coverage": 80}
EOJSON
  chmod 444 "$CONFIG_PATH"
  echo "  Config installed (${MODE} mode, locked)"
elif [ "$FORCE" = true ]; then
  # Force overwrite: unlock, write, re-lock
  chmod 644 "$CONFIG_PATH" 2>/dev/null || true
  cat > "$CONFIG_PATH" <<EOJSON
{"mode": "${MODE}", "created_at": "$(date +%Y-%m-%d)", "min_read_coverage": 80}
EOJSON
  chmod 444 "$CONFIG_PATH"
  echo "  Config overwritten (${MODE} mode, locked)"
else
  echo "  Config exists at ${CONFIG_PATH}. Use --force to overwrite."
fi

# Make hooks executable
chmod +x "${SENTINEL_HOME}"/hooks/behavioral/*.sh 2>/dev/null || true
chmod +x "${SENTINEL_HOME}"/hooks/memory/*.sh 2>/dev/null || true
chmod +x "${SENTINEL_HOME}"/hooks/safety/*.sh 2>/dev/null || true

echo ""

# --- Mode banner ---
if [ "$MODE" = "enforce" ]; then
  echo "  Mode: ENFORCE (default) -- config locked at ${CONFIG_PATH}"
else
  echo "  Mode: WARN (opt-in) -- WARNING: warn mode provides NO enforcement. See docs/ENFORCE-MODE.md"
fi

echo ""
echo "━━━ Complete Setup ━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "1. Add hooks to Claude Code:"
echo "   ./bin/sentinel merge"
echo ""
echo "2. Set SENTINEL_HOME in your shell profile:"
echo "   export SENTINEL_HOME=\"${SENTINEL_HOME}\""
echo ""
echo "3. Verify installation:"
echo "   sentinel doctor"
echo ""
echo "Hooks activate on your next Claude Code session."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
