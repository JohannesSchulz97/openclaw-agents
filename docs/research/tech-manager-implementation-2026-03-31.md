# Tech Manager Implementation Analysis

**Date:** 2026-03-31
**Scope:** `.openclaw/agents/tech-manager/` — all scripts, AGENTS.md, IDENTITY.md, USER.md, cron jobs

---

## What Is the Tech Manager

Tech Manager is a manager-type OpenClaw agent that runs on three recurring cron jobs (hourly monitoring, daily morning report, daily evening report). It has no persistent session — every cron invocation is isolated. It monitors 16 dev-pa agents and reports anomalies or summaries to the `#tech-management` Slack channel (`<channel-id>`).

It does not chat with developers. It does not respond to check-ins. Its sole function is observation and reporting to leadership (dev1 Schulz, dev10 Soyka, dev10 Becker).

---

## Cron Jobs (3 total)

All jobs use `model: openai-codex/gpt-5.4`, `sessionTarget: isolated`, and `delivery.mode: none`.

### 1. Hourly Monitoring (`agent:tech-manager:cron:monitoring`)

- **Schedule:** Every 60 minutes (3,600,000 ms), all day
- **Timeout:** 180 seconds
- **What it does:**
  1. Runs `check-bottlenecks.sh` for all 17 agents
  2. Runs `check-missed-checkins.sh --threshold 3` for all 17 agents
  3. Runs `check-cron-activation.sh` for all 17 agents
  4. If all three return `all_clear: true`, outputs `NO_ACTION` — sends nothing
  5. If any issues found, composes and sends a Slack alert to the tech-management channel

**Alert format:**
- Bottlenecks: `🚨` prefix with agent, type, severity, duration
- Missed check-ins: `⚠️` prefix with who missed, count, last activity
- Cron activations: `✅` prefix listing newly activated agents

### 2. Morning Status Report (`agent:tech-manager:cron:morning-report`)

- **Schedule:** Every 24 hours (86,400,000 ms) — no fixed wall-clock time in cron config, triggered by wakeMode
- **Timeout:** 300 seconds
- **What it does:**
  1. Runs `check-status.sh` for all 17 agents
  2. For each agent that has `github-activity.sh`, reads their USER.md for GitHub usernames and runs it with `--since 24` (yesterday's activity)
  3. Composes a structured morning report and sends to `#tech-management`

**Report sections:** Team overview (active/awaiting/inactive counts), per-developer breakdown (status, GitHub activity, last interaction), notable patterns.

### 3. Evening Report (`agent:tech-manager:cron:evening-report`)

- **Schedule:** Every 24 hours (same as morning)
- **Timeout:** 300 seconds
- **What it does:**
  1. Runs `check-status.sh`
  2. Runs `github-activity.sh --since 10` for agents that have it (today's work)
  3. Runs `check-bottlenecks.sh` and `check-missed-checkins.sh`
  4. Composes evening report including a resource allocation suggestion section

**Report sections:** Today's summary (commits, PRs, issues), issues and blockers, resource allocation suggestion (who is overloaded/underutilized, recommended rebalancing).

---

## Scripts

All scripts output JSON conforming to a standard envelope via `lib/json-response.sh`:
- Success: `{success: true, operation, timestamp, data}`
- Error: `{success: false, operation, timestamp, error: {code, message}}`

### `check-status.sh`

**Purpose:** Snapshot of every agent's current state.

**Data sources:**
- `openclaw sessions --all-agents --json` (live session list)
- Fallback: `$AGENT_DIR/sessions/sessions.json` (file-based)
- `$AGENT_DIR/memory/poll-state.json` (check-in state, supports old and new schema)
- `$AGENT_DIR/memory/` (daily notes — just checks for existence and latest date)

**Output per agent:**
- `name`, `last_session_activity` (ISO timestamp or null), `sessions_today` (count)
- `awaiting_response` (bool — derived from `*_responded` fields in new schema, or old `awaiting_response` field)
- `poll_state` (object with missed_checkins + epoch fields for new schema)
- `has_recent_notes` (bool), `latest_note_date` (YYYY-MM-DD)

**Summary fields:** `total_agents`, `active_today`, `awaiting_response`, `inactive`

**Schema awareness:** Detects new schema by presence of `last_morning_epoch`. Falls through to old `awaiting_response`/`last_check_in` fields if not present.

### `check-bottlenecks.sh`

**Purpose:** Detect three classes of problems per agent.

**Detection logic:**

1. **Long-running session** (`long_running_session`, severity: medium): Session duration >= 2 hours AND updated within the last 10 minutes. Reads `sessions.json`, excludes cron sessions.

2. **Possible loop** (`possible_loop`, severity: high): >5 cron sessions since the last human interaction AND silence > 2 hours. Indicates an agent firing repeatedly without the developer engaging.

3. **Developer unresponsive** (`developer_unresponsive`, severity: high): `awaiting_response` is true AND last check-in epoch is >= 8 hours ago.

4. **Blocked keywords** (`blocked_keywords`, severity: medium): Case-insensitive grep for `blocked|stuck|waiting|error|failed|can't proceed|cannot proceed` in the last 3 daily note files.

**Output:** `{bottlenecks: [...], all_clear: bool}`

Each bottleneck entry: `{agent, type, detail, severity, since}`

### `check-missed-checkins.sh`

**Purpose:** Alert when developers have not interacted past a threshold.

**Default threshold:** 3 missed check-ins (passed as `--threshold 3` from the hourly cron job).

**Skip conditions:** Agent missing `poll-state.json` OR `work-schedule.json` — treated as not yet bootstrapped.

**Schema handling:**
- New schema: reads `missed_checkins` directly from poll-state (set by `checkin-guard.sh`)
- Old schema: calculates missed count from elapsed time vs `interval_minutes` in `poll-config.json` (default 240 minutes)

**Severity classification:**
- `warning`: missed >= threshold
- `critical`: missed >= threshold * 2

**Output:** `{threshold, alerts: [...], all_clear: bool}`

Each alert: `{agent, developer, missed_count, last_human_interaction, hours_since_interaction, severity}`

Note: `developer` field is currently just the agent name (same value as `agent`) — not the human developer name.

### `check-cron-activation.sh`

**Purpose:** Auto-activate check-in schedules for agents that completed bootstrap.

**Logic:** For each agent, checks if `work-schedule.json` exists. If yes, queries `openclaw cron list --json` for session keys `agent:<name>:cron:morning`, `agent:<name>:cron:midday`, `agent:<name>:cron:evening`. If all three exist, skips. If any are missing, runs `scripts/update-cron-schedule.sh --agent <name>` from the openclaw-agents repo root.

**Repo root discovery:** Looks for `~/openclaw-agents` or walks up from script directory.

**Output:** `{activated: [...], skipped: [...], errors: [...], all_clear: bool}`

`all_clear` is true when `activated` and `errors` are both empty (skipped agents are not considered an issue).

### `lib/json-response.sh`

Shared library providing: `log` (stderr), `json_timestamp` (UTC ISO), `json_success`, `json_error`, `parse_quiet_flag`.

---

## Data the Tech Manager Has Access To

| Data Source | Access Method | Notes |
|---|---|---|
| Live session list | `openclaw sessions --all-agents --json` | All agents, all session types |
| Per-agent sessions file | `~/.openclaw/agents/<name>/sessions/sessions.json` | File fallback if CLI unavailable |
| Poll state | `~/.openclaw/agents/<name>/memory/poll-state.json` | Both old and new schema supported |
| Daily notes | `~/.openclaw/agents/<name>/memory/YYYY-MM-DD.md` | Existence check + keyword scan |
| Work schedule | `~/.openclaw/agents/<name>/work-schedule.json` | Used only to skip unbootstrapped agents |
| Poll config | `~/.openclaw/agents/<name>/poll-config.json` | Interval minutes (old schema fallback) |
| Agent identity | `~/.openclaw/agents/<name>/IDENTITY.md` | Read at LLM layer, not by scripts |
| Agent USER.md | `~/.openclaw/agents/<name>/USER.md` | Read at LLM layer for GitHub usernames |
| GitHub activity | `~/.openclaw/agents/<name>/scripts/github-activity.sh` | Only <your-org> org repos |
| Cron job list | `openclaw cron list --json` | Used by check-cron-activation.sh |

**The tech manager has read-only access. It never modifies agent files.**

The exception is `check-cron-activation.sh`, which calls `scripts/update-cron-schedule.sh` (a repo-level script) to add cron jobs — this modifies the cron runtime, not agent workspace files.

---

## Monitored Agents (16)

dev6, dev5, dev10, dev10, dev1, <github-username>, dev9, dev7, dev10, dev3, dev10, dev10, dev10, dev10-jean, dev8, dev10

Note: `<your-org>` appears in cron job payloads but NOT in USER.md. This is a discrepancy — the cron messages pass it as an agent name but the manager config table does not include it.

---

## Limitations and Known Issues

### 1. No Work Schedule Awareness (Issues #51, #52)

The monitoring cron runs every 60 minutes all day, including nights, weekends, and outside developers' working hours. `check-missed-checkins.sh` and `check-bottlenecks.sh` have no concept of whether a developer is expected to be online. This generates false positive alerts on weekends and off-hours.

Agents without `work-schedule.json` are skipped by `check-missed-checkins.sh`, but for agents that do have a schedule, the scripts do not consult those hours when determining if a check-in is truly "missed."

### 2. No Check-in Content Aggregation (Issue #60)

The tech manager can see THAT developers checked in (via poll-state) but does not read or aggregate WHAT was discussed. Morning and evening reports cannot summarize what developers are working on unless GitHub activity is available. Daily notes are only scanned for blocked keywords, not summarized.

### 3. Morning/Evening Reports Run at Unpredictable Times

Both morning and evening report jobs use `"kind": "every", "everyMs": 86400000` (24h). There is no wall-clock time anchoring in the cron config. The actual send time depends on when the gateway process started. The USER.md specifies 09:00 CET / 17:00 CET but the cron config does not enforce these times.

### 4. No Web Search Access (Issue #46)

Tech Manager cannot look up external context (documentation, announcements, etc.) because the web search API key is not configured.

### 5. `developer` Field in Missed Check-in Alerts Is the Agent Name

In `check-missed-checkins.sh`, the alert object sets `developer: $developer` where `$developer` is initialized as the agent name (not the human developer's name). The human name is not read from IDENTITY.md or USER.md at the script layer.

### 6. `<your-org>` Discrepancy

The cron job payloads pass `<your-org>` in the agent list, but `USER.md` does not include this agent in the monitored agents table. This means the tech manager's scripts will attempt to process an agent whose entry is absent from the manager's own configuration.

### 7. `all_clear` Logic in `check-cron-activation.sh`

`all_clear` is false only when there are errors or new activations. Skipped agents (already active, or no schedule yet) do not prevent `all_clear`. This is correct behavior, but means the hourly cron will briefly send a Slack message whenever a new agent gets their schedule activated (by design — treated as an informational event).

### 8. Possible Loop Detection Threshold Is Not Configurable

The `check-bottlenecks.sh` script uses hardcoded thresholds: 5 cron sessions since last human interaction, 2 hours of silence. These cannot be tuned without editing the script.

### 9. Daily Note Keyword Scan Has No Context

The keyword grep (`blocked|stuck|waiting|error|failed|can't proceed|cannot proceed`) is very broad. Words like "error" or "waiting" appear in neutral contexts frequently. There is no disambiguation or surrounding-context capture — just keyword presence triggers a medium-severity bottleneck.

---

## Summary

The tech manager is a well-structured monitoring agent with four shell scripts that produce predictable JSON output. Its primary purpose is exception-based alerting (hourly) plus daily narrative reports. It is passive — it reads, never writes — except for the cron activation side-effect. The key gaps are: no work-schedule awareness for off-hours suppression, no content aggregation from check-in conversations, and imprecise alert timing due to the `every 24h` schedule approach.
