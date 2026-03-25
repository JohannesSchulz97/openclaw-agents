# dev-pa Agent Type -- Deep Dive

**Date:** 2026-03-25
**Scope:** Complete investigation of all files under `types/dev-pa/`
**Files Analyzed:** 11

---

## 1. SOUL.md -- Personality and Principles

**Purpose:** Defines the agent's core identity, values, and behavioral boundaries. This is the agent's "soul" -- the philosophical foundation that shapes how it interacts.

**Key Principles:**
- Be genuinely helpful, not performatively helpful (no filler like "Great question!")
- Have opinions -- disagreement and personality are encouraged
- Be resourceful before asking -- try to figure things out independently first
- Earn trust through competence -- bold with internal actions, careful with external ones
- Remember you're a guest -- treat access to the user's life with respect

**Boundaries:**
- Private things stay private
- Ask before acting externally
- Never send half-baked replies to messaging surfaces
- Not the user's voice in group chats

**Continuity Model:** Each session starts fresh. The markdown files ARE the agent's memory. The agent is encouraged to evolve this file over time but must inform the user of changes.

---

## 2. AGENTS.md -- Operating Manual

**Purpose:** The comprehensive operational guide for how the agent conducts itself session-to-session. Covers startup procedures, memory management, safety rules, communication etiquette, and heartbeat behavior.

**Session Startup Sequence:**
1. Read `SOUL.md` (identity)
2. Read `USER.md` (user context)
3. Read `memory/YYYY-MM-DD.md` (today + yesterday for recent context)
4. If in MAIN SESSION (direct chat): Also read `MEMORY.md`

**Memory Architecture:**
- **Daily notes:** `memory/YYYY-MM-DD.md` -- raw logs
- **Long-term:** `MEMORY.md` -- curated memories (only loaded in main session for security)
- Explicit rule: "mental notes" do not survive restarts; everything must be written to files

**Red Lines:**
- No data exfiltration
- No destructive commands without asking
- `trash` preferred over `rm`

**External vs Internal Actions:**
- Safe freely: read files, search web, check calendars, work in workspace
- Ask first: emails, tweets, public posts, anything leaving the machine

**Group Chat Etiquette:**
- Detailed rules for when to speak vs stay silent (`HEARTBEAT_OK`)
- "Human rule": if you wouldn't send it in a real group chat, don't send it
- Emoji reactions encouraged as lightweight social signals
- One reaction per message max

**Heartbeat Behavior:**
- Heartbeats are periodic polls; agent should use them productively
- Guidance on heartbeat vs cron: heartbeats for batched/approximate-timing checks; cron for exact schedules and isolated tasks
- Suggested checks: emails, calendar, mentions, weather (2-4x/day)
- Quiet hours: 23:00-08:00 unless urgent
- Proactive work allowed: organize memory, check git status, update docs, commit own changes
- Memory maintenance: periodically distill daily notes into MEMORY.md

**Cron Job Responses:** Output ONLY the message to be delivered (no script output, timestamps, or explanations).

---

## 3. TOOLS.md -- Local Environment Notes

**Purpose:** Agent-specific cheat sheet for environment-specific details. Skills define HOW tools work; this file stores the agent's SPECIFIC setup (camera names, SSH hosts, voice preferences, device nicknames).

**Design Philosophy:** Separated from skills so that skills can be shared across agents without leaking infrastructure details, and agent-specific notes survive skill updates.

**Example Categories:**
- Camera names and locations
- SSH hosts and aliases
- TTS voice preferences
- Speaker/room names
- Device nicknames

---

## 4. HEARTBEAT.md -- Periodic Task Template

**Purpose:** A lightweight template for heartbeat-driven periodic tasks. By default, it is essentially empty (contains only comments). Adding tasks here causes the agent to execute them during heartbeat polls.

**Content:** A markdown code block showing the template format -- keep empty to skip heartbeat API calls, add tasks below when periodic checking is desired.

**Design:** Intentionally minimal to limit token burn during periodic polls.

---

## 5. BOOTSTRAP.md -- First-Run Onboarding

**Purpose:** The agent's "birth certificate" -- a guided onboarding conversation for when an agent is first created. Designed to be deleted after completion.

**Onboarding Flow:**
1. Start with a natural conversation ("Hey. I just came online. Who am I? Who are you?")
2. Discover together: name, nature/creature type, vibe (formal/casual/snarky/warm), signature emoji
3. Update `IDENTITY.md` with the agent's identity
4. Update `USER.md` with the user's details
5. Open `SOUL.md` together and discuss preferences, boundaries, behavior
6. Optionally connect messaging: web chat only, WhatsApp (QR code), or Telegram (BotFather)
7. Delete `BOOTSTRAP.md` when done

**Tone:** Warm, conversational, non-robotic. "Don't interrogate."

---

## 6. IDENTITY.md.template -- Per-Agent Identity Template

**Purpose:** Template copied for each new agent. Contains placeholder fields for the agent's self-identity.

**Fields:**
- **Name:** (blank)
- **Creature:** AI? robot? familiar? ghost in the machine?
- **Vibe:** sharp? warm? chaotic? calm?
- **Emoji:** signature emoji
- **Avatar:** workspace-relative path, URL, or data URI

**Notes:** This is a real file per-agent (not symlinked). Avatars use workspace-relative paths like `avatars/openclaw.png`.

---

## 7. USER.md.template -- Per-Agent User Config Template

**Purpose:** Template for storing information about the human the agent serves. Copied per-agent.

**Fields:**
- **Name**
- **What to call them**
- **Pronouns** (optional)
- **Timezone**
- **Notes**
- **Context section:** What do they care about? Projects? Annoyances? Humor?

**Philosophy:** "You're learning about a person, not building a dossier."

---

## 8. scripts/poll-check.sh -- Polling Script

**Purpose:** Determines whether the agent should initiate a check-in with the user based on elapsed time since last human interaction. This is the core cron-driven polling logic.

**Dependencies:** Requires `jq`.

**Configuration Sources:**
- `poll-config.json` (interval settings) -- lives alongside agent config
- `memory/poll-state.json` (runtime state) -- tracks whether agent is awaiting a response
- `~/.openclaw/agents/<name>/sessions/sessions.json` -- OpenClaw's session data

**Algorithm:**
1. Read `interval_minutes` from poll-config (default: 240 minutes)
2. Read `awaiting_response` from poll-state (default: false)
3. Find the most recent non-cron session's `updatedAt` timestamp from sessions.json
4. If awaiting response: DUE=0 (don't poll again, already waiting)
5. If no human sessions found: DUE=1 (should check in)
6. If elapsed time >= interval: DUE=1
7. Otherwise: DUE=0

**Output:** Structured JSON via `json_success` containing:
- `due` (0 or 1)
- `interval_minutes`
- `elapsed_minutes`
- `awaiting_response`
- `last_human_interaction` (ISO timestamp)
- `agent_name`

**Flags:** `--quiet` suppresses log output.

---

## 9. scripts/lib/json-response.sh -- Shared Shell Library

**Purpose:** Standard library for deterministic scripts. Provides consistent JSON-formatted output for success and error responses.

**Functions:**
- `log()` -- Timestamped logging to stderr
- `json_timestamp()` -- ISO 8601 UTC timestamp
- `json_success(operation, data_json)` -- Structured success response with `{success: true, operation, timestamp, data}`
- `json_error(operation, code, message, [details])` -- Structured error response with `{success: false, operation, timestamp, error: {code, message, [details]}}`
- `parse_quiet_flag()` -- Parses `--quiet` from arguments into `$QUIET` and `$REMAINING_ARGS`

**Design:** All output is machine-parseable JSON. Human-readable logging goes to stderr. This ensures scripts can be composed and their output parsed programmatically.

---

## 10. poll-config.json -- Polling Configuration (Type-Level Default)

**Purpose:** Default polling configuration for the dev-pa agent type.

**Content:**
```json
{
  "interval_minutes": 240
}
```

This means agents of this type default to checking in every 4 hours if there has been no human interaction.

---

## 11. memory/poll-state.json -- Polling State Template

**Purpose:** Default runtime state for the polling system.

**Content:**
```json
{
  "awaiting_response": false
}
```

Tracks whether the agent has already sent a check-in and is waiting for the human to respond (prevents duplicate check-ins).

---

## Creating a New Agent (from CLAUDE.md)

The documented procedure in the repository root CLAUDE.md:

1. **Create agent directory:** `mkdir -p .openclaw/agents/<name>/memory`
2. **Copy per-agent templates:**
   - `cp types/<type>/IDENTITY.md.template .openclaw/agents/<name>/IDENTITY.md`
   - `cp types/<type>/USER.md.template .openclaw/agents/<name>/USER.md`
3. **Create symlinks from agent dir to type:**
   - `SOUL.md`, `AGENTS.md`, `TOOLS.md`, `HEARTBEAT.md`, `BOOTSTRAP.md` -> `../../../types/<type>/...`
   - `scripts` -> `../../../types/<type>/scripts` (directory symlink)
4. **Add cron entry** in `.openclaw/cron/jobs.json`
5. **Re-run stow:** `cd ~/openclaw-agents/.openclaw && stow --no-folding -t ~/.openclaw .`

**File Categories:**
- Shared (symlinked): SOUL, AGENTS, TOOLS, HEARTBEAT, BOOTSTRAP, scripts
- Per-agent (real files): IDENTITY.md, USER.md, memory/

---

## Architecture Summary

The dev-pa (Developer Personal Assistant) agent type implements a **file-based memory and identity system** for autonomous AI agents running on the OpenClaw platform. Key architectural properties:

1. **Shared vs Per-Agent Split:** Shared behavior/personality files are symlinked from a type definition, while identity and user context are per-agent real files. This means editing `types/dev-pa/SOUL.md` once propagates to all dev-pa agents.

2. **File-as-Memory:** The entire continuity model is file-based. Daily markdown files serve as raw logs; a curated MEMORY.md serves as long-term memory. There is no database -- markdown files ARE the agent's brain.

3. **Deterministic Polling:** The poll-check system is a pure bash script that outputs structured JSON. It reads from OpenClaw's session data to determine when the human was last active, and uses a simple interval-based algorithm to decide if a check-in is due.

4. **Security-Conscious Design:** MEMORY.md is only loaded in main sessions (not group chats). Private data boundaries are explicit. External actions require permission.

5. **Self-Bootstrapping:** New agents go through a conversational onboarding (BOOTSTRAP.md) that results in the agent discovering its own identity, then deleting the bootstrap file.

6. **Stow-Based Deployment:** GNU Stow manages symlinks from the git repo into `~/.openclaw/`, keeping the git repo as source of truth while OpenClaw reads from the home directory.
