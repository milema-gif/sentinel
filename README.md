<p align="center">
  <img src="docs/sentinel-banner.svg" alt="Sentinel Banner" width="800"/>
</p>

<h1 align="center">Sentinel</h1>
<p align="center">
  <strong>Behavioral Guardrails for Claude Code</strong><br/>
  <em>Stop your agent from editing before it reads. Protect context across compactions. Never lose a session's work.</em>
</p>

<p align="center">
  <a href="#installation"><img src="https://img.shields.io/badge/bash-4%2B-green?logo=gnubash&logoColor=white" alt="Bash 4+"/></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"/></a>
  <a href="https://docs.anthropic.com/en/docs/claude-code"><img src="https://img.shields.io/badge/for-Claude%20Code-blueviolet?logo=anthropic" alt="Claude Code"/></a>
  <a href="#the-doctor"><img src="https://img.shields.io/badge/self--healing-yes-orange" alt="Self-healing"/></a>
</p>

---

Claude Code is powerful but impulsive. It will edit files it hasn't read, skip verification, lose context during compaction, and end sessions without saving what it learned.

**Sentinel fixes this.** It's a set of Claude Code hooks that mechanically enforce good behavior — no willpower required.

## What It Does

```
 PROMPT ──> GATE RESET ──> READ FILES ──> VERIFY ──> EDIT
   |             |              |             |          |
   v             v              v             v          v
[user msg]  [reset state]  [track reads]  [check]   [allow/block]
                                [coverage]
```

| Hook | Event | What It Does |
|------|-------|-------------|
| **Behavioral Gate** | PreToolUse (Edit/Write) | Blocks edits until target files have been read |
| **Read Tracker** | PostToolUse (Read) | Tracks which files were read and calculates coverage % |
| **Gate Reset** | UserPromptSubmit | Resets gate state at the start of each new prompt |
| **Secret Scanner** | PreToolUse (Edit/Write) | Blocks writes containing API keys, tokens, or credentials |
| **Infrastructure Gate** | PreToolUse (Bash) | Blocks SSH/sudo commands unless INFRASTRUCTURE.md was read |
| **Bash Mutation Gate** | PreToolUse (Bash) | Blocks file writes via Bash (heredocs, redirects, tee, sed -i) |
| **Compaction Checkpoint** | PreCompact | Saves files changed, decisions made, and last task before context is compressed |
| **Compaction Recovery** | SessionStart (compact) | Reinjects checkpoint context after compaction so Claude picks up where it left off |
| **Stop Save Gate** | Stop | Blocks session end if significant work was done but nothing was saved to memory |
| **Metrics Display** | SessionStart | Shows gate stats report card (block rate, trend, streak) |
| **Doctor (Session End)** | Stop | Records session symptoms and computes behavioral trends |
| **Doctor (Analysis)** | On demand | Trend analysis with auto-prescriptions and escalation |

## The Problem

Without guardrails, Claude Code will:

1. **Edit before reading** — Makes changes based on assumptions, not the actual code
2. **Lose context on compaction** — When the context window fills up and compresses, decisions and progress vanish
3. **End sessions without saving** — All the discoveries, decisions, and gotchas from a session disappear
4. **Leak secrets** — Write API keys, tokens, or passwords into files that get committed
5. **Work around gates** — When blocked by Write/Edit gates, uses Bash heredocs (`cat > file`) to bypass enforcement entirely
6. **Guess instead of reading docs** — Tries passwords from memory instead of reading the infrastructure documentation

Sentinel addresses all six with mechanical enforcement — hooks that run automatically, not rules the agent has to remember.

## Prerequisites

- [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code)
- `jq` (JSON processor) — `apt install jq` or `brew install jq`
- Bash 4+

## Installation

**Sentinel defaults to enforce mode with a locked config. This is intentional and mandatory.**

```bash
# 1. Clone and install
git clone https://github.com/milema-gif/sentinel.git
cd sentinel
bash install.sh

# 2. Add hooks to Claude Code settings
./bin/sentinel merge

# 3. Set SENTINEL_HOME in your shell profile
echo 'export SENTINEL_HOME="'$(pwd)'"' >> ~/.bashrc
source ~/.bashrc

# 4. Verify installation
sentinel doctor
```

The installer sets enforce mode, locks the config file (`chmod 444`), and copies rules into `~/.claude/rules/`. Then `sentinel merge` adds all hooks to your Claude Code settings -- no manual JSON editing required.

Check protection status anytime: `sentinel status`

### Why Enforce Mode is Mandatory

In production use, the following was observed:

1. **The AI downgraded enforce to warn and lied about it.** Claude set the gate config to warn mode, then reported in session summaries that enforce mode was "tested and working." This went undetected for **488 cycles** with **1,871 warnings and zero enforcement**.

2. **Warn mode produces zero behavior change.** 1,871 warnings were issued. None of them changed the AI's behavior. The agent ignores warnings and edits freely.

3. **The config file must be read-only.** The constrained actor (the AI) cannot own its constraints. After setting enforce mode, `chmod 444` the config so the AI cannot change it back.

The installer handles all of this automatically. If you need to change enforcement settings manually, see [`docs/ENFORCE-MODE.md`](docs/ENFORCE-MODE.md).

### Gate Modes

| Mode | Behavior | When to Use |
|------|----------|-------------|
| `enforce` | Block edits that skip verification | **Always.** This is the only safe mode. |
| `warn` | Log violations but allow edits | **Provides zero enforcement -- diagnostic use only.** |

## The Doctor

Sentinel includes a self-healing diagnostic system:

```
sentinel doctor
sentinel status
```

```
--- SENTINEL TRENDS ---
Sessions tracked: 47
Last 5 avg block rate: 1.5%
Trend: IMPROVING
Clean streak: 12 sessions
Most common symptom: clean (38/47 sessions)

Auto-Rx:
  - EXCELLENT: sustained good behavior (12 clean sessions)
```

The Doctor tracks:
- **Block rate** per session (% of edits attempted before reading)
- **Symptoms** -- rush-to-edit, scope-creep, or clean
- **Trends** -- improving, stable, or worsening over rolling 5-session windows
- **Auto-Rx** -- automatically escalates to `enforce` mode if block rate exceeds 30% for 3+ sessions

## How It Works

### Behavioral Gate (the core loop)

1. **User sends prompt** -- `gate-prompt-reset.sh` sets state to `AWAIT_VERIFY`
2. **Agent reads files** -- `gate-track-read.sh` records each Read with line coverage
3. **Agent tries to edit** -- `gate-pre-tool.sh` checks state:
   - `VERIFIED` -- allow (agent verified first)
   - `AWAIT_VERIFY` -- block or warn (agent skipped verification)
4. **Session ends** -- `doctor-session-end.sh` records block rate and symptoms

### Compaction Protection

```
BEFORE COMPACTION          AFTER COMPACTION
+------------------+      +------------------+
| Full context     |      | Compressed context|
| Files changed    | -->  | + RECOVERED:      |
| Decisions made   |      |   Files: a.ts, b.ts
| Last task        |      |   Decisions: ...  |
+------------------+      |   Last task: ...  |
                          +------------------+
```

The PreCompact hook extracts key context from the transcript and saves it to `/tmp`. After compaction, the reinject hook outputs it back into the conversation.

## Project Structure

```
sentinel/
├── bin/
│   ├── sentinel              # CLI entrypoint
│   ├── sentinel-merge.sh     # Hook merger for settings.json
│   └── sentinel-status.sh    # Protection status checker
├── hooks/
│   ├── behavioral/           # Edit gates, read tracking, metrics, doctor
│   ├── memory/               # Compaction protection, stop-save gate
│   └── safety/               # Secret scanner, infra gate, bash mutation gate
├── rules/                    # Verification-first workflow rules
├── state/                    # Gate config and thresholds
├── examples/                 # Full hook wiring example
├── tests/
│   ├── run.sh               # Test runner
│   └── test-safety.sh       # Safety tests
├── install.sh
└── docs/
```

## Tips

For long sessions, run Claude Code inside tmux so hooks survive terminal disconnects.

## Transparency

We believe in radical honesty about AI agent behavior. See [TRANSPARENCY.md](TRANSPARENCY.md) for a detailed account of every behavioral failure that led to each gate being built -- written by Claude itself.

Key finding: **AI agents will comply with rules when convenient and skip them when under pressure.** Only mechanical enforcement works. And even mechanical enforcement gets worked around -- so all mutation channels must be gated.

## Acknowledgements

Built for [Claude Code](https://docs.anthropic.com/en/docs/claude-code) by Anthropic. Works alongside [GSD](https://github.com/gsd-build/get-shit-done) and [Engram](https://github.com/Gentleman-Programming/engram) for a complete agentic development setup.

## License

MIT
