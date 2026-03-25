# Research: How `last_interaction` in poll-state.json Gets Updated

**Date:** 2026-03-25
**Status:** Complete
**Classification:** Actionable (design bug identified)

---

## Executive Summary

**`last_interaction` is ONLY updated by the cron job itself. There is NO mechanism for the main agent session (human chatting with the agent) to update this timestamp.** This means the "idle timeout" logic is fundamentally broken -- it measures time since the last cron-triggered check-in, not time since the last actual human interaction.

---

## Finding 1: Who Writes to poll-state.json?

There are exactly **two writers** to `poll-state.json`, and both are cron-triggered:

### Writer 1: The cron job payload (via agent LLM)

In `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs.json`:

- **dev1 (line 46):** The cron payload instructs the agent: "...then update memory/poll-state.json with timestamp"
- **<your-org> (line 82):** The cron payload instructs the agent: "...Use the 'write' tool to update memory/poll-state.json with current timestamp"

Both cron jobs run in `"sessionTarget": "isolated"` sessions, meaning they are completely disconnected from the main conversation session.

### Writer 2: poll-check.sh (initialization only)

In `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/poll-check.sh` (lines 30-35):

The script creates a default `poll-state.json` with the current timestamp ONLY if the file does not exist. This is a one-time initialization, not an ongoing update mechanism.

### No Other Writers Exist

Exhaustive search confirmed:
- No Claude hooks (`.claude/hooks/`) reference poll-state.json or last_interaction
- No OpenClaw skills (`cc-openclaw/`) write to poll-state.json
- No session startup logic in `AGENTS.md` updates poll-state.json
- No other shell scripts write to this file
- `HEARTBEAT.md` is a blank template with no interaction tracking
- `AGENTS.md` Session Startup section (lines 9-17) reads memory files but never writes to poll-state.json

---

## Finding 2: What Does AGENTS.md Say About Updating poll-state.json?

**Nothing.** The Session Startup instructions (lines 9-17) tell the agent to:
1. Read SOUL.md
2. Read USER.md
3. Read memory/YYYY-MM-DD.md
4. If in main session, read MEMORY.md

There is no instruction to update `last_interaction` when a human initiates a conversation or during any main session activity.

---

## Finding 3: What Does HEARTBEAT.md Say?

**Nothing relevant.** The file at `/Users/<hostname>/openclaw-agents/types/dev-pa/HEARTBEAT.md` is a blank template with only a comment about keeping it empty.

AGENTS.md does mention heartbeat behavior (lines 128-208) including proactive checks and tracking in `memory/heartbeat-state.json`, but this is a separate state file from `poll-state.json` and has no bearing on the `last_interaction` timestamp.

---

## Finding 4: The Cron Job Flow

The complete flow for both agents:

```
1. OpenClaw cron fires (every 28800000ms = 8 hours)
2. Isolated session spawns
3. Agent runs scripts/poll-check.sh
4. poll-check.sh reads last_interaction from poll-state.json
5. Compares elapsed time against interval_minutes (240 min)
6. Returns JSON with {due: 0|1}
7. If due == 1:
   a. Agent sends Slack message
   b. Agent writes updated timestamp to poll-state.json  <-- ONLY update point
8. If due == 0:
   a. Agent outputs "NO_ACTION"
   b. poll-state.json is NOT updated
```

---

## Finding 5: The Design Bug

### The Intended Behavior (inferred)
The system appears designed so that if the human has not interacted with the agent for 240 minutes (4 hours), the agent should proactively check in via Slack.

### The Actual Behavior
The system checks if the cron job itself last ran a check-in more than 240 minutes ago. Human interaction is completely invisible to this mechanism.

### Concrete Scenario Demonstrating the Bug

1. **T+0h:** Cron fires, sends check-in, writes `last_interaction = T+0h`
2. **T+1h:** Human chats with agent for 2 hours in main session (last_interaction NOT updated)
3. **T+3h:** Human finishes chatting
4. **T+4h:** Cron fires, reads `last_interaction = T+0h`, calculates 4h elapsed >= 4h interval, `due = 1`
5. Agent sends check-in to Slack saying "Hey! Just checking in. How's it going?" -- despite the human having just been chatting 1 hour ago

Conversely:
1. **T+0h:** Cron fires, check-in not due, no action, `last_interaction` stays at previous value
2. **T+4h:** Cron fires, sends check-in, writes `last_interaction = T+4h`
3. **T+5h through T+11h:** Human is completely absent, no interaction at all
4. **T+12h:** Cron fires, reads `last_interaction = T+4h`, 8h elapsed >= 4h, sends check-in
5. This happens to work correctly, but only because the cron interval (8h) is longer than the poll interval (4h)

### Current Mitigation (Accidental)
The cron jobs are now set to `everyMs: 28800000` (8 hours), and the poll interval is 240 minutes (4 hours). Since the cron fires every 8 hours and the threshold is 4 hours, `due` will almost always be `1` when the cron fires. This effectively converts the "idle check-in" into a "periodic check-in every 8 hours" -- which may be acceptable behavior, but it is NOT what the architecture suggests was intended.

---

## Finding 6: Schema Divergence Between Agents

The two agents have different poll-state.json schemas:

**dev1** (`/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/memory/poll-state.json`):
```json
{
  "interval_minutes": 240,
  "last_interaction": "2026-03-25T00:30:00Z"
}
```

**<your-org>** (`/Users/<hostname>/openclaw-agents/.openclaw/agents/<your-org>/memory/poll-state.json`):
```json
{
  "last_check": "2026-03-25T00:31:30Z",
  "last_interaction": "2026-03-25T00:31:30Z",
  "interval_minutes": 240
}
```

<your-org> has an extra `last_check` field (same value as `last_interaction`). This is likely because the cron payload for <your-org> uses a different instruction format that results in the agent writing slightly different JSON. The `poll-check.sh` script only reads `interval_minutes` and `last_interaction`, so `last_check` is ignored.

---

## Recommendations

### Option A: Accept "Periodic Check-in" Semantics (Minimal Change)
If the goal is simply "check in every N hours regardless of human activity," the current system works fine with the 8-hour cron interval. Rename `last_interaction` to `last_checkin` to clarify semantics, and remove the misleading 240-minute interval (or set it to match the cron interval).

### Option B: Add Main Session Interaction Tracking (Correct Fix)
To implement true idle-timeout behavior:

1. **Add an instruction to AGENTS.md Session Startup** (around line 16):
   ```
   5. Update memory/poll-state.json with current timestamp (set last_interaction to now)
   ```

2. **Or add a session hook** that writes to poll-state.json when the main session starts. Currently no such hook mechanism exists in the `.claude/hooks/` directory for this purpose.

3. **Or use OpenClaw's session events** (if the platform supports session-start callbacks) to update the timestamp.

The challenge with Option B is that the cron job runs in an `"isolated"` session, so it reads a file that the main session writes to. This should work since both sessions share the same filesystem, but race conditions are possible.

### Option C: Use OpenClaw Platform-Level Activity Detection
If OpenClaw tracks session activity internally (e.g., `lastRunAtMs` in the cron state), the cron payload could be modified to check platform-level activity rather than a file-based timestamp.

---

## Files Examined

| File | Path | Relevance |
|------|------|-----------|
| poll-state.json (dev1) | `.openclaw/agents/dev1/memory/poll-state.json` | Primary state file |
| poll-state.json (<your-org>) | `.openclaw/agents/<your-org>/memory/poll-state.json` | Primary state file |
| poll-check.sh | `types/dev-pa/scripts/poll-check.sh` | Reads last_interaction, calculates due |
| jobs.json | `.openclaw/cron/jobs.json` | Cron payloads that instruct agent to update poll-state |
| AGENTS.md | `types/dev-pa/AGENTS.md` | Session startup instructions (no poll-state update) |
| HEARTBEAT.md | `types/dev-pa/HEARTBEAT.md` | Blank template (no interaction tracking) |
| openclaw.sh hook | `.claude/hooks/blockers/openclaw.sh` | CLI blocker only, no poll-state interaction |
| Prior research | `docs/research/duplicate-slack-replies-race-condition-2026-03-24.md` | Related findings on race conditions |
| Prior research | `docs/research/agent-memory-isolation-audit-2026-03-24.md` | Related findings on state divergence |
