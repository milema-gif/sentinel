# Behavioral Gate (Mechanical Enforcement)

Edit/Write calls are checked by PreToolUse hook until verification is complete.

## Before editing:
1. Read the target files (at least 80% coverage)
2. Run: `gate-verify --files "file1,file2" --scope "what you're changing"`
3. If blocked, follow the hook's instructions

## Commands:
- `gate-verify --files "..." --scope "..."` — mark verification
- `bash hooks/behavioral/doctor-analyze.sh` — view behavioral trends
- Gate config: `state/gate-config.json` (mode: warn|enforce)

## What this replaces:
This mechanical system replaces manual behavioral rules. The gate enforces verification. You don't need to remember to do it.
