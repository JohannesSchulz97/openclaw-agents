# OpenClaw Cross-Session Message Injection Research

**Date:** 2026-04-09
**Status:** CONFIRMED -- No native mechanism exists; workarounds and pending feature request identified

## Executive Summary

**OpenClaw does NOT have a native mechanism to inject a message from one session into another session's transcript.** The specific problem -- a cron job running in `sessionTarget: "isolated"` sends a Slack DM via `openclaw message send`, but the sent message does not appear in the developer's DM session history -- has no built-in solution.

However, the research uncovered **three partial mechanisms** and **one pending feature request** that are directly relevant:

1. **`delivery.mode: "announce"`** -- Posts cron output to a chat channel AND a brief summary to the main session. Does NOT inject into the DM session transcript as a conversation message.
2. **`sessions_send` agent tool** -- Can deliver a message from one session to another, including DM sessions. Available to agents during their turn but unreliable when used by cheap models.
3. **`SendParamsSchema.sessionKey` (transcript mirror)** -- The gateway's `message send` protocol accepts an optional `sessionKey` that mirrors the delivered output back into a session transcript. But the CLI does not expose this flag, and it is buggy (Issue #54186).
4. **Feature Request #52789: `delivery.mode="session"`** -- Proposes exactly the mechanism we need: framework-level delivery from isolated cron jobs to a target session. Not yet implemented.

## Detailed Findings

### 1. Cron Delivery Modes (Complete Enumeration)

The cron system supports exactly three delivery modes:

| Mode | Behavior | Session Impact |
|------|----------|----------------|
| `"none"` | Agent handles delivery itself via tools | No session injection. Agent must use `openclaw message send` or `sessions_send` tool. |
| `"announce"` | Framework delivers cron output to a chat channel | Posts a **brief summary** to the main session via system event. Does NOT inject into any specific DM session. |
| `"webhook"` | Framework POSTs finished payload to a URL | No session impact at all. |

**Key insight:** `delivery.mode: "announce"` does deliver to a chat channel AND posts a summary to the main session, but the main-session summary is a system event, not a conversation message. It does not appear in the DM session transcript that the developer sees when replying.

### 2. `sessions_send` Agent Tool

The `sessions_send` tool is available to agents during their turn and can deliver a message to another session:

```
sessions_send(sessionKey, message, timeoutSeconds)
```

- **`timeoutSeconds: 0`** = fire-and-forget (enqueue and return immediately)
- **`timeoutSeconds: N`** = wait up to N seconds for the target agent to respond
- Messages are persisted with `message.provenance.kind = "inter_session"` for traceability
- Target agent processes the message as a new user message in their session

**Relevance to our problem:** A cron job running in an isolated session could use `sessions_send` to inject its message into the developer's main DM session (`session:main` or `agent:<name>:main`). The developer would then see the message in their conversation history.

**Limitation:** This relies on the LLM correctly calling the tool with the right parameters. Cheap models (used for cron) frequently drop required parameters, causing silent delivery failures. This is the exact problem cited in Feature Request #52789.

### 3. `SendParamsSchema.sessionKey` (Transcript Mirror)

The gateway's `SendParamsSchema` for `message send` includes:

```typescript
/** Optional session key for mirroring delivered output back into the transcript. */
sessionKey: TOptional<TString>
```

When present, the outbound message is mirrored into the specified session's transcript via `appendAssistantMessageToSessionTranscript`. This creates a delivery record in the JSONL transcript.

**Problem:** The `openclaw message send` CLI command does NOT pass `agentId` or `sessionKey` to `runMessageAction()`. Without `agentId`, the session route resolution is skipped and the mirror object is never constructed (Issue #54186). This means the CLI `message send` literally cannot mirror to any session transcript.

**If this bug were fixed**, an agent running in an isolated cron session could call `openclaw message send` with a `--session-key` flag to both send the Slack DM and mirror it into the DM session transcript. But this flag does not exist on the CLI today.

### 4. Feature Request #52789: `delivery.mode="session"`

Filed ~3 weeks ago, this proposes exactly the mechanism we need:

> The framework would take the cron job's output summary and deliver it to the target session key via `sessions_send` after the job completes -- the same way announce posts to a channel, but internally.

**Status:** Open, not yet implemented.

**Proposed config:**
```json
{
  "delivery": {
    "mode": "session",
    "sessionKey": "agent:dev1:main"
  }
}
```

### 5. `system event` Command

`openclaw system event --text "..."` enqueues a system event into the main session and optionally triggers a heartbeat. System events are processed during heartbeat, not as conversation messages.

**Not useful for our problem:** System events are not conversation messages. They don't appear in the DM transcript and don't provide context for the developer's reply.

### 6. `openclaw agent --session-id` 

The `openclaw agent` command accepts `--session-id` to run an agent turn in a specific session. But as documented in MEMORY.md, `--session-id` does NOT isolate sessions -- all map to `agent:NAME:main`. This is a known limitation.

The `AgentParamsSchema` also includes `internalEvents` (type `task_completion`), which is the mechanism subagents use to announce completion back to parent sessions. But this is internal to the subagent framework and not directly accessible for cron job injection.

## Available Workarounds (Ranked)

### Workaround 1: Agent uses `sessions_send` tool (Best Available)

**How:** In the cron prompt, instruct the agent to use `sessions_send` to inject its output into the developer's main DM session before sending the Slack DM.

```
After composing your check-in message:
1. Use sessions_send with sessionKey "agent:<name>:main" and timeoutSeconds 0 to inject the message into the developer's DM session
2. Then use the message tool to send the Slack DM
```

**Pros:** Creates a real conversation entry in the DM session. Developer's reply has full context.
**Cons:** Relies on LLM tool use accuracy. Cheap models may fail silently. Double token cost (two sends).

### Workaround 2: Use `sessionTarget: "session:slack:direct:<slack-user-id>"` instead of `"isolated"`

**How:** Configure the cron job to run in the developer's DM session directly, not in an isolated session.

```json
{
  "sessionTarget": "session:slack:direct:u09l59gj3qt",
  "delivery": { "mode": "none" }
}
```

**Pros:** Cron job runs in the DM session itself, so all context is shared. The agent can send the message and it appears in the same session history.
**Cons:** This is what we HAD before (current `session:main` config). The reason we moved to `isolated` was to avoid session pollution. Each cron run adds to the DM session's context window, and multiple cron jobs share the same history.

### Workaround 3: Use `delivery.mode: "announce"` with main-session summary

**How:** Configure announce delivery so the cron output is posted to the Slack DM AND a summary goes to the main session.

**Pros:** Built-in, reliable, no LLM tool use required.
**Cons:** The main-session entry is a brief system event summary, not the full message. It may not provide enough context for the developer's reply.

### Workaround 4: Write to memory file, reference in DM session

**How:** The cron job writes its output to `memory/pending-checkin.md`. When the developer replies in the DM session, the agent reads the memory file for context.

**Pros:** No session injection needed. Agent can always read memory files.
**Cons:** Indirect. Agent must be prompted to check for pending context. Not a clean solution.

## Conclusion

**There is no native OpenClaw mechanism to solve this problem today.** The closest built-in option is `delivery.mode: "announce"`, but it only posts a brief summary to the main session as a system event, not a full conversation message in the DM transcript.

**Recommended approach for our use case:**

1. **Short-term:** Use Workaround 1 (`sessions_send` in the cron prompt) with our primary model (gpt-5.4), which is reliable at tool use. Add verification in the prompt to ensure the tool call succeeds.

2. **Medium-term:** Track Feature Request #52789 (`delivery.mode="session"`) and adopt it when released. This would be the clean, framework-level solution.

3. **Alternative:** If session isolation is not strictly required, revert to `sessionTarget: "session:main"` (Workaround 2), accepting the session pollution tradeoff.

## Source References

- [OpenClaw Cron Jobs Documentation](https://docs.openclaw.ai/cli/cron)
- [Feature: Add delivery.mode="session" for cron jobs -- Issue #52789](https://github.com/openclaw/openclaw/issues/52789)
- [Feature: delivery.mode="main-only" -- Issue #32431](https://github.com/openclaw/openclaw/issues/32431)
- [Bug: openclaw message send CLI does not write to session transcript -- Issue #54186](https://github.com/openclaw/openclaw/issues/54186)
- [Session Tools Documentation](https://docs.openclaw.ai/concepts/session-tool)
- [Cron announce delivery bugs -- Issues #23322, #22298, #14696](https://github.com/openclaw/openclaw/issues/23322)
- [Isolated cron jobs: --post-mode full removed -- Issue #10069](https://github.com/openclaw/openclaw/issues/10069)
- Source code analysis: `/opt/homebrew/lib/node_modules/openclaw/dist/plugin-sdk/src/`
  - `gateway/protocol/schema/agent.d.ts` -- SendParamsSchema with sessionKey mirror field
  - `gateway/protocol/schema/cron.d.ts` -- CronDeliverySchema (none/announce/webhook)
  - `cron/types.d.ts` -- CronDeliveryMode type definition
  - `agents/subagent-announce*.d.ts` -- Announce flow for cron delivery
  - `commands/agent-via-gateway.d.ts` -- AgentCliOpts (deliver, replyTo, replyChannel, sessionId)
