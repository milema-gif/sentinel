#!/usr/bin/env bash
# Sentinel — Session-end autopsy
# Reads behavioral_metrics.json, computes session stats, appends to doctor_history.json
set -euo pipefail

METRICS="${SENTINEL_HOME:-$HOME/.claude}/state/behavioral_metrics.json"
HISTORY="${SENTINEL_HOME:-$HOME/.claude}/state/doctor_history.json"

# Fail silent if no metrics
[[ -f "$METRICS" ]] || exit 0

# Initialize history if missing
if [[ ! -f "$HISTORY" ]]; then
  printf '{"sessions":[],"trend":{"last_5_avg_block_rate":0,"direction":"new","clean_streak":0}}\n' > "$HISTORY"
fi

# Extract counts from metrics (default 0 for missing fields)
cycles=$(jq -r '.cycles // 0' "$METRICS" 2>/dev/null || echo 0)
blocked=$(jq -r '.blocked // 0' "$METRICS" 2>/dev/null || echo 0)
warned=$(jq -r '.warned // 0' "$METRICS" 2>/dev/null || echo 0)
allowed=$(jq -r '.allowed // 0' "$METRICS" 2>/dev/null || echo 0)
verified=$(jq -r '.verified // 0' "$METRICS" 2>/dev/null || echo 0)

# Compute block rate
total=$((cycles > 0 ? cycles : (blocked + allowed + warned)))
total=$((total > 0 ? total : 1))
block_rate=$(awk "BEGIN {printf \"%.2f\", ${blocked} / ${total}}")
block_pct=$(awk "BEGIN {printf \"%.0f\", ${blocked} / ${total} * 100}")

# Detect symptoms
symptoms="[]"
if [[ "$blocked" -gt 0 ]]; then
  symptoms=$(echo "$symptoms" | jq '. + ["rush-to-edit"]')
fi
if [[ "$verified" -gt "$cycles" ]] && [[ "$cycles" -gt 0 ]]; then
  symptoms=$(echo "$symptoms" | jq '. + ["scope-creep"]')
fi
if [[ "$blocked" -eq 0 ]] && [[ "$warned" -eq 0 ]]; then
  symptoms=$(echo "$symptoms" | jq '. + ["clean"]')
fi

today=$(date +%Y-%m-%d)

# Append session record
jq --arg date "$today" \
   --argjson cycles "$cycles" \
   --argjson blocked "$blocked" \
   --argjson warned "$warned" \
   --argjson allowed "$allowed" \
   --argjson verified "$verified" \
   --argjson block_rate "$block_rate" \
   --argjson symptoms "$symptoms" \
   '.sessions += [{
     "date": $date,
     "cycles": $cycles,
     "blocked": $blocked,
     "warned": $warned,
     "allowed": $allowed,
     "verified": $verified,
     "block_rate": $block_rate,
     "symptoms": $symptoms
   }]' "$HISTORY" > "${HISTORY}.tmp" && mv "${HISTORY}.tmp" "$HISTORY"

# Compute trend over last 5 and previous 5
last5_avg=$(jq '[.sessions[-5:][].block_rate] | if length > 0 then (add / length) else 0 end' "$HISTORY")
prev5_avg=$(jq '[.sessions[-10:-5][].block_rate] | if length > 0 then (add / length) else 0 end' "$HISTORY")
session_count=$(jq '.sessions | length' "$HISTORY")

# Trend direction
direction="stable"
diff_pp=$(awk "BEGIN {printf \"%.1f\", (${last5_avg} - ${prev5_avg}) * 100}")
if awk "BEGIN {exit !(${last5_avg} < ${prev5_avg} - 0.05)}"; then
  direction="improving"
elif awk "BEGIN {exit !(${last5_avg} > ${prev5_avg} + 0.05)}"; then
  direction="worsening"
fi

# Clean streak (consecutive sessions from end with block_rate < 0.10)
clean_streak=$(jq '[.sessions | reverse | to_entries[] | select(.value.block_rate >= 0.10) | .key] | if length > 0 then .[0] else (.sessions | length) end' "$HISTORY" 2>/dev/null || echo 0)

# Update trend in history
jq --argjson avg "$last5_avg" \
   --arg dir "$direction" \
   --argjson streak "$clean_streak" \
   '.trend = {
     "last_5_avg_block_rate": ($avg * 100 | round / 100),
     "direction": $dir,
     "clean_streak": $streak
   }' "$HISTORY" > "${HISTORY}.tmp" && mv "${HISTORY}.tmp" "$HISTORY"

last5_pct=$(awk "BEGIN {printf \"%.1f\", ${last5_avg} * 100}")

# Format symptoms for display
symptom_list=$(echo "$symptoms" | jq -r '.[]' 2>/dev/null)

# Trend arrow
trend_arrow="→"
[[ "$direction" == "improving" ]] && trend_arrow="↓"
[[ "$direction" == "worsening" ]] && trend_arrow="↑"

# Output report
cat <<REPORT
━━━ SESSION SYMPTOMS ━━━━━━━━━━━━━━━━━━━━━━━
Cycles: ${cycles} | Verified: ${verified} | Blocked: ${blocked}
Block rate: ${block_pct}%

Symptoms detected:
REPORT

if [[ -z "$symptom_list" ]] || echo "$symptoms" | jq -e 'length == 0' >/dev/null 2>&1; then
  echo "  - [none]"
else
  while IFS= read -r s; do
    case "$s" in
      rush-to-edit)  echo "  - RUSH: ${blocked} edit attempt(s) before verification" ;;
      scope-creep)   echo "  - SCOPE-CREEP: verified ${verified} times across ${cycles} cycles" ;;
      clean)         echo "  - CLEAN: no blocks or warnings" ;;
      *)             echo "  - ${s}" ;;
    esac
  done <<< "$symptom_list"
fi

cat <<REPORT

Trend (last 5 sessions): $(echo "$direction" | tr '[:lower:]' '[:upper:]') ${trend_arrow} (avg ${last5_pct}%)
Streak: ${clean_streak} clean sessions (< 10% block rate)

REPORT

# Auto-prescription
echo "Rx:"
rx_printed=0
if awk "BEGIN {exit !(${block_rate} > 0.30)}"; then
  echo "  - Block rate > 30% -> consider switching to enforce mode"
  rx_printed=1
elif awk "BEGIN {exit !(${block_rate} > 0.20)}"; then
  echo "  - Block rate > 20% -> review verification habits"
  rx_printed=1
fi
if [[ "$clean_streak" -ge 5 ]]; then
  echo "  - EXCELLENT: ${clean_streak} consecutive clean sessions"
  rx_printed=1
fi
if awk "BEGIN {exit !(${last5_avg} < 0.05)}" && [[ "$session_count" -ge 5 ]]; then
  echo "  - STABLE: gate is effective, consider relaxing min_read_coverage"
  rx_printed=1
fi
if [[ "$rx_printed" -eq 0 ]]; then
  echo "  - [no action needed]"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
