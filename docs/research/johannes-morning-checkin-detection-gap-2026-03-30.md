# Research: Why dev1 Morning Check-in Response Was Missed

Date: 2026-03-30
Investigator: Claude Code (research agent)

## Summary

dev1 DID respond to the morning check-in. Our prior investigation incorrectly concluded he had not. The root cause is a multi-part design gap in how `checkin-guard.sh` tracks and detects responses — specifically a stale `last_morning_epoch: 0` in `poll-state.json` that breaks the response detection condition.

---

## What Actually Happened (Timeline)

All times UTC:

| Time | Event |
|------|-------|
| 23:30:00 | Morning cron job ran (dev1 Morning Check-in, cron job `e1e1bf73`) |
| 23:35:12 | dev1 sent a voice message in reply |
| 23:35–23:38 | dev1's agent transcribed the voice message (Whisper turbo model) |
| 23:38:51 | Agent replied to dev1 in Slack — gateway log: `delivered reply to user:<slack-id>` |
| 23:38:51 | `sessions.json` key `agent:dev1:slack:direct:u09l59gj3qt` updated to epoch 1774913931 |

dev1's actual reply (from JSONL): "Hey, good morning. So today I'm planning to continue working on openclaw-agents... improve the tech manager... work on open issues... starting with a new project about a company anthology..."

The check-in was responded to within 8 minutes and 51 seconds of the agent sending it.

---

## Why We Missed It: Root Cause Analysis

### The Core Problem: `last_morning_epoch` is 0

`poll-state.json` at time of investigation:
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

`last_morning_epoch: 0` means "the morning check-in epoch was never recorded (or was reset to zero)".

### How checkin-guard.sh Detects Responses

`checkin-guard.sh` uses this logic (lines 108–118):

```bash
if [[ -n "$LAST_HUMAN_EPOCH_S" ]]; then
    if (( LAST_HUMAN_EPOCH_S > LAST_MORNING_EPOCH && LAST_MORNING_EPOCH > 0 )); then
        MORNING_RESPONDED=true
    fi
fi
```

The `LAST_HUMAN_EPOCH_S` is derived from `sessions.json` by taking the max `updatedAt` across all non-cron sessions.

At investigation time:
- `LAST_HUMAN_EPOCH_S` = 1774913931 (slack direct session, 23:38:51 UTC — dev1's reply)
- `LAST_MORNING_EPOCH` = 0 (from poll-state.json)

Condition evaluation: `1774913931 > 0 AND 0 > 0` → **FALSE** because `0 > 0` is false.

The guard correctly requires `LAST_MORNING_EPOCH > 0` to prevent false positives (otherwise any human activity would count as a response to every check-in type), but when `last_morning_epoch` is 0, the guard can never detect a morning response.

### The Impossible State: morning_responded=true with last_morning_epoch=0

This state is self-contradictory. `checkin-guard.sh` lines 157–160 show that when the morning cron runs, it ALWAYS executes:

```bash
LAST_MORNING_EPOCH=$NOW_EPOCH
MORNING_RESPONDED=false
```

So if `checkin-guard.sh` ran today's morning check-in correctly, `last_morning_epoch` would be ~1774913400, not 0.

The current state (`morning_responded=true`, `last_morning_epoch=0`) means the `morning_responded=true` flag is stale — it was set by a previous run (possibly yesterday or an earlier iteration today), but `last_morning_epoch` was subsequently zeroed or the checkin-guard failed to write its update for today's run.

### Why `awaiting_response: true` Was Also Misleading

The `awaiting_response` field is set to `true` whenever `SKIP=false` (i.e., when the check-in is not skipped due to recent activity). It is set to `false` only when the check-in was skipped. It does NOT indicate "we are waiting for a response to the current check-in" — it indicates "this check-in was sent (not skipped)". This field is therefore misleading as a "response pending" signal.

When we saw `awaiting_response: true`, that confirmed the check-in was sent, but we incorrectly used the `morning_responded: true` from a stale state to infer dev1 replied. The real detection logic requires `last_morning_epoch > 0` to be useful, and that was missing.

---

## The Correct Way to Check If an Agent Responded

### Method 1: Compare sessions.json timestamps (what checkin-guard does, when working)

```bash
LAST_HUMAN_EPOCH_S=$(jq -r '
    to_entries
    | map(select(.key | test("cron") | not))
    | map(.value.updatedAt // 0)
    | max // 0
' ~/.openclaw/agents/dev1/sessions/sessions.json)

LAST_MORNING_EPOCH=$(jq -r '.last_morning_epoch // 0' \
    ~/.openclaw/agents/dev1/memory/poll-state.json)

# If LAST_HUMAN_EPOCH_S > LAST_MORNING_EPOCH AND LAST_MORNING_EPOCH > 0 => responded
```

This is reliable ONLY when `last_morning_epoch` has been set correctly by today's checkin-guard run.

### Method 2: Check sessions.json directly with known cron run time

If you know the cron ran at time T, check if any non-cron session has `updatedAt > T`:

```bash
CRON_RAN_AT_MS=1774913400000  # epoch_ms when morning cron ran
MAX_HUMAN_MS=$(jq -r '
    to_entries
    | map(select(.key | test("cron") | not))
    | map(.value.updatedAt // 0)
    | max // 0
' ~/.openclaw/agents/dev1/sessions/sessions.json)
# If MAX_HUMAN_MS > CRON_RAN_AT_MS => human activity happened after the check-in was sent
```

For dev1: `1774913931075 > 1774913400000` → **TRUE** (responded 531 seconds later)

### Method 3: openclaw sessions CLI

```bash
openclaw sessions --agent dev1 --json
```

Shows all sessions with `updatedAt` timestamps and `kind`. Non-cron sessions (`kind: "direct"`) are human-initiated. The `agent:dev1:slack:direct:u09l59gj3qt` session at `2026-03-30T23:38:51 UTC` confirms human interaction after the morning check-in.

### Method 4: Gateway log

```bash
grep "delivered reply to user:<slack-id>" ~/.openclaw/logs/gateway.log
```

Shows `2026-03-31T01:38:51 [slack] delivered reply to user:<slack-id>` (01:38:51 CET = 23:38:51 UTC), which confirms the agent processed dev1's incoming message and delivered a reply.

### Method 5: JSONL session file

The JSONL at `~/.openclaw/agents/dev1/sessions/c9fdfb95-f853-4c73-8f67-341721ce44a6.jsonl` contains the full message exchange. The `toolResult` entry at 23:37:48 UTC shows Whisper transcription of dev1's voice reply.

---

## OpenClaw Message/Session Visibility Tools Discovered

| Tool | Command | What It Shows |
|------|---------|---------------|
| Session list | `openclaw sessions --agent dev1 --json` | All sessions with updatedAt, kind, token counts |
| Session list (recent) | `openclaw sessions --active 120 --agent dev1` | Sessions active in last N minutes |
| Session list (all agents) | `openclaw sessions --all-agents --json` | Cross-agent session view |
| Message read | `openclaw message read --channel slack --target user:<slack-id> --limit N` | Recent Slack messages |
| Gateway logs | `~/.openclaw/logs/gateway.log` | "delivered reply to user:XXXXX" events |
| JSONL files | `~/.openclaw/agents/<name>/sessions/*.jsonl` | Full message-level conversation history |
| sessions.json | `~/.openclaw/agents/<name>/sessions/sessions.json` | Session index with updatedAt, sessionId, origin |

**Notable limitation**: `openclaw message read` does not appear to read from an agent's DM history — no output was returned when attempted. The reliable view of message history is via the JSONL session files directly.

---

## Identified Bugs / Design Gaps

### Bug 1: `last_morning_epoch` can be 0 while `morning_responded` is true

The poll-state can contain logically contradictory values. If checkin-guard fails to write its state update (e.g., due to a crash, script error, or race condition), subsequent runs see stale data.

**Impact**: The response detection condition `LAST_MORNING_EPOCH > 0` will always fail, making it impossible to detect responses to that check-in type until the cron fires again and sets a new epoch.

### Bug 2: `awaiting_response` field is ambiguous

The field name implies "we are awaiting a response", but it actually means "the check-in was sent (not skipped)". It gets set to `false` only when SKIP=true. A developer looking at this field to assess response status will draw wrong conclusions.

### Bug 3: No inter-day reset of `last_X_epoch` / `X_responded` flags

poll-state.json is cumulative across days. If yesterday's morning_responded was set to `true` and today's checkin-guard.sh fails to write (or last_morning_epoch gets corrupted), the stale `morning_responded=true` persists into the next day's midday check evaluation, which will see `PREV_UNANSWERED=false` incorrectly.

### Bug 4: The midday check sees stale morning state

Because `last_morning_epoch=0`, when midday's checkin-guard runs and evaluates:

```bash
if [[ "$MORNING_RESPONDED" == "false" && "$LAST_MORNING_EPOCH" -gt 0 ]]; then
    PREV_UNANSWERED=true
fi
```

`LAST_MORNING_EPOCH=0` so this is false — midday sees no unanswered morning check-in. In this case that's actually a false negative in the right direction (doesn't generate noise), but it's by accident.

---

## Recommendations

1. **Add consistency validation** to checkin-guard.sh: if `last_X_epoch=0` but `X_responded=true`, treat the responded flag as stale and reset it to false.

2. **Rename `awaiting_response`** to `last_checkin_skipped` (boolean, inverted meaning) or replace with `last_checkin_sent_at_epoch` to make the semantics clear.

3. **Add daily reset logic**: On each morning check-in, validate that `last_morning_epoch` is being set to a non-zero value and log an error if the write fails.

4. **Add a diagnostic command** to check-missed-checkins.sh or as a standalone script that reads sessions.json directly and computes response status from raw timestamps, bypassing poll-state.json entirely. This would be the authoritative check.

5. **Consider `openclaw sessions --agent NAME --active N`** as the correct real-time check for recent agent activity, as it queries the live session store rather than the agent's self-maintained state file.

---

## Saved Research Files

- `/Users/<hostname>/openclaw-agents/docs/research/dev1-morning-checkin-detection-gap-2026-03-30.md` (this file)
