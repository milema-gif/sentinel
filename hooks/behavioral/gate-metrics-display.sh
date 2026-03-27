#!/bin/bash
# Sentinel — Gate Metrics Display (SessionStart hook)
# Shows a report card of behavioral gate stats at session start.
# Install: SessionStart hook
set -uo pipefail

METRICS_FILE="${SENTINEL_HOME:-$HOME/.claude}/state/behavioral_metrics.json"
CONFIG_FILE="${SENTINEL_HOME:-$HOME/.claude}/state/gate-config.json"

mode="warn"
if [ -f "$CONFIG_FILE" ] && command -v jq &>/dev/null; then
    mode=$(jq -r '.mode // "warn"' "$CONFIG_FILE" 2>/dev/null) || mode="warn"
fi

if [ ! -f "$METRICS_FILE" ] || ! command -v jq &>/dev/null; then
    echo "━━━ SENTINEL GATE ━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Mode: $mode | Cycles: 0 | Verified: 0"
    echo "Blocked: 0 | Warned: 0 | Allowed: 0"
    echo "Block rate: 0% | Status: NEW"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
fi

cycles=$(jq -r '.cycles // 0' "$METRICS_FILE" 2>/dev/null) || cycles=0
verified=$(jq -r '.verified // 0' "$METRICS_FILE" 2>/dev/null) || verified=0
blocked=$(jq -r '.blocked // 0' "$METRICS_FILE" 2>/dev/null) || blocked=0
warned=$(jq -r '.warned // 0' "$METRICS_FILE" 2>/dev/null) || warned=0
allowed=$(jq -r '.allowed // 0' "$METRICS_FILE" 2>/dev/null) || allowed=0

total_actions=$((blocked + warned + allowed))
if [ "$total_actions" -gt 0 ]; then
    block_rate=$(awk "BEGIN { printf \"%.1f\", ($blocked / $total_actions) * 100 }")
else
    block_rate="0"
fi

if [ "$cycles" -eq 0 ]; then
    trend="NEW"
elif [ "$cycles" -lt 5 ]; then
    trend="COLLECTING"
elif [ "$blocked" -eq 0 ]; then
    trend="CLEAN"
else
    trend="ACTIVE"
fi

echo "━━━ SENTINEL GATE ━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Mode: $mode | Cycles: $cycles | Verified: $verified"
echo "Blocked: $blocked | Warned: $warned | Allowed: $allowed"
echo "Block rate: ${block_rate}% | Trend: $trend"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit 0
