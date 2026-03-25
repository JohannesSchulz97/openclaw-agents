# OpenClaw Slack Message Routing Architecture

**Date:** 2026-03-25
**Scope:** How OpenClaw routes incoming Slack DMs to agent sessions
**Trigger:** Slack DM to <slack-id> (<your-org>) was handled by the "main" agent on gpt-5.4, not <your-org> agent

---

## Executive Summary

**The routing bindings exist but are NOT being honored for inbound Slack DMs.** Despite explicit `bindings` configuration mapping Slack user <slack-id> to agent `<your-org>`, all inbound Slack DMs are being routed to the `main` agent's session store. The `<your-org>` agent only has cron job sessions -- zero Slack DM sessions.

This is either a bug in OpenClaw's routing engine, or the bindings only apply to outbound message routing (which agent *sends* to which Slack user), not inbound message dispatch.

---

## Findings

### 1. Routing Bindings Configuration

The `openclaw.json` has explicit bindings in the `bindings` array:

```json
"bindings": [
  {
    "type": "route",
    "agentId": "dev1",
    "match": {
      "channel": "slack",
      "accountId": "<slack-id>"
    }
  },
  {
    "type": "route",
    "agentId": "<your-org>",
    "match": {
      "channel": "slack",
      "accountId": "<slack-id>"
    }
  }
]
```

`openclaw agents bindings` confirms these are registered:
- **dev1** <-> slack:<slack-id>
- **<your-org>** <-> slack:<slack-id>

### 2. What Actually Happens: All DMs Go to "main"

Despite bindings, ALL Slack DM sessions live under the **main** agent's session store:

| Session Key | Agent | Model | Provider |
|---|---|---|---|
| `agent:main:slack:direct:u07h87k34qj` | main | gpt-5.4 | openai-codex |
| `agent:main:slack:direct:u09l59gj3qt` | main | gpt-5.4 | openai-codex |
| `agent:main:main` | main | gpt-5.4 | openai-codex |

Session file location: `/Users/<hostname>/.openclaw/agents/main/sessions/`

The session for <slack-id> shows:
- `origin.label`: "<your-org> AG"
- `origin.from`: "slack:<slack-id>"
- `agentId`: NOT set at session level (inherited from path)
- `workspaceDir`: `/Users/<hostname>/.openclaw/workspace` (the **main** agent's workspace, NOT <your-org>'s)
- `model`: gpt-5.4 via openai-codex

### 3. <your-org> Agent Has ZERO Slack Sessions

<your-org> agent's session store (`~/.openclaw/agents/<your-org>/sessions/`) contains **only cron job sessions**:

Every single session key follows this pattern:
```
agent:<your-org>:cron:b2c7a3d1-...
agent:<your-org>:cron:b2c7a3d1-...:run:<uuid>
```

There are **zero** sessions matching `agent:<your-org>:slack:*` -- confirming that inbound Slack DMs from <slack-id> never reach <your-org> agent.

### 4. The "Main" Session

The "main" session is not a special routing target. It is simply the default agent (`"id": "main"` in `agents.list`). When no agent-specific routing is applied at the session dispatch layer, messages fall through to `main`.

The main agent:
- Has no workspace override (uses default: `~/.openclaw/workspace`)
- Has no explicit model override (uses `agents.defaults.model.primary`: `openai-codex/gpt-5.4`)
- Has no agent-specific personality files (the `/Users/<hostname>/.openclaw/agents/main/` directory contains only `agent/` and `sessions/`)

### 5. Model Configuration Architecture

Models are configured at multiple levels:

| Level | Config Location | Model | Used By |
|---|---|---|---|
| **Global default** | `agents.defaults.model.primary` | `openai-codex/gpt-5.4` | All agents unless overridden |
| **Agent-level** | `agents.list[].model` | `openai-codex/gpt-5.4` | dev1, <your-org> (same as default) |
| **Cron job payload** | `cron/jobs-config.json` payload.model | `fw-mm25` | Cron sessions for both agents |
| **Session-level** | Inherited from creation context | Varies | Per-session override |

The cron jobs explicitly set `"model": "fw-mm25"` in the payload, which is why cron sessions use `accounts/fireworks/models/minimax-m2p5` via the fw-mm25 provider -- this is a per-session model override at job creation time, not an agent-level setting.

### 6. Session Scoping

The `session.dmScope` is set to `"per-channel-peer"`, meaning each Slack user gets their own session. This is working correctly -- <slack-id> and <slack-id> have separate sessions. The problem is that both sessions are scoped under `agent:main:` rather than their bound agents.

### 7. Channel Configuration

Slack channel config:
- `dmPolicy`: `"pairing"` -- DMs require pairing approval
- `mode`: `"socket"` -- Socket Mode connection
- `streaming`: `"partial"` with `nativeStreaming: true`
- `groupPolicy`: `"allowlist"`

The `dmPolicy: "pairing"` means these DMs were approved. But the routing decision happens AFTER pairing, and it routes to `main` instead of the bound agent.

### 8. Agent Workspace Structure

Each agent has its own workspace symlinked via stow:

- **main**: `~/.openclaw/workspace` (no personality files besides defaults)
- **dev1**: workspace at `~/openclaw-agents/.openclaw/agents/dev1`, symlinked to `~/.openclaw/agents/dev1/`
- **<your-org>**: workspace at `~/openclaw-agents/.openclaw/agents/<your-org>`, symlinked to `~/.openclaw/agents/<your-org>/`

<your-org> agent has IDENTITY.md, USER.md, SOUL.md, TOOLS.md, AGENTS.md, BOOTSTRAP.md, HEARTBEAT.md -- but since DMs route to `main`, none of these personality files are loaded for Slack conversations. The session report for the <slack-id> DM shows it loads workspace files from `/Users/<hostname>/.openclaw/workspace/` (main's workspace).

---

## Architecture Diagram

```
Slack DM from <slack-id>
         |
         v
  OpenClaw Gateway
  (Socket Mode listener)
         |
         v
  Session Dispatch
  (dmScope: per-channel-peer)
         |
         |  EXPECTED: Check bindings -> route to <your-org>
         |  ACTUAL:   Falls through to "main" agent
         |
         v
  agent:main:slack:direct:u07h87k34qj
  (model: gpt-5.4, workspace: ~/.openclaw/workspace)
         |
         |  (<your-org> personality files NOT loaded)
         |
         v
  Response sent back to <slack-id>
```

```
Cron Job (every 2h)
         |
         v
  Cron Scheduler
  (agentId: <your-org>, model: fw-mm25)
         |
         v
  agent:<your-org>:cron:b2c7a3d1-...
  (model: minimax-m2p5, workspace: <your-org>'s workspace)
         |
         |  (<your-org> personality files ARE loaded)
         |
         v
  Outbound: openclaw message send --channel slack --target user:<slack-id>
```

---

## Key Question Answers

### Q1: How does OpenClaw route incoming Slack messages?
Currently, all inbound Slack DMs go to the `main` agent regardless of bindings. The session key format is `agent:main:slack:direct:<lowercase-user-id>`. Bindings appear to be either not consulted during inbound dispatch, or there is a bug preventing them from being applied.

### Q2: What is the "main session"?
The `main` agent is the default agent (first in `agents.list`). It has no special workspace, no personality files beyond defaults, and uses the global default model (`openai-codex/gpt-5.4`). It acts as a catch-all for messages that are not routed to specific agents.

### Q3: What model/provider is configured for <your-org>?
`openai-codex/gpt-5.4` -- same as the global default. However, its cron jobs override this to `fw-mm25` (resolves to `accounts/fireworks/models/minimax-m2p5`).

### Q4: Routing config?
Bindings exist at `openclaw.json -> bindings[]`. There is no separate `routing` config key (confirmed: `Config path not found: routing`). The bindings are the routing mechanism.

### Q5: How are agents associated with Slack users?
Via the `bindings` array in `openclaw.json`, matching `channel: "slack"` + `accountId: "<SLACK_USER_ID>"`. Both USER.md files (dev1 and <your-org>) are empty templates with no Slack user ID mappings.

### Q6: How does the cron job get a different model?
The model is specified per-job in the cron payload: `"model": "fw-mm25"`. This overrides the agent-level default at session creation time. Model selection is thus per-session, with the hierarchy: session-level > agent-level > global default.

### Q7: When <slack-id> sends a Slack DM, how does OpenClaw decide which agent handles it?
**Currently: it does not decide. Everything goes to `main`.** The bindings configuration exists but is not being applied to inbound Slack DM routing. This is the core architectural issue.

---

## Hypotheses for Root Cause

1. **Bindings are outbound-only**: The `bindings` feature may only control which agent's identity is used when *sending* messages, not which agent handles *inbound* messages. The cron jobs already use `openclaw message send` explicitly, so bindings may be a display/identity layer rather than a routing layer.

2. **Bindings require gateway restart**: The bindings may have been added after the gateway was started, and the gateway caches routing rules at boot time.

3. **Bug in binding evaluation**: The matching logic may have a bug (e.g., case sensitivity -- the session key uses lowercase `u07h87k34qj` while the binding uses uppercase `<slack-id>`).

4. **Feature not yet implemented**: The `type: "route"` binding may be a planned feature that is not yet wired into the inbound message dispatch path in OpenClaw 2026.3.13.

---

## Recommended Next Steps

1. **Check OpenClaw docs**: `openclaw docs "agent bindings routing"` -- confirm whether bindings are intended to route inbound messages.
2. **Restart the gateway**: `openclaw gateway --force` -- in case bindings are cached at startup.
3. **Test with `openclaw agents bind --help`**: Check if there are additional flags or modes needed.
4. **Check gateway logs**: `openclaw logs` during an inbound Slack DM to see if binding matching is attempted and fails.
5. **File a bug/question on OpenClaw**: If bindings should route inbound messages but do not, this is a bug.

---

## Evidence Files

- Config: `~/.openclaw/openclaw.json`
- Main sessions: `~/.openclaw/agents/main/sessions/sessions.json`
- <your-org> sessions: `~/.openclaw/agents/<your-org>/sessions/sessions.json`
- Cron config: `~/openclaw-agents/.openclaw/cron/jobs-config.json`
