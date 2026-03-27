#!/usr/bin/env bash
set -euo pipefail

# sentinel-merge.sh — Idempotent settings.json hook merge tool
# Merges Sentinel hooks from examples/settings.json into user's Claude Code settings.json

SENTINEL_HOME="${SENTINEL_HOME:-$(cd "$(dirname "$0")/.." && pwd)}"
export SENTINEL_HOME

# --- Defaults ---
DRY_RUN=false
TARGET="${HOME}/.claude/settings.json"
SOURCE="${SENTINEL_HOME}/examples/settings.json"

# --- Parse flags ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --target)
      TARGET="$2"
      shift 2
      ;;
    --target=*)
      TARGET="${1#--target=}"
      shift
      ;;
    -h|--help)
      echo "Usage: sentinel merge [--dry-run] [--target PATH]"
      echo ""
      echo "Merge Sentinel hooks into Claude Code settings.json"
      echo ""
      echo "Options:"
      echo "  --dry-run       Show what would change without writing"
      echo "  --target PATH   Override target file (default: ~/.claude/settings.json)"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

# --- Preflight checks ---
if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed."
  echo "Install with: sudo apt install jq  (Debian/Ubuntu)"
  echo "              brew install jq       (macOS)"
  exit 1
fi

if [[ ! -f "$SOURCE" ]]; then
  echo "ERROR: Source file not found: $SOURCE"
  echo "Is SENTINEL_HOME set correctly? Current: $SENTINEL_HOME"
  exit 1
fi

# --- Fresh install: no target file ---
if [[ ! -f "$TARGET" ]]; then
  TARGET_DIR="$(dirname "$TARGET")"
  if $DRY_RUN; then
    EVENT_TYPES=$(jq -r '.hooks | keys[]' "$SOURCE")
    HOOK_COUNT=0
    for evt in $EVENT_TYPES; do
      COUNT=$(jq -r ".hooks[\"$evt\"][] | .hooks | length" "$SOURCE" | paste -sd+ | bc)
      HOOK_COUNT=$((HOOK_COUNT + COUNT))
      echo "  $evt: would add $COUNT hook(s)"
    done
    echo ""
    echo "Settings created (dry-run): would write $TARGET with $HOOK_COUNT hooks"
    exit 0
  fi
  mkdir -p "$TARGET_DIR"
  cp "$SOURCE" "$TARGET"
  EVENT_TYPES=$(jq -r '.hooks | keys[]' "$SOURCE")
  HOOK_COUNT=0
  for evt in $EVENT_TYPES; do
    COUNT=$(jq -r ".hooks[\"$evt\"][] | .hooks | length" "$SOURCE" | paste -sd+ | bc)
    HOOK_COUNT=$((HOOK_COUNT + COUNT))
    echo "  $evt: added $COUNT hook(s)"
  done
  echo ""
  echo "Settings created: $TARGET ($HOOK_COUNT hooks installed)"
  exit 0
fi

# --- Merge into existing file ---

# Back up before first merge (only if no backup exists yet)
BACKUP="${TARGET}.sentinel-backup"
if [[ ! -f "$BACKUP" ]]; then
  if ! $DRY_RUN; then
    cp "$TARGET" "$BACKUP"
    echo "Backup created: $BACKUP"
  else
    echo "Backup would be created: $BACKUP"
  fi
fi

# Read source and target
SOURCE_JSON=$(cat "$SOURCE")
TARGET_JSON=$(cat "$TARGET")

# Ensure target has a hooks object
if ! echo "$TARGET_JSON" | jq -e '.hooks' &>/dev/null; then
  TARGET_JSON=$(echo "$TARGET_JSON" | jq '. + {"hooks": {}}')
fi

TOTAL_ADDED=0
TOTAL_PRESENT=0

# Get all event types from source
EVENT_TYPES=$(echo "$SOURCE_JSON" | jq -r '.hooks | keys[]')

for EVT in $EVENT_TYPES; do
  # Get source matcher groups for this event type
  MATCHER_COUNT=$(echo "$SOURCE_JSON" | jq -r ".hooks[\"$EVT\"] | length")

  EVT_ADDED=0
  EVT_PRESENT=0

  for ((m=0; m<MATCHER_COUNT; m++)); do
    MATCHER=$(echo "$SOURCE_JSON" | jq -r ".hooks[\"$EVT\"][$m].matcher")
    SRC_HOOKS_COUNT=$(echo "$SOURCE_JSON" | jq -r ".hooks[\"$EVT\"][$m].hooks | length")

    for ((h=0; h<SRC_HOOKS_COUNT; h++)); do
      SRC_CMD=$(echo "$SOURCE_JSON" | jq -r ".hooks[\"$EVT\"][$m].hooks[$h].command")
      SRC_HOOK=$(echo "$SOURCE_JSON" | jq -c ".hooks[\"$EVT\"][$m].hooks[$h]")

      # Check if this Sentinel hook command already exists in the target
      # Search across all matcher groups in the target for this event type
      FOUND=false
      if echo "$TARGET_JSON" | jq -e ".hooks[\"$EVT\"]" &>/dev/null; then
        EXISTING=$(echo "$TARGET_JSON" | jq -r ".hooks[\"$EVT\"][]?.hooks[]?.command // empty")
        while IFS= read -r existing_cmd; do
          if [[ "$existing_cmd" == "$SRC_CMD" ]]; then
            FOUND=true
            break
          fi
        done <<< "$EXISTING"
      fi

      if $FOUND; then
        EVT_PRESENT=$((EVT_PRESENT + 1))
        TOTAL_PRESENT=$((TOTAL_PRESENT + 1))
      else
        EVT_ADDED=$((EVT_ADDED + 1))
        TOTAL_ADDED=$((TOTAL_ADDED + 1))

        # Find or create a matcher group in the target for this matcher
        if echo "$TARGET_JSON" | jq -e ".hooks[\"$EVT\"]" &>/dev/null; then
          # Check if a matching matcher group exists
          MATCHER_IDX=$(echo "$TARGET_JSON" | jq -r --arg m "$MATCHER" ".hooks[\"$EVT\"] | to_entries[] | select(.value.matcher == \$m) | .key" | head -1)
          if [[ -n "$MATCHER_IDX" ]]; then
            # Append hook to existing matcher group
            TARGET_JSON=$(echo "$TARGET_JSON" | jq --argjson hook "$SRC_HOOK" --arg evt "$EVT" --argjson idx "$MATCHER_IDX" \
              '.hooks[$evt][$idx].hooks += [$hook]')
          else
            # Create new matcher group
            TARGET_JSON=$(echo "$TARGET_JSON" | jq --arg evt "$EVT" --arg m "$MATCHER" --argjson hook "$SRC_HOOK" \
              '.hooks[$evt] += [{"matcher": $m, "hooks": [$hook]}]')
          fi
        else
          # Create event type with matcher group
          TARGET_JSON=$(echo "$TARGET_JSON" | jq --arg evt "$EVT" --arg m "$MATCHER" --argjson hook "$SRC_HOOK" \
            '.hooks[$evt] = [{"matcher": $m, "hooks": [$hook]}]')
        fi
      fi
    done
  done

  if [[ $EVT_ADDED -gt 0 ]]; then
    echo "  $EVT: added $EVT_ADDED hook(s)"
  elif [[ $EVT_PRESENT -gt 0 ]]; then
    echo "  $EVT: already present ($EVT_PRESENT hook(s))"
  fi
done

echo ""

# Write result
if [[ $TOTAL_ADDED -eq 0 ]]; then
  echo "All Sentinel hooks already installed ($TOTAL_PRESENT hooks present)"
else
  if $DRY_RUN; then
    echo "$TOTAL_ADDED hooks would be added, $TOTAL_PRESENT already present (dry-run)"
  else
    # Atomic write: write to tmp then move
    TMP="${TARGET}.tmp"
    echo "$TARGET_JSON" | jq '.' > "$TMP"
    mv "$TMP" "$TARGET"
    echo "$TOTAL_ADDED hooks added, $TOTAL_PRESENT already present"
  fi
fi

exit 0
