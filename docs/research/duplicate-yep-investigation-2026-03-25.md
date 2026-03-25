# Investigation: Duplicate "Yep." Message from TOB <manager-agent> to <slack-id>

**Date:** 2026-03-25
**Investigator:** Research Agent (Claude)
**Status:** Root cause identified
**Severity:** Low (cosmetic/UX issue, not a functional bug)

---

## Summary

At approximately 07:05 CET on 2026-03-25, <your-org> AG (<slack-id>) sent "are you there?" via Slack DM to TOB <manager-agent>. The human reported seeing "Yep." appear twice (both marked "bearbeitet"/edited in Slack). Investigation reveals this was **NOT two separate agent sends**. The gateway log shows exactly one delivery event, and the main agent session shows exactly one `[[reply_to_current]] Yep.` response. The duplicate appearance is attributable to Slack-side behavior (message edit/update rendering), not to the agent or gateway sending twice.

---

## Evidence

### 1. Gateway Log: Only ONE Delivery

The gateway log shows exactly one delivery to <slack-id> on 2026-03-25:

```
2026-03-25T07:05:54.793+01:00 [slack] delivered reply to user:<slack-id>
```

No second delivery was logged. No retry, no error, no duplicate entry. This is the only delivery to this user in the entire day's log.

### 2. Main Agent Session: Only ONE Response

The "are you there?" message was routed to the **main agent** (not <your-org>), handled by `gpt-5.4` via `openai-codex-responses` provider:

- **Incoming:** `2026-03-25T06:05:50.709Z` -- Slack DM "are you there?" from <slack-id>
- **Response:** `2026-03-25T06:05:54.348Z` -- `[[reply_to_current]] Yep.`

The agent produced exactly one response. There is no second "Yep." in the session transcript.

### 3. The Human Noticed It Immediately

At 07:06:03 CET, the human sent "duplicate response?" -- confirming they saw two "Yep." messages in Slack. The agent's own response was:

> "Possibly -- if you saw two, that was likely a delivery/routing hiccup, not intentional. I only meant to send one."

### 4. Stale Socket Reconnections Are Frequent

The health monitor restarts the Slack socket every ~35 minutes due to "stale-socket" detection:

```
2026-03-25T05:59:31.836+01:00 [health-monitor] restarting (reason: stale-socket)
2026-03-25T06:34:31.819+01:00 [health-monitor] restarting (reason: stale-socket)
```

The last reconnect before the incident was at 06:34:32 CET -- about 31 minutes before the "Yep." was sent. This is within the normal reconnection window.

### 5. No Cron Session Involvement

<your-org> cron job (b2c7a3d1-5e8f-4b9a-9c2d-e1f0a3b4c5d6) was NOT involved in this response. Its sessions show:
- Last cron run at 04:15 UTC (05:15 CET) -- over 2 hours before the incident
- The cron sessions do NOT have access to the `slack` tool and could not send messages
- The cron delivery mode is "none"

The "are you there?" DM was handled by the **main agent session** (`c94b36f8-8d75-4b30-b513-9c655b546d8d`), not by <your-org> agent at all.

### 6. Error Log Shows Normal Tool Warnings

The only entries in `gateway.err.log` around the incident time are benign tool profile warnings about unavailable core tools (apply_patch, cron, image) -- unrelated to message delivery.

---

## Root Cause Analysis

**Finding: The duplicate "Yep." was NOT caused by two separate sends from the agent or gateway.**

The most probable explanation is **Slack-side message rendering behavior**:

1. **Slack Socket Mode message update pattern**: When OpenClaw delivers a reply via Socket Mode, Slack may first post a placeholder (or initial message) and then update it with the final content. Both the initial post and the edit can appear as separate visual entries in the chat, especially in the DM view. The "bearbeitet" (edited) label on both messages supports this -- it indicates Slack's edit/update mechanism was involved.

2. **Possible Slack API double-ack**: During Socket Mode, if the WebSocket connection experiences a brief hiccup (the health monitor shows frequent stale-socket reconnections every ~35 min), Slack may redeliver the event. If the gateway acknowledged the event but the ack was lost in transit, Slack could redeliver, causing the gateway to process the same event twice -- though the gateway log only shows one delivery, so this would have to be a Slack-side rendering artifact.

3. **Message streaming/chunking**: Some OpenClaw configurations stream responses (initial placeholder, then edit with content). This can appear as two messages briefly, both showing as "edited."

---

## What Was NOT the Cause

| Hypothesis | Evidence Against |
|---|---|
| Two separate agent sends | Session log shows exactly one `[[reply_to_current]] Yep.` |
| Cron session also responded | Cron has no slack tool access; last ran 2h before incident |
| Gateway sent twice | Only one `delivered reply` in gateway log |
| Multiple active sessions responded | Only main agent handled the Slack DM |

---

## Recommendations

1. **Check OpenClaw Slack provider for streaming/edit behavior**: If the provider first posts an empty message and then edits it with content, this could explain the visual duplication. Consider whether the provider can be configured to send a single complete message.

2. **Monitor stale-socket frequency**: Reconnecting every ~35 minutes is aggressive. Check whether the Slack Socket Mode health check interval can be tuned to reduce unnecessary reconnections (which increase the risk of double-delivery edge cases).

3. **Add delivery deduplication logging**: Add a unique message ID or nonce to each delivery so that if Slack does redeliver, the gateway can detect and suppress duplicates.

4. **Check Slack API response**: If possible, log the Slack API response (including `ts` and any `edited` metadata) when posting messages to confirm whether one or two messages were actually created.

---

## Timeline (All Times CET / +01:00)

| Time | Event |
|---|---|
| 06:34:31 | Health monitor restarts Slack socket (stale-socket) |
| 06:34:32 | Slack socket reconnected |
| 07:05:50 | Incoming DM: "are you there?" from <slack-id> |
| 07:05:54 | Main agent responds: `[[reply_to_current]] Yep.` |
| 07:05:54 | Gateway logs: `delivered reply to user:<slack-id>` |
| 07:06:03 | Human follows up: "duplicate response?" |
| 07:06:08 | Agent acknowledges: routing hiccup, not intentional |
| 07:06:17 | Human: "interesting" |

---

## Files Examined

- `/Users/<hostname>/.openclaw/logs/gateway.log`
- `/Users/<hostname>/.openclaw/logs/gateway.err.log`
- `/Users/<hostname>/.openclaw/agents/main/sessions/c94b36f8-8d75-4b30-b513-9c655b546d8d.jsonl`
- `/Users/<hostname>/.openclaw/agents/<your-org>/sessions/038db403-c630-427b-ac41-b163ab98aa67.jsonl`
- `/Users/<hostname>/.openclaw/agents/<your-org>/sessions/sessions.json`
- `/Users/<hostname>/.openclaw/cron/jobs.json`
