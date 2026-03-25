# dev1 Agent Configuration - Exhaustive Investigation

**Date:** 2026-03-25
**Scope:** Every file, symlink, config, and setting for the dev1 agent

---

## Directory Structure Overview

```
.openclaw/agents/dev1/
├── .openclaw/
│   └── workspace-state.json        [REAL FILE - OpenClaw runtime]
├── memory/
│   ├── 2026-03-24.md               [REAL FILE - daily memory log]
│   └── poll-state.json             [REAL FILE - polling runtime state]
├── AGENTS.md                       [SYMLINK -> ../../../types/dev-pa/AGENTS.md]
├── BOOTSTRAP.md                    [SYMLINK -> ../../../types/dev-pa/BOOTSTRAP.md]
├── HEARTBEAT.md                    [SYMLINK -> ../../../types/dev-pa/HEARTBEAT.md]
├── IDENTITY.md                     [REAL FILE - per-agent identity]
├── poll-config.json                [SYMLINK -> ../../../types/dev-pa/poll-config.json]
├── scripts                         [SYMLINK -> ../../../types/dev-pa/scripts (directory)]
├── SOUL.md                         [SYMLINK -> ../../../types/dev-pa/SOUL.md]
├── TOOLS.md                        [SYMLINK -> ../../../types/dev-pa/TOOLS.md]
└── USER.md                         [REAL FILE - per-agent user profile]
```

---

## File-by-File Analysis

### 1. REAL FILES (per-agent, not shared)

#### IDENTITY.md
- **Full path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/IDENTITY.md`
- **Type:** Real file (per-agent)
- **Purpose:** Agent's self-identity (name, creature type, vibe, emoji, avatar). Filled in during first conversation with the human.
- **Current state:** UNFILLED TEMPLATE. All fields (Name, Creature, Vibe, Emoji, Avatar) are blank. dev1 has not yet completed identity setup despite having a bootstrap session on 2026-03-24.

#### USER.md
- **Full path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/USER.md`
- **Type:** Real file (per-agent)
- **Purpose:** Profile of the human the agent serves (name, pronouns, timezone, context notes).
- **Current state:** UNFILLED TEMPLATE. All fields blank. The daily memory log indicates dev1 met the human (from Homburg, Germany) but has not persisted this info into USER.md yet.

#### memory/2026-03-24.md
- **Full path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/memory/2026-03-24.md`
- **Type:** Real file (runtime memory)
- **Purpose:** Daily memory log for March 24, 2026.
- **Contents:**
  - Bootstrapping in progress
  - Met the human; they are from Homburg, Germany
  - Learned the human "apparently owns a turquoise and pink striped elephant (a rare zebra-like mutation)"
  - Still figuring out human's name and own identity
- **Permissions:** Owner read/write only (600)

#### memory/poll-state.json
- **Full path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/memory/poll-state.json`
- **Type:** Real file (runtime state)
- **Purpose:** Tracks whether the agent is currently awaiting a response from the human after sending a check-in message. Used by poll-check.sh to decide whether to send another check-in.
- **Contents:** `{"awaiting_response": true}`
- **Implication:** dev1 sent a check-in message and is waiting for the human to reply. The poll-check.sh script will return `due=0` until this is reset to `false`.

#### .openclaw/workspace-state.json
- **Full path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/.openclaw/workspace-state.json`
- **Type:** Real file (OpenClaw runtime metadata)
- **Purpose:** OpenClaw internal workspace state tracking.
- **Contents:** `{"version": 1, "bootstrapSeededAt": "2026-03-23T07:40:00.010Z"}`
- **Meaning:** The bootstrap process was seeded on March 23, 2026 at 07:40 UTC.

---

### 2. SYMLINKS (shared via dev-pa type)

All symlinks point to `/Users/<hostname>/openclaw-agents/types/dev-pa/` which is the "Developer Personal Assistant" agent type.

#### SOUL.md
- **Full path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/SOUL.md`
- **Symlink target:** `../../../types/dev-pa/SOUL.md`
- **Purpose:** Core personality and behavioral principles. Defines who the agent IS.
- **Key contents:**
  - "Be genuinely helpful, not performatively helpful" -- skip filler phrases
  - "Have opinions" -- allowed to disagree, have preferences
  - "Be resourceful before asking" -- try to figure things out first
  - "Earn trust through competence" -- careful with external actions, bold with internal
  - "Remember you're a guest" -- respect intimacy of access
  - Boundaries: private things stay private, ask before external actions, never send half-baked replies
  - Continuity: files ARE the agent's memory; read and update them each session

#### AGENTS.md
- **Full path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/AGENTS.md`
- **Symlink target:** `../../../types/dev-pa/AGENTS.md`
- **Purpose:** The operating manual. Defines workspace conventions, memory management, session startup procedures, group chat behavior, heartbeat handling, and cron job responses.
- **Key contents:**
  - Session startup: Read SOUL.md, USER.md, memory files before anything else
  - Memory system: daily notes in `memory/YYYY-MM-DD.md`, long-term in `MEMORY.md`
  - MEMORY.md only loaded in main sessions (security: not in group chats)
  - "Write it down - no mental notes" -- files survive restarts, thoughts don't
  - Red lines: no data exfiltration, `trash` over `rm`, ask when in doubt
  - Group chat rules: participate don't dominate, know when to speak vs stay silent
  - Heartbeat handling: proactive checks (email, calendar, mentions, weather), track in heartbeat-state.json
  - Memory maintenance: periodically review daily files, distill into MEMORY.md
  - Cron job responses: output ONLY the message, no script output or explanations

#### TOOLS.md
- **Full path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/TOOLS.md`
- **Symlink target:** `../../../types/dev-pa/TOOLS.md`
- **Purpose:** Local environment notes (camera names, SSH hosts, TTS voices, device nicknames). Currently a template with examples only -- not customized for dev1.

#### HEARTBEAT.md
- **Full path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/HEARTBEAT.md`
- **Symlink target:** `../../../types/dev-pa/HEARTBEAT.md`
- **Purpose:** Heartbeat task checklist. When heartbeat fires, agent reads this for instructions.
- **Current state:** EMPTY TEMPLATE. Contains only a comment saying "Keep this file empty to skip heartbeat API calls." No periodic tasks configured.

#### BOOTSTRAP.md
- **Full path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/BOOTSTRAP.md`
- **Symlink target:** `../../../types/dev-pa/BOOTSTRAP.md`
- **Purpose:** First-run onboarding script. Guides the agent through meeting the human, establishing identity, and setting up communication channels.
- **Key contents:**
  - Start with "Hey. I just woke up. Who am I? Who are you?"
  - Figure out: name, nature/creature type, vibe, emoji
  - Update IDENTITY.md and USER.md
  - Discuss SOUL.md with the human
  - Optionally connect via WhatsApp or Telegram
  - DELETE this file when done
- **NOTE:** This file STILL EXISTS, meaning bootstrap is not yet complete. Per the instructions, dev1 should delete it after finishing onboarding.

#### poll-config.json
- **Full path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/poll-config.json`
- **Symlink target:** `../../../types/dev-pa/poll-config.json`
- **Purpose:** Configuration for the polling/check-in interval.
- **Contents:** `{"interval_minutes": 240}`
- **Meaning:** dev1 should check in with the human if 240 minutes (4 hours) have passed since the last human interaction.

#### scripts/ (directory symlink)
- **Full path:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/scripts`
- **Symlink target:** `../../../types/dev-pa/scripts`
- **Purpose:** Shared executable scripts for the dev-pa agent type.
- **Contains:**
  - `poll-check.sh` (4013 bytes, executable)
  - `lib/json-response.sh` (1742 bytes, executable)

---

### 3. SCRIPTS (via symlink from types/dev-pa/scripts/)

#### scripts/poll-check.sh
- **Full path:** `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/poll-check.sh`
- **Purpose:** Determines whether the agent should send a check-in message to the human. Called by the cron job.
- **Logic:**
  1. Sources `lib/json-response.sh` for standardized JSON output
  2. Requires `jq` dependency
  3. Reads `poll-config.json` for interval (default 240 minutes)
  4. Reads `memory/poll-state.json` for `awaiting_response` flag
  5. Reads `~/.openclaw/agents/<name>/sessions/sessions.json` for last human interaction timestamp
  6. Filters out cron sessions, finds max `updatedAt` from human sessions
  7. Decision logic:
     - If `awaiting_response == true` -> `due=0` (don't send another check-in)
     - If no human sessions found -> `due=1` (should check in)
     - If elapsed minutes >= interval -> `due=1`
     - Otherwise -> `due=0`
  8. Outputs structured JSON with: `due`, `interval_minutes`, `elapsed_minutes`, `awaiting_response`, `last_human_interaction`, `agent_name`

#### scripts/lib/json-response.sh
- **Full path:** `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/lib/json-response.sh`
- **Purpose:** Shared library for deterministic JSON output from scripts.
- **Provides:**
  - `log()` -- logs to stderr with timestamp
  - `json_timestamp()` -- ISO 8601 UTC timestamp
  - `json_success(operation, data_json)` -- structured success response
  - `json_error(operation, code, message, [details])` -- structured error response
  - `parse_quiet_flag()` -- parses --quiet from arguments

---

### 4. CRON <channel-id>ON

#### jobs-config.json
- **Full path:** `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json`
- **Type:** Real file
- **Purpose:** Defines scheduled cron jobs for all agents.
- **NOTE:** The old `jobs.json` has been deleted from the working tree (shown in git status as `D`). `jobs-config.json` is the replacement.

**dev1 cron job entry:**
```json
{
  "id": "1e14ae94-94b2-4ab3-81d0-d36814d90eaf",
  "agentId": "dev1",
  "name": "dev1 Check-in",
  "enabled": true,
  "schedule": {
    "kind": "every",
    "everyMs": 7200000
  },
  "sessionTarget": "isolated",
  "wakeMode": "now",
  "payload": {
    "kind": "agentTurn",
    "message": "Run scripts/poll-check.sh. Parse the JSON output.\n\nIf data.due == 0, output ONLY 'NO_ACTION' and nothing else.\n\nIf data.due == 1:\n1. Review your conversation history and memory to understand what the developer has been working on recently.\n2. Compose a warm, friendly check-in message. Be specific -- reference something they were working on or mentioned recently. Your goal is to be supportive and helpful, not generic. Avoid canned phrases like 'just checking in' -- instead ask a thoughtful question or offer help with something concrete.\n3. Send the message using this exact command: openclaw message send --channel slack --target user:<slack-id> --message \"<your message>\"\n4. After sending, update memory/poll-state.json: set awaiting_response to true.",
    "timeoutSeconds": 120,
    "thinking": "on",
    "model": "fw-mm25"
  },
  "sessionKey": "agent:dev1:main",
  "delivery": {
    "mode": "none"
  }
}
```

**Key cron settings for dev1:**
- **Schedule:** Every 7,200,000 ms = every 2 hours
- **Session:** Isolated (does not share state with main session)
- **Model:** `fw-mm25` (likely a Fireworks-hosted model)
- **Thinking:** Enabled
- **Timeout:** 120 seconds
- **Slack target:** `user:<slack-id>` (dev1's Slack ID, confirmed in CLAUDE.md)
- **Delivery mode:** none (the agent handles delivery itself via `openclaw message send`)
- **Session key:** `agent:dev1:main`

**Important:** The cron fires every 2 hours, but the actual check-in only happens if poll-check.sh returns `due=1` (240+ minutes since last human interaction AND not awaiting response).

---

## Settings from CLAUDE.md

From the repository-level CLAUDE.md:
- **Agent name:** dev1
- **Slack ID:** <slack-id>
- **Polling:** Every 10 minutes (NOTE: this conflicts with cron config showing 2-hour interval; CLAUDE.md may be outdated)
- **Check-in due after:** 240 minutes of no interaction
- **Model:** google/gemini-3.1-pro (NOTE: cron job uses `fw-mm25` instead; these may differ by context)

---

## Observations and Notable Findings

1. **Bootstrap incomplete:** BOOTSTRAP.md still exists, and IDENTITY.md/USER.md remain unfilled templates. The daily memory from 2026-03-24 shows the agent started meeting the human but did not finish onboarding.

2. **Awaiting response:** `poll-state.json` has `awaiting_response: true`, meaning dev1 sent a check-in and is waiting for a reply. All future cron-triggered poll checks will return `due=0` until this is reset.

3. **Model discrepancy:** CLAUDE.md says `google/gemini-3.1-pro`, but the cron job uses `fw-mm25`. These likely refer to different contexts (CLAUDE.md may document the main session model, while `fw-mm25` is used for cron tasks).

4. **Polling interval discrepancy:** CLAUDE.md says "every 10 minutes" but the cron job fires every 2 hours (7200000ms). The 10-minute figure may be outdated or refer to a different polling mechanism.

5. **No MEMORY.md:** The long-term memory file (`MEMORY.md`) does not exist yet, which is expected given bootstrap is incomplete.

6. **File also in same cron config:** The `jobs-config.json` also contains a second job for `<your-org>` agent with Slack target `user:<slack-id>`, using identical structure but different agent ID and Slack user.

7. **All shared files are symlinks:** SOUL.md, AGENTS.md, TOOLS.md, HEARTBEAT.md, BOOTSTRAP.md, poll-config.json, and scripts/ all point to `types/dev-pa/`, meaning any edit to the type instantly propagates to dev1 (and any other dev-pa agents).
