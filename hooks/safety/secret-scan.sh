#!/bin/bash
# Sentinel — PreToolUse hook: scans Write/Edit content for leaked secrets.
# Exits non-zero (blocks the write) if a secret pattern is found.

INPUT=$(cat)
TOOL=$(echo "$INPUT" | jq -r '.tool_name // ""' 2>/dev/null)

# Get the content being written
if [ "$TOOL" = "Write" ]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.content // ""' 2>/dev/null)
elif [ "$TOOL" = "Edit" ]; then
    CONTENT=$(echo "$INPUT" | jq -r '.tool_input.new_string // ""' 2>/dev/null)
else
    exit 0
fi

# Skip if no content
[ -z "$CONTENT" ] && exit 0

# File path — allow .env.example files
FILEPATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""' 2>/dev/null)
if echo "$FILEPATH" | grep -qE '\.(example|sample|template)$'; then
    exit 0
fi

# Secret patterns to catch
PATTERNS=(
    'sk-[a-zA-Z0-9]{20,}'
    'ghp_[a-zA-Z0-9]{36,}'
    'github_pat_[a-zA-Z0-9_]{50,}'
    'gho_[a-zA-Z0-9]{36,}'
    'OPENAI_API_KEY=sk'
    'GH_TOKEN=[a-zA-Z0-9_]+'
    'GROQ_API_KEY=[a-zA-Z0-9_-]+'
    'FRED_API_KEY=[a-zA-Z0-9]+'
    'password=[^${}"][a-zA-Z0-9!@#$%^&*]{6,}'
)

for PATTERN in "${PATTERNS[@]}"; do
    if echo "$CONTENT" | grep -qEi "$PATTERN"; then
        MATCH=$(echo "$CONTENT" | grep -oEi "$PATTERN" | head -1)
        # Redact the match for display
        REDACTED="${MATCH:0:15}..."
        echo '{"error": "BLOCKED: Secret pattern detected: '"$REDACTED"'. Move secrets to env files."}' >&2
        exit 2
    fi
done

exit 0
