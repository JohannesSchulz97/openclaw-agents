# OpenClaw Cross-Agent Communication & Session Access Architecture

**Date:** 2026-03-26
**Researcher:** Claude Code (Research Agent)
**Purpose:** Architecture research for building a "manager" agent that monitors other agents
**Status:** Actionable -- contains concrete implementation paths

---

## Executive Summary

OpenClaw provides **strong agent isolation** by design but offers several mechanisms that a manager agent can leverage for cross-agent monitoring. There is no built-in "manager" or "supervisor" agent pattern, but the existing primitives (CLI commands, shared filesystem, Slack channel, cron system) can be composed to build one.

**Key finding:** The most viable approach combines:
1. `openclaw sessions --all-agents --json` for session metadata (built-in)
2. Shared filesystem files for agent status reporting
3. Slack channel posting for inter-agent communication
4. A dedicated cron job for the manager agent

---

## 1. Cross-Session Read Access

### How Sessions Work

Each agent has its own isolated session store:
```
~/.openclaw/agents/<agent-id>/sessions/sessions.json
```

Agents discovered: `main`, `dev1`, `<your-org>`, `dev10`, `dev10`, `dev10-jean`, `dev10`

### CLI Cross-Agent Session Reading (CONFIRMED WORKING)

The `openclaw sessions` command supports cross-agent reading:

```bash
# Read a specific agent's sessions
openclaw sessions --agent dev10 --json

# Read ALL agents' sessions at once
openclaw sessions --all-agents --json

# Filter to recently active sessions
openclaw sessions --all-agents --active 120 --json
```

**Output includes per-session:**
- `key` -- session identifier (includes agent ID)
- `updatedAt` -- epoch ms timestamp
- `ageMs` -- time since last update
- `inputTokens`, `outputTokens`, `totalTokens` -- token usage
- `model`, `modelProvider` -- which model is running
- `agentId` -- which agent owns the session
- `kind` -- session type (direct, cron, etc.)

**This is the primary monitoring mechanism.** A manager agent can run this command to see:
- Which agents are active
- When each agent last had activity
- Token consumption per agent
- Whether sessions are cron-triggered or human-initiated

### Direct File Access

Since all agents run on the same machine under the same OS user, a manager agent CAN directly read other agents' session files at:
```
~/.openclaw/agents/<agent-id>/sessions/sessions.json
```

However, the CLI approach is preferred as it handles parsing and aggregation.

### Session Isolation Model

- Each agent has isolated sessions (separate `sessions.json` files)
- Agents CANNOT access each other's session conversation content through the CLI
- The `sessions` command exposes **metadata only** (timestamps, token counts, models) -- NOT message content
- Session content (actual conversation history) is stored in the agent's `agent/` directory and is not exposed via CLI

---

## 2. Agent-to-Agent Communication

### No Built-In Agent-to-Agent Messaging

OpenClaw does NOT have a native "send message from Agent A to Agent B" mechanism. The `message send` command sends to external channels (Slack, Telegram, etc.), not to other agents internally.

### Agent Control Protocol (ACP)

The `openclaw acp` command provides a bridge to the Gateway, allowing programmatic agent interaction:

```bash
openclaw acp --session <key> --message "..."
```

This could theoretically be used to inject messages into another agent's session, but it is designed for external tooling integration, not inter-agent communication.

### `openclaw agent` Command (VIABLE for Manager)

The `openclaw agent` command runs a single agent turn:

```bash
# Run a turn as a specific agent
openclaw agent --agent dev10 --message "Report your status"

# Run with delivery to a channel
openclaw agent --agent dev10 --message "Report status" --deliver --reply-channel slack --reply-to "#agent-status"
```

**This is significant for a manager agent.** The manager could:
1. Use `openclaw agent --agent <id> --message "..."` to trigger a turn on another agent
2. That agent processes the message and can respond
3. With `--deliver`, the response goes to a shared Slack channel

### Message Broadcast

```bash
openclaw message broadcast --channel slack --targets user:<slack-id>,user:<slack-id> --message "Status check"
```

This sends to multiple Slack users but does NOT trigger agent turns -- it is a plain channel message.

---

## 3. Slack Integration

### Single Bot, Multiple Agents

**Critical finding:** All agents share a SINGLE Slack bot/app:
- Bot token: `xoxb-7586154609507-...`
- App token: `xapp-1-A0ALMV7AD0B-...`
- Mode: Socket mode
- Streaming: Partial + native streaming enabled

### Routing via Bindings

Agent-to-Slack-user mapping is done through `bindings` in `openclaw.json`:

```json
{
  "type": "route",
  "agentId": "dev1",
  "match": {
    "channel": "slack",
    "peer": { "kind": "direct", "id": "<slack-id>" }
  }
}
```

Each agent is bound to a specific Slack user ID via DM routing:
| Agent | Slack User ID |
|-------|--------------|
| dev1 | <slack-id> |
| <your-org> | <slack-id> |
| dev10 | <slack-id> |
| dev10 | <slack-id> |
| dev10-jean | <slack-id> |
| dev10 | <slack-id> |

### Can Multiple Agents Post to the Same Channel?

**Yes.** The `openclaw message send` command does not restrict by agent. Any agent can post to any Slack target:

```bash
openclaw message send --channel slack --target "#shared-channel" --message "..."
openclaw message send --channel slack --target user:<slack-id> --message "..."
```

**Implication for manager agent:** A shared Slack channel (e.g., `#agent-status`) could serve as a communication hub where:
- The manager agent posts summaries
- Individual agents post status updates
- Humans can observe all agent activity

### DM Scope

Configuration: `"dmScope": "per-channel-peer"` -- each DM creates a separate session per channel peer.

---

## 4. Memory/State Sharing

### Agent Directory Structure

Each agent at `~/.openclaw/agents/<id>/` contains:
```
SOUL.md          -- personality (symlink to repo)
AGENTS.md        -- operating manual (symlink)
IDENTITY.md      -- per-agent identity (symlink)
USER.md          -- per-agent user info (symlink)
HEARTBEAT.md     -- periodic tasks (symlink)
TOOLS.md         -- tool config (symlink)
BOOTSTRAP.md     -- first-run (symlink)
scripts/         -- shared scripts (symlink)
memory/          -- per-agent runtime state
  poll-state.json  -- polling state (symlink to repo)
sessions/        -- session data (local, not symlinked)
agent/           -- agent runtime state (local)
.openclaw/       -- agent-specific openclaw config
```

### Shared Memory Directory

There is a `~/.openclaw/agents/memory/` directory at the agents root level containing:
```json
// ~/.openclaw/agents/memory/poll-state.json
{
  "interval_minutes": 240,
  "last_interaction": "2026-03-23T07:40:35Z"
}
```

This appears to be a **legacy/shared** poll state, separate from per-agent memory. Per-agent memory lives at `~/.openclaw/agents/<id>/memory/`.

### Can an Agent Read Another Agent's Memory?

**Technically yes, via filesystem.** All agents run under the same OS user (`<hostname>`), and the memory directories are world-readable (`drwxr-xr-x`). An agent running a shell command could:

```bash
cat ~/.openclaw/agents/dev10/memory/poll-state.json
cat ~/.openclaw/agents/dev1/memory/2026-03-26.md
```

**However, agents are workspace-scoped.** Each agent's workspace is set to its own directory (e.g., `workspace: /Users/<hostname>/openclaw-agents/.openclaw/agents/dev10`). Agents would need to use absolute paths to reach outside their workspace. OpenClaw's boundary security blocks symlinks outside the workspace, but direct file reads via shell commands are NOT blocked.

### Memory Search

The `openclaw memory` command supports search and indexing:
```bash
openclaw memory search "deployment" --max-results 20
openclaw memory status
```

This appears to be scoped to the current agent's memory, not cross-agent.

---

## 5. Viable Manager Agent Architecture

### Option A: CLI-Based Monitor (Recommended -- Simplest)

Create a new agent (`manager`) with a cron job that:

1. Runs `openclaw sessions --all-agents --json` to get session metadata
2. Reads each agent's `memory/poll-state.json` for last check-in status
3. Reads each agent's recent `memory/YYYY-MM-DD.md` for activity summaries
4. Compiles a status report
5. Posts to a shared Slack channel via `openclaw message send`

**Cron job payload:**
```
1. Run: openclaw sessions --all-agents --json --active 240
2. For each agent in [dev1, dev10, dev10, dev10-jean, dev10, <your-org>]:
   - Read ~/.openclaw/agents/<agent>/memory/poll-state.json
   - Check if agent has been active recently
3. Compile team status summary
4. Post to Slack: openclaw message send --channel slack --target "#agent-status" --message "<summary>"
```

**Pros:** Uses only existing CLI tools, no code changes needed.
**Cons:** Cannot read conversation content, only metadata.

### Option B: Shared Status Files

Modify the dev-pa type to have agents write status summaries to a shared location.

1. Add to `HEARTBEAT.md` or cron payload: "After each check-in, write a one-line status to `/Users/<hostname>/openclaw-agents/.openclaw/agents/<name>/memory/status.json`"
2. Manager agent reads all `status.json` files

**Status file format:**
```json
{
  "agent": "dev10",
  "timestamp": "2026-03-26T10:00:00Z",
  "status": "active",
  "last_checkin_sent": true,
  "last_human_response": "2026-03-26T09:30:00Z",
  "summary": "Checked in with dev10 about API refactoring"
}
```

**Pros:** Rich status data, agents self-report.
**Cons:** Requires modifying the dev-pa type and re-syncing.

### Option C: Shared Slack Channel Hub

Create a dedicated Slack channel (e.g., `#kai-status`) where:

1. Each agent posts a status update after every check-in (add to cron payload)
2. Manager agent reads the channel via `openclaw message read --channel slack --target "#kai-status" --limit 50`
3. Manager compiles and analyzes the status messages

**Pros:** Human-visible, uses existing Slack infrastructure, natural communication pattern.
**Cons:** Requires agents to actively post, adds token cost per agent.

### Option D: Hybrid (Recommended for Production)

Combine Options A + B + C:

1. **Manager cron job** runs every 2-4 hours
2. **Step 1:** `openclaw sessions --all-agents --json` for live metadata
3. **Step 2:** Read each agent's `memory/poll-state.json` for check-in state
4. **Step 3:** Read each agent's last `status.json` (if implementing Option B)
5. **Step 4:** Compile report and post to `#kai-status` Slack channel
6. **Step 5:** If any agent appears stuck (no activity for >4h, or error state), alert the human

---

## 6. Implementation Recommendations

### Create the Manager Agent

```bash
scripts/create-agent.sh --name manager --slack-id <your-slack-id> --type dev-pa --model openai-codex/gpt-5.4
```

### Manager Cron Job (Add to jobs-config.json)

```json
{
  "id": "manager-status-check",
  "agentId": "manager",
  "name": "Manager Status Check",
  "enabled": true,
  "schedule": { "kind": "every", "everyMs": 14400000 },
  "sessionTarget": "isolated",
  "wakeMode": "now",
  "payload": {
    "kind": "agentTurn",
    "message": "Run team status check:\n1. Run: openclaw sessions --all-agents --json\n2. For each agent, read ~/.openclaw/agents/<id>/memory/poll-state.json\n3. Compile status report showing: agent name, last activity, token usage, check-in state\n4. Post report to Slack: openclaw message send --channel slack --target \"#kai-status\" --message \"<report>\"",
    "timeoutSeconds": 300,
    "thinking": "on",
    "model": "openai-codex/gpt-5.4"
  },
  "sessionKey": "agent:manager:main",
  "delivery": { "mode": "none" }
}
```

### Modify dev-pa Agents to Write Status (Optional Enhancement)

Add to the cron check-in payload for each agent, after step 6:

```
7. Write a JSON status file: echo '{"agent":"<name>","timestamp":"<now>","status":"ok","last_checkin":"<summary>"}' > memory/status.json
```

---

## 7. Security Considerations

- All agents run under the same OS user -- filesystem isolation is NOT enforced at the OS level
- OpenClaw's boundary security blocks symlinks outside workspace but does NOT prevent shell commands from reading arbitrary files
- The single Slack bot token means any agent can impersonate any other in Slack DMs (they all post as the same bot)
- API keys in `openclaw.json` are readable by all agents (Fireworks, Google, Slack tokens)
- A manager agent with shell access could read conversation content from other agents' `agent/` directories

---

## 8. Limitations and Open Questions

1. **No conversation content access via CLI** -- `openclaw sessions` shows metadata only, not message history
2. **No built-in agent-to-agent messaging** -- must go through external channels (Slack) or filesystem
3. **No agent health/liveness endpoint** -- must infer from session timestamps
4. **Session memory is opaque** -- the `memory search` command appears agent-scoped
5. **Unclear if `openclaw agent --agent <id>` creates cross-session pollution** -- needs testing
6. **The `openclaw system presence` command** may show agent liveness but requires a running gateway -- needs investigation

---

## Appendix: Key File Paths

| Resource | Path |
|----------|------|
| Main config | `~/.openclaw/openclaw.json` |
| Agent list | `~/.openclaw/openclaw.json` -> `agents.list` |
| Agent workspace | `~/.openclaw/agents/<id>/` |
| Agent sessions | `~/.openclaw/agents/<id>/sessions/sessions.json` |
| Agent memory | `~/.openclaw/agents/<id>/memory/` |
| Agent runtime | `~/.openclaw/agents/<id>/agent/` |
| Cron config | `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json` |
| Repo agent configs | `/Users/<hostname>/openclaw-agents/.openclaw/agents/<id>/` |
| Type definitions | `/Users/<hostname>/openclaw-agents/types/dev-pa/` |

## Appendix: Key CLI Commands for Manager Agent

```bash
# Session monitoring
openclaw sessions --all-agents --json
openclaw sessions --all-agents --active 120 --json
openclaw sessions --agent <id> --json

# Message sending
openclaw message send --channel slack --target "#channel" --message "..."
openclaw message send --channel slack --target user:<SLACK_ID> --message "..."
openclaw message broadcast --channel slack --targets "target1,target2" --message "..."
openclaw message read --channel slack --target "#channel" --limit 50 --json

# Agent interaction
openclaw agent --agent <id> --message "..." --json
openclaw agent --agent <id> --message "..." --deliver --reply-channel slack --reply-to "#channel"

# System status
openclaw agents list --json
openclaw channels status
openclaw cron list
openclaw cron runs
openclaw system presence --json
```
