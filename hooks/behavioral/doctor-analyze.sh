#!/usr/bin/env bash
# Sentinel Doctor — Installation validator with binary verdict
# Run: sentinel doctor   (or: bash hooks/behavioral/doctor-analyze.sh)
# Trends: sentinel doctor --trends
set -euo pipefail

# ── Color support ──────────────────────────────────────────────
if [ -t 1 ]; then
  GREEN="\033[32m"
  RED="\033[31m"
  YELLOW="\033[33m"
  BOLD="\033[1m"
  RESET="\033[0m"
else
  GREEN="" RED="" YELLOW="" BOLD="" RESET=""
fi

FAILS=0
WARNS=0
PASSES=0
TOTAL_CHECKS=9

pass() {
  printf "${GREEN}[PASS]${RESET} %s\n" "$1"
  PASSES=$((PASSES + 1))
}

fail() {
  printf "${RED}[FAIL]${RESET} %s\n" "$1"
  printf "  Fix: %s\n" "$2"
  FAILS=$((FAILS + 1))
}

warn() {
  printf "${YELLOW}[WARN]${RESET} %s\n" "$1"
  printf "  Fix: %s\n" "$2"
  WARNS=$((WARNS + 1))
}

# ── Trend analysis (legacy) ───────────────────────────────────
run_trends() {
  local HISTORY="${SENTINEL_HOME:-$HOME/.claude}/state/doctor_history.json"
  local GATE_CONFIG="${SENTINEL_HOME:-$HOME/.claude}/state/gate-config.json"

  if [[ ! -f "$HISTORY" ]]; then
    echo "No session history found. Run a session first."
    exit 0
  fi

  local session_count
  session_count=$(jq '.sessions | length' "$HISTORY")
  if [[ "$session_count" -eq 0 ]]; then
    echo "No sessions tracked yet."
    exit 0
  fi

  local last5_avg prev5_avg last5_pct
  last5_avg=$(jq '[.sessions[-5:][].block_rate] | if length > 0 then (add / length) else 0 end' "$HISTORY")
  prev5_avg=$(jq '[.sessions[-10:-5][].block_rate] | if length > 0 then (add / length) else 0 end' "$HISTORY")
  last5_pct=$(awk "BEGIN {printf \"%.1f\", ${last5_avg} * 100}")

  local direction="STABLE"
  if awk "BEGIN {exit !(${last5_avg} < ${prev5_avg} - 0.05)}"; then
    direction="IMPROVING"
  elif awk "BEGIN {exit !(${last5_avg} > ${prev5_avg} + 0.05)}"; then
    direction="WORSENING"
  fi

  local trend_arrow="→"
  [[ "$direction" == "IMPROVING" ]] && trend_arrow="↓"
  [[ "$direction" == "WORSENING" ]] && trend_arrow="↑"

  local clean_streak most_common
  clean_streak=$(jq '[.sessions | reverse | to_entries[] | select(.value.block_rate >= 0.10) | .key] | if length > 0 then .[0] else (.sessions | length) end' "$HISTORY" 2>/dev/null || echo 0)
  most_common=$(jq -r '[.sessions[].symptoms[]] | group_by(.) | sort_by(-length) | .[0] | "\(.[0]) (\(length)/'"${session_count}"' sessions)"' "$HISTORY" 2>/dev/null || echo "none")

  cat <<REPORT
━━━ SENTINEL TRENDS ━━━━━━━━━━━━━━━━━━━━━━━━
Sessions tracked: ${session_count}
Last 5 avg block rate: ${last5_pct}%
Trend: ${direction} ${trend_arrow}
Clean streak: ${clean_streak} sessions
Most common symptom: ${most_common}

REPORT

  echo "Auto-Rx:"
  local rx_printed=0

  local high_block_last3 low_block_last5 last5_count
  high_block_last3=$(jq '[.sessions[-3:][].block_rate | select(. > 0.30)] | length' "$HISTORY")
  low_block_last5=$(jq '[.sessions[-5:][].block_rate | select(. < 0.05)] | length' "$HISTORY")
  last5_count=$(jq '[.sessions[-5:][]] | length' "$HISTORY")

  if [[ "$high_block_last3" -ge 3 ]]; then
    echo "  - ESCALATE: block rate > 30% for 3+ sessions"
    if [[ -f "$GATE_CONFIG" ]]; then
      jq '.mode = "enforce"' "$GATE_CONFIG" > "${GATE_CONFIG}.tmp" && mv "${GATE_CONFIG}.tmp" "$GATE_CONFIG"
      echo "    -> AUTO-APPLIED: gate-config.json switched to enforce mode"
    fi
    rx_printed=1
  fi

  if [[ "$low_block_last5" -ge 5 ]] && [[ "$last5_count" -ge 5 ]]; then
    echo "  - STABLE: gate effective, consider relaxing min_read_coverage"
    rx_printed=1
  fi

  if [[ "$clean_streak" -ge 5 ]]; then
    echo "  - EXCELLENT: sustained good behavior (${clean_streak} clean sessions)"
    rx_printed=1
  fi

  if [[ "$rx_printed" -eq 0 ]]; then
    if awk "BEGIN {exit !(${last5_avg} < 0.10)}"; then
      echo "  - Block rate < 10% -> gate is working, stay in current mode"
    else
      echo "  - Block rate ${last5_pct}% -> monitor and review verification habits"
    fi
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  exit 0
}

# ── Dispatch --trends ──────────────────────────────────────────
if [[ "${1:-}" == "--trends" ]]; then
  run_trends
fi

# ── Installation checks ───────────────────────────────────────

echo ""
echo "${BOLD}Sentinel Doctor${RESET}"
echo "==============="
echo ""

# Check 1: SENTINEL_HOME set
check_sentinel_home() {
  if [[ -n "${SENTINEL_HOME:-}" ]] && [[ -d "$SENTINEL_HOME" ]]; then
    pass "SENTINEL_HOME is set ($SENTINEL_HOME)"
  else
    fail "SENTINEL_HOME not set or directory missing" \
         "export SENTINEL_HOME=\"/path/to/sentinel\" in shell profile"
  fi
}

# Check 2: Config exists
check_config_exists() {
  local config="$HOME/.claude/state/gate-config.json"
  if [[ -f "$config" ]]; then
    pass "Config exists ($config)"
  else
    fail "Config file missing ($config)" \
         "Run \$SENTINEL_HOME/install.sh"
  fi
}

# Check 3: Config mode is enforce
check_config_mode() {
  local config="$HOME/.claude/state/gate-config.json"
  if [[ ! -f "$config" ]]; then
    fail "Config mode: cannot check (file missing)" \
         "Run \$SENTINEL_HOME/install.sh"
    return
  fi
  local mode
  mode=$(jq -r '.mode // "unknown"' "$config" 2>/dev/null || echo "parse-error")
  if [[ "$mode" == "enforce" ]]; then
    pass "Config mode: enforce"
  else
    fail "Config mode: $mode (must be enforce)" \
         "echo '{\"mode\":\"enforce\",\"min_read_coverage\":80}' > ~/.claude/state/gate-config.json && chmod 444 ~/.claude/state/gate-config.json"
  fi
}

# Check 4: Config is read-only
check_config_readonly() {
  local config="$HOME/.claude/state/gate-config.json"
  if [[ ! -f "$config" ]]; then
    fail "Config permissions: cannot check (file missing)" \
         "Run \$SENTINEL_HOME/install.sh"
    return
  fi
  local perms
  perms=$(stat -c '%a' "$config" 2>/dev/null || stat -f '%Lp' "$config" 2>/dev/null || echo "unknown")
  # No write bits: 444, 440, 400, 044, 004, etc.
  if [[ "$perms" =~ ^[0-4][0-4][0-4]$ ]] && ! [[ "$perms" =~ [2367] ]]; then
    pass "Config is read-only ($perms)"
  else
    fail "Config is writable ($perms) -- must have no write bits" \
         "chmod 444 ~/.claude/state/gate-config.json"
  fi
}

# Check 5: Hook scripts exist
check_hooks_exist() {
  local hooks=(
    hooks/behavioral/gate-prompt-reset.sh
    hooks/behavioral/gate-metrics-display.sh
    hooks/behavioral/gate-pre-tool.sh
    hooks/behavioral/gate-track-read.sh
    hooks/safety/secret-scan.sh
    hooks/safety/infra-pre-tool.sh
    hooks/safety/bash-mutation-gate.sh
    hooks/memory/precompact-checkpoint.sh
    hooks/memory/stop-save-gate.sh
  )
  local missing=0
  local total=${#hooks[@]}

  for hook in "${hooks[@]}"; do
    if [[ ! -f "${SENTINEL_HOME:-/nonexistent}/$hook" ]]; then
      fail "Hook missing: $hook" \
           "Re-run installer or check SENTINEL_HOME path"
      missing=$((missing + 1))
    fi
  done

  if [[ "$missing" -eq 0 ]]; then
    pass "Hook scripts exist ($total/$total)"
  fi
}

# Check 6: Hook scripts are executable
check_hooks_executable() {
  local hooks=(
    hooks/behavioral/gate-prompt-reset.sh
    hooks/behavioral/gate-metrics-display.sh
    hooks/behavioral/gate-pre-tool.sh
    hooks/behavioral/gate-track-read.sh
    hooks/safety/secret-scan.sh
    hooks/safety/infra-pre-tool.sh
    hooks/safety/bash-mutation-gate.sh
    hooks/memory/precompact-checkpoint.sh
    hooks/memory/stop-save-gate.sh
  )
  local not_exec=0
  local total=${#hooks[@]}

  for hook in "${hooks[@]}"; do
    local path="${SENTINEL_HOME:-/nonexistent}/$hook"
    if [[ -f "$path" ]] && [[ ! -x "$path" ]]; then
      not_exec=$((not_exec + 1))
    fi
  done

  if [[ "$not_exec" -eq 0 ]]; then
    pass "Hook scripts are executable ($total/$total)"
  else
    fail "Hook scripts not executable ($not_exec/$total missing +x)" \
         "chmod +x \$SENTINEL_HOME/hooks/**/*.sh"
  fi
}

# Check 7: Settings.json has hooks (WARN-level)
check_settings_hooks() {
  local settings="$HOME/.claude/settings.json"
  if [[ ! -f "$settings" ]]; then
    warn "Settings.json not found ($settings)" \
         "Add hooks from \$SENTINEL_HOME/examples/settings.json to ~/.claude/settings.json"
    return
  fi
  if grep -q "sentinel\|SENTINEL_HOME" "$settings" 2>/dev/null; then
    pass "Settings.json has Sentinel hooks"
  else
    warn "Settings.json missing Sentinel hooks" \
         "Add hooks from \$SENTINEL_HOME/examples/settings.json to ~/.claude/settings.json"
  fi
}

# Check 8: gate-verify on PATH (WARN-level)
check_gate_verify() {
  if command -v gate-verify &>/dev/null || [[ -f "$HOME/.local/bin/gate-verify" ]]; then
    pass "gate-verify on PATH"
  else
    warn "gate-verify not on PATH" \
         "ln -sf \$HOME/.claude/bin/gate-verify.sh ~/.local/bin/gate-verify"
  fi
}

# Check 9: Rules installed (WARN-level)
check_rules_installed() {
  local sentinel_rules=0
  if [[ -d "$HOME/.claude/rules" ]]; then
    # Check for any .md files that exist in both sentinel/rules/ and ~/.claude/rules/
    if [[ -d "${SENTINEL_HOME:-/nonexistent}/rules" ]]; then
      for rule in "${SENTINEL_HOME}"/rules/*.md; do
        local basename
        basename=$(basename "$rule" 2>/dev/null)
        if [[ -f "$HOME/.claude/rules/$basename" ]]; then
          sentinel_rules=$((sentinel_rules + 1))
        fi
      done
    fi
  fi

  if [[ "$sentinel_rules" -gt 0 ]]; then
    pass "Rules installed ($sentinel_rules rule files)"
  else
    warn "No Sentinel rules found in ~/.claude/rules/" \
         "Re-run installer"
  fi
}

# ── Run all checks ────────────────────────────────────────────

check_sentinel_home
check_config_exists
check_config_mode
check_config_readonly
check_hooks_exist
check_hooks_executable
check_settings_hooks
check_gate_verify
check_rules_installed

# ── Verdict ───────────────────────────────────────────────────

echo ""
echo "---------------"

if [[ "$FAILS" -eq 0 ]]; then
  local_verdict="PASS"
  local_detail="${PASSES}/${TOTAL_CHECKS} checks passed"
  if [[ "$WARNS" -gt 0 ]]; then
    local_detail="${local_detail}, ${WARNS} warning(s)"
  fi
  printf "${BOLD}VERDICT: ${GREEN}%s${RESET} (%s)\n" "$local_verdict" "$local_detail"
  exit 0
else
  local_verdict="FAIL"
  local_detail="${FAILS} failed"
  if [[ "$WARNS" -gt 0 ]]; then
    local_detail="${local_detail}, ${WARNS} warning(s)"
  fi
  printf "${BOLD}VERDICT: ${RED}%s${RESET} (%s)\n" "$local_verdict" "$local_detail"
  exit 1
fi
