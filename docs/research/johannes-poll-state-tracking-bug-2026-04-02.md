# dev1 poll-state.json Tracking Bug Analysis

**Date:** 2026-04-02
**Status:** Actionable -- root cause identified, fix needed

## Symptom

- Morning cron fired at 05:01 IST, dev1 responded at 09:02 with audio message
- Agent transcribed and replied at 09:05
- But `poll-state.json` shows `last_morning_epoch: 0` and `morning_responded: true`
- Midday check-in at 12:33 said "Haven't heard back this morning" -- completely wrong

## Current poll-state.json (live on host)

```json
{
  "morning_responded": true,
  "midday_responded": false,
  "evening_responded": true,
  "last_morning_epoch": 0,
  "last_midday_epoch": 1774854006,
  "last_evening_epoch": 0,
  "missed_checkins": 0,
  "awaiting_response": true
}
```

## Root Cause: The Agent Overwrites checkin-guard.sh's State

There are **two writers** to `poll-state.json`, and they conflict:

### Writer 1: `checkin-guard.sh` (correct, deterministic)

The guard script (`types/dev-pa/scripts/checkin-guard.sh`) properly manages state:

1. **Lines 187-200**: When a check-in fires, it sets `last_X_epoch = $NOW_EPOCH` and resets `X_responded = false`
2. **Lines 138-148**: On subsequent runs, it detects human activity by comparing `LAST_HUMAN_EPOCH_S > LAST_X_EPOCH`
3. **Lines 202-226**: Writes the complete updated state back to `poll-state.json` with all fields including `checkin_dispatched` and `last_state_date`

This is well-designed. If ONLY checkin-guard.sh wrote to poll-state.json, the system would work correctly.

### Writer 2: The LLM Agent (via cron payload instructions) -- THE BUG

The **Daily Summary cron payload** (jobs-config.json, lines 428-431 for dev1) instructs the agent:

> "4. Update ~/.openclaw/agents/dev1/memory/poll-state.json: set `last_summary_epoch` to current Unix epoch (seconds)."

The agent, being an LLM, reads the file, adds `last_summary_epoch`, but in doing so **can corrupt or lose other fields**. However, this is not the primary issue today.

### The Real Bug: `awaiting_response` vs `checkin_dispatched` Field Name Mismatch

**Critical finding:** The live `poll-state.json` has the field `"awaiting_response": true` but checkin-guard.sh writes `"checkin_dispatched"` (line 224). This means:

1. **The file on disk was NOT written by the current version of checkin-guard.sh.** The current script writes `checkin_dispatched`, but the live file has `awaiting_response`.
2. **The morning cron at 05:01 either did not run checkin-guard.sh, or the guard's state write was overwritten.** If checkin-guard.sh had actually run and written successfully, the file would have `checkin_dispatched` (not `awaiting_response`), `last_morning_epoch` would be non-zero, and `last_state_date` would be present.

**The live file is missing `last_state_date` entirely.** The current checkin-guard.sh always writes `last_state_date`. This confirms the live file was written by a DIFFERENT writer (the LLM agent or an old version of the script).

### What Happened Step by Step

1. **05:01**: Morning cron fires. The cron payload tells the agent to run `scripts/checkin-guard.sh morning`.
2. **checkin-guard.sh runs**, sets `last_morning_epoch = <now>`, writes poll-state.json with `checkin_dispatched` and `last_state_date`.
3. **The agent then composes and sends the morning message.**
4. **SOMETIME AFTER**: Something overwrites poll-state.json with the OLD schema (containing `awaiting_response` instead of `checkin_dispatched`, missing `last_state_date`, and with `last_morning_epoch: 0`).
5. **Most likely culprit**: The evening check-in or daily summary from the PREVIOUS day (April 1) -- the LLM agent reads poll-state.json, modifies it to add/update fields, but uses the old field names and resets values it doesn't understand.

### Supporting Evidence

- `last_morning_epoch: 0` -- if checkin-guard.sh ran at 05:01, this would be ~1774846860. It's 0, meaning it was reset.
- `last_midday_epoch: 1774854006` -- this is April 2, 2026, approximately 12:33 IST. This was set by the midday checkin-guard.sh run.
- `morning_responded: true` -- but `last_morning_epoch` is 0. The guard script has a consistency check (lines 110-113) that would reset this to `false` if it saw this combination. The fact it's `true` means this was written by the LLM, not by checkin-guard.sh.
- `awaiting_response` instead of `checkin_dispatched` -- old field name, confirms non-guard writer.
- Missing `last_state_date` -- guard always writes this. Its absence proves a non-guard writer.

## Why the Midday Said "Haven't Heard Back This Morning"

When the midday cron ran:

1. `checkin-guard.sh midday` ran and read poll-state.json
2. It found `last_morning_epoch: 0` (corrupted by LLM overwrite)
3. Lines 159-162: midday checks `MORNING_RESPONDED == false && LAST_MORNING_EPOCH > 0` for `prev_unanswered`
4. With `last_morning_epoch: 0`, the guard would NOT set `prev_unanswered = true` via this check
5. BUT the guard also found `morning_responded: true` with `last_morning_epoch: 0` (inconsistency), and the consistency check on lines 110-113 reset `morning_responded` to `false`
6. The midday cron payload says: "If no morning context is available, just ask what they're focused on" and "If data.prev_unanswered == true, mention briefly and move on."
7. The `prev_unanswered` was `false` (because `last_morning_epoch == 0` fails the `> 0` check), BUT the LLM agent looked at session history and saw no morning response (because the session was potentially different, or the LLM relied on its own understanding of poll-state)

Actually, the more likely explanation for "Haven't heard back this morning" is that the midday cron runs in `session:main`. The morning cron ALSO runs in `session:main`. So the agent has the full morning conversation in its session history. If the morning check-in was sent but the response came 4 hours later (09:02), the agent should have seen it. The message "Haven't heard back this morning" likely came from the `prev_unanswered` flag in the guard output, OR the agent interpreted the corrupted state incorrectly.

## Five Answers

### 1. Who writes to poll-state.json?

Three writers:
- **checkin-guard.sh** (3x/day: morning, midday, evening) -- deterministic, correct
- **The LLM agent via Daily Summary cron** (1x/day at 19:30 CET) -- adds `last_summary_epoch`, can corrupt other fields
- **The LLM agent via ad-hoc decisions** -- the agent may read/modify poll-state.json during conversations if it decides to track something

### 2. How does `last_morning_epoch` get set?

By `checkin-guard.sh` lines 188-189:
```bash
morning)
    LAST_MORNING_EPOCH=$NOW_EPOCH
    MORNING_RESPONDED=false
    ;;
```
This happens when the morning cron fires and the guard runs. The value is written to disk on line 210.

### 3. How does `morning_responded` get set to true?

By `checkin-guard.sh` lines 138-141:
```bash
if (( LAST_HUMAN_EPOCH_S > LAST_MORNING_EPOCH && LAST_MORNING_EPOCH > 0 )); then
    MORNING_RESPONDED=true
fi
```
This happens on the NEXT run of checkin-guard.sh (midday or evening), when it detects that the last human session activity is newer than when the morning check-in fired. The human does NOT mark it -- the guard script does it automatically.

### 4. Why is `last_morning_epoch: 0`?

Because the LLM agent overwrote poll-state.json AFTER checkin-guard.sh set it. Evidence:
- Field name `awaiting_response` (old) instead of `checkin_dispatched` (current)
- Missing `last_state_date` field (guard always writes this)
- `morning_responded: true` with `last_morning_epoch: 0` (impossible if guard wrote it -- guard has consistency check)

Most likely the previous day's Daily Summary cron (April 1 at 19:30 CET) or evening check-in overwrote the file with a corrupted version that reset `last_morning_epoch` to 0.

### 5. What does the midday cron payload say?

The dev1 midday payload (jobs-config.json lines 382-384):
- Runs `scripts/checkin-guard.sh midday`
- Parses JSON output
- If `data.prev_unanswered == true`, "mention briefly and move on"
- "References what they said their priority was this morning... If no morning context is available, just ask what they're focused on"

The midday relies on BOTH the guard's `prev_unanswered` flag AND the LLM's session memory. The guard computes `prev_unanswered` by checking `MORNING_RESPONDED == false && LAST_MORNING_EPOCH > 0`. With corrupted state (`last_morning_epoch: 0`), `prev_unanswered` would be `false` -- so the "Haven't heard back" message came from the LLM's own interpretation, not the guard.

## Recommended Fixes

### Fix 1: Stop the LLM from writing full poll-state.json (HIGH PRIORITY)

The Daily Summary cron should NOT tell the agent to update poll-state.json directly. Instead:
- Option A: Use a SEPARATE file for `last_summary_epoch` (e.g., `memory/summary-state.json`)
- Option B: Have the cron payload use a deterministic script to update ONLY the `last_summary_epoch` field via `jq`

### Fix 2: Make checkin-guard.sh preserve unknown fields (MEDIUM PRIORITY)

Currently checkin-guard.sh writes a fresh JSON object from scratch (lines 206-226). If the LLM added `last_summary_epoch`, the guard will drop it. Change to read-modify-write pattern using `jq` to preserve existing fields while updating known ones.

### Fix 3: Migrate `awaiting_response` to `checkin_dispatched` on live host (IMMEDIATE)

The live file still has the old field name. Run checkin-guard.sh once to overwrite with correct schema, or manually fix the file.

## Files Investigated

- `/Users/<hostname>/.openclaw/agents/dev1/memory/poll-state.json` -- live state (corrupted)
- `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json` -- all cron payloads
- `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/checkin-guard.sh` -- guard script (correct)
- `/Users/<hostname>/openclaw-agents/types/dev-pa/AGENTS.md` -- agent instructions
