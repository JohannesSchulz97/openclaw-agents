# Investigation: <your-org> Cron Job -- Slack Message Not Delivered

**Date:** 2025-03-25
**Status:** Root cause identified
**Severity:** High -- agent is burning tokens without delivering value

---

## Summary

<your-org> cron job (ID: `b2c7a3d1-5e8f-4b9a-9c2d-e1f0a3b4c5d6`) ran successfully (65s, status ok) but **no Slack message was delivered to <slack-id>**. The agent decided to send a message (`data.due == 1`) but **could not figure out how to invoke the Slack tool**, spending the entire 65-second session in a thinking loop trying to discover the mechanism.

## Root Cause

**The agent does not have the `slack` tool exposed in its function/tool definitions.** The model (`minimax-m2p5` via Fireworks) can only call tools that are explicitly listed in its tool definitions. The Slack skill SKILL.md exists as a reference document, but the actual `slack` tool function is not wired into the agent's tool set for cron sessions.

### Evidence Chain

1. **poll-check.sh returned `due: 1`** -- the agent correctly determined a check-in was needed.

2. **The agent spent 16+ tool calls trying to find Slack** -- it searched for:
   - `which slack` (found Slack CLI for app development, not messaging)
   - `env | grep -i slack` (no Slack environment variables)
   - OpenClaw `channels --help` (channel management, not ad-hoc messaging)
   - Read the Slack SKILL.md (found JSON action format like `sendMessage`)
   - But could not find a way to actually invoke it

3. **The thinking trace shows the agent looping** -- the final thinking block is ~8,000+ characters of the agent going in circles: "let me try one more thing... actually wait... let me check if there's a way..." repeated dozens of times until the 120s timeout.

4. **No `slack` tool call ever appears in the session** -- the only tools called were: `exec`, `memory_search`, `sessions_history`, `read`. Never `slack`.

5. **The cron job delivery config is `"mode": "none"`** -- meaning even if the agent produced output text, OpenClaw would not auto-deliver it to Slack.

## Comparison with dev1

| Aspect | dev1 | <your-org> |
|--------|----------|---------------|
| Last run duration | 4,284ms (4s) | 65,008ms (65s) |
| Last run status | ok | ok |
| Last delivery status | not-delivered | not-delivered |
| Delivery mode | none | none |
| Model | minimax-m2p5 | minimax-m2p5 |
| Gateway Slack deliveries (Mar 24) | 6 to <slack-id> | 4 to <slack-id> |
| Gateway Slack deliveries (Mar 25) | 0 | 0 |

**Key insight:** dev1 also shows `lastDeliveryStatus: "not-delivered"` and `delivery.mode: "none"`. The Mar 24 deliveries to both users came from **direct interactive sessions** (user-initiated Slack conversations), not from cron jobs. Neither agent has successfully delivered a cron-triggered Slack message via the delivery mechanism.

dev1 runs in 4s because it hits `data.due == 0` (NO_ACTION path) most of the time. When <your-org> hits `due == 1`, it burns 65s trying and failing.

## Three Problems Identified

### Problem 1: Missing Slack Tool in Cron Sessions (PRIMARY)

The `slack` tool is not available in the agent's cron session tool definitions. The agent can read the Slack SKILL.md but cannot call the `slack` function. The tool must be explicitly wired into the agent's available tools.

### Problem 2: Cron Delivery Mode is "none"

Both cron jobs have `delivery.mode: "none"`. Even if the agent produced a valid Slack message as output text, the cron system would not deliver it anywhere. The delivery mode should be configured to route output to Slack.

### Problem 3: Model Spinning (Token Waste)

The minimax-m2p5 model spent 65 seconds (203,287 total tokens) in an unproductive thinking loop when it could not find the Slack tool. There is no circuit-breaker or early-exit mechanism when the agent cannot accomplish the task.

## Token Impact

Latest failed run: **203,287 tokens** (70,306 input + 7,464 output + thinking overhead)
With runs every 2 hours and `due == 1` each time, this could burn significant tokens daily with zero value delivered.

## Recommended Fixes

### Fix 1: Wire the Slack Tool into Agent Sessions

Ensure the `slack` tool function is available in cron-triggered sessions for <your-org>. This likely requires configuration in the agent's tool definitions or the cron payload.

### Fix 2: Configure Cron Delivery Mode

Change `delivery.mode` from `"none"` to route output to Slack:
```json
{
  "delivery": {
    "mode": "slack",
    "target": "user:<slack-id>"
  }
}
```
Or use whatever the correct OpenClaw delivery configuration is.

### Fix 3: Add Early Exit to Cron Payload

Update the cron payload message to include a fail-fast instruction:
```
If you cannot find or invoke the slack tool, output 'SLACK_<slack-id>' immediately. Do not spend time searching for alternatives.
```

### Fix 4: Verify with dev1

Check if dev1 has ever successfully sent a cron-triggered Slack message, or if all dev1 deliveries also came from interactive sessions. If so, the same fix is needed for both agents.

---

## Files Examined

- `~/.openclaw/agents/<your-org>/sessions/5e0369bc-5dab-496f-b772-483554ad7ee7.jsonl` (latest cron session)
- `~/.openclaw/agents/<your-org>/scripts/poll-check.sh`
- `~/.openclaw/agents/<your-org>/memory/poll-state.json`
- `~/.openclaw/agents/<your-org>/TOOLS.md`
- `~/.openclaw/agents/<your-org>/SOUL.md`
- `~/.openclaw/logs/gateway.log`
- Cron job config via `openclaw cron list --json`
- Session list via `openclaw sessions --agent <your-org> --json`
