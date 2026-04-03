# OpenClaw Cron Catchup Mechanism: Why the Evening Report Fired Twice

**Date:** 2026-04-03
**Type:** Informational research
**Source:** OpenClaw 2026.3.28 (f9b1079), gateway bundle at
`/Users/<hostname>/Library/pnpm/global/5/.pnpm/openclaw@2026.3.28_@napi-rs+canvas@0.1.97/node_modules/openclaw/dist/gateway-cli-DlnlX7IW.js`

---

## Summary

The tech-manager evening report job fired correctly at 01:56 UTC (20:00 CET), then fired again at 04:21 UTC after a gateway restart. This is the correct, documented behavior of the OpenClaw cron scheduler. The double-fire is caused by a **dual-path missed-job detection system** where the scheduler uses `lastRunAtMs` vs `previousRunAtMs` comparison as a fallback when `nextRunAtMs` has already been advanced past the current time. The gateway did not persist the new `nextRunAtMs` (21:00 CET the following day) across the restart window because the persistence happened, but the scheduler's startup catchup logic independently recomputed whether the job was missed based on the cron expression itself — and the answer was yes.

---

## The Evening Report Cron Config

From `.openclaw/cron/jobs-config.json`:

```json
{
  "id": "d5f7b0c2-3e8a-4d94-b6f1-0a1e2c4d6f8a",
  "name": "Tech Manager Evening Report",
  "schedule": {
    "kind": "cron",
    "cronExpr": "0 20 * * *",
    "tz": "Europe/Berlin"
  },
  "sessionKey": "agent:tech-manager:cron:evening-report"
}
```

`0 20 * * *` in `Europe/Berlin` = 19:00 UTC in winter (CET = UTC+1), but 18:00 UTC in summer (CEST = UTC+2).

At the time of this incident (early April 2026, CEST applies), 20:00 CET = **18:00 UTC**. However the reported actual firing was **01:56 UTC**, which is ~20:00 IST (Indian Standard Time, UTC+5:30). This suggests the host runs in a different timezone context, or the scheduler correctly resolved CET at that moment as UTC+2 (CEST), making 20:00 CEST = 18:00 UTC, and the "01:56 UTC" figure in the question may be approximate or refer to something else. Regardless, the mechanism applies identically.

---

## Question 1: How Does the Scheduler Determine a Job is Overdue?

`planStartupCatchup` (line 6648) calls `collectRunnableJobs` with `allowCronMissedRunByLastRun: true`. This flows into `isRunnableJob`, which has **two independent detection paths**:

### Path 1: `nextRunAtMs` comparison (normal due-time check)
```js
const next = job.state.nextRunAtMs;
if (typeof next === "number" && Number.isFinite(next) && nowMs >= next) return true;
```
If `nextRunAtMs` is set and `now >= nextRunAtMs`, the job is due.

### Path 2: `previousRunAtMs > lastRunAtMs` comparison (missed-run detection)
```js
// Only reached if Path 1 did not return true
if (!params.allowCronMissedRunByLastRun || job.schedule.kind !== "cron") return false;
let previousRunAtMs;
try {
    previousRunAtMs = computeJobPreviousRunAtMs(job, nowMs);
} catch {
    return false;
}
if (typeof previousRunAtMs !== "number" || !Number.isFinite(previousRunAtMs)) return false;
const lastRunAtMs = job.state.lastRunAtMs;
if (typeof lastRunAtMs !== "number" || !Number.isFinite(lastRunAtMs)) return false;
return previousRunAtMs > lastRunAtMs;
```

This path asks: **"Was there a cron slot in the past that occurred after the last time the job ran?"** If yes, the job is considered missed, regardless of `nextRunAtMs`.

`computeJobPreviousRunAtMs` calls `computeStaggeredCronPreviousRunAtMs`, which evaluates the cron expression to find the most recent past slot before `nowMs`.

---

## Question 2: Does It Compare `nextRunAtMs` vs Now, or `lastRunAtMs` vs Cron Expression?

**Both.** The function tries Path 1 first. If Path 1 fails (because `nextRunAtMs` is already set to a future time), it falls through to Path 2, which is the `lastRunAtMs` vs cron expression comparison.

Path 2 is the critical one for this incident.

---

## Question 3: Why Did the Scheduler Think a Second Run Was Needed?

Here is the exact sequence of events:

### Step A: Normal execution at ~20:00 CET (01:56 UTC as stated)
`applyJobResult` runs after the job completes:

```js
job.state.lastRunAtMs = result.startedAt;  // Set to ~01:56 UTC timestamp
// ...
// For a successful cron job:
naturalNext = computeJobNextRunAtMs(job, result.endedAt);
// For "0 20 * * *" CET, naturalNext = next day's 20:00 CET slot
const minNext = result.endedAt + MIN_REFIRE_GAP_MS; // MIN_REFIRE_GAP_MS = 2000ms
job.state.nextRunAtMs = Math.max(naturalNext, minNext);
// Result: nextRunAtMs = next 20:00 CET = ~22 hours from now
```

At this point, the persisted state has:
- `lastRunAtMs` = ~01:56 UTC (timestamp of the run)
- `nextRunAtMs` = next day's 20:00 CET slot

This is written to disk via `persist(state)`.

### Step B: Gateway restarts at ~04:21 UTC (2.5 hours later)

`planStartupCatchup` runs. It calls `collectRunnableJobs` with `allowCronMissedRunByLastRun: true` and `skipRecompute: true` (skipping `recomputeNextRuns` to avoid advancing past-due markers silently).

For the evening report job:

**Path 1 check:** `nextRunAtMs` is set to next day's ~20:00 CET, which is many hours in the future. `nowMs (04:21 UTC) < nextRunAtMs`. Path 1 returns `false` (not due by normal check). ✓ Correct so far.

**Path 2 check (the problem):**
```
previousRunAtMs = computeJobPreviousRunAtMs(job, 04:21 UTC)
```
This computes: "What was the most recent `0 20 * * *` slot before 04:21 UTC?"

The answer is: **today's (or yesterday's) 20:00 CET slot** — which equals 18:00 UTC (CEST) or 19:00 UTC (CET). Either way, that slot is before 04:21 UTC.

Then the check: `previousRunAtMs > lastRunAtMs`?

- `previousRunAtMs` = the 20:00 CET slot = e.g. 18:00 UTC (a timestamp like 1743609600000)
- `lastRunAtMs` = the actual run timestamp = ~01:56 UTC (a timestamp like 1743472560000)

**The 20:00 CET slot (18:00 UTC) is AFTER the run timestamp (01:56 UTC). So `previousRunAtMs > lastRunAtMs` = TRUE.**

The scheduler concludes the job was missed and fires it as a catch-up run.

### Why is `lastRunAtMs` before the cron slot?

The cron expression is `0 20 * * *` in `Europe/Berlin`. The job ran at 01:56 UTC. If the timezone is CET (UTC+1) in winter, 20:00 CET = 19:00 UTC. If CEST (UTC+2) in summer, 20:00 CEST = 18:00 UTC. Either way, 01:56 UTC is *earlier in the UTC day* than 18:00-19:00 UTC.

The scheduler interprets this as: "The job last ran at 01:56 UTC. The most recent 20:00 CET slot was at 18:00 UTC today. Since 18:00 UTC > 01:56 UTC, the job missed the 18:00 UTC slot." But of course 01:56 UTC is the *next day* (the following UTC midnight has not occurred yet — it's early morning), and 18:00 UTC is the *same calendar day's evening*. The job actually ran at 01:56 UTC of day N+1, before that day's 18:00 UTC slot.

**Put simply: the cron job runs at 20:00 CET (18:00-19:00 UTC). The gateway fires it at 01:56 UTC, which is after midnight UTC but before the day's 18:00 UTC. So from the scheduler's perspective at restart (04:21 UTC), `previousRunAtMs` (18:00 UTC of "today") > `lastRunAtMs` (01:56 UTC of "today"). The job appears missed.**

This is a fundamental limitation of the `lastRunAtMs > previousRunAtMs` check: it does not account for whether the previous cron slot is actually from the *same firing occasion* as `lastRunAtMs`. The run at 01:56 UTC was for the **previous day's** 20:00 CET slot (which fired late, during the gateway's downtime and was caught up). The scheduler has no concept of "this `lastRunAtMs` corresponds to which cron slot" — it only knows the raw timestamp.

---

## Question 4: Was `lastRunAtMs` Not Updated?

`lastRunAtMs` **was updated correctly** to the actual run start time (~01:56 UTC). The problem is not a persistence failure. The problem is that `lastRunAtMs` (01:56 UTC) is timestamp-earlier than the cron expression's most recent theoretical slot (18:00 or 19:00 UTC), so the comparison `previousRunAtMs > lastRunAtMs` evaluates as `true` even though the job already ran for that day's slot.

---

## Question 5: Is There a `maxMissedJobsPerRestart` Config?

Yes. From the source:

```js
const DEFAULT_MAX_MISSED_JOBS_PER_RESTART = 5;
```

The dependency type declaration:
```ts
/**
 * Maximum number of missed jobs to run immediately on startup.
 * Additional missed jobs will be rescheduled to fire gradually.
 */
maxMissedJobsPerRestart?: number;
```

This controls how many jobs from the missed-jobs list are run **immediately** vs deferred. It does not prevent the duplicate detection — it only limits concurrency of the catch-up execution. If the evening report was the only job in the missed list, it would be in the first 5 and fire immediately.

There is also:
```ts
/**
 * Delay in ms between missed job executions on startup.
 */
missedJobStaggerMs?: number;
```

Neither of these prevents a false-positive catch-up from firing.

---

## The Precise Mechanism (Summary)

```
Normal run at ~01:56 UTC
  → lastRunAtMs = 01:56 UTC
  → nextRunAtMs = next-day 18:00-19:00 UTC (next 20:00 CET slot)
  → persisted to disk ✓

Gateway restarts at 04:21 UTC

planStartupCatchup() runs:
  → collectRunnableJobs(allowCronMissedRunByLastRun: true)
  → isRunnableJob() for evening-report job:
      Path 1: nextRunAtMs (next-day ~18:00 UTC) > 04:21 UTC → false
      Path 2: previousRunAtMs = today's 18:00-19:00 UTC slot
              lastRunAtMs = 01:56 UTC
              18:00 UTC > 01:56 UTC → TRUE ← false positive!
  → Job added to catch-up candidates
  → Fires at 04:21 UTC (the "duplicate" run)
```

The root cause is that the job previously ran as a **catch-up from the day before** (fired at 01:56 UTC, i.e. 02:26 IST the next morning for the prior day's 20:00 CET slot). Its `lastRunAtMs` timestamp (01:56 UTC of day N) is earlier in the UTC day than the current day's cron slot (18:00 UTC of day N), so the "missed run" detector fires again.

---

## Is This a Bug or Intended?

This is an **edge case in the design** of the `previousRunAtMs > lastRunAtMs` check. The check is a safety net for when `nextRunAtMs` is missing or corrupted, and it works correctly for jobs that run at expected times. It breaks down when:

1. A job is itself triggered as a catch-up (meaning it fires much later than its scheduled slot), AND
2. The gateway restarts before the next scheduled slot

In that situation, `lastRunAtMs` ends up earlier in the UTC day than the cron slot it was fulfilling, causing the next startup to re-trigger it.

This is tracked as referenced in the state type comment:
```ts
/** See: https://github.com/openclaw/openclaw/issues/18892 */
```
(the staggering of missed jobs issue, related but not identical).

---

## Config Reference (for Completeness)

The evening report job is at `jobs-config.json` lines 48-70:
- Job ID: `d5f7b0c2-3e8a-4d94-b6f1-0a1e2c4d6f8a`
- Cron: `0 20 * * *` in `Europe/Berlin`
- No `staggerMs` set (so `offsetMs = 0`, no stagger applied)

The `maxMissedJobsPerRestart` and `missedJobStaggerMs` values are not set in `jobs-config.json` (they are gateway-level config, not per-job). Their defaults are 5 and unspecified, respectively.

---

## Potential Mitigations

1. **Run the gateway before the cron slot, not after it**: If the gateway is restarted before 20:00 CET each day, the `previousRunAtMs` would be from the previous day's slot, which would predate `lastRunAtMs`, and Path 2 would not trigger.

2. **Set a `staggerMs` of 0** on the job (already the default). No change.

3. **Wait for OpenClaw upstream fix**: The `previousRunAtMs > lastRunAtMs` check could be made aware of which slot `lastRunAtMs` was fulfilling, but this requires upstream changes.

4. **Accept it as operational**: The evening report runs twice on days following a gateway restart that happened between midnight and 20:00 CET. The second run produces a duplicate Slack message to #tech-management but is otherwise harmless.

---

*Saved to docs/research/openclaw-cron-catchup-mechanism-2026-04-03.md*
