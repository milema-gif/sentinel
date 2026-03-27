#!/usr/bin/env bash
# Sentinel Test Runner — run all safety tests
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SENTINEL_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export SENTINEL_HOME

echo "--- Sentinel Test Suite ---------------------"
echo ""

# Run safety tests
bash "$SCRIPT_DIR/test-safety.sh"
EXIT_CODE=$?

echo ""
echo "----------------------------------------------"

exit $EXIT_CODE
