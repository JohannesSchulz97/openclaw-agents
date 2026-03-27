# Research: Deleting Slack Messages Sent by OpenClaw Bot

**Date:** 2026-03-27
**Status:** Actionable
**Goal:** Find and delete creepy check-in messages sent to developers from unbootstrapped agents

---

## Summary

OpenClaw has full support for deleting Slack messages via `openclaw message delete`. The main challenge is obtaining the message IDs (Slack `ts` values) and the correct target identifiers for DM conversations.

---

## Key Findings

### 1. OpenClaw `message delete` Command -- CONFIRMED WORKING

```bash
openclaw message delete \
  --channel slack \
  --target <user-or-channel-id> \
  --message-id <slack-ts>
```

- The `delete` action is listed in Slack channel capabilities
- Dry-run confirms the command accepts the right parameters
- The bot (@tob_kai) can delete its own messages (Slack bots can always delete their own messages with `chat:write` scope)

### 2. Message Reading from DMs -- CURRENTLY BROKEN

```bash
openclaw message read --channel slack --target <slack-id> --limit 5 --json
# Error: An API error occurred: channel_not_found
```

- `message read` fails with `channel_not_found` for all user IDs tested
- This is likely because the Slack API requires a DM channel ID (D-prefixed), not a user ID (U-prefixed), for `conversations.history`
- The bot may be missing `im:history` scope, or OpenClaw's Slack adapter does not auto-open DM channels for the `read` command

### 3. Message IDs Found in Logs (Limited)

Only 2 message IDs are visible in the current gateway logs:

| Message ID (ts) | Timestamp | Likely Target |
|---|---|---|
| `1774606505.628359` | 2026-03-27T10:15:05Z | dev10 (<slack-id>) -- cron check-in |
| `1774608036.194599` | 2026-03-27T10:40:36Z | <your-org> (<slack-id>) -- Bootstrap Trigger |

The logs do NOT record target user/channel next to "Sent via Slack" entries. The `delivered reply to user:UXXXX` lines show interactive replies, not cron-initiated messages.

### 4. LCM Database Does Not Store Slack Message IDs

The `lcm.db` stores conversation content and token counts but not Slack-specific message identifiers (ts values). There is no way to retrieve historical message IDs from this database.

### 5. Bot Identity and Capabilities

- **Bot name:** @tob_kai
- **Team:** <your-org> NEU (T07H84JHXEX)
- **Supported actions:** send, broadcast, react, reactions, read, edit, **delete**, download-file, pin, unpin, list-pins
- **Chat types:** direct, channel, thread

---

## Approaches to Delete Messages

### Option A: Use `openclaw message delete` with Known Message IDs (Best for recent messages)

For the 2 message IDs found in logs:

```bash
# Delete the message sent around 10:15 (likely to dev10)
openclaw message delete --channel slack --target <slack-id> --message-id 1774606505.628359

# Delete the message sent around 10:40 (likely to <your-org>)
openclaw message delete --channel slack --target <slack-id> --message-id 1774608036.194599
```

**Caveat:** The `--target` might need the DM channel ID (D-prefixed) instead of the user ID. If user ID does not work, you need to look up the DM channel ID via the Slack API.

### Option B: Use Slack API Directly via curl (Best for bulk deletion)

If you have access to the bot token, you can:

1. **Open DM channel** to get the channel ID:
   ```bash
   curl -X POST https://slack.com/api/conversations.open \
     -H "Authorization: Bearer xoxb-YOUR-BOT-TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"users": "<slack-id>"}'
   # Returns: {"ok": true, "channel": {"id": "D0XXXXXXX"}}
   ```

2. **List messages in DM channel** to find bot messages:
   ```bash
   curl "https://slack.com/api/conversations.history?channel=D0XXXXXXX&limit=100" \
     -H "Authorization: Bearer xoxb-YOUR-BOT-TOKEN"
   ```

3. **Delete each bot message**:
   ```bash
   curl -X POST https://slack.com/api/chat.delete \
     -H "Authorization: Bearer xoxb-YOUR-BOT-TOKEN" \
     -H "Content-Type: application/json" \
     -d '{"channel": "D0XXXXXXX", "ts": "1774606505.628359"}'
   ```

**Required scopes:** `chat:write` (for delete), `im:history` (for reading DM history), `conversations:open` (or `im:write`)

### Option C: Use Slack CLI (Available but different auth)

The Slack CLI is installed (`/Users/<hostname>/.local/bin/slack`) and authenticated for workspace `<your-org>` (T07H84JHXEX) as user <slack-id>. However, this is a user-level CLI for Slack app development, not for bot message management. It would not have access to delete bot messages.

### Option D: Ask Developers to Delete Messages Themselves

Each developer can delete bot messages in their own DM:
- Open the DM with @tob_kai
- Hover over each bot message
- Click "..." > "Delete message" (this only works if workspace admins allow message deletion)

**Note:** Slack users typically cannot delete other users'/bots' messages. Only the bot itself or workspace admins can delete bot messages.

---

## Required Information to Proceed

1. **Bot token (xoxb-...)**: Check if it is stored in OpenClaw's internal config. It is not in `/Users/<hostname>/.openclaw/credentials/`. It may be in `openclaw.json` or environment variables.

2. **DM channel IDs**: Need to map each user ID to their DM channel with the bot. This requires either:
   - The Slack API `conversations.open` call
   - Or fixing the `message read` command to work with user IDs

3. **Historical message IDs**: The gateway logs only retain recent entries. Older creepy check-in messages from before the standardization fix may not have their ts values logged anywhere.

---

## Recommended Action Plan

1. **Check for bot token:**
   ```bash
   openclaw config get channels.slack.token 2>&1
   # or
   grep -r "xoxb" ~/.openclaw/ 2>/dev/null
   ```

2. **If token available -- write a bulk delete script:**
   - For each agent's target user, call `conversations.open` to get DM channel ID
   - Call `conversations.history` to list bot messages
   - Filter for messages matching the creepy check-in pattern
   - Call `chat.delete` for each matching message

3. **If token not directly available -- use OpenClaw's message delete:**
   - First fix the `message read` issue (may need to report as bug)
   - Or use `openclaw message delete` with the 2 known message IDs as a test

4. **Prevent future creepy messages:**
   - Already addressed by the standardized check-in messages (commit a3b25fc)
   - Ensure all agents have `.BOOTSTRAP.md.done` markers or stop bootstrap cron jobs for agents that should not auto-bootstrap

---

## Agents Affected

Based on logs, the following agents sent cron-triggered messages today:

| Agent | Slack User | Status |
|---|---|---|
| dev10 | <slack-id> | Active cron check-ins, interactive conversation ongoing |
| <your-org> | <slack-id> | Bootstrap trigger fired, unbootstrapped (no .BOOTSTRAP.md.done) |
| dev1 | <slack-id> | Cron scheduled |
| dev10 | <slack-id> | Cron scheduled |

All 18 dev-pa agents have cron jobs and could have sent messages to their respective developers.
