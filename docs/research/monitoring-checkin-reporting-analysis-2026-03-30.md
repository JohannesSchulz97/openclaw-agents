# Monitoring, Check-in, and Reporting Setup Analysis

**Date:** 2026-03-30
**Scope:** Full analysis of current data capture for priorities, blockers, workload, and capacity

---

## 1. Dev-PA Agent Check-ins (What Agents Report)

### Scheduling Model

Two coexisting models:

| Model | Script | Used By | Schedule |
|-------|--------|---------|----------|
| **Legacy (poll-based)** | `poll-check.sh` | Most agents (14 of 17) | Every 2h cron, `poll-check.sh` determines if due based on `interval_minutes` (default 240min) |
| **New (time-of-day)** | `checkin-guard.sh` | dev1 (3 fixed-time), dev5 (evening only) | Exact cron times: morning/midday/evening |

`poll-check.sh` is marked DEPRECATED but still the primary mechanism for most agents.

### Check-in Content (from cron payload)

Each dev-pa check-in message asks the developer:

1. **What they have been working on** since last check-in
2. **GitHub activity** (PRs, commits, reviews, issues) -- pulled from `github-activity.sh --since 24`
3. **Work NOT visible in GitHub** -- explicitly asks about meetings, design discussions, code reviews, research, architecture planning, pairing, mentoring, documentation
4. **Current blockers** or anything they need help with

### Check-in Tone Variations (dev1/dev5 with checkin-guard.sh)

| Time | Focus | Tone |
|------|-------|------|
| Morning | Plans and focus for the day | Energetic, forward-looking |
| Midday | Progress and what's keeping them busy | Collaborative, curious |
| Evening | Recap -- what went well, what didn't, carry-over | Reflective, appreciative |

### State Tracking

**poll-state.json (new schema):**
- `morning_responded`, `midday_responded`, `evening_responded` -- boolean per check-in slot
- `last_morning_epoch`, `last_midday_epoch`, `last_evening_epoch` -- timestamp of last check-in sent
- `missed_checkins` -- rolling counter
- `awaiting_response` -- boolean

**poll-state.json (old schema):**
- `awaiting_response` -- boolean
- `last_check_in` -- ISO timestamp

### Heartbeat (HEARTBEAT.md)

The dev-pa HEARTBEAT.md is essentially empty (template comment only). Agents are instructed in AGENTS.md to use heartbeats for:
- Email checking
- Calendar checking
- Social mentions
- Weather
- Memory maintenance

But no structured data is captured -- heartbeat is ad-hoc and proactive-behavior oriented.

---

## 2. Tech-Manager Agent Monitoring

### Cron Schedule

| Job | Frequency | Monitored Agents |
|-----|-----------|-----------------|
| **Hourly Monitoring** | Every 1h | dev1, dev10, dev10, dev10, dev10-jean (5 original only) + all 18 for cron-activation |
| **Morning Report** | Daily (86400000ms) | dev1, dev10, dev10, dev10, dev10-jean (5 only) |
| **Evening Report** | Daily (86400000ms) | dev1, dev10, dev10, dev10, dev10-jean (5 only) |

**Critical Gap:** Morning/evening reports and bottleneck/missed-checkin monitoring only cover 5 of 17 agents. The 12 newer agents (dev3, <github-username>, dev5, dev6, dev7, dev8, dev9, dev10, dev10, dev10, dev10, <your-org>) are NOT monitored by the tech-manager for bottlenecks or missed check-ins.

### check-bottlenecks.sh -- What It Detects

| Detection | Threshold | Severity | Data Source |
|-----------|-----------|----------|-------------|
| **Long-running sessions** | >2h continuous, updated within last 10min | Medium | `sessions/sessions.json` |
| **Possible loop** | >5 cron sessions with no human interaction for >2h | High | `sessions/sessions.json` |
| **Developer unresponsive** | Awaiting response for >8h | High | `memory/poll-state.json` |
| **Blocked keywords** | Keywords in last 3 days of notes: `blocked\|stuck\|waiting\|error\|failed\|can't proceed\|cannot proceed` | Medium | `memory/YYYY-MM-DD.md` |

### check-missed-checkins.sh -- What It Detects

- Counts missed check-ins based on elapsed time vs poll interval
- Supports both old schema (elapsed time calculation) and new schema (reads `missed_checkins` directly)
- **Threshold:** Default 3 (configurable via `--threshold`)
- **Severity levels:** `warning` (>= threshold), `critical` (>= threshold * 2)
- Skips agents not yet bootstrapped (missing `work-schedule.json` or `poll-state.json`)

### check-status.sh -- What It Reports (Morning/Evening)

Per agent:
- Last session activity timestamp
- Sessions today count
- Awaiting response boolean
- Poll state details
- Has recent daily notes (boolean + date)

Summary:
- Total agents, active today, awaiting response, inactive

### Morning Report Structure

- Team overview: X active, Y awaiting, Z inactive
- Per developer: status, GitHub activity (24h), last interaction
- Notable patterns/concerns

### Evening Report Structure

- Total commits, PRs, issues across team
- Per-developer breakdown of what shipped
- Bottlenecks and missed check-ins
- **Resource allocation suggestion** -- who is overloaded/underutilized, suggested rebalancing

---

## 3. Data Currently Captured

### What IS Captured

| Data Point | Where | By Whom |
|------------|-------|---------|
| **What developer is working on** | Check-in responses (free text in Slack) | Dev-PA agents |
| **GitHub activity** (PRs, commits, reviews) | `github-activity.sh` output | Dev-PA + Tech-Manager |
| **Non-GitHub work** | Check-in responses (explicitly asked) | Dev-PA agents |
| **Blockers** (keyword-based) | `memory/YYYY-MM-DD.md` grep | Tech-Manager `check-bottlenecks.sh` |
| **Response compliance** | `poll-state.json` | `checkin-guard.sh` / `poll-check.sh` |
| **Session activity** | `sessions/sessions.json` | OpenClaw runtime |
| **Agent availability** | `check-status.sh` | Tech-Manager |
| **Developer unresponsiveness** | >8h awaiting response | Tech-Manager `check-bottlenecks.sh` |

### What IS NOT Captured (Gaps)

| Gap | Impact | Notes |
|-----|--------|-------|
| **No structured priority tracking** | Cannot answer "what are top priorities across team" | Check-ins ask what devs are "working on" but don't capture priority/urgency levels |
| **No structured blocker tracking** | Blockers are only detected via keyword grep in notes (`blocked\|stuck\|...`), no categorization, no resolution tracking | If a developer writes "I'm waiting for API access" -- it may or may not match keywords |
| **No workload/capacity metrics** | Evening report suggests resource allocation but has no quantitative input | No story points, task counts, complexity estimates, or time allocation data |
| **No project/task association** | Cannot answer "what is the status of Project X" | Activity is per-developer, not per-project |
| **12 of 17 agents not fully monitored** | Tech-manager only runs bottleneck/missed-checkin/status checks on 5 original agents | Newer agents have check-in crons but are invisible to management reporting |
| **No check-in response content analysis** | Responses go to Slack DMs, not captured in structured form | Tech-manager reads `memory/` files but these are agent-written summaries, not the raw developer responses |
| **No trend analysis** | No historical tracking of patterns over time | Each report is a snapshot; no week-over-week comparison |
| **Inconsistent check-in models** | 2 agents use `checkin-guard.sh` (3x/day at fixed times), 14 use deprecated `poll-check.sh` (every 2h interval) | Different data schemas, different compliance tracking |
| **No sprint/milestone tracking** | Cannot answer "are we on track for the milestone" | No integration with project management tools |
| **Heartbeat data not captured** | Email, calendar, weather checks are ad-hoc and not reported upward | Potentially useful context (upcoming meetings, deadlines) not surfaced |

---

## 4. Architecture Summary

```
Developer <-- Slack DM --> Dev-PA Agent (17 agents)
                              |
                              v
                         poll-state.json (compliance)
                         memory/YYYY-MM-DD.md (notes)
                         sessions/sessions.json (activity)
                              |
                              v (reads)
                         Tech-Manager Agent (1 agent)
                              |
                              v
                         #tech-management Slack channel
                         (morning report, evening report, hourly alerts)
```

---

## 5. Key Findings and Recommendations

### Critical Issues

1. **Agent monitoring coverage gap:** Only 5 of 17 agents are monitored by tech-manager scripts. The `--agents` parameter in hourly/morning/evening cron jobs needs to include all active agents.

2. **Deprecated script still primary:** `poll-check.sh` is marked deprecated but 14 agents still use it. Migration to `checkin-guard.sh` would provide better tracking (per-slot response tracking vs binary awaiting_response).

### Structural Gaps for Priority/Blocker/Workload Visibility

3. **No structured data extraction from check-in responses.** Developer replies are free-text Slack DMs. To get priority/blocker/workload data, you would need either:
   - Agents to parse responses and write structured data to memory files
   - A post-processing layer that reads Slack DM history and extracts structured fields

4. **Blocker detection is keyword-only.** The grep for `blocked|stuck|waiting|error|failed` in daily notes is a blunt instrument. A developer saying "I'm blocked on the design review" gets caught, but "still waiting to hear back from the client about requirements" might not. No severity, categorization, or resolution tracking exists.

5. **No workload quantification.** The system captures what people are working on (qualitative) but not how much they have on their plate (quantitative). The evening report's "resource allocation suggestion" is generated by the LLM from GitHub activity alone, with no actual capacity data.

6. **No project-level view.** All data is organized per-agent/per-developer. There is no mechanism to ask "what is the status of Feature X across all developers working on it."
