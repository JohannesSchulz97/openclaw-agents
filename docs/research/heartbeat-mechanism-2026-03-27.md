# Heartbeat Mechanism Research

**Date:** 2026-03-27
**Researcher:** Claude Opus 4.6 (Research Agent)
**Classification:** Informational

---

## Executive Summary

The "heartbeat" in openclaw-agents refers to **two distinct but related concepts** that are often conflated in documentation:

1. **OpenClaw Heartbeat** -- A built-in OpenClaw platform feature that periodically wakes agents. The `HEARTBEAT.md` file is read by the agent during these wakes. Currently **effectively disabled** (the file contains only a comment telling agents to skip heartbeat API calls).

2. **Cron Check-in Jobs** -- Custom cron jobs that run `poll-check.sh` every 2 hours. These are the **actual active mechanism** performing periodic developer check-ins. All 18 dev-pa agents have enabled cron check-in jobs that are actively running.

The CLAUDE.md documentation says "Heartbeat: every 10 minutes" for each agent, but this refers to the OpenClaw platform heartbeat interval, not the cron check-in jobs. The cron check-in jobs run every 2 hours and only send a Slack message if the developer has been inactive for 240 minutes (4 hours).

---

## Component Breakdown

### 1. HEARTBEAT.md (Effectively Empty / Disabled)

**File:** `/Users/<hostname>/openclaw-agents/types/dev-pa/HEARTBEAT.md`

Contains only a template comment instructing agents to keep it empty to skip heartbeat API calls. This means the OpenClaw platform heartbeat (which fires every 10 minutes per CLAUDE.md) results in the agent replying `HEARTBEAT_OK` and doing nothing productive.

The AGENTS.md does describe productive heartbeat uses (checking inbox, calendar, weather, memory maintenance), but since HEARTBEAT.md is empty, none of these actually execute.

### 2. poll-config.json (Inactivity Threshold)

**File:** `/Users/<hostname>/openclaw-agents/types/dev-pa/poll-config.json`

```json
{ "interval_minutes": 240 }
```

Sets the inactivity threshold to 240 minutes (4 hours). If a developer has not interacted with their agent for 4+ hours, the check-in becomes "due."

### 3. poll-check.sh (Decision Engine)

**File:** `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/poll-check.sh`

This is the core logic script. It:

1. Reads `poll-config.json` for the interval (240 min default)
2. Reads `memory/poll-state.json` for `awaiting_response` flag
3. Queries `sessions.json` to find the last human (non-cron) interaction timestamp
4. Calculates elapsed minutes since last human interaction
5. Outputs JSON with `due: 0` or `due: 1`

**Decision logic:**
- If `awaiting_response == true` (already sent a check-in, waiting for reply): `due = 0` (do not send another)
- If no human sessions found: `due = 1` (should check in)
- If elapsed >= 240 minutes: `due = 1`
- Otherwise: `due = 0`

### 4. Cron Check-in Jobs (The Active Mechanism)

**Config:** `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json`

Each dev-pa agent has a cron job with:
- **Schedule:** Every 7,200,000 ms (2 hours)
- **Model:** openai-codex/gpt-5.4
- **Session:** Isolated (does not share context with main conversation)
- **Timeout:** 180 seconds
- **Enabled:** true for all agents

**Cron job workflow (when triggered every 2 hours):**
1. Run `poll-check.sh` and parse JSON output
2. If `data.due == 0`: output `NO_ACTION` and stop
3. If `data.due == 1`:
   a. Read USER.md for developer name, context, GitHub usernames
   b. Read IDENTITY.md for target Slack user ID
   c. Optionally run `github-activity.sh` to gather recent GitHub activity
   d. Review conversation history for context
   e. Compose a casual 2-3 sentence check-in message via Slack DM
   f. Send via `openclaw message send --channel slack --target user:<SLACK_ID>`
   g. Set `awaiting_response: true` in `memory/poll-state.json`

### 5. Runtime Status (Active and Running)

`openclaw cron list` confirms **all 18 dev-pa check-in jobs are active**:
- 17 agents show status "ok" with "Last" timestamps of 1-2 hours ago
- 1 agent (dev10) shows status "idle" (has not run yet, next run in ~2 hours)
- All scheduled at "every 2h"

Additionally, 3 tech-manager jobs are running (hourly monitoring, morning report, evening report).

---

## Relationship: Heartbeat vs. Cron Check-in

| Aspect | OpenClaw Heartbeat | Cron Check-in |
|--------|-------------------|---------------|
| **Trigger** | OpenClaw platform, every 10 min | Cron scheduler, every 2 hours |
| **Config file** | HEARTBEAT.md | jobs-config.json + poll-config.json |
| **Currently active?** | Fires but does nothing (HEARTBEAT.md empty) | Yes, actively sending Slack messages |
| **Session type** | Main session (has conversational context) | Isolated session (no shared context) |
| **Purpose (designed)** | Batch checks: inbox, calendar, memory maintenance | Developer check-in via Slack DM |
| **Purpose (actual)** | Agent replies HEARTBEAT_OK | Sends check-in if developer inactive 4+ hours |

The AGENTS.md describes the heartbeat as an opportunity for proactive behavior (checking inbox, weather, memory maintenance), but since HEARTBEAT.md is empty, this is dormant functionality. The cron check-in jobs are doing the actual periodic outreach work.

---

## Notable Gap: Missing Agent

Agent **malarvizhi** (Slack ID: <slack-id>) is listed in CLAUDE.md but has **no cron check-in job** in `jobs-config.json`. This agent will not receive periodic check-ins unless a job is added.

---

## Key Files

- `/Users/<hostname>/openclaw-agents/types/dev-pa/HEARTBEAT.md` -- Empty template (heartbeat disabled)
- `/Users/<hostname>/openclaw-agents/types/dev-pa/AGENTS.md` -- Documents heartbeat behavior and guidance
- `/Users/<hostname>/openclaw-agents/types/dev-pa/poll-config.json` -- 240-minute inactivity threshold
- `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/poll-check.sh` -- Decision engine script
- `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json` -- All cron job definitions (source of truth)
