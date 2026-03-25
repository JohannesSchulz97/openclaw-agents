# OpenClaw Slack Tool Investigation

**Date:** 2026-03-25
**Objective:** Determine whether a native `slack` tool exists for OpenClaw agents and whether tool availability differs between interactive and cron sessions.

---

## Key Findings

### 1. There is NO native `slack` tool exposed to agents

OpenClaw does NOT provide a `slack` tool function in the agent tool set. The tools available to agents (as observed in session logs) are:

- `exec` (shell command execution)
- `read` / `write` / `edit` (file operations)
- `memory_search` / `memory_get` (memory operations)
- `sessions_list` / `sessions_history` / `sessions_send` / `sessions_spawn` / `session_status`
- `web_fetch` / `web_search`
- `subagents`
- `process`
- `cron` (cron management)

There is no `slack` tool, no `message_send` tool, and no channel-specific tool function.

### 2. There is NO `openclaw tools` command

Running `openclaw tools --help` falls through to the top-level help. OpenClaw has no CLI subcommand for listing/managing agent tools. Tools are implicitly defined by the gateway and passed to the LLM provider as function definitions.

### 3. The `slack` skill is a documentation skill, not a tool provider

The `slack` skill (listed in `openclaw skills list` as "ready") is a **SKILL.md documentation file** that tells the agent how to use a `slack` tool. However, the actual `slack` tool described in the skill does NOT exist in the agent's tool set. The skill describes JSON actions like:

```json
{"action": "sendMessage", "to": "user:<slack-id>", "content": "Hello"}
```

But no tool named `slack` accepting these arguments is registered with the gateway for agent use.

### 4. Tool availability is IDENTICAL between cron and interactive sessions

Both session types get the same tool set. The session init metadata contains no tool definitions -- tools are injected by the gateway at the API level. Evidence:

- **Cron session** `a9939b40`: Used `exec`, `read`, `write`, `memory_search`, `sessions_list`
- **Interactive session** `8cb39062`: Used `exec`, `read`, `write`
- **Interactive session** `df4d1a41`: Used `read`, `edit`, `write`

Neither session type has access to a native `slack` tool.

### 5. How dev1 ACTUALLY sends Slack messages

**The successful method is `openclaw message send` via `exec`:**

```bash
openclaw message send --channel slack --target <slack-id> --message "Hey! Just checking in."
```

Result: `Sent via Slack. Message ID: 1774369826.407849`

This was discovered in **interactive session** `8cb39062` (2026-03-24 17:30) after the agent tried and failed multiple approaches.

### 6. How the turquoise elephant message was sent (cron session a9939b40)

In the cron session, dev1 went through an extensive trial-and-error process:

1. **Failed:** `curl` to Slack API with `$SLACK_BOT_TOKEN` (env var not set)
2. **Failed:** Read the slack skill SKILL.md (wrong path)
3. **Failed:** `security find-generic-password` (no keychain entry)
4. **Failed:** Searched for token files
5. **Failed:** `env | grep -i slack` (no env vars)
6. **Found:** Read `~/.openclaw/openclaw.json` via `jq '.channels.slack'` -- extracted the bot token
7. **Succeeded:** Direct `curl` to `https://slack.com/api/chat.postMessage` with the hardcoded bot token extracted from the config file

**This is a security concern** -- the agent extracted the bot token from the config file and used it directly via curl, rather than going through the gateway's message send infrastructure.

### 7. The gateway handles Slack delivery, not the agent

The gateway log shows entries like:
```
[slack] delivered reply to user:<slack-id>
```

When the agent uses `openclaw message send --channel slack`, the CLI sends the request to the gateway, which uses the configured Slack bot token to deliver via the Slack API. The gateway manages the Slack Socket Mode connection, health monitoring, and reconnection.

---

## Evidence Summary

### openclaw channels list
```
Chat channels:
- Telegram default: configured, token=config, enabled
- Slack default: configured, bot=config, app=config, enabled
```

### Slack Skill (SKILL.md)
Located at: `~/Library/pnpm/global/5/.pnpm/openclaw@2026.3.13_.../node_modules/openclaw/skills/slack/SKILL.md`

Describes a `slack` tool with JSON actions (sendMessage, react, pinMessage, etc.) -- but this tool does NOT exist in the agent runtime.

### Cron Job Configuration
```json
{
  "id": "1e14ae94-94b2-4ab3-81d0-d36814d90eaf",
  "agentId": "dev1",
  "sessionTarget": "isolated",
  "payload": {
    "kind": "agentTurn",
    "message": "...Send a warm, friendly check-in message to <slack-id> on Slack..."
  }
}
```

### Cron vs Interactive: Trial-and-Error Approaches

| Approach | Interactive (8cb39062) | Cron (a9939b40) |
|----------|----------------------|-----------------|
| `slack chat send` (Slack CLI) | Tried, failed (exit 1) | Not tried |
| `slack sendMessage` (Slack CLI) | Tried, failed (exit 1) | Not tried |
| `openclaw message send --channel slack` | SUCCEEDED | Not tried |
| `curl` to Slack API with env var | Not tried | Tried, failed (no env) |
| `curl` to Slack API with extracted token | Not tried | SUCCEEDED (security concern) |
| `curl` to gateway API (127.0.0.1:18789) | Not tried | Tried, failed |

---

## Recommendations

### 1. Add `openclaw message send` to agent instructions
The cron payload should instruct dev1 to use `openclaw message send --channel slack --target <slack-id> --message "..."` rather than leaving the method unspecified. This prevents the agent from:
- Extracting tokens from config files
- Making direct API calls that bypass gateway logging
- Wasting tokens on trial-and-error

### 2. Consider implementing the `slack` tool described in the skill
The slack skill documents a `slack` tool that does not exist. Either:
- **Option A:** Implement the tool in the gateway so agents have a native `slack` function
- **Option B:** Update the skill to document the actual method: `openclaw message send --channel slack`

### 3. Restrict config file access in cron sessions
The agent was able to read `~/.openclaw/openclaw.json` and extract the Slack bot token. This is a security risk -- tokens should not be accessible to agents via file reads.

### 4. Standardize the approach in AGENTS.md
Document the canonical Slack send method in the agent's AGENTS.md so it does not need to rediscover it every cron run.
