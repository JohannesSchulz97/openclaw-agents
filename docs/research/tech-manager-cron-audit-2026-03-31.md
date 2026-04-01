# Tech-Manager Cron Audit

**Date:** 2026-03-31
**Researcher:** Claude Code (research-only, no files modified)

---

## 1. Job Count

The tech-manager has **3 cron jobs** in the runtime (`openclaw cron list`):

| Session Key | Name |
|---|---|
| `agent:tech-manager:cron:monitoring` | Tech Manager Hourly Monitoring |
| `agent:tech-manager:cron:morning-report` | Tech Manager Morning Status Report |
| `agent:tech-manager:cron:evening-report` | Tech Manager Evening Report |

Source of truth: `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json`

---

## 2. Schedule Type: All Three Are Interval-Based (NOT Wall-Clock)

This is the most important finding.

All three tech-manager jobs use `schedule.kind: "every"` (interval-based), NOT `schedule.kind: "cron"` (wall-clock). The contrast with developer check-in jobs is stark: dev1, dev10, dev10 all use `cronExpr` with `tz`; the tech-manager uses `everyMs`.

### Job Details

**Hourly Monitoring**
- Kind: `every`
- Interval: `everyMs: 3600000` (1 hour)
- Anchor: `2026-03-31 07:51:54` (set when `apply-cron.sh` last ran)
- Last run: `2026-03-31 12:14:44` (status: ok, 19.4s)
- Next run: `2026-03-31 13:14:44`
- Fires every hour from the anchor point forward

**Morning Status Report**
- Kind: `every`
- Interval: `everyMs: 86400000` (24 hours)
- Anchor: `2026-03-31 07:51:56`
- Last run: `2026-03-30 16:22:25` (status: ok, 120.2s)
- Next run: `2026-03-31 16:22:25`
- This means it fires at ~16:22 local time every day, NOT at a configured morning time

**Evening Report**
- Kind: `every`
- Interval: `everyMs: 86400000` (24 hours)
- Anchor: `2026-03-31 07:51:58`
- Last run: `2026-03-31 07:49:31` (status: ok, 91.9s)
- Next run: `2026-04-01 07:49:31`
- This means it fires at ~07:49 local time every day, NOT at a configured evening time

---

## 3. Critical Issue: Morning and Evening Reports Fire at Wrong Times

The interval-based scheduling means the reports fire at **whatever time `apply-cron.sh` last ran plus accumulated drift**, not at configured wall-clock times.

Current effective schedule (local time, as of 2026-03-31):
- "Morning" report fires at: **~16:22** (late afternoon)
- "Evening" report fires at: **~07:49** (early morning)

These labels are inverted relative to when they actually run. The "morning" report runs in the afternoon and the "evening" report runs in the early morning. This is because `apply-cron.sh` was run at ~07:51 on 2026-03-31, which reset the anchors, and the previous run times accumulated from that anchor.

The root cause: when `apply-cron.sh` runs, it sets `anchorMs` to the current time. Jobs then fire at `anchor + N * interval`, meaning the exact firing time drifts to whatever time the script was last applied.

This is a known design limitation noted in project memory: the `schedule.kind: "cron"` with `cronExpr + tz` was added for developer check-in jobs precisely to get wall-clock scheduling, but the tech-manager jobs were never migrated to use it.

---

## 4. Recent Activity Summary (Last 24h)

### Session file pattern

Sessions follow a clear pattern: small files (~7-8KB) are hourly monitoring runs; large files (87KB-523KB) are morning/evening report runs or interactive sessions.

### Hourly Monitoring (today, 2026-03-31)

Runs observed (all NO_ACTION — no new agent activations needed):
- 08:15 — 0 activated, 17 skipped, all_clear
- 09:15 — 0 activated, 17 skipped, all_clear
- 10:15 — 0 activated, 17 skipped, all_clear
- 11:15 — 0 activated, 17 skipped, all_clear
- 12:15 — 0 activated, 17 skipped, all_clear

All 17 agents are either already active or have no `work-schedule.json` yet. The monitoring job is functioning correctly.

Notable behavior: every monitoring session shows the tech-manager noting "The user has sent the same cron activation request twice again. I should only execute the check once to avoid duplicate processing." This indicates the cron trigger delivers the message twice per session (a known OpenClaw behavior or `wakeMode: "now"` artifact).

### Evening Report (2026-03-31 07:49)

Ran successfully. Sent to Slack channel `<channel-id>`. Message ID: `1774936251.382669`.

Report covered all 17 agents. Key findings reported:
- `<your-org>` org totals (last 10h): 29 commits, 2 PRs opened, 18 PRs merged, 6 issues opened, 3 closed
- Main contributors: dev1 (openclaw-agents work), dev9 (core navigation/PiP/calendar), dev6, dev5, dev10
- Bottlenecks and check-in compliance were included
- Resource allocation suggestions included

The content was substantive and correctly scoped to <your-org> org.

### Morning Report (2026-03-30 16:22)

Ran on the previous day (2026-03-30 at 16:22). The session file is the large `0435fb7e` file (200KB). This session was complex — the tech-manager discovered its own GitHub activity queries were returning stale/incorrect data, investigated the issue, found the correct mapping between agents and GitHub usernames, and sent corrected per-developer reports. It also committed fixes to the repo (`[feature/bootstrap-improvements 894654f] fix(manager): correct GitHub activity queries, add per-employee report format`).

The next morning report is due at ~16:22 today (2026-03-31), which has not fired yet at time of research (~12:20).

---

## 5. Issues Identified

### Issue 1: Morning and evening report times are not wall-clock anchored (HIGH)

Both the morning and evening reports use `everyMs: 86400000` instead of `cronExpr`. This means:
- They fire at a fixed offset from when `apply-cron.sh` was last run
- The current anchor (07:51 on 2026-03-31) causes the morning report to fire at 16:22 and the evening report at 07:49 — effectively swapped
- Re-running `apply-cron.sh` at any time shifts these firing times to that moment + 24h

**Fix:** Migrate both jobs to `schedule.kind: "cron"` with `cronExpr` and `tz`, matching the pattern used by developer check-in jobs. For example:
- Morning report: `cronExpr: "0 8 * * 1-5"`, `tz: "Europe/Berlin"` (or whatever the operator's timezone is)
- Evening report: `cronExpr: "0 18 * * 1-5"`, `tz: "Europe/Berlin"`

### Issue 2: Monitoring job delivers cron message twice per session (LOW)

Every hourly monitoring session shows the tech-manager agent receiving the cron trigger message twice, causing it to note it's ignoring the duplicate. This is cosmetically harmless (the agent is smart enough to run the check once), but adds unnecessary tokens and indicates a platform-level delivery issue worth investigating.

### Issue 3: Morning report runs at wrong time for its intended purpose (MEDIUM)

At 16:22, a "morning" report is not useful as a morning planning tool. The content is correct but the timing undermines the purpose of the report (team visibility at the start of the workday).

### Issue 4: Evening report content fired before most developers start work (MEDIUM)

At 07:49, an "evening" report fires before most European developers (the majority of the team) have even started their day. The report contains yesterday's summary — which is fine — but the timing means <manager-agent> would see it mixed in with morning activity rather than at day-end.

---

## 6. What Is Working

- All 3 jobs are enabled and running without errors (`consecutiveErrors: 0` on all)
- Hourly monitoring correctly identifies when all agents are already active and outputs NO_ACTION
- The evening report successfully sends substantive content to Slack with accurate GitHub data
- The monitoring job's `check-cron-activation.sh` correctly skips all 17 agents (no new activations needed today)
- Model is `openai-codex/gpt-5.4` on all jobs as configured
- Session isolation is correct: monitoring and reports run in `isolated` sessions
- `delivery.mode: "none"` on all 3 jobs (no automatic delivery, agent sends via Slack tool)

---

## 7. Source of Truth vs Runtime Discrepancy

The source of truth (`jobs-config.json`) defines all three jobs with `schedule.kind: "every"`. The runtime matches this exactly. There is no discrepancy between config and runtime for tech-manager jobs.

The runtime adds `anchorMs` (not in the config file) which is set by OpenClaw when the job is first created/applied.

---

## Files Referenced

- `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json` — source of truth
- `~/.openclaw/agents/tech-manager/sessions/` — runtime session files
- Runtime: `openclaw cron list --json`
