# Tech Manager requireMention Analysis

**Date:** 2026-03-27
**Status:** Actionable - Critical configuration issue identified
**Scope:** tech-manager agent, #tech-management channel (<channel-id>)

---

## Executive Summary

The tech-manager agent's `requireMention: false` setting for channel <channel-id> is configured at the correct location (`channels.slack.channels`), but there is a **critical missing property**: the `allow: true` flag is absent from the channel entry. When `groupPolicy: "allowlist"` is active, channels MUST have `allow: true` to be permitted. Without it, the channel may be silently dropped by the gateway before `requireMention` is even evaluated.

Additionally, the AGENTS.md instructions contain a **soft behavioral override** that tells the agent to self-censor most messages even when they ARE delivered -- a "When in doubt, stay silent" directive that creates a second layer of filtering at the agent level.

---

## Configuration Audit

### 1. openclaw.json - Channel Config (Lines 539-587)

```json
"channels": {
  "slack": {
    "groupPolicy": "allowlist",       // Line 557
    "channels": {
      "<channel-id>": {
        "requireMention": false        // Line 584
      }
    }
  }
}
```

**ISSUE: Missing `allow: true`**

Per OpenClaw docs, when `groupPolicy: "allowlist"`, each channel entry needs `allow: true` to be permitted. The current config only has `requireMention: false` but no `allow` property. The correct config should be:

```json
"<channel-id>": {
  "allow": true,
  "requireMention": false
}
```

Without `allow: true`, the gateway may treat the channel as not-allowlisted, which would cause messages to be silently dropped before the `requireMention` flag is ever consulted.

### 2. openclaw.json - Binding (Lines 371-381)

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

The binding is correct. It routes all messages from channel <channel-id> to the `tech-manager` agent. No `requireMention` override exists at the binding level (bindings do not support `requireMention`).

### 3. openclaw.json - Agent Entry (Lines 190-195)

```json
{
  "id": "tech-manager",
  "name": "tech-manager",
  "workspace": "/Users/<hostname>/openclaw-agents/.openclaw/agents/tech-manager",
  "agentDir": "/Users/<hostname>/.openclaw/agents/tech-manager/agent",
  "model": "openai-codex/gpt-5.4"
}
```

Standard agent entry. No agent-level `requireMention` or group chat overrides.

---

## Message Routing Flow Analysis

Here is the complete message flow for a non-mention message in #tech-management:

```
1. Slack sends message to OpenClaw gateway
   |
2. Gateway checks: channels.slack.groupPolicy = "allowlist"
   |
3. Gateway checks: Is <channel-id> in channels.slack.channels?
   |-- YES (key exists)
   |
4. Gateway checks: Does entry have allow: true?
   |-- MISSING (only requireMention: false exists)
   |-- POTENTIAL DROP POINT: If gateway requires explicit allow: true,
   |   message is dropped here with no log or a "group not allowed" log
   |
5. IF message passes step 4:
   Gateway checks: requireMention for <channel-id>?
   |-- requireMention: false -> message passes mention gate
   |
6. Gateway matches binding: peer.kind=channel, peer.id=<channel-id>
   |-- Routes to agentId: tech-manager
   |
7. Agent receives message, processes AGENTS.md instructions
   |
8. AGENTS.md "Channel Presence" section (lines 76-90):
   Agent applies SOFT FILTER:
   - Respond when: @mentioned, blockers, direct questions, relevant info
   - Stay silent when: casual, off-scope, directed at others, venting
   - "When in doubt, stay silent"
   |
9. Agent decides whether to respond based on content analysis
```

**There are TWO potential failure points:**
- Step 4: Gateway-level drop due to missing `allow: true`
- Step 8: Agent-level self-censoring via AGENTS.md instructions

---

## Detailed Analysis of Each Configuration Layer

### Layer 1: `channels.slack.channels.<channel-id>` (Gateway Level)

**Where requireMention is configured:** `channels.slack.channels.<ID>.requireMention`

This is the CORRECT and ONLY location for Slack per-channel `requireMention`. Per OpenClaw docs:
- Slack uses `channels.slack.channels.<id>` for per-channel config
- Discord uses `guilds.*.channels.*`
- These are NOT interchangeable

**Current value:** `requireMention: false` -- This means the bot should respond to ALL messages in this channel, not just @mentions.

**Missing value:** `allow: true` -- Required when `groupPolicy: "allowlist"`.

### Layer 2: Bindings (Routing Level)

Bindings do NOT support `requireMention`. Bindings only control which agent handles messages from which peer. The binding for <channel-id> correctly routes to tech-manager.

`requireMention` is evaluated BEFORE binding matching -- it is a channel-level gate, not a routing-level gate.

### Layer 3: `groupPolicy` (Access Control Level)

`groupPolicy: "allowlist"` (line 557) means ONLY channels explicitly listed in `channels.slack.channels` with `allow: true` are permitted.

**This is the likely root cause of the issue.** The channel IS listed but without `allow: true`, its allowlist status may be ambiguous.

### Layer 4: AGENTS.md (Agent Behavioral Level)

Lines 76-90 of AGENTS.md contain the "Channel Presence" section:

```markdown
**Respond when:**
- You are @mentioned directly
- Someone reports a blocker, issue, or asks for help in your domain
- A direct question about team status, workload, or agent activity is asked
- Information surfaces that is relevant to your monitoring duties

**Stay silent when:**
- Casual conversation between team members
- Topics clearly outside your scope
- Messages directed at a specific person (not you)
- Someone is venting

**When in doubt, stay silent.**
```

This creates a SOFT OVERRIDE. Even if the gateway delivers every message (requireMention: false), the agent's instructions tell it to stay silent for most messages. This is intentional design -- but it means the agent will only respond to a subset of messages even when `requireMention: false` is working correctly.

**This is NOT a bug -- this is the intended behavior.** The agent should see all messages but choose when to respond based on content relevance.

---

## Root Cause Diagnosis

### Primary Issue: Missing `allow: true`

**Severity: HIGH**

The channel config at line 583-585 is:
```json
"<channel-id>": {
  "requireMention": false
}
```

It should be:
```json
"<channel-id>": {
  "allow": true,
  "requireMention": false
}
```

Per OpenClaw Slack docs: "When `groupPolicy: 'allowlist'`, channels must have `allow: true`." The `requireMention` property alone may not constitute an implicit allow.

**Verification steps:**
1. Check gateway logs: `openclaw logs --follow`
2. Send a test message (no @mention) in #tech-management
3. Look for `drop group message` or `group not allowed` entries
4. If no log entries at all, the channel is being silently dropped

### Secondary Issue: Agent Self-Censoring (by design)

**Severity: LOW (informational)**

The AGENTS.md "Channel Presence" guidelines instruct the agent to stay silent for most messages. This is intentional and appropriate for a manager agent. However, if someone is testing by posting casual messages without @mentioning, the agent would correctly stay silent even if the gateway is delivering messages.

### Tertiary Issue: Thread Behavior

**Severity: LOW**

Per GitHub issue #23064, even with `requireMention: false`, thread replies may not be delivered to the bot unless it has already posted in that thread. This is a known OpenClaw limitation. A proposed `thread.autoFollow: true` option does not yet exist.

---

## Recommended Fix

### Step 1: Add `allow: true` to channel config

Edit `~/.openclaw/openclaw.json`, line 583-585:

**Before:**
```json
"<channel-id>": {
  "requireMention": false
}
```

**After:**
```json
"<channel-id>": {
  "allow": true,
  "requireMention": false
}
```

### Step 2: Restart gateway

```bash
openclaw gateway restart
```

### Step 3: Verify with logs

```bash
openclaw logs --follow
```

Then send a test message in #tech-management (without @mentioning the bot) and confirm the message is delivered to the tech-manager agent.

### Step 4: Verify agent response behavior

Remember that even with `requireMention: false` working, the agent will still self-censor based on AGENTS.md guidelines. To test that messages are being DELIVERED (even if the agent stays silent), check:
- `openclaw sessions --agent tech-manager --json` to see if a session was created
- Agent memory files for evidence of message receipt

---

## Summary of All requireMention-Related Settings

| Location | Value | Effect |
|---|---|---|
| `channels.slack.channels.<channel-id>.requireMention` | `false` | Gateway should deliver all messages (not just @mentions) |
| `channels.slack.channels.<channel-id>.allow` | **MISSING** | Channel may be silently dropped by allowlist gate |
| `channels.slack.groupPolicy` | `"allowlist"` | Requires explicit `allow: true` per channel |
| `bindings[6]` (tech-manager) | peer.kind: "channel", peer.id: "<channel-id>" | Routes <channel-id> messages to tech-manager agent |
| AGENTS.md "Channel Presence" (lines 76-90) | Respond/silent guidelines | Agent self-censors based on content relevance |
| SOUL.md | "Be concise and structured" | No requireMention implications |
| IDENTITY.md | Slack Channel ID: <channel-id> | Confirms correct channel target |

---

## Known OpenClaw Bugs Related to requireMention

1. **Multi-account Discord bug (#45300):** requireMention: true broken in multi-account Discord -- not applicable to Slack
2. **WhatsApp mention detection (#11758):** wasMentioned always false -- not applicable to Slack
3. **Telegram hardcoded provider (#21467):** resolveGroupRequireMentionFor uses WhatsApp provider -- not applicable to Slack
4. **Thread auto-follow (#23064):** Thread replies not delivered even with requireMention: false -- POTENTIALLY APPLICABLE
5. **Per-channel replyToMode (#31130):** No per-channel replyToMode override -- tangentially related
6. **requireMentionFromIds (#23896):** Feature request for per-user mention gating -- not yet implemented

None of these bugs directly explain the Slack issue. The most likely cause remains the missing `allow: true` property.

---

## Files Reviewed

1. `~/.openclaw/openclaw.json` -- Full gateway and agent configuration
2. `/Users/<hostname>/openclaw-agents/.openclaw/agents/tech-manager/AGENTS.md` -- Agent operating manual
3. `/Users/<hostname>/openclaw-agents/.openclaw/agents/tech-manager/SOUL.md` -- Agent personality
4. `/Users/<hostname>/openclaw-agents/.openclaw/agents/tech-manager/IDENTITY.md` -- Agent identity and channel target
5. `/Users/<hostname>/openclaw-agents/types/manager/AGENTS.md` -- Type-level operating manual (identical to agent copy)
6. `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json` -- Cron jobs (delivery.mode: "none", uses openclaw message send)
