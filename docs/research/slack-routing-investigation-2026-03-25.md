# Slack Routing Bindings Investigation

**Date:** 2026-03-25
**Status:** RESOLVED -- Bindings ARE working. Problem is likely elsewhere.

## Executive Summary

The Slack routing bindings in `~/.openclaw/openclaw.json` are correctly formatted and actively functioning. The evidence shows that new Slack DMs are being routed to the correct agents (`dev1` and `<your-org>`), not to `main`. The perception that "messages still go to main" is likely caused by one of the alternative explanations listed below.

## Evidence

### 1. Bindings Are Correctly Configured

```
openclaw agents bindings
Routing bindings:
- dev1 <- slack peer=direct:<slack-id>
- <your-org> <- slack peer=direct:<slack-id>
```

The JSON format in `openclaw.json` is correct:
```json
{
  "bindings": [
    { "type": "route", "agentId": "dev1", "match": { "channel": "slack", "peer": { "kind": "direct", "id": "<slack-id>" } } },
    { "type": "route", "agentId": "<your-org>", "match": { "channel": "slack", "peer": { "kind": "direct", "id": "<slack-id>" } } }
  ]
}
```

### 2. Bindings Were Hot-Reloaded Successfully

Gateway log at `2026-03-25T06:31:45`:
```
config change detected; evaluating reload (bindings)
config change applied (dynamic reads: bindings)
```

### 3. Routed Sessions ARE Being Used (Most Recent)

| Session Key | Agent | Updated At (epoch ms) | Relative |
|---|---|---|---|
| `agent:<your-org>:slack:direct:u07h87k34qj` | <your-org> | 1774420435118 | **MOST RECENT** |
| `agent:dev1:slack:direct:u09l59gj3qt` | dev1 | 1774420421048 | **SECOND MOST RECENT** |
| `agent:main:slack:direct:u07h87k34qj` | main | 1774418779266 | OLDER (stale) |
| `agent:main:slack:direct:u09l59gj3qt` | main | 1774364458552 | MUCH OLDER (stale) |

The routed agent sessions have MORE RECENT timestamps than the `main` sessions. This proves routing IS working for new messages.

### 4. Agent Workspaces Are Properly Configured

```json
{
  "id": "dev1",
  "workspace": "/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1",
  "agentDir": "/Users/<hostname>/.openclaw/agents/dev1/agent",
  "model": "openai-codex/gpt-5.4",
  "bindings": 1
}
```

Both agents have:
- Workspace directories with SOUL.md, IDENTITY.md, TOOLS.md (symlinked from types)
- Agent directories with auth-profiles.json and models.json
- Active sessions under their own session stores

### 5. Routing Engine Source Code Confirms Correct Priority

From `resolveAgentRoute()` in the OpenClaw source:
1. **Tier 1: Peer match** (exact `peer.kind` + `peer.id`) -- THIS IS OUR BINDING TYPE
2. Tier 2: Parent peer match (thread inheritance)
3. Tier 3: Guild + roles (Discord)
4. Tier 4: Guild only (Discord)
5. Tier 5: Team match (Slack `teamId`)
6. Tier 6: Account match
7. Tier 7: Channel-wide match (`accountId: "*"`)
8. Tier 8: Default agent (fallback to `main`)

Our bindings use peer-level matching (Tier 1), which is the HIGHEST priority.

### 6. dmScope Setting Is Correct

```json
{ "session": { "dmScope": "per-channel-peer" } }
```

This ensures Slack DMs create separate sessions per peer, not collapsed into a single main session.

## Why It May APPEAR Broken

### Hypothesis A: Stale Main Sessions Show in `openclaw sessions`

The old `agent:main:slack:direct:*` sessions still exist in the `main` agent's session store. When running `openclaw sessions` (which defaults to `--agent main`), these stale sessions appear, giving the impression that routing still goes to `main`. But they are NOT being updated anymore.

### Hypothesis B: Agent Responds Without Custom Identity

If the agents (`dev1`, `<your-org>`) are routing correctly but respond with the same default personality as `main` (e.g., same model, same system prompt), the responses may be indistinguishable from `main`. Check that:
- The agent's SOUL.md / IDENTITY.md files are being loaded
- The agent's workspace is correctly picked up

### Hypothesis C: Cron Jobs Running Under `main`

The logs show cron sessions under `agent:main:*`. If cron-triggered messages are being sent via the `main` agent's delivery context, replies might appear to come from `main` even though inbound routing works.

### Hypothesis D: Model Override Not Applied

Both agents are configured with `model: "openai-codex/gpt-5.4"` -- same as `main`. If the expectation was that `dev1` should use `google/gemini-3.1-pro` (as stated in CLAUDE.md), the agent entry needs a model override.

## Recommended Actions

### 1. Verify Agent Identity Is Loading

Send a test DM from <slack-id> and check which session key the gateway creates:
```bash
openclaw sessions --agent dev1 --active 5 --json
```

### 2. Clean Up Stale Main Sessions (Optional)

The old main sessions are harmless but confusing. They will age out naturally, or can be cleaned:
```bash
openclaw sessions cleanup --agent main --dry-run
openclaw sessions cleanup --agent main --enforce
```

### 3. Set Agent-Specific Models

If `dev1` should use Gemini:
```bash
openclaw config set 'agents.list[1].model' 'google/gemini-3.1-pro'
```

### 4. Verify Agent System Prompt Loading

Check the agent's workspace files are being used by looking at the transcript:
```bash
ls ~/.openclaw/agents/dev1/sessions/transcripts/
```
Read the most recent transcript to verify SOUL.md / IDENTITY.md content appears.

### 5. Test With Explicit Agent Override

Force a message through the agent to verify it works:
```bash
openclaw agent --agent dev1 --message "Who are you?" --channel slack --deliver
```

## Configuration Reference (Verified Working Format)

The binding format in `openclaw.json` is:
```json
{
  "bindings": [
    {
      "type": "route",
      "agentId": "<agent-id>",
      "match": {
        "channel": "slack",
        "peer": {
          "kind": "direct",
          "id": "<SLACK_USER_ID>"
        }
      }
    }
  ]
}
```

The CLI equivalent:
```bash
openclaw agents bind --agent <agent-id> --bind slack
```
Note: The CLI `bind` command uses `--bind <channel[:accountId]>` syntax and does NOT support peer-level specification. Peer bindings must be configured via `openclaw.json` directly.

## Routing Architecture

```
Inbound Slack DM from <slack-id>
    |
    v
Gateway receives message
    |
    v
resolveAgentRoute() evaluates tiers:
    Tier 1: peer match -> binding "dev1 <- slack peer=direct:<slack-id>" MATCHES
    |
    v
Session key: agent:dev1:slack:direct:u09l59gj3qt
    |
    v
Agent "dev1" runs with:
    - workspace: /Users/<hostname>/openclaw-agents/.openclaw/agents/dev1
    - agentDir: /Users/<hostname>/.openclaw/agents/dev1/agent
    - model: openai-codex/gpt-5.4
```
