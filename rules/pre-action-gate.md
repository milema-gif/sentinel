# Pre-Action Gate

This rule applies to EVERY conversation, in EVERY directory with a known project.

## The Problem This Solves
AI agents jump from "understand" to "execute" and skip "verify." This gate forces confirmation of what's true NOW before touching code.

## When It Applies
Before ANY of these actions on project source files:
- `Edit` tool calls
- `Write` tool calls (new files)
- Launching agents that will edit files

## When It Does NOT Apply
- Reading files, searching, grepping, globbing
- Memory operations
- Conversation, planning, exploration
- Non-project files (scratch files, config)

## The Flow
```
0. CONTEXT   — Can I answer: why now? what's broken? what's success? (if no → ASK)
1. INTENT    — User says what to work on
2. RECALL    — Load relevant context/memory
3. VERIFY    — Read source files. Fill checklist.
4. PRESENT   — Show checklist + findings to user
5. GREENLIGHT — User confirms
6. EXECUTE   — Only now touch code
```

## Full Checklist (non-trivial edits)
```
PRE-ACTION CHECK:
- [ ] Project path: {path}
- [ ] Files read: {list of files just read}
- [ ] Memory vs code: {any drift noted, or "matches"}
- [ ] Scope: {what specifically changing and why}
- [ ] Risk: {low/med/high — med+ needs rollback plan}
- [ ] Validation: {how to prove the change works}
- [ ] Rollback: {what to revert if wrong}
```

## Mini Checklist (trivial one-line fixes only)
```
QUICK CHECK: Read {file} ✓ | Change: {one-liner scope} | Validate: {command}
```

## Critical Behavior Rules

1. **Default action is verification, not coding.** When the user says "do it," the first action is Read files and fill the checklist — not Edit.
2. **Memory is a claim, not truth.** Always Read the file and confirm before building on assumptions.
3. **No silent scope expansion.** The checklist Scope field defines what's changing. New scope = new checklist.
4. **Greenlight is per-scope.** Approving scope A doesn't authorize scope B.
