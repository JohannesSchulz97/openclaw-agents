# Research: Tech-Manager Evening Report Duplicate on Gateway Restart

**Date:** 2026-04-03
**Trigger:** Tech-manager sent two evening reports today — 01:56 UTC and 04:21 UTC. The second was a gateway-restart catch-up duplicate.

---

## Summary Finding

The tech-manager evening report job has NO guard script. It fires unconditionally whenever the OpenClaw cron scheduler decides it should run. `checkin-guard.sh` is a dev-pa-only mechanism and does not exist in any form for manager-type agents. When the gateway restarts and catches up missed schedules, the evening report job re-fires with nothing to stop it.

---

## 1. The Evening Report Job (jobs-config.json)

File: `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json`, job id `d5f7b0c2-3e8a-4d94-b6f1-0a1e2c4d6f8a`

```
"name": "Tech Manager Evening Report"
"schedule": { "kind": "cron", "cronExpr": "0 20 * * *", "tz": "Europe/Berlin" }
"sessionKey": "agent:tech-manager:cron:evening-report"
"wakeMode": "now"
```

The payload message begins directly with task instructions:

> "You are the Tech Manager agent. Generate your evening status report. 1. Run `bash scripts/collect-daily-notes.sh`..."

There is no guard invocation anywhere in this payload. The job unconditionally tells the agent to generate and send a report. No script is called first, no state is checked, no deduplication exists.

### wakeMode: "now"

This is the critical enabler of the duplicate. `wakeMode: "now"` instructs OpenClaw to run the job immediately on gateway restart if its scheduled time was missed while the gateway was down. When the gateway restarted between the two report times, it saw the 20:00 CET job as missed and fired it again, producing the 04:21 UTC report.

---

## 2. checkin-guard.sh — What It Does and Who It Serves

File: `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/checkin-guard.sh`

### Mechanism

checkin-guard.sh is a lightweight idempotency guard for dev-pa check-ins. When called, it:

1. Reads `sessions/sessions.json` and finds the most recent non-cron human interaction timestamp.
2. If the developer was active within the last 20 minutes (`SKIP_IF_ACTIVE_MINUTES=20`), it outputs `skip: true` and the agent does nothing.
3. Reads `memory/poll-state.json` which tracks per-type timestamps: `last_morning_epoch`, `last_midday_epoch`, `last_evening_epoch`, and `*_responded` flags.
4. Performs a day-boundary reset when `last_state_date` differs from today's UTC date.
5. Records the current epoch for the check-in type that just fired, then writes the updated state back.
6. Outputs JSON: `{ skip, reason, checkin_type, prev_unanswered, missed_checkins, agent_name }`.

### What it does NOT do for deduplication

checkin-guard.sh does not check whether the same check-in type already fired today. It records `last_morning_epoch`, `last_midday_epoch`, `last_evening_epoch` as timestamps, but the guard logic (`SKIP=true`) is based solely on recent human activity, not on whether the job already ran. If the developer was not active in the last 20 minutes, `skip` will be `false` and the check-in fires — even if it already ran an hour ago.

This means checkin-guard.sh would not have prevented the duplicate even for a dev-pa agent's evening check-in if the developer was inactive.

### Where it lives

The script lives exclusively in `types/dev-pa/scripts/`. There is no equivalent in `types/manager/scripts/`. The manager scripts directory contains:

- `check-cron-activation.sh`
- `check-status.sh`
- `check-missed-checkins.sh`
- `check-bottlenecks.sh`
- `check-session-health.sh`
- `check-session-sizes.sh`
- `collect-daily-notes.sh`
- `lib/json-response.sh`

None of these are guard scripts. None of them are invoked as a pre-flight check in any tech-manager cron job payload.

---

## 3. Tech-Manager poll-state.json — Does Not Exist

Path checked: `~/.openclaw/agents/tech-manager/memory/poll-state.json`

This file does not exist. The tech-manager has no poll-state tracking at all. Even if a guard script were added for the manager type, there is currently no state file it could read to determine whether the evening report already fired today.

The dev-pa agents each have `memory/poll-state.json` written and maintained by `checkin-guard.sh`. The tech-manager has no analogous file.

---

## 4. HEARTBEAT.md for Manager Type

File: `/Users/<hostname>/openclaw-agents/types/manager/HEARTBEAT.md`

Contents: The file is intentionally empty, with a comment noting that manager agents use cron jobs for scheduled reports and heartbeat API calls are not needed. This confirms the manager type is entirely cron-driven with no periodic self-check mechanism.

---

## 5. The Three Tech-Manager Cron Jobs

From jobs-config.json:

| Job | Schedule | Guard? |
|-----|----------|--------|
| Tech Manager Hourly Monitoring | every 3600000ms | None |
| Tech Manager Morning Status Report | every 86400000ms | None |
| Tech Manager Evening Report | `0 20 * * *` Europe/Berlin | None |

All three fire unconditionally. The morning report uses `kind: "every"` at 86400000ms (24h), not a true cron expression, so it has different catch-up semantics. The evening report uses a true cron expression with `wakeMode: "now"`, making it the most vulnerable to gateway-restart duplication.

---

## 6. Root Cause Summary

| Layer | Status |
|-------|--------|
| checkin-guard.sh exists for tech-manager | NO |
| poll-state.json exists for tech-manager | NO |
| Evening report payload has any guard logic | NO |
| wakeMode enables catch-up on restart | YES — this fired the duplicate |
| checkin-guard.sh would fully prevent this even for dev-pa | NO — its skip logic is activity-based, not run-count-based |

The immediate cause is `wakeMode: "now"` on the evening report job combined with no idempotency mechanism. On gateway restart, OpenClaw fires the job again for the missed schedule slot. The agent receives an unconditional instruction to generate and send a report, which it does.

---

## 7. What a Fix Would Look Like

Two separate problems need to be addressed:

### Problem A: No guard for tech-manager cron jobs

A `report-guard.sh` script could be created for the manager type, analogous to `checkin-guard.sh` for dev-pa. It would:

- Read (and write) a `memory/report-state.json` file tracking `last_evening_report_epoch`, `last_morning_report_epoch`, etc.
- Check if the relevant report type already fired within a cooldown window (e.g., 6 hours for the evening report).
- Output `{ skip: true/false, reason }` in the same JSON convention.
- The tech-manager cron job payloads would invoke this guard first, and if `skip == true`, output `NO_ACTION` and stop.

### Problem B: checkin-guard.sh does not prevent same-type duplicates for dev-pa either

The 20-minute activity window only skips if the developer was recently active. If a dev-pa agent's evening check-in fires twice due to a gateway restart and the developer was inactive, checkin-guard.sh would output `skip: false` both times, potentially sending two messages.

A proper deduplication guard would also need to check whether `last_evening_epoch` is within the current calendar day (or within a cooldown window) and return `skip: true` if so. This logic is not currently present in checkin-guard.sh.

### Problem C: wakeMode

Changing `wakeMode` from `"now"` to `"skip"` (if OpenClaw supports it) would prevent catch-up firing entirely. This is the most surgical fix for the restart scenario specifically, but would mean missed reports are simply skipped rather than caught up. For the evening report this is probably the right tradeoff — a missed evening report is better than a duplicate one.

---

## Files Referenced

- `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json` — cron job definitions
- `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/checkin-guard.sh` — dev-pa guard (not available to manager)
- `/Users/<hostname>/openclaw-agents/types/manager/scripts/` — all manager scripts (no guard present)
- `/Users/<hostname>/openclaw-agents/types/manager/HEARTBEAT.md` — confirms cron-only operation
- `~/.openclaw/agents/tech-manager/memory/poll-state.json` — does not exist
