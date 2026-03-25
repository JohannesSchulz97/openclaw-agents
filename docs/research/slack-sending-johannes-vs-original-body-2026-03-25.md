# Research: Why dev1 Can Send Slack Messages But <your-org> Cannot

**Date:** 2026-03-25
**Status:** Root cause identified
**Classification:** Actionable -- requires configuration fix

---

## Executive Summary

Both agents have identical infrastructure setup (cron jobs, scripts, bindings, poll-config). The difference is **behavioral, not structural**: dev1 (through trial and error in its cron sessions) discovered how to read the Slack bot token from `~/.openclaw/openclaw.json` and use `curl` to call the Slack API directly. <your-org> has been unable to reliably replicate this discovery, and in its most recent run explicitly reported `SLACK_<slack-id>`.

Neither agent has a native `slack` tool available in cron sessions. Both agents are improvising. dev1 just improvises more successfully.

---

## Detailed Findings

### 1. Infrastructure: Identical

| Component | dev1 | <your-org> |
|-----------|----------|---------------|
| Agent registered | Yes | Yes |
| Slack binding | `<slack-id>` | `<slack-id>` |
| Cron job enabled | Yes | Yes |
| Cron schedule | Every 2h | Every 2h |
| Cron model | `fw-mm25` (MiniMax) | `fw-mm25` (MiniMax) |
| Session target | `isolated` | `isolated` |
| poll-check.sh | Identical script | Identical script |
| poll-config.json | `interval_minutes: 240` | `interval_minutes: 240` |
| AGENTS.md | Identical | Identical |
| TOOLS.md | Identical (default template) | Identical (default template) |
| Directory structure | Identical | Identical |

### 2. The Actual Problem: No Native Slack Tool in Cron Sessions

When cron jobs execute, the agent gets these tools: `cron, edit, exec, memory_get, memory_search, process, read, sessions_history, sessions_list, sessions_send, sessions_spawn, session_status, subagents, web_fetch, web_search, write`.

**There is no `slack` tool.** Both agents must improvise to send Slack messages.

### 3. How dev1 Succeeds (Improvisation Chain)

In its most recent cron run (session `a9939b40`), dev1 went through this discovery process:

1. Tried `curl` with `$SLACK_BOT_TOKEN` env var -- failed (not set)
2. Tried `security` keychain lookup -- failed (no slack credentials)
3. Searched for token files -- failed
4. **Read `~/.openclaw/openclaw.json | jq '.channels.slack'`** -- SUCCESS
5. Extracted `botToken: xoxb-REDACTED`
6. Used `curl` with that token to call `https://slack.com/api/chat.postMessage` -- SUCCESS

dev1 has successfully sent messages in at least 5 cron runs by repeating this pattern.

### 4. How <your-org> Fails (Inconsistent Improvisation)

<your-org>'s cron run history shows a chaotic pattern:

- **Run at 07:20 UTC**: Claimed "Sent check-in message" -- unclear if actually delivered
- **Run at 07:27 UTC**: Explicitly said: "The `slack` tool isn't available in my current toolset... You'll need to either: 1. Send the Slack message manually, or 2. Configure the slack tool"
- **Run at 07:56 UTC**: Found `/Users/<hostname>/.local/bin/slack` CLI but discovered it is the Slack app development CLI (not for sending messages)
- **Run at 08:10 UTC**: Claimed success via some other method
- **Run at 08:30 UTC**: Reported "Slack CLI is for building apps, not sending messages. Also, the stored token is expired."
- **Run at 09:03 UTC**: Claimed success (Slack ID: `1774336221.160909`)
- **Most recent run (05:15 UTC today)**: Reported `SLACK_<slack-id>` after researching the issue

The key difference: **<your-org> never discovered the `~/.openclaw/openclaw.json` config file** containing the bot token. It keeps trying different failed approaches each run because each cron session is isolated with no memory of previous attempts.

### 5. Why the Inconsistency

Both agents use the MiniMax model (`fw-mm25`) in isolated cron sessions. Each run starts fresh with no memory of previous tool-discovery attempts. Whether an agent successfully finds the Slack token depends on:

- The model's exploration strategy in that particular run
- How much context from workspace files guides the search
- Pure luck in the sequence of `exec` commands tried

dev1 happened to try `cat ~/.openclaw/openclaw.json | jq '.channels.slack'` and found the token. <your-org> has not consistently discovered this path.

---

## Root Cause

**There is no documented, reliable mechanism for agents to send Slack messages from cron sessions.** The `slack` tool is not available in cron contexts. Agents must:

1. Discover the bot token exists in `~/.openclaw/openclaw.json`
2. Extract it via `jq`
3. Manually `curl` the Slack API

This is fragile and non-deterministic.

---

## Recommendations

### Option A: Add Slack Token to Agent TOOLS.md (Quick Fix)

Add the following to both agents' `TOOLS.md`:

```markdown
### Slack Messaging (Cron Sessions)

The `slack` tool is NOT available in cron sessions. To send Slack messages:

1. Read the bot token: `cat ~/.openclaw/openclaw.json | jq -r '.channels.slack.botToken'`
2. Send via curl:
   ```bash
   curl -s -X POST \
     -H 'Content-type: application/json' \
     -H "Authorization: Bearer $BOT_TOKEN" \
     --data '{"channel":"USER_ID","text":"Your message"}' \
     https://slack.com/api/chat.postMessage
   ```
```

### Option B: Create a Slack Helper Script (Better Fix)

Create `scripts/slack-send.sh` that encapsulates token discovery and message sending, so agents just call `scripts/slack-send.sh <user_id> <message>`.

### Option C: Enable Slack Tool in Cron Sessions (Best Fix)

If OpenClaw supports it, configure cron sessions to include the `slack` tool. This would eliminate the need for agents to improvise entirely.

### Option D: Use Cron Delivery Mode (Alternative)

The cron jobs currently have `"delivery": {"mode": "none"}`. Changing this to deliver via Slack channel would let OpenClaw handle message delivery natively, removing the need for agents to call the Slack API at all.

---

## Files Examined

- `/Users/<hostname>/.openclaw/cron/jobs.json` -- cron job definitions
- `/Users/<hostname>/.openclaw/cron/runs/1e14ae94*.jsonl` -- dev1 cron run history
- `/Users/<hostname>/.openclaw/cron/runs/b2c7a3d1*.jsonl` -- <your-org> cron run history
- `/Users/<hostname>/.openclaw/agents/dev1/sessions/a9939b40*.jsonl` -- dev1 latest cron session
- `/Users/<hostname>/.openclaw/agents/<your-org>/sessions/038db403*.jsonl` -- <your-org> latest cron session
- `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/AGENTS.md` -- agent config
- `/Users/<hostname>/openclaw-agents/.openclaw/agents/<your-org>/AGENTS.md` -- agent config
- `/Users/<hostname>/openclaw-agents/.openclaw/agents/*/TOOLS.md` -- tools config (both default)
- `/Users/<hostname>/openclaw-agents/.openclaw/agents/*/poll-config.json` -- poll config (both identical)
- `/Users/<hostname>/openclaw-agents/.openclaw/agents/*/scripts/poll-check.sh` -- poll script (both identical)
