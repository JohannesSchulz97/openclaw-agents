# OpenClaw Slack Integration for Multi-Agent Setup

**Date:** 2026-03-26
**Scope:** How Slack integration works across all agents, message routing, identity, and channel targeting

---

## Executive Summary

All agents share a **single Slack bot** (`@tob_kai`) on the **<your-org> NEU** workspace (Team ID: `T07H84JHXEX`). There is one `botToken` and one `appToken` configured globally. Agents send messages via `openclaw message send --channel slack` which routes through the gateway. Inbound DM routing via bindings is configured but has known issues (all inbound DMs currently fall through to the `main` agent). Sending to Slack **channels** (not just user DMs) is supported -- the `channel:C<ID>` target syntax works.

---

## 1. Slack Configuration (openclaw.json)

The Slack channel is configured globally at `channels.slack`:

```json
{
  "channels": {
    "slack": {
      "mode": "socket",
      "enabled": true,
      "botToken": "xoxb-7586154609507-...",
      "appToken": "xapp-1-A0ALMV7AD0B-...",
      "userTokenReadOnly": true,
      "groupPolicy": "allowlist",
      "streaming": "partial",
      "nativeStreaming": true,
      "dmPolicy": "pairing"
    }
  }
}
```

Key points:
- **Socket Mode** connection (not webhook-based)
- **Single bot token** (`xoxb-...`) shared by ALL agents
- **Single app token** (`xapp-...`) for Socket Mode
- **DM policy:** `pairing` -- inbound DMs require approval
- **Group policy:** `allowlist` -- bot must be explicitly allowed in channels
- **Bot identity:** `@tob_kai` (confirmed via `openclaw channels capabilities`)

### Implication: All Agents Appear as the Same Bot

Since there is one Slack app/bot token, every agent that sends a message appears as `@tob_kai` in Slack. There is no per-agent Slack identity. A manager agent would also appear as `@tob_kai`.

---

## 2. Agent-to-Slack-User Routing (Bindings)

Bindings map Slack users to agents for DM routing:

```
openclaw agents bindings:
- dev1      <- slack peer=direct:<slack-id>
- <your-org> <- slack peer=direct:<slack-id>
- dev10         <- slack peer=direct:<slack-id>
- dev10         <- slack peer=direct:<slack-id>
- dev10-jean   <- slack peer=direct:<slack-id>
- dev10          <- slack peer=direct:<slack-id>
```

The binding format in `openclaw.json`:

```json
{
  "type": "route",
  "agentId": "dev1",
  "match": {
    "channel": "slack",
    "peer": {
      "kind": "direct",
      "id": "<slack-id>"
    }
  }
}
```

### Known Issue: Inbound Routing Not Working

Per previous research (`openclaw-slack-routing-architecture-2026-03-25.md`), **inbound Slack DMs all route to the `main` agent** regardless of bindings. The bindings are registered but not being honored for inbound dispatch. All inbound DM sessions live under `agent:main:slack:direct:<userid>`. This may be:
- A bug in OpenClaw 2026.3.13
- Bindings may be outbound-only (identity layer, not routing layer)
- May require a gateway restart to take effect

**Outbound sending works correctly** -- agents use `openclaw message send` explicitly in their cron jobs.

---

## 3. Message Sending Mechanism

### The Canonical Method

```bash
openclaw message send --channel slack --target user:<SLACK_ID> --message "<text>"
```

Example:
```bash
openclaw message send --channel slack --target user:<slack-id> --message "Hey! Just checking in."
```

This CLI command goes through the gateway, which uses the configured bot token to deliver via the Slack API.

### Target Syntax

| Target Format | Description | Confirmed Working |
|---|---|---|
| `user:<SLACK_USER_ID>` | DM to a specific user | Yes (all agents use this) |
| `channel:<SLACK_CHANNEL_ID>` | Post to a Slack channel | Yes (dry-run test succeeded) |
| `<SLACK_USER_ID>` (bare) | DM to user (older syntax) | Yes (seen in earlier sessions) |

**Sending to a Slack channel (not just DMs) IS supported.** The dry-run test confirmed:
```bash
openclaw message send --channel slack --target channel:C12345 --message "test" --dry-run
# Result: "Sent via Slack. Message ID: unknown"
```

The bot must be a member of the target channel for this to work (due to `groupPolicy: "allowlist"`).

### Additional Send Options

From `openclaw message send --help`:
- `--media <path-or-url>` -- Attach files/images
- `--reply-to <id>` -- Reply to a specific message
- `--thread-id <id>` -- Post in a thread
- `--silent` -- Send without notification (Discord/Telegram only, not Slack)
- `--dry-run` -- Preview without sending

### Slack Channel Capabilities

Confirmed via `openclaw channels capabilities --channel slack`:
- **Chat types:** direct, channel, thread
- **Actions:** send, broadcast, react, reactions, read, edit, delete, download-file, pin, unpin, list-pins, member-info, emoji-list
- **Media:** supported
- **Native commands:** supported
- **Threads:** supported

---

## 4. How Agents Currently Use Slack

### Cron-Based Check-ins

All 6 agents have identical cron jobs (every 2 hours) that:
1. Run `scripts/poll-check.sh` to determine if a check-in is due
2. If due, compose a personalized message
3. Send via: `openclaw message send --channel slack --target user:<SLACK_ID> --message "<text>"`
4. Delivery mode is `"none"` -- the agent handles delivery itself (not the cron scheduler)

### No Native Slack Tool

There is NO native `slack` tool in the agent runtime. Agents send messages by executing the CLI command via the `exec` tool. The `slack` skill that exists in OpenClaw describes a tool interface that is not implemented.

---

## 5. Key Question: Same or Separate Slack App?

**Answer: Same Slack app. One bot. One identity.**

- All agents share the single `@tob_kai` bot token
- There is no mechanism in OpenClaw to assign different Slack apps to different agents
- The `botToken` is configured at the channel level (`channels.slack.botToken`), not per-agent
- A manager agent posting to a channel would also appear as `@tob_kai`

### Implications for a Manager Agent

If you want a manager agent that posts to a Slack channel:
1. **Identity:** It will appear as `@tob_kai` (same as all other agents). Recipients cannot distinguish which agent sent the message from the Slack bot name alone. You would need to include the agent name in the message text itself.
2. **Channel access:** The `@tob_kai` bot must be invited to the target channel.
3. **Target syntax:** Use `channel:<CHANNEL_ID>` as the target.
4. **No separate identity:** To get a separate bot identity, you would need a second Slack app with its own token. OpenClaw does not natively support multiple Slack accounts in a single instance (there is only one `channels.slack` config block).

### Workarounds for Agent Identity

- **Message prefix:** Have each agent prepend its name: `"[dev1] Hey, just checking in..."`
- **Bot profile override:** Slack's `chat.postMessage` API supports `username` and `icon_emoji` overrides if the bot has the right scopes, but this would require direct API calls (bypassing the gateway)
- **Separate OpenClaw instance:** Run a second OpenClaw instance with a different Slack app for the manager agent (heavy-weight solution)

---

## 6. Sending to Channels vs. DMs

### To a User DM
```bash
openclaw message send --channel slack --target user:<slack-id> --message "Hello"
```

### To a Slack Channel
```bash
openclaw message send --channel slack --target channel:<channel-id> --message "Hello team"
```

### To a Thread in a Channel
```bash
openclaw message send --channel slack --target channel:<channel-id> --reply-to 1234567890.123456 --message "Thread reply"
```

### Finding Channel IDs

Use the directory command:
```bash
openclaw directory groups list --channel slack
```

Note: This currently returns empty (`[]`), likely because the bot has not been added to any channels yet, or `groupPolicy: "allowlist"` requires explicit configuration. Once the bot is added to channels, they should appear here.

You can also use:
```bash
openclaw channels resolve --channel slack --kind group "#channel-name"
```

---

## 7. Architecture Diagram

```
                   Slack Workspace (<your-org> NEU)
                          |
                    @tob_kai bot
                    (Socket Mode)
                          |
                          v
                   OpenClaw Gateway
                   (port 18789, local)
                          |
            +-------------+-------------+
            |                           |
      INBOUND DMs                 OUTBOUND Sends
      (Socket Mode)               (CLI -> Gateway -> Slack API)
            |                           |
            v                           v
    Session Dispatch           openclaw message send
    (dmScope: per-channel-peer)  --channel slack
            |                    --target user:<ID>
            |                    --target channel:<ID>
            |                           |
      EXPECTED:                   Works correctly.
      Bindings route to           Agent runs CLI command
      specific agents.            via exec tool.
                                        |
      ACTUAL:                     Gateway uses botToken
      All go to "main"           to POST to Slack API.
      agent. Bug/limitation.
```

---

## 8. Summary of Answers

| Question | Answer |
|---|---|
| How are agents mapped to Slack users? | Via `bindings` in `openclaw.json` (peer kind=direct, Slack user ID) |
| Same or separate Slack app? | **Same app** (`@tob_kai`), single bot token, shared by all agents |
| Can an agent send to a channel? | **Yes**, use `--target channel:<CHANNEL_ID>` |
| Can an agent send to a user DM? | **Yes**, use `--target user:<SLACK_USER_ID>` |
| Does inbound routing work? | **No** -- bindings exist but inbound DMs all go to `main` agent |
| Does a manager need its own identity? | Not possible with current setup (single bot token). Differentiate via message content. |
| Bot token location? | `channels.slack.botToken` in `~/.openclaw/openclaw.json` |
| App token location? | `channels.slack.appToken` in `~/.openclaw/openclaw.json` |
| How do agents send messages? | Via `exec` tool running `openclaw message send` (no native slack tool) |
| Thread support? | Yes, via `--reply-to <message_id>` |
| Media/file support? | Yes, via `--media <path-or-url>` |

---

## 9. Relevant File Paths

- **Main config:** `/Users/<hostname>/.openclaw/openclaw.json`
- **Cron jobs:** `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json`
- **Agent directories:** `/Users/<hostname>/openclaw-agents/.openclaw/agents/<name>/`
- **Poll check script:** `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/poll-check.sh`
- **Prior research:** `/Users/<hostname>/openclaw-agents/docs/research/openclaw-slack-routing-architecture-2026-03-25.md`
- **Prior research:** `/Users/<hostname>/openclaw-agents/docs/research/openclaw-slack-tool-investigation-2026-03-25.md`
