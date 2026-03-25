# <your-org> Agent Configuration Investigation

**Date:** 2026-03-25
**Scope:** Exhaustive review of all files, symlinks, configs, and settings for the `<your-org>` agent

---

## 1. Directory Structure Overview

```
.openclaw/agents/<your-org>/
├── .openclaw/
│   └── workspace-state.json        [REAL FILE - runtime]
├── memory/
│   └── poll-state.json              [REAL FILE - runtime state]
├── IDENTITY.md                      [REAL FILE - per-agent, unfilled template]
├── USER.md                          [REAL FILE - per-agent, unfilled template]
├── AGENTS.md        -> ../../../types/dev-pa/AGENTS.md       [SYMLINK]
├── BOOTSTRAP.md     -> ../../../types/dev-pa/BOOTSTRAP.md    [SYMLINK]
├── HEARTBEAT.md     -> ../../../types/dev-pa/HEARTBEAT.md    [SYMLINK]
├── SOUL.md          -> ../../../types/dev-pa/SOUL.md         [SYMLINK]
├── TOOLS.md         -> ../../../types/dev-pa/TOOLS.md        [SYMLINK]
├── poll-config.json -> ../../../types/dev-pa/poll-config.json [SYMLINK]
└── scripts          -> ../../../types/dev-pa/scripts          [SYMLINK - directory]
```

---

## 2. File-by-File Analysis

### 2.1 REAL FILES (per-agent, unique to <your-org>)

#### IDENTITY.md
- **Path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/<your-org>/IDENTITY.md`
- **Type:** Real file (636 bytes)
- **Purpose:** Defines the agent's persona (name, creature type, vibe, emoji, avatar). Filled in during first-run bootstrap conversation.
- **Status:** UNFILLED TEMPLATE. All fields are placeholder instructions. The agent has NOT completed its bootstrap process (has not chosen a name, vibe, etc.).

#### USER.md
- **Path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/<your-org>/USER.md`
- **Type:** Real file (477 bytes)
- **Purpose:** Stores information about the human the agent assists (name, pronouns, timezone, context). Updated over time as the agent learns about its user.
- **Status:** UNFILLED TEMPLATE. No user information has been populated. The bootstrap conversation has not occurred.

#### memory/poll-state.json
- **Path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/<your-org>/memory/poll-state.json`
- **Type:** Real file (33 bytes, permissions: `-rw-------`)
- **Purpose:** Tracks whether the agent is currently waiting for a human response after sending a check-in message. Used by `poll-check.sh` to avoid sending duplicate check-ins.
- **Contents:**
  ```json
  {
    "awaiting_response": false
  }
  ```
- **Status:** Default/initial state. The agent has not sent a check-in yet (or the flag was reset).

#### .openclaw/workspace-state.json
- **Path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/<your-org>/.openclaw/workspace-state.json`
- **Type:** Real file (70 bytes, permissions: `-rw-------`)
- **Purpose:** OpenClaw runtime state. Records when the agent workspace was first seeded/bootstrapped.
- **Contents:**
  ```json
  {
    "version": 1,
    "bootstrapSeededAt": "2026-03-24T06:09:18.682Z"
  }
  ```
- **Status:** Bootstrap was seeded on 2026-03-24 at 06:09 UTC, but the agent has NOT completed the interactive bootstrap process (IDENTITY.md and USER.md remain unfilled, BOOTSTRAP.md still exists).

---

### 2.2 SYMLINKED FILES (shared via dev-pa type)

All symlinks point to `../../../types/dev-pa/` which resolves to `/Users/<hostname>/openclaw-agents/types/dev-pa/`.

#### SOUL.md
- **Link target:** `types/dev-pa/SOUL.md`
- **Purpose:** Core personality and behavioral principles. Defines the agent's fundamental character.
- **Key directives:**
  - Be genuinely helpful, not performatively helpful
  - Have opinions and personality
  - Be resourceful before asking questions
  - Earn trust through competence
  - Remember you are a guest in someone's life
  - Private things stay private
  - Never send half-baked replies to messaging surfaces

#### AGENTS.md
- **Link target:** `types/dev-pa/AGENTS.md`
- **Purpose:** The agent's complete operating manual. Covers session startup, memory management, group chat behavior, heartbeat handling, and workspace conventions.
- **Key features:**
  - Session startup reads SOUL.md, USER.md, daily memory files, and optionally MEMORY.md
  - Memory system: daily notes in `memory/YYYY-MM-DD.md` + curated long-term in `MEMORY.md`
  - Group chat rules: speak only when adding value, stay silent during casual banter
  - Heartbeat protocol: proactive checks (email, calendar, mentions, weather) 2-4x daily
  - Cron job response format: output ONLY the delivery message
  - Red lines: no data exfiltration, `trash` over `rm`, ask before destructive ops

#### TOOLS.md
- **Link target:** `types/dev-pa/TOOLS.md`
- **Purpose:** Per-agent local notes for environment-specific details (camera names, SSH hosts, TTS voices, etc.).
- **Status:** Template only. No agent-specific tool notes have been added.

#### HEARTBEAT.md
- **Link target:** `types/dev-pa/HEARTBEAT.md`
- **Purpose:** Checklist/reminders for the agent to process during heartbeat polls.
- **Status:** Template only with a comment block. Effectively empty, meaning heartbeat polls will result in `HEARTBEAT_OK` (no proactive tasks configured).

#### BOOTSTRAP.md
- **Link target:** `types/dev-pa/BOOTSTRAP.md`
- **Purpose:** First-run onboarding script. Guides the agent through its initial conversation to establish identity, learn about its user, and set up communication channels.
- **Status:** STILL EXISTS. Per the instructions, this file should be deleted after bootstrap completes. Its presence confirms the agent has NOT completed first-run onboarding.

#### poll-config.json
- **Link target:** `types/dev-pa/poll-config.json`
- **Purpose:** Configures the polling interval for check-in due calculations.
- **Contents:**
  ```json
  {
    "interval_minutes": 240
  }
  ```
- **Meaning:** The agent considers a check-in "due" if 240 minutes (4 hours) have passed since the last human interaction.

#### scripts/ (directory symlink)
- **Link target:** `types/dev-pa/scripts/`
- **Purpose:** Shared executable scripts for the dev-pa agent type.
- **Contents:**
  - `poll-check.sh` - Main polling script that determines if a check-in is due
  - `lib/json-response.sh` - Shared library for structured JSON output (logging, success/error responses)

---

### 2.3 SCRIPTS (via symlinked directory)

#### scripts/poll-check.sh
- **Path:** `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/poll-check.sh`
- **Purpose:** Determines whether the agent should send a check-in message to its human.
- **Logic:**
  1. Reads `poll-config.json` for `interval_minutes` (default: 240)
  2. Reads `memory/poll-state.json` for `awaiting_response` flag
  3. Reads `~/.openclaw/agents/<name>/sessions/sessions.json` for last human interaction timestamp
  4. Filters out cron sessions, finds the most recent `updatedAt` from human sessions
  5. Decision:
     - If `awaiting_response == true`: DUE=0 (already waiting, do not send again)
     - If no human sessions found: DUE=1 (should check in)
     - If elapsed minutes >= interval: DUE=1
     - Otherwise: DUE=0
  6. Outputs structured JSON via `json_success`

#### scripts/lib/json-response.sh
- **Path:** `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/lib/json-response.sh`
- **Purpose:** Standard library providing `log()`, `json_timestamp()`, `json_success()`, `json_error()` functions for deterministic script output.

---

## 3. Cron Job Configuration

### jobs-config.json (source of truth in repo)
- **Path:** `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json`

### jobs.json (stowed to ~/.openclaw/cron/)
- **Path:** `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs.json`

Both files are IDENTICAL in content. <your-org> entry:

```json
{
  "id": "b2c7a3d1-5e8f-4b9a-9c2d-e1f0a3b4c5d6",
  "agentId": "<your-org>",
  "name": "<your-org> Check-in",
  "enabled": true,
  "schedule": {
    "kind": "every",
    "everyMs": 7200000
  },
  "sessionTarget": "isolated",
  "wakeMode": "now",
  "payload": {
    "kind": "agentTurn",
    "message": "Run scripts/poll-check.sh. Parse the JSON output.\n\nIf data.due == 0, output ONLY 'NO_ACTION' and nothing else.\n\nIf data.due == 1:\n1. Review your conversation history and memory...\n2. Compose a warm, friendly check-in message...\n3. Send the message using: openclaw message send --channel slack --target user:<slack-id> --message \"<your message>\"\n4. After sending, update memory/poll-state.json: set awaiting_response to true.",
    "timeoutSeconds": 120,
    "thinking": "on",
    "model": "fw-mm25"
  },
  "sessionKey": "agent:<your-org>:main",
  "delivery": {
    "mode": "none"
  }
}
```

**Key cron settings:**
- **Schedule:** Every 7,200,000 ms = every 2 hours
- **Session:** Isolated (does not pollute main conversation)
- **Model:** `fw-mm25` (likely Fireworks-hosted model)
- **Thinking:** Enabled
- **Timeout:** 120 seconds
- **Slack target:** `user:<slack-id>` (<your-org>'s human, different from dev1's `<slack-id>`)
- **Delivery mode:** `none` (agent handles delivery itself via `openclaw message send`)

---

## 4. Stow/Symlink Chain (Live System)

The live `~/.openclaw/agents/<your-org>/` directory shows stow symlinks pointing back to the repo:

```
~/.openclaw/agents/<your-org>/
├── AGENTS.md      -> ../../../openclaw-agents/.openclaw/agents/<your-org>/AGENTS.md
├── BOOTSTRAP.md   -> ../../../openclaw-agents/.openclaw/agents/<your-org>/BOOTSTRAP.md
├── HEARTBEAT.md   -> ../../../openclaw-agents/.openclaw/agents/<your-org>/HEARTBEAT.md
├── IDENTITY.md    -> ../../../openclaw-agents/.openclaw/agents/<your-org>/IDENTITY.md
├── SOUL.md        -> ../../../openclaw-agents/.openclaw/agents/<your-org>/SOUL.md
├── TOOLS.md       -> ../../../openclaw-agents/.openclaw/agents/<your-org>/TOOLS.md
├── USER.md        -> ../../../openclaw-agents/.openclaw/agents/<your-org>/USER.md
├── poll-config.json -> ../../../openclaw-agents/.openclaw/agents/<your-org>/poll-config.json
├── .openclaw/      [directory, NOT symlinked]
├── agent/          [directory, NOT symlinked - runtime]
├── memory/         [directory, NOT symlinked]
├── scripts/        [directory, NOT symlinked - stow expands dir symlinks]
└── sessions/       [directory, NOT symlinked - runtime, 30 items]
```

This means there is a double symlink chain for shared files:
```
~/.openclaw/agents/<your-org>/SOUL.md
  -> openclaw-agents/.openclaw/agents/<your-org>/SOUL.md  (stow link)
    -> types/dev-pa/SOUL.md  (type inheritance link)
```

Note: The `scripts/` directory is expanded by stow (not a single symlink), and the `memory/`, `sessions/`, `agent/`, `.openclaw/` directories are local runtime directories managed by OpenClaw.

---

## 5. Comparison with dev1 Agent

| Aspect | <your-org> | dev1 |
|--------|--------------|----------|
| Agent type | dev-pa | dev-pa |
| Slack target | <slack-id> | <slack-id> |
| Cron schedule | Every 2 hours | Every 2 hours |
| Poll interval | 240 min (4h) | 240 min (4h) |
| Model | fw-mm25 | fw-mm25 |
| Bootstrap completed | NO | Unknown |
| Session key | agent:<your-org>:main | agent:dev1:main |

---

## 6. Key Findings

1. **Agent is NOT bootstrapped.** IDENTITY.md, USER.md are unfilled templates. BOOTSTRAP.md still exists (should be deleted after first-run). The workspace was seeded on 2026-03-24 but the interactive onboarding conversation never happened.

2. **Cron job is ENABLED and running.** The check-in job fires every 2 hours. However, since the agent has no identity or user context, any check-in messages it composes will lack personalization.

3. **Poll state is clean.** `awaiting_response: false` means it is not currently waiting for a reply and will attempt to check in if the 240-minute interval has elapsed.

4. **Double symlink chain.** Stow creates links from `~/.openclaw/` to the repo, and the repo files themselves are symlinks to `types/dev-pa/`. This means edits to type files propagate to all agents of that type automatically.

5. **Identical cron config in two files.** Both `jobs.json` and `jobs-config.json` exist with identical content. The relationship between these two files is unclear -- one may be the git-tracked source and the other the stowed runtime copy.

6. **HEARTBEAT.md is effectively empty.** No proactive tasks are configured, so heartbeat polls will always return `HEARTBEAT_OK`.
