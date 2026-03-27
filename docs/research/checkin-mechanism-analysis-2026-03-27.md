# Check-in Mechanism Analysis: Why Check-ins Are Silently Suppressed

**Date:** 2026-03-27
**Status:** ROOT CAUSE IDENTIFIED -- Actionable bug
**Severity:** High -- affects all 19 agents

---

## Executive Summary

Check-in messages are being silently suppressed because `awaiting_response` in `poll-state.json` is stuck at `true`. Once the agent sends a check-in and sets `awaiting_response = true`, **nothing ever resets it back to `false`**. Every subsequent cron invocation sees `awaiting_response == true`, forces `due = 0`, and the agent outputs `NO_ACTION`.

---

## Root Cause: `awaiting_response` Is a One-Way Latch

### The Bug (poll-check.sh lines 76-77)

```bash
if [[ "$AWAITING_RESPONSE" == "true" ]]; then
    DUE=0    # <-- ALWAYS suppresses check-in when awaiting_response is true
```

Once `awaiting_response` is set to `true` (which happens in step 6 of the cron payload after sending a check-in), it is NEVER reset to `false`. There is no code anywhere that detects a human reply and flips it back.

### Evidence from Live System (dev1 agent)

- `poll-state.json` (both repo and live): `{"awaiting_response": true}`
- Last human interaction: `2026-03-26T10:21:40Z` (819 minutes ago at time of analysis)
- Cron fires every 2 hours, interval threshold is 240 minutes
- Elapsed time (819 min) far exceeds threshold (240 min)
- But `awaiting_response == true` forces `due = 0` unconditionally
- Result: Every cron run outputs `NO_ACTION`, no check-in is ever sent again

---

## Complete Logic Flow: Cron Firing to Message (or Suppression)

### Step 1: Cron Fires (every 7200000ms = 2 hours)

OpenClaw cron scheduler triggers the job. The job has:
- `sessionTarget: "isolated"` -- creates an isolated session
- `sessionKey: "agent:dev1:main"` -- session key for the cron
- `delivery.mode: "none"` -- no automatic delivery, agent must send manually
- `payload.message` -- the full prompt instructing the agent what to do

### Step 2: Agent Runs poll-check.sh

The cron prompt tells the agent: "Run scripts/poll-check.sh. Parse the JSON output."

poll-check.sh does this:

1. **Reads config:** `poll-config.json` -> `interval_minutes: 240`
2. **Reads state:** `poll-state.json` -> `awaiting_response: true/false`
3. **Queries sessions.json:** Finds all non-cron sessions, gets the max `updatedAt` timestamp as "last human interaction"
4. **Decision logic:**

```
if awaiting_response == true:
    DUE = 0                          # SUPPRESSED unconditionally
elif no human sessions found:
    DUE = 1                          # Should check in
elif elapsed_minutes >= interval:
    DUE = 1                          # Should check in
else:
    DUE = 0                          # Too recent, skip
```

5. **Returns JSON** with `data.due`, `data.elapsed_minutes`, `data.awaiting_response`, etc.

### Step 3: Agent Decides Based on `data.due`

The cron prompt says:
- `If data.due == 0, output ONLY 'NO_ACTION' and nothing else.`
- `If data.due == 1:` ... compose and send check-in message

### Step 4 (when due==1): Agent Sends Check-in

Steps include reading USER.md, running github-activity.sh, composing a personalized message, and sending via `openclaw message send`.

### Step 5 (when due==1): Agent Sets awaiting_response = true

Cron prompt step 6: "After sending, update memory/poll-state.json: set awaiting_response to true."

### Step 6: THE PROBLEM -- Nothing Ever Resets awaiting_response

There is NO mechanism to detect a human reply and reset `awaiting_response` to `false`. The possible places this could happen:
- **poll-check.sh** -- Does NOT reset it. Only reads it.
- **Cron payload** -- Only sets it to `true` (step 6). Never sets it to `false`.
- **HEARTBEAT.md** -- Empty. No heartbeat logic touches poll-state.
- **AGENTS.md** -- No mention of poll-state.json or resetting awaiting_response.
- **Any other script** -- No other script touches poll-state.json.

---

## What "Last Interaction" Means

The script checks `sessions.json` for the most recent `updatedAt` among non-cron sessions. It filters cron sessions using:

```jq
to_entries | map(select(.key | test("cron") | not))
```

This correctly identifies human sessions (e.g., `agent:dev1:slack:direct:u09l59gj3qt`). The timestamp represents the last time any non-cron session was updated -- which includes BOTH human messages and agent responses in that session.

**Important:** There is NO check for "was the last message from the agent vs. the human." The `updatedAt` timestamp updates whenever the session is touched, regardless of who sent the last message. This means even an agent-only reply updates the "last human interaction" timestamp.

---

## Is There a "Last Message Was From Agent" Condition?

**No.** Neither `poll-check.sh` nor the cron payload check who sent the last message. The script only checks:
1. Was there a non-cron session? (yes/no)
2. How long ago was it updated? (elapsed vs. interval)
3. Is `awaiting_response` true? (one-way latch)

The `sessions.json` file only contains `updatedAt` timestamps and origin metadata per session -- it does not contain the message history or last-sender information. The script has no visibility into whether the last message was from the human or the agent.

---

## All Suppression Conditions

A check-in is suppressed (DUE=0) when ANY of these are true:

| Condition | How it triggers | Can it self-resolve? |
|-----------|----------------|---------------------|
| `awaiting_response == true` | Agent sent a check-in previously | **NO -- this is the bug** |
| `elapsed_minutes < interval_minutes` | Human interacted within last 240 min | Yes -- time passes |

---

## Bugs and Issues Found

### BUG 1 (Critical): `awaiting_response` never resets

**Impact:** After the first successful check-in, ALL future check-ins are permanently suppressed for that agent.

**Fix options:**

**Option A (Recommended): Reset in poll-check.sh based on human reply detection.**
If a human session's `updatedAt` is newer than the last check-in time, reset `awaiting_response` to `false`. This requires storing the last check-in timestamp.

```bash
# After reading AWAITING_RESPONSE and LAST_HUMAN_EPOCH_S:
LAST_CHECKIN_EPOCH=$(jq -r '.last_checkin_epoch // 0' "$POLL_STATE_FILE")
if [[ "$AWAITING_RESPONSE" == "true" && -n "$LAST_HUMAN_EPOCH_S" ]]; then
    if (( LAST_HUMAN_EPOCH_S > LAST_CHECKIN_EPOCH )); then
        # Human replied since our last check-in
        jq '.awaiting_response = false' "$POLL_STATE_FILE" > "$POLL_STATE_FILE.tmp" && mv "$POLL_STATE_FILE.tmp" "$POLL_STATE_FILE"
        AWAITING_RESPONSE="false"
    fi
fi
```

And in the cron payload step 6, also store the check-in timestamp:
```
set awaiting_response to true and last_checkin_epoch to current unix timestamp
```

**Option B (Simpler but coarser): Add a timeout to awaiting_response.**
If `awaiting_response` has been true for longer than the interval, reset it.

```bash
if [[ "$AWAITING_RESPONSE" == "true" && -n "$LAST_HUMAN_EPOCH_S" ]]; then
    if (( ELAPSED_MINUTES >= INTERVAL_MINUTES )); then
        # Waited long enough, allow new check-in
        AWAITING_RESPONSE="false"
    fi
fi
```

**Option C (Simplest): Remove awaiting_response entirely.**
Just use the elapsed time check. If the human hasn't interacted in 240 minutes, send a check-in regardless. The `awaiting_response` guard was presumably meant to prevent spamming, but the 240-minute interval already prevents that.

### BUG 2 (Minor): `updatedAt` conflates human and agent activity

The session's `updatedAt` updates when the AGENT replies, not just when the human sends a message. So if the agent sends a message at 10:21, the "last human interaction" is recorded as 10:21 even though the human may have last spoken at 10:15. This inflates the apparent recency of human interaction and could delay check-ins by a few minutes.

### BUG 3 (Design): Cron sessions use `sessionKey: "agent:dev1:main"`

The cron job's `sessionKey` is `agent:dev1:main`, which is the SAME key as the main interactive session. This means cron runs share the same session as human conversations. The `sessionTarget: "isolated"` suggests OpenClaw creates isolated execution contexts, but the session key overlap could cause confusion if OpenClaw updates the `main` session's `updatedAt` when the cron runs. However, the session data shows separate cron-prefixed keys being created, so this may be handled correctly by OpenClaw.

---

## Immediate Fix (Manual)

To unblock all agents right now, reset `awaiting_response` to `false`:

```bash
for agent_dir in ~/.openclaw/agents/*/memory; do
    if [[ -f "$agent_dir/poll-state.json" ]]; then
        jq '.awaiting_response = false' "$agent_dir/poll-state.json" > "$agent_dir/poll-state.json.tmp" \
            && mv "$agent_dir/poll-state.json.tmp" "$agent_dir/poll-state.json"
        echo "Reset: $agent_dir/poll-state.json"
    fi
done
```

**Warning:** This only fixes it until the next check-in is sent, at which point `awaiting_response` gets stuck at `true` again.

---

## Recommended Permanent Fix Priority

1. **Fix poll-check.sh** to auto-reset `awaiting_response` (Option A or B above)
2. **Update cron payload** to store `last_checkin_epoch` alongside `awaiting_response`
3. **Run sync-agents.sh** to propagate the fix to all agent directories
4. **Stow** to deploy to `~/.openclaw/`
5. **Manual reset** of all current `poll-state.json` files
