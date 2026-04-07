---
name: openclaw-add-channel
description: Add a Slack DM binding for an agent — adds Slack user ID to allowFrom and creates the agent binding
argument-hint: [agent-name] [slack-user-id]
disable-model-invocation: true
---

# Add Slack Channel Binding

Add agent `$0` with Slack user ID `$1` to the DM allowlist and create a routing binding. This is Slack-only — we don't use Telegram, WhatsApp, or GChat for agent bindings.

Note: `create-agent.sh` already handles this for new agents. This skill is for adding Slack access to an existing agent that was created without it, or for adding additional Slack user IDs.

## Steps

1. **Add Slack user ID to the DM allowlist:**

Edit `~/.openclaw/openclaw.json` and add `$1` (the Slack user ID, e.g., `<slack-id>`) to the `channels.slack.allowFrom` array if not already present.

2. **Add agent binding** (if not already bound):
```bash
openclaw agents bind $0 --bind slack:default
```
Or manually add to the `bindings` array in `openclaw.json`:
```json
{"agentId": "$0", "match": {"channel": "slack", "accountId": "default"}}
```

3. **Validate and restart:**
```bash
openclaw config validate
openclaw gateway restart
```

4. **Verify:**
```bash
openclaw agents bindings | grep "$0"
```
Confirm the agent shows a Slack binding.

5. **Test:** Send a DM to the agent from the Slack user to confirm routing works.

## Important

- `dmPolicy` is `"allowlist"` — only Slack user IDs in the `allowFrom` array can DM agents
- No keychain operations needed — Slack tokens are already configured at the channel level
- No secrets scripts to update
