---
name: openclaw-new-agent
description: Create a new agent — two-phase process across dev machine (PR) and host (post-deploy verification)
argument-hint: [agent-name] [slack-user-id]
disable-model-invocation: true
---

# Create New Agent

Create agent `$0` with Slack user ID `$1`. This is a two-phase process split across machines.

## Phase 1: Dev machine (via PR)

Run `create-agent.sh` on the dev machine:
```bash
scripts/create-agent.sh --name $0 --slack-id $1 [--type dev-pa] [--display-name "Display Name"]
```

This script:
- Creates the agent directory in `.openclaw/agents/$0/`
- Copies shared files from `types/<type>/`
- Creates per-agent template files (IDENTITY.md, USER.md, work-schedule.json)
- Adds the Slack user ID to `channels.slack.allowFrom` in `openclaw.json`
- Adds cron job entries to `jobs-config.json`

Commit the result, open a PR, merge to main. Deploy pipeline runs automatically.

## Phase 2: Host (post-deploy verification)

After the deploy pipeline completes:

1. **Verify agent directory exists:**
```bash
ls ~/.openclaw/agents/$0/
```
Check that shared files are symlinks (SOUL.md, AGENTS.md, etc.) and per-agent files are real (IDENTITY.md, USER.md).

2. **Restart gateway** to pick up the new agent config:
```bash
openclaw config validate
openclaw gateway restart
```

3. **Verify agent is registered:**
```bash
openclaw agents list | grep "$0"
```

4. **Verify Slack binding:**
```bash
openclaw agents bindings | grep "$0"
```

5. **Trigger bootstrap** (first-time agent initialization):
```bash
bash scripts/trigger-bootstrap.sh --agent $0
```

6. **Test:** Send a DM from the Slack user to verify routing works.

## Quick host-side alternative

For testing only (bypasses the type system):
```bash
openclaw agents add $0 --workspace ~/.openclaw/agents/$0 --model openai-codex/gpt-5.4
openclaw agents bind $0 --bind slack:default
```
This creates a minimal agent without shared files from `types/`. Not recommended for production agents.

## Removing an agent

On the dev machine:
```bash
scripts/remove-agent.sh --name $0
```
Commit, PR, merge. On the host after deploy: `openclaw gateway restart`.
