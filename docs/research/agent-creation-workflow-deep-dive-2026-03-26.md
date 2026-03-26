# Agent Creation Workflow Deep Dive

**Date:** 2026-03-26
**Scope:** Full agent creation workflow analysis for openclaw-agents repository
**Classification:** Informational (reference material)

---

## 1. Existing Agents

| Agent Name     | Slack ID       | Type         | GitHub Users                   |
|----------------|----------------|--------------|--------------------------------|
| dev1       | <slack-id>   | dev-pa       | <github-username>, <manager-agent>     |
| <your-org>  | <slack-id>   | dev-pa       | --                             |
| dev10          | <slack-id>   | dev-pa       | <github-username>                         |
| dev10          | <slack-id>   | dev-pa       | <github-username>                     |
| dev10-jean    | <slack-id>   | dev-pa       | <github-username>                     |
| dev10           | <slack-id>   | dev-pa       | <github-username>               |
| tech-manager   | N/A (channel)  | manager      | N/A                            |

**7 total agent directories** under `.openclaw/agents/`.

---

## 2. openclaw.json Agent Entry Structure

Each agent in `agents.list[]` follows this exact structure:

```json
{
  "id": "dev1",
  "name": "dev1",
  "workspace": "/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1",
  "agentDir": "/Users/<hostname>/.openclaw/agents/dev1/agent",
  "model": "openai-codex/gpt-5.4"
}
```

**Key fields:**
- `id` and `name`: Both set to the kebab-case agent name
- `workspace`: Points to the openclaw-agents repo copy (`REPO_ROOT/.openclaw/agents/<name>`)
- `agentDir`: Points to the stowed location (`~/.openclaw/agents/<name>/agent`)
- `model`: Reads from `agents.defaults.model.primary` (currently `openai-codex/gpt-5.4`)

The `add_agent_entry()` function in `scripts/lib/openclaw-utils.sh` reads the default model from `agents.defaults.model.primary` automatically.

---

## 3. Bindings Configuration

Each dev-pa agent gets a Slack DM route binding:

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

The tech-manager agent has a different binding (channel, not direct):

```json
{
  "type": "route",
  "agentId": "tech-manager",
  "match": {
    "channel": "slack",
    "peer": {
      "kind": "channel",
      "id": "<channel-id>"
    }
  }
}
```

The `add_binding()` function in `openclaw-utils.sh` ONLY creates `kind: "direct"` bindings. Channel bindings must be added manually.

---

## 4. Allowlist / AllowFrom Configuration

### 4.1 Two Separate Allowlist Mechanisms

**Mechanism A: `channels.slack.allowFrom` (in openclaw.json)**

```json
"channels": {
  "slack": {
    "dmPolicy": "allowlist",
    "allowFrom": [
      "<slack-id>",
      "<slack-id>",
      "<slack-id>",
      "<slack-id>",
      "<slack-id>",
      "<slack-id>"
    ]
  }
}
```

This controls which Slack users can DM the bot. Current dmPolicy is `"allowlist"`, meaning only users in this array can send DMs.

**Mechanism B: `~/.openclaw/credentials/slack-default-allowFrom.json`**

```json
{
  "version": 1,
  "allowFrom": [
    "<slack-id>",
    "<slack-id>",
    "<slack-id>",
    "<slack-id>",
    "<slack-id>"
  ]
}
```

This is managed by the pairing system. Note: dev10's ID (`<slack-id>`) is in `openclaw.json` but NOT in this credentials file.

### 4.2 Does create-agent.sh Handle Allowlist?

**NO.** `create-agent.sh` does NOT add the new agent's Slack ID to:
- `channels.slack.allowFrom` in `openclaw.json`
- `~/.openclaw/credentials/slack-default-allowFrom.json`

This is a **documented gap** in the workflow. After running `create-agent.sh`, you must manually add the Slack user ID to the `allowFrom` array, or the user will be unable to DM the bot.

### 4.3 What create-agent.sh DOES Handle

The script handles these openclaw.json modifications via `openclaw-utils.sh`:
1. Adds entry to `agents.list[]` (via `add_agent_entry`)
2. Adds Slack DM route binding to `bindings[]` (via `add_binding`)

It does NOT modify:
- `channels.slack.allowFrom`
- `channels.slack.channels` (for channel-based agents)
- The credentials file

---

## 5. Cron Job Template

The `add_cron_job()` function in `scripts/lib/cron-utils.sh` creates this structure for dev-pa agents:

```json
{
  "id": "<generated-uuid>",
  "agentId": "<agent-name>",
  "name": "<Display Name> Check-in",
  "enabled": true,
  "schedule": {
    "kind": "every",
    "everyMs": 7200000
  },
  "sessionTarget": "isolated",
  "wakeMode": "now",
  "payload": {
    "kind": "agentTurn",
    "message": "<check-in message with substituted slack_id>",
    "timeoutSeconds": 180,
    "thinking": "on",
    "model": "<model>"
  },
  "sessionKey": "agent:<agent-name>:main",
  "delivery": {
    "mode": "none"
  }
}
```

**Key parameters:**
- Schedule: every 7200000ms (2 hours)
- Session: `isolated` with `wakeMode: "now"`
- Timeout: 180 seconds
- Delivery: `none` (agent sends messages itself via openclaw CLI)
- Session key: `agent:<name>:main`

**Note:** The cron template in `cron-utils.sh` uses a simpler message than what's currently in jobs-config.json. The existing jobs have been manually enhanced with GitHub activity integration steps. New agents created by the script will get the simpler message template.

---

## 6. Full create-agent.sh Workflow (8 Steps)

1. **Validate** -- Check name format (kebab-case), Slack ID format (U...), type dir exists, agent doesn't already exist, jq and stow installed
2. **Create agent directory** -- mkdir `.openclaw/agents/<name>/memory/`, write `.agent-type` file, copy `IDENTITY.md.template` and `USER.md.template`, create/copy `memory/poll-state.json`
3. **Sync shared files** -- Runs `sync-agents.sh` which copies SOUL.md, AGENTS.md, TOOLS.md, HEARTBEAT.md, BOOTSTRAP.md, poll-config.json, and scripts/ from `types/<type>/` into the agent directory
4. **Add cron job** -- Uses `cron-utils.sh:add_cron_job()` to append a check-in job to `jobs-config.json`
5. **Apply cron** -- Runs `apply-cron.sh` to reconcile gateway cron jobs with config (3-phase: ADD/EDIT/REMOVE)
6. **Run stow** -- `cd .openclaw && stow --no-folding -t ~/.openclaw .` to create symlinks
7. **Register in openclaw.json** -- Adds `agents.list[]` entry and `bindings[]` route via `openclaw-utils.sh`
8. **Update CLAUDE.md** -- Appends agent info section before "## Useful Commands"

---

## 7. Workflow Gaps and Missing Steps

### GAP 1: allowFrom Not Updated (CRITICAL)

`create-agent.sh` does NOT add the Slack user ID to `channels.slack.allowFrom` in openclaw.json. With `dmPolicy: "allowlist"`, the new user will be silently rejected when trying to DM the bot.

**Manual fix required after agent creation:**
```bash
# Edit openclaw.json and add the Slack ID to channels.slack.allowFrom array
# Then restart gateway:
openclaw gateway restart
```

### GAP 2: Cron Message Template Outdated

The `cron-utils.sh` template generates a simpler check-in message that lacks the GitHub activity integration steps present in the manually-enhanced existing jobs. New agents will not have:
- GitHub username lookup from USER.md
- GitHub activity script execution
- Organization-scoped activity restrictions

### GAP 3: Gateway Restart Not Triggered

After modifying `openclaw.json` (adding agent entry and binding), `create-agent.sh` does NOT restart the gateway. The new agent and binding may not be recognized until manual restart.

### GAP 4: IDENTITY.md and USER.md Need Manual Editing

The script copies templates but does not substitute agent-specific values. The "Next steps" output correctly mentions this, but it's easy to forget.

### GAP 5: No Validation of Existing allowFrom

The script doesn't check whether the Slack ID is already in allowFrom or warn that it needs to be added.

---

## 8. apply-cron.sh Reconciliation Process

Three-phase declarative sync:
1. **ADD** -- Config entries with no gateway match (by agentId) get created via `openclaw cron add`
2. **EDIT** -- Config entries with existing gateway match get updated via `openclaw cron edit`
3. **REMOVE** -- Gateway jobs with agentId NOT in config get deleted via `openclaw cron rm`

Uses locking (`flock` on Linux, `mkdir`-based on macOS) to prevent concurrent runs.

---

## 9. sync-agents.sh Behavior

- Reads `.agent-type` file from each agent directory (falls back to `dev-pa`)
- Copies shared files: SOUL.md, AGENTS.md, TOOLS.md, HEARTBEAT.md, BOOTSTRAP.md, poll-config.json
- Rsyncs `scripts/` directory (with `--delete` flag)
- Template files (IDENTITY.md, USER.md) are only copied if target does NOT already exist
- Removes any existing symlinks before copying (handles migration from symlink-based to copy-based approach)
- Idempotent and safe to run multiple times

---

## 10. Complete Agent Creation Checklist

For a new dev-pa agent, the full process is:

```bash
# 1. Run the creation script
scripts/create-agent.sh --name <agent-name> --slack-id <SLACK_ID>

# 2. MANUAL: Add Slack ID to allowFrom in openclaw.json
# Edit channels.slack.allowFrom array to include the new Slack ID

# 3. MANUAL: Edit IDENTITY.md with agent personality
# Edit .openclaw/agents/<name>/IDENTITY.md

# 4. MANUAL: Edit USER.md with user context and GitHub username
# Edit .openclaw/agents/<name>/USER.md

# 5. MANUAL: Restart gateway to pick up openclaw.json changes
openclaw gateway restart

# 6. MANUAL: Optionally update the cron job message to include GitHub activity
# Edit .openclaw/cron/jobs-config.json, then run scripts/apply-cron.sh

# 7. Trigger first bootstrap session
openclaw cron run <job-id>
```
