#!/usr/bin/env bash
# Sentinel Status — Quick binary PROTECTED / NOT PROTECTED verdict
# Run: sentinel status   (or: bash bin/sentinel-status.sh)
# Flags: --json (machine-readable), --quiet (single-word verdict)
set -euo pipefail

# ── Color support ──────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN="\033[32m"
  RED="\033[31m"
  BOLD="\033[1m"
  RESET="\033[0m"
else
  GREEN="" RED="" BOLD="" RESET=""
fi

# ── Resolve paths ──────────────────────────────────────────────
SENTINEL_HOME="${SENTINEL_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
GATE_CONFIG="$HOME/.claude/state/gate-config.json"
SETTINGS_JSON="$HOME/.claude/settings.json"

# ── Parse flags ────────────────────────────────────────────────
OUTPUT_MODE="human"
for arg in "$@"; do
  case "$arg" in
    --json)  OUTPUT_MODE="json" ;;
    --quiet) OUTPUT_MODE="quiet" ;;
  esac
done

# ── Check functions ────────────────────────────────────────────
# Each check sets: check_<name>=true/false, fail_<name>="reason", fix_<name>="command"

check_config_exists=false
fail_config_exists=""
fix_config_exists=""

check_enforce_mode=false
fail_enforce_mode=""
fix_enforce_mode=""

check_config_locked=false
fail_config_locked=""
fix_config_locked=""

check_hooks_installed=false
fail_hooks_installed=""
fix_hooks_installed=""

# Check 1: Config exists
if [[ -f "$GATE_CONFIG" ]]; then
  check_config_exists=true
else
  fail_config_exists="gate-config.json not found at $GATE_CONFIG"
  fix_config_exists="Run: sentinel doctor (follow remediation steps)"
fi

# Check 2: Enforce mode
if [[ "$check_config_exists" == "true" ]]; then
  MODE=$(grep -o '"mode"[[:space:]]*:[[:space:]]*"[^"]*"' "$GATE_CONFIG" 2>/dev/null | head -1 | grep -o '"[^"]*"$' | tr -d '"' || echo "unknown")
  if [[ "$MODE" == "enforce" ]]; then
    check_enforce_mode=true
  else
    fail_enforce_mode="mode is \"$MODE\" (must be \"enforce\")"
    fix_enforce_mode="Run: sentinel doctor (follow remediation steps)"
  fi
else
  fail_enforce_mode="cannot check mode (config missing)"
  fix_enforce_mode="Run: sentinel doctor (follow remediation steps)"
fi

# Check 3: Config locked (no write bits)
if [[ "$check_config_exists" == "true" ]]; then
  PERMS=$(stat -c '%a' "$GATE_CONFIG" 2>/dev/null || stat -f '%Lp' "$GATE_CONFIG" 2>/dev/null || echo "000")
  # Check if any write bit is set (owner, group, other)
  if [[ $((8#$PERMS & 8#222)) -eq 0 ]]; then
    check_config_locked=true
  else
    fail_config_locked="config has write permissions ($PERMS), should be read-only (444)"
    fix_config_locked="Run: chmod 444 $GATE_CONFIG"
  fi
else
  fail_config_locked="cannot check permissions (config missing)"
  fix_config_locked="Run: sentinel doctor (follow remediation steps)"
fi

# Check 4: Hooks installed in settings.json
if [[ -f "$SETTINGS_JSON" ]]; then
  if grep -q "behavioral/" "$SETTINGS_JSON" 2>/dev/null; then
    check_hooks_installed=true
  else
    fail_hooks_installed="no Sentinel hooks found in settings.json"
    fix_hooks_installed="Run: sentinel merge"
  fi
else
  fail_hooks_installed="settings.json not found at $SETTINGS_JSON"
  fix_hooks_installed="Run: sentinel merge"
fi

# ── Determine verdict ─────────────────────────────────────────
PROTECTED=true
if [[ "$check_config_exists" != "true" ]] || \
   [[ "$check_enforce_mode" != "true" ]] || \
   [[ "$check_config_locked" != "true" ]] || \
   [[ "$check_hooks_installed" != "true" ]]; then
  PROTECTED=false
fi

# ── Output: JSON ───────────────────────────────────────────────
if [[ "$OUTPUT_MODE" == "json" ]]; then
  cat <<ENDJSON
{
  "protected": $PROTECTED,
  "checks": {
    "config_exists": $check_config_exists,
    "enforce_mode": $check_enforce_mode,
    "config_locked": $check_config_locked,
    "hooks_installed": $check_hooks_installed
  }
}
ENDJSON
  if [[ "$PROTECTED" == "true" ]]; then exit 0; else exit 1; fi
fi

# ── Output: Quiet ──────────────────────────────────────────────
if [[ "$OUTPUT_MODE" == "quiet" ]]; then
  if [[ "$PROTECTED" == "true" ]]; then
    echo "PROTECTED"
    exit 0
  else
    echo "NOT PROTECTED"
    exit 1
  fi
fi

# ── Output: Human-readable ─────────────────────────────────────
echo ""
if [[ "$PROTECTED" == "true" ]]; then
  # Get display values
  PERMS_DISPLAY=$(stat -c '%a' "$GATE_CONFIG" 2>/dev/null || stat -f '%Lp' "$GATE_CONFIG" 2>/dev/null || echo "locked")
  printf "${BOLD}${GREEN}PROTECTED${RESET}\n"
  echo ""
  printf "  Mode:    enforce\n"
  printf "  Config:  locked (%s)\n" "$PERMS_DISPLAY"
  printf "  Hooks:   installed in settings.json\n"
  echo ""
  echo "Sentinel is actively enforcing behavioral gates."
  echo ""
  exit 0
else
  printf "${BOLD}${RED}NOT PROTECTED${RESET}\n"
  echo ""

  # Show each failure
  if [[ "$check_config_exists" != "true" ]]; then
    printf "  Config:       ${RED}missing${RESET} (%s)\n" "$fail_config_exists"
  fi
  if [[ "$check_enforce_mode" != "true" ]]; then
    printf "  Config mode:  ${RED}%s${RESET}\n" "$fail_enforce_mode"
  fi
  if [[ "$check_config_locked" != "true" ]] && [[ "$check_config_exists" == "true" ]]; then
    printf "  Config lock:  ${RED}%s${RESET}\n" "$fail_config_locked"
  fi
  if [[ "$check_hooks_installed" != "true" ]]; then
    printf "  Hooks:        ${RED}%s${RESET}\n" "$fail_hooks_installed"
  fi

  # Numbered fix steps
  echo ""
  echo "To fix:"
  FIX_NUM=1
  if [[ "$check_config_exists" != "true" ]]; then
    printf "  %d. %s\n" "$FIX_NUM" "$fix_config_exists"
    FIX_NUM=$((FIX_NUM + 1))
  fi
  if [[ "$check_enforce_mode" != "true" ]] && [[ "$check_config_exists" == "true" ]]; then
    printf "  %d. %s\n" "$FIX_NUM" "$fix_enforce_mode"
    FIX_NUM=$((FIX_NUM + 1))
  fi
  if [[ "$check_config_locked" != "true" ]] && [[ "$check_config_exists" == "true" ]]; then
    printf "  %d. %s\n" "$FIX_NUM" "$fix_config_locked"
    FIX_NUM=$((FIX_NUM + 1))
  fi
  if [[ "$check_hooks_installed" != "true" ]]; then
    printf "  %d. %s\n" "$FIX_NUM" "$fix_hooks_installed"
    FIX_NUM=$((FIX_NUM + 1))
  fi
  echo ""
  exit 1
fi
