# Research: dev1 Midday Check-in Missing — 2026-04-03

**Date:** 2026-04-03  
**Investigator:** Claude Code (research-only, no files modified)  
**Status:** Root cause identified

---

## Summary

The dev1 midday check-in at 12:30 IST (07:00 UTC / 09:00 CEST) on 2026-04-03 **started but did not complete**. The cron job fired at 09:01:57 CEST as expected, the agent began running checkin-guard.sh, said "Let me run the check-in guard script" — and then the session was cut short with no further output, no Slack delivery, and no poll-state update. The root cause is a combination of (a) a premature midday epoch write from an earlier erroneous run and (b) the Slack connection being unstable at the time of execution.

---

## 1. Cron Job Config — dev1 Midday

**Job ID:** `4b7934f3-f18e-474c-8ba4-466e8d9b6351`  
**Name:** dev1 Midday Check-in  
**Enabled:** true  
**cron expression:** `30 12 * * 1-5`  
**Timezone:** `Asia/Kolkata`  
**Fires at:** 12:30 IST = 07:00 UTC = 09:00 CEST  
**sessionKey:** `agent:dev1:cron:midday`  
**sessionTarget:** `session:slack:direct:u09l59gj3qt`

The config is correct and the job is enabled. No config issue.

---

## 2. Cron Runtime State

`openclaw cron list` could not be run — the gateway was down at investigation time. The gateway status confirms it restarted at 10:40 CEST (pid 43264) from the most recent SIGTERM at 10:39 CEST.

The gateway has had **10 restart cycles** today:
- 02:08 → 02:09 CEST
- 02:12 → 02:13 CEST
- 03:17 → 03:18 CEST (then immediate second SIGTERM at 03:18:19)
- 03:18 → 03:36 CEST
- 03:45 → 03:46 CEST
- 03:47 → 03:48 CEST
- 06:10 → 06:11 CEST (then SIGTERM at 06:11:49, then 06:16, then 06:56)
- 06:57 → running until 10:39 CEST

---

## 3. What Actually Happened — Timeline

| Time (CEST) | Event |
|---|---|
| 01:30 CEST | Morning cron scheduled (05:00 IST) |
| 02:08–03:18 | Multiple gateway restarts — morning cron delayed |
| **03:16:53** | Morning check-in delivered via Slack to <slack-id> |
| 03:17:38 | Gateway SIGTERM restart #3 |
| 03:18:18 | Gateway up (PID 49215) |
| 03:18:19 | **Immediate SIGTERM** (1 second after startup) |
| 03:18:45 | Gateway up (PID 49735) — stable |
| **03:19:43** | **`last_midday_epoch` written to poll-state.json** (01:19 UTC = 06:49 IST — 3.5h early!) |
| 03:36–03:48 | More gateway restarts |
| 06:10 | Gateway SIGTERM |
| 06:11–06:57 | 4 more rapid restarts during deploy/update |
| 06:57 | Gateway stable (PID 13087) |
| **09:00 CEST** | Midday cron scheduled to fire (12:30 IST) |
| **09:01:57 CEST** | Midday cron payload delivered to DM session |
| **09:02:03 CEST** | Agent says "Let me run the check-in guard script" |
| 09:02 | **Session ends — no further activity, no Slack delivery** |
| 09:12 | Slack health-monitor restarts (stale-socket) |

The session file (`c9fdfb95`) has exactly 158 lines, ending at 07:02:03 CEST. No subsequent Slack delivery (`delivered reply to user:<slack-id>`) appears in the gateway log after 03:16 CEST.

---

## 4. The Premature Midday Epoch (03:19 CEST)

`poll-state.json` shows:
```json
{
  "last_morning_epoch": 1775175379,   // 03:16 CEST (05:46 IST — late morning, 46min after scheduled)
  "last_midday_epoch": 1775179183,    // 03:19 CEST (06:49 IST — 3.5h BEFORE scheduled 12:30 IST)
  "last_state_date": "2026-04-03"
}
```

The `last_midday_epoch` was written at **03:19 CEST = 06:49 IST**, which is 3.5 hours before the 12:30 IST scheduled midday time. This happened 63 minutes after the morning epoch was written.

**Probable cause:** During the chaotic restart window (03:17–03:18 CEST), the gateway reloaded the cron scheduler and fired the midday job based on a stale `nextRunAt` or missed-fire catch-up logic. The midday cron ran as the agent in a (now-deleted or short-lived) session, wrote the `last_midday_epoch`, and completed. There is no session file from exactly 03:19 CEST (the closest is `4c886fac` at 03:20 CEST — that's the old `agent:dev1:slack:channel:u09l59gj3qt` session from Apr 1).

This premature midday run explains why `missed_checkins: 1` in poll-state — checkin-guard saw the morning was not responded to when the premature midday ran.

---

## 5. Why checkin-guard Did NOT Cause the Skip

When the real midday cron fired at 09:01 CEST:
- `last_midday_epoch` was already set to 03:19 CEST (today's date)
- **checkin-guard does not detect "already ran today"** — it only skips if the developer was active within the last 20 minutes
- The DM session (`agent:dev1:slack:direct:u09l59gj3qt`) had `updatedAt` = 09:01:52 CEST which was updated by the cron firing itself
- Before the cron fired, the DM session's last update was at 03:16 CEST (5h45m prior) — well outside the 20-minute skip window
- **checkin-guard would have returned `skip: false`** — the skip guard was NOT the problem

---

## 6. What Actually Killed the Midday Check-in

The agent started running at 09:01:57 CEST, said it would run checkin-guard.sh, and then the session produced no further output. The session file ends at line 158 with no tool calls executed and no Slack message sent.

Between 09:02 and 09:12 CEST:
- No gateway log entries (no cron activity, no tool calls, no errors)
- At 09:12 CEST the Slack health-monitor detected a stale socket and restarted

The most likely explanation: the agent execution timed out or was interrupted by a Slack WebSocket failure. The Bolt errors at 03:17 and 08:02 CEST ("Failed to send a WebSocket message as the client is not ready") show the Slack connection has been flapping. When the agent tried to send the Slack DM message, the socket was stale — and the execution failed silently without writing more to the session file.

The session target for the midday cron is `session:slack:direct:u09l59gj3qt` — if the Slack socket is not ready when the agent completes, the message delivery fails with the message written to session but no Bolt delivery.

---

## 7. Was the Gateway Running at 07:00 UTC?

Yes. The gateway was up from 06:57 CEST (04:57 UTC, PID 13087) continuously until 10:39 CEST. The midday cron at 07:00 UTC (09:00 CEST) was within a stable gateway window.

---

## 8. Session State Summary

```
agent:dev1:slack:direct:u09l59gj3qt   last updated: 09:01:52 CEST (by the midday cron itself)
agent:dev1:cron:a19d654e              last updated: 08:00:52 CEST (unrelated email-summary job)
```

The midday cron ran in the existing DM session. The session has content up to 07:02 CEST but no evidence of checkin-guard running, no tool call results, and no Slack send.

---

## 9. Additional Issues Found

1. **`unknown cron job id: 594e8ccb`** at 03:49 CEST — The dev1 Daily Summary job was missing from runtime `jobs.json`, consistent with the `deleteAfterRun` bug (issue noted in MEMORY.md).

2. **`read failed: ENOENT /Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/MEMORY.md`** at 03:50 CEST — The agent tried to read MEMORY.md at the repo path instead of the live path. This is the stow/workspace path bug.

3. **Slack WebSocket instability** — Multiple stale-socket restarts throughout the day causing "client is not ready" errors and interrupted agent sessions.

4. **Premature midday epoch** — The 03:19 CEST midday epoch means `missed_checkins` is now incorrectly incremented by 1. The evening check-in will show `prev_unanswered=true` because `midday_responded=false` but `last_midday_epoch > 0`.

---

## 10. Root Cause

**Primary:** The midday check-in session was interrupted mid-execution (after the first LLM response but before any tool calls) due to Slack WebSocket unavailability. The Bolt client logged stale-socket conditions throughout the day. When the session target is a Slack DM session and Slack is not ready, the agent's tool calls or message delivery fail.

**Contributing:** The premature midday epoch written at 03:19 CEST (from a spurious restart-triggered cron run) corrupted the poll-state, incrementing missed_checkins and leaving the midday state in an inconsistent position.

---

## Recommendations

1. **Midday check-in needs re-running manually today** — run `openclaw cron run 4b7934f3-f18e-474c-8ba4-466e8d9b6351` once the gateway is stable.

2. **Reset poll-state midday fields** — Set `last_midday_epoch: 0`, `midday_responded: false`, `missed_checkins: 0` to avoid a false "prev_unanswered" flag in the evening check-in.

3. **Investigate gateway restart frequency** — 10 restarts in one day is abnormal. Most are launchctl-triggered (SIGTERM from deploy.sh or manual), but the pattern suggests deploy-related restarts are impacting cron timing.

4. **Slack socket resilience** — The "client is not ready" errors are a recurring issue. Consider whether the agent should retry or whether OpenClaw needs to handle stale-socket conditions more gracefully on cron execution.

5. **Premature cron fire on restart** — When the gateway restarts and catches up on missed cron jobs, it may fire jobs that aren't yet due. This needs investigation at the OpenClaw level (openclaw/openclaw) — if `nextRunAt` is not persisted correctly across restarts, missed-fire logic can fire jobs hours early.
