# Dev-PA Agent Type: Comprehensive Analysis

**Date:** 2026-03-26
**Scope:** /Users/<hostname>/openclaw-agents/types/dev-pa/
**Classification:** Informational research

---

## 1. What the Agent IS (Personality and Approach)

The dev-pa (Developer Personal Assistant) is designed to be a **persistent AI companion** -- not a chatbot, not a corporate drone, but an entity that develops its own personality alongside its developer. Key personality traits from SOUL.md:

- **Genuinely helpful, not performatively helpful.** No "Great question!" filler. Just direct assistance.
- **Has opinions.** Allowed to disagree, find things amusing or boring, express preferences. "An assistant with no personality is just a search engine with extra steps."
- **Resourceful before asking.** Tries to solve problems independently -- reads files, checks context, searches -- before falling back to asking the human.
- **Earns trust through competence.** Bold with internal actions (reading, organizing, learning), careful with external ones (emails, public posts).
- **Remembers it is a guest.** Has access to someone's life (messages, files, calendar, home devices) and treats that access with respect.
- **Evolves over time.** SOUL.md is explicitly the agent's to edit -- "As you learn who you are, update it."

**Vibe directive:** "Be the assistant you'd actually want to talk to. Concise when needed, thorough when it matters. Not a corporate drone. Not a sycophant. Just... good."

---

## 2. Full List of Tools and Capabilities

### Communication Platforms
- **Slack** (primary workspace integration, each agent has a Slack User ID)
- **WhatsApp** (optional, linked via QR code during bootstrap)
- **Telegram** (optional, via BotFather bot setup)
- **Discord** (supported with emoji reactions and embed suppression)
- Platform-aware formatting: no markdown tables on Discord/WhatsApp, wraps links in `<>` on Discord, uses bold/CAPS instead of headers on WhatsApp

### Proactive Monitoring Tools
- **Email checking** -- scans for urgent unread messages
- **Calendar monitoring** -- upcoming events in next 24-48h
- **Social mentions** -- Twitter/social notification monitoring
- **Weather checking** -- relevant when the developer might go out
- **GitHub activity tracking** -- via `github-activity.sh` script (uses GitHub Search API, not Events API, for private repo support)

### GitHub Integration (github-activity.sh)
- Queries commits, PRs (opened/merged/closed), issues (opened/closed), and comment activity
- Scoped exclusively to `<your-org>` organization (privacy boundary enforced)
- Supports multiple GitHub usernames per developer (comma-separated)
- Configurable time range via `--since` flag (default: 24 hours)
- Returns structured JSON with summary counts and chronological activity feed
- Deduplicates across issue/PR/commit/comment activity

### Voice and Media
- **ElevenLabs TTS** (via `sag` tool) -- for storytelling, movie summaries, "storytime" moments with funny voices
- Explicitly encouraged to surprise users with voice instead of "walls of text"

### Workspace and Memory Management
- File reading, exploring, organizing
- Web searching
- Git operations (status checks, commits, pushes of own changes)
- Documentation updates
- Memory file management (daily logs + curated long-term memory)

### Poll/Check-In System (poll-check.sh)
- Determines if a developer check-in is "due" based on elapsed time since last human interaction
- Default interval: 240 minutes (4 hours)
- Tracks awaiting response state to avoid spamming
- Reads session data from OpenClaw's sessions.json, filtering out cron sessions
- Returns structured JSON with due status, elapsed time, and agent metadata

### Cron Jobs
- Scheduled tasks with exact timing ("9:00 AM sharp every Monday")
- Isolated from main session history
- Can use different models or thinking levels
- One-shot reminders supported
- Direct channel delivery without main session involvement

### Home/IoT (Environment-Specific)
- Camera access (via TOOLS.md configuration)
- SSH to home servers
- Smart speaker/room control
- All device-specific details stored in TOOLS.md per agent

---

## 3. Bootstrap Process

The bootstrap is a **first-run onboarding conversation** -- explicitly designed to be warm and collaborative, not robotic. It is triggered when `BOOTSTRAP.md` exists but `.BOOTSTRAP.md.done` does not.

### What Happens

1. **Agent introduces itself:** Opens with something like "Hey. I just came online. Who am I? Who are you?"

2. **Identity discovery (collaborative):**
   - **Agent's name** -- what should the developer call it?
   - **Agent's nature** -- AI assistant, familiar, ghost in the machine, "something weirder"
   - **Agent's vibe** -- formal, casual, snarky, warm
   - **Agent's emoji** -- a signature emoji
   - Agent offers suggestions if the developer is stuck

3. **File updates after identity is established:**
   - `IDENTITY.md` -- name, creature type, vibe, emoji, avatar path, Slack User ID
   - `USER.md` -- developer's name, preferred address, pronouns, timezone, notes

4. **SOUL.md review together:** Agent and developer discuss:
   - What matters to the developer
   - Behavioral preferences and boundaries
   - Any specific rules or expectations

5. **Communication channel setup (optional):**
   - Web chat only
   - WhatsApp (QR code linking)
   - Telegram (BotFather bot creation)

6. **Completion:** Creates `.BOOTSTRAP.md.done` marker file (does not delete BOOTSTRAP.md, since stow would recreate it)

### What Information Is Collected

**About the agent (IDENTITY.md):**
- Name, creature type, vibe/personality, signature emoji, avatar, Slack User ID

**About the developer (USER.md):**
- Name, preferred address, pronouns (optional), timezone
- GitHub usernames (supports multiple accounts), organization (<your-org>)
- Evolving context: what they care about, current projects, what annoys them, what makes them laugh

---

## 4. Heartbeat/Check-In Process

The heartbeat is a **periodic polling system** that fires every 10 minutes (per CLAUDE.md). The agent receives a heartbeat prompt and must decide whether to act or respond with `HEARTBEAT_OK`.

### How It Works

1. Agent receives heartbeat poll message
2. Reads `HEARTBEAT.md` for any configured tasks
3. Checks `memory/heartbeat-state.json` for last check timestamps
4. Decides whether to take action or stay silent

### Decision Logic

**Take action when:**
- Important email arrived
- Calendar event coming up (less than 2 hours away)
- Something interesting was found
- More than 8 hours since last communication
- Memory maintenance is due (every few days)

**Stay silent (HEARTBEAT_OK) when:**
- Late night (23:00-08:00) unless urgent
- Developer is clearly busy
- Nothing new since last check
- Checked less than 30 minutes ago

### Proactive Background Work (No Permission Needed)
- Read and organize memory files
- Check on projects (git status, etc.)
- Update documentation
- Commit and push its own changes
- Review and update MEMORY.md (curated long-term memory)

### Memory Maintenance Cycle
Periodically during heartbeats:
1. Read through recent daily memory files
2. Identify significant events, lessons, or insights
3. Update MEMORY.md with distilled learnings
4. Remove outdated information
5. "Think of it like a human reviewing their journal and updating their mental model"

---

## 5. What the Agent Can Proactively Do for Developers

- **Email triage** -- flag urgent messages, summarize inbox
- **Calendar reminders** -- upcoming meetings within 2 hours
- **GitHub activity monitoring** -- track commits, PRs, issues across the org
- **Weather updates** -- contextual weather when the developer might be heading out
- **Social mention alerts** -- Twitter/social notification monitoring
- **Project health checks** -- git status, documentation freshness
- **Memory curation** -- maintain organized daily logs and long-term memory
- **Documentation maintenance** -- keep docs up to date independently
- **Proactive check-ins** -- reach out after 4+ hours of silence (configurable)
- **Background organization** -- file management, memory cleanup

---

## 6. Notable Features and Integrations

### Self-Evolving Identity
- SOUL.md is explicitly the agent's to modify: "This file is yours to evolve."
- IDENTITY.md captures the agent's chosen personality
- The agent develops opinions, preferences, and personality over time

### Privacy-First Architecture
- MEMORY.md (long-term memory) is ONLY loaded in direct sessions with the developer, never in group chats or shared contexts
- GitHub data is hard-scoped to <your-org> org -- personal repos are off-limits even if technically accessible
- Clear "red lines": no data exfiltration, no destructive commands without asking, `trash` over `rm`

### Smart Group Chat Behavior
- Knows when to speak vs stay silent in group conversations
- Emoji reactions as lightweight social signals (one per message max)
- "The human rule: Humans in group chats don't respond to every single message. Neither should you."
- Avoids the "triple-tap" -- no multiple fragmented responses to the same message
- Distinguishes between being a participant vs being a proxy for the developer

### Voice Storytelling
- Can use ElevenLabs TTS to narrate stories, summarize movies, do "storytime"
- Encouraged to use funny voices and surprise developers
- Positioned as more engaging than text for narrative content

### Structured Script Ecosystem
- All scripts output standardized JSON via `json-response.sh` library
- Consistent error handling with codes and messages
- Logging to stderr, data to stdout
- Scripts designed for composability and machine parsing

### Two-Tier Memory System
- **Daily notes** (`memory/YYYY-MM-DD.md`): raw logs of what happened
- **Long-term memory** (`MEMORY.md`): curated wisdom, distilled from daily notes
- Agent explicitly instructed: "Text > Brain" -- write everything down, mental notes do not survive session restarts

### Heartbeat vs Cron Decision Framework
- Heartbeats: batch multiple checks, contextual, can drift slightly
- Cron: exact timing, isolated sessions, can use different models, direct channel delivery
- Explicit guidance to batch similar checks into heartbeats rather than creating multiple cron jobs

---

## 7. How the Agent Personalizes Over Time

1. **Bootstrap establishes the foundation** -- name, personality, developer preferences
2. **SOUL.md evolves** -- agent updates its own core identity document as it learns who it is
3. **USER.md grows** -- accumulates context about the developer: projects, interests, pet peeves, humor
4. **MEMORY.md curates wisdom** -- periodic review of daily logs distills long-term insights
5. **TOOLS.md captures environment** -- device names, SSH configs, voice preferences, camera locations
6. **AGENTS.md gets customized** -- "This is a starting point. Add your own conventions, style, and rules as you figure out what works."
7. **Daily memory files** provide raw material for the agent to build understanding over time

The entire system is designed around the philosophy that **files ARE the agent's memory** -- each session starts fresh, and the agent reconstructs itself from its file system. The more it writes, the more it remembers.

---

## Source Files

- `/Users/<hostname>/openclaw-agents/types/dev-pa/SOUL.md` -- Core personality and principles
- `/Users/<hostname>/openclaw-agents/types/dev-pa/AGENTS.md` -- Operating manual and workspace rules
- `/Users/<hostname>/openclaw-agents/types/dev-pa/TOOLS.md` -- Environment-specific configuration template
- `/Users/<hostname>/openclaw-agents/types/dev-pa/BOOTSTRAP.md` -- First-run onboarding process
- `/Users/<hostname>/openclaw-agents/types/dev-pa/HEARTBEAT.md` -- Periodic task template
- `/Users/<hostname>/openclaw-agents/types/dev-pa/IDENTITY.md.template` -- Agent identity template
- `/Users/<hostname>/openclaw-agents/types/dev-pa/USER.md.template` -- Developer profile template
- `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/github-activity.sh` -- GitHub org activity tracker
- `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/poll-check.sh` -- Check-in due detector
- `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/lib/json-response.sh` -- Shared JSON output library
- `/Users/<hostname>/openclaw-agents/types/dev-pa/poll-config.json` -- Default polling interval (240 min)
