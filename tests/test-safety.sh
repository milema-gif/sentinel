#!/usr/bin/env bash
# Sentinel Safety Tests — validates doctor detects misconfig, tampering, path failures
# Run via: bash tests/run.sh  (or directly: bash tests/test-safety.sh)
set -euo pipefail

# ── Test framework (inline, no dependencies) ─────────────────
PASSED=0
FAILED=0
FAILED_NAMES=()

pass_test() {
  local name="$1"
  printf "  PASS  %s\n" "$name"
  PASSED=$((PASSED + 1))
}

fail_test() {
  local name="$1"
  local reason="$2"
  printf "  FAIL  %s -- %s\n" "$name" "$reason"
  FAILED=$((FAILED + 1))
  FAILED_NAMES+=("$name")
}

# ── Paths ─────────────────────────────────────────────────────
# Real sentinel home — used to locate the actual doctor script
REAL_SENTINEL_HOME="${SENTINEL_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
DOCTOR="$REAL_SENTINEL_HOME/hooks/behavioral/doctor-analyze.sh"

if [[ ! -f "$DOCTOR" ]]; then
  echo "ERROR: doctor-analyze.sh not found at $DOCTOR"
  exit 2
fi

# Temp dirs accumulator for cleanup
TEMP_DIRS=()

cleanup() {
  for d in "${TEMP_DIRS[@]}"; do
    # Restore write bits so rm can clean up read-only files
    chmod -R u+w "$d" 2>/dev/null || true
    rm -rf "$d"
  done
}
trap cleanup EXIT

# ── Fixture builder ───────────────────────────────────────────
# Creates a complete, healthy sentinel + HOME tree in temp dirs.
# Sets TEMP_SENTINEL and TEMP_HOME variables.
setup_sentinel_fixture() {
  TEMP_SENTINEL=$(mktemp -d /tmp/sentinel-test-XXXX)
  TEMP_HOME=$(mktemp -d /tmp/sentinel-home-XXXX)
  TEMP_DIRS+=("$TEMP_SENTINEL" "$TEMP_HOME")

  # Create all 9 hook scripts (touch + chmod +x)
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
  for hook in "${hooks[@]}"; do
    mkdir -p "$TEMP_SENTINEL/$(dirname "$hook")"
    printf '#!/usr/bin/env bash\ntrue\n' > "$TEMP_SENTINEL/$hook"
    chmod +x "$TEMP_SENTINEL/$hook"
  done

  # Create config at temp HOME/.claude/state/gate-config.json
  mkdir -p "$TEMP_HOME/.claude/state"
  echo '{"mode":"enforce","min_read_coverage":80}' > "$TEMP_HOME/.claude/state/gate-config.json"
  chmod 444 "$TEMP_HOME/.claude/state/gate-config.json"

  # Create settings.json with sentinel reference
  echo '{"hooks":{"sentinel":"$SENTINEL_HOME/hooks"}}' > "$TEMP_HOME/.claude/settings.json"

  # Create rules directory with a dummy rule
  mkdir -p "$TEMP_HOME/.claude/rules"
  mkdir -p "$TEMP_SENTINEL/rules"
  echo "# dummy rule" > "$TEMP_SENTINEL/rules/test-rule.md"
  echo "# dummy rule" > "$TEMP_HOME/.claude/rules/test-rule.md"

  # Create gate-verify stand-in
  mkdir -p "$TEMP_HOME/.local/bin"
  touch "$TEMP_HOME/.local/bin/gate-verify"
  chmod +x "$TEMP_HOME/.local/bin/gate-verify"
}

# Run doctor with overridden HOME and SENTINEL_HOME.
# Captures stdout+stderr into $DOCTOR_OUTPUT and exit code into $DOCTOR_EXIT.
run_doctor() {
  DOCTOR_OUTPUT=$(HOME="$TEMP_HOME" SENTINEL_HOME="$TEMP_SENTINEL" \
    PATH="$TEMP_HOME/.local/bin:$PATH" \
    bash "$DOCTOR" 2>&1) || true
  # Re-run to capture exit code (the || true above swallows it)
  HOME="$TEMP_HOME" SENTINEL_HOME="$TEMP_SENTINEL" \
    PATH="$TEMP_HOME/.local/bin:$PATH" \
    bash "$DOCTOR" >/dev/null 2>&1 && DOCTOR_EXIT=0 || DOCTOR_EXIT=$?
}

# ── Test cases ────────────────────────────────────────────────

test_unset_sentinel_home() {
  local name="test_unset_sentinel_home"
  setup_sentinel_fixture

  # Run doctor with SENTINEL_HOME unset
  DOCTOR_OUTPUT=$(HOME="$TEMP_HOME" \
    bash -c 'unset SENTINEL_HOME; bash "'"$DOCTOR"'"' 2>&1) || true
  HOME="$TEMP_HOME" \
    bash -c 'unset SENTINEL_HOME; bash "'"$DOCTOR"'"' >/dev/null 2>&1 && DOCTOR_EXIT=0 || DOCTOR_EXIT=$?

  if [[ "$DOCTOR_EXIT" -ne 0 ]] && echo "$DOCTOR_OUTPUT" | grep -qi "SENTINEL_HOME not set"; then
    pass_test "$name"
  else
    fail_test "$name" "Expected exit 1 + 'SENTINEL_HOME not set' in output (got exit=$DOCTOR_EXIT)"
  fi
}

test_missing_config() {
  local name="test_missing_config"
  setup_sentinel_fixture

  # Remove the config file
  chmod u+w "$TEMP_HOME/.claude/state/gate-config.json"
  rm -f "$TEMP_HOME/.claude/state/gate-config.json"

  run_doctor

  if [[ "$DOCTOR_EXIT" -ne 0 ]] && echo "$DOCTOR_OUTPUT" | grep -qi "Config file missing"; then
    pass_test "$name"
  else
    fail_test "$name" "Expected exit 1 + 'Config file missing' in output (got exit=$DOCTOR_EXIT)"
  fi
}

test_warn_mode_tamper() {
  local name="test_warn_mode_tamper"
  setup_sentinel_fixture

  # Replace config with warn mode
  chmod u+w "$TEMP_HOME/.claude/state/gate-config.json"
  echo '{"mode":"warn","min_read_coverage":80}' > "$TEMP_HOME/.claude/state/gate-config.json"
  chmod 444 "$TEMP_HOME/.claude/state/gate-config.json"

  run_doctor

  if [[ "$DOCTOR_EXIT" -ne 0 ]] && echo "$DOCTOR_OUTPUT" | grep -qi "warn.*must be enforce\|mode.*warn"; then
    pass_test "$name"
  else
    fail_test "$name" "Expected exit 1 + mode warn message (got exit=$DOCTOR_EXIT)"
  fi
}

test_config_writable() {
  local name="test_config_writable"
  setup_sentinel_fixture

  # Make config writable (644)
  chmod u+w "$TEMP_HOME/.claude/state/gate-config.json"
  chmod 644 "$TEMP_HOME/.claude/state/gate-config.json"

  run_doctor

  if [[ "$DOCTOR_EXIT" -ne 0 ]] && echo "$DOCTOR_OUTPUT" | grep -qi "writable"; then
    pass_test "$name"
  else
    fail_test "$name" "Expected exit 1 + 'writable' in output (got exit=$DOCTOR_EXIT)"
  fi
}

test_missing_hooks() {
  local name="test_missing_hooks"
  setup_sentinel_fixture

  # Remove the entire hooks directory
  rm -rf "$TEMP_SENTINEL/hooks"

  run_doctor

  if [[ "$DOCTOR_EXIT" -ne 0 ]] && echo "$DOCTOR_OUTPUT" | grep -qi "Hook missing"; then
    pass_test "$name"
  else
    fail_test "$name" "Expected exit 1 + 'Hook missing' in output (got exit=$DOCTOR_EXIT)"
  fi
}

test_wrong_hook_paths() {
  local name="test_wrong_hook_paths"
  setup_sentinel_fixture

  # Remove some (but not all) hook scripts
  rm -f "$TEMP_SENTINEL/hooks/safety/secret-scan.sh"
  rm -f "$TEMP_SENTINEL/hooks/memory/stop-save-gate.sh"

  run_doctor

  if [[ "$DOCTOR_EXIT" -ne 0 ]] && echo "$DOCTOR_OUTPUT" | grep -qi "Hook missing"; then
    pass_test "$name"
  else
    fail_test "$name" "Expected exit 1 + 'Hook missing' in output (got exit=$DOCTOR_EXIT)"
  fi
}

test_healthy_system() {
  local name="test_healthy_system"
  setup_sentinel_fixture

  run_doctor

  if [[ "$DOCTOR_EXIT" -eq 0 ]]; then
    pass_test "$name"
  else
    fail_test "$name" "Expected exit 0 for healthy system (got exit=$DOCTOR_EXIT, output: $DOCTOR_OUTPUT)"
  fi
}

# ── Run all tests ─────────────────────────────────────────────

echo "Running safety tests..."
echo ""

test_unset_sentinel_home
test_missing_config
test_warn_mode_tamper
test_config_writable
test_missing_hooks
test_wrong_hook_paths
test_healthy_system

echo ""
echo "Results: $PASSED passed, $FAILED failed (out of $((PASSED + FAILED)) tests)"

if [[ "$FAILED" -gt 0 ]]; then
  echo "Failed tests: ${FAILED_NAMES[*]}"
  exit 1
fi

exit 0
