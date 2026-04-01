# Cross-Agent Slack Messaging: Context Loss Analysis

**Date:** 2026-04-01
**Researcher:** Claude Code (Research Agent)
**Status:** Informational -- architectural analysis with solution options
**Trigger:** dev10-Jean's agent sends DM to dev1 via TOB <manager-agent> bot; dev1' agent has no context when dev1 replies

---

## Executive Summary

OpenClaw has **no built-in inter-agent messaging**. When Agent A (dev10-jean) sends a Slack DM to User B (dev1), it uses the shared `@tob_kai` bot to deliver a plain Slack message. When User B replies, the inbound message is routed to Agent B (dev1) via bindings, but Agent B's session has zero context about what Agent A originally sent. This is a fundamental architectural gap -- not a bug, but a missing feature.

**Root Cause:** `openclaw message send` is a fire-and-forget channel message command. It does not inject context into the receiving agent's session. There is no envelope, metadata, or cross-agent session linking.

**Impact:** Cross-agent communication via Slack DM is broken by design. The sending agent pollutes its own session with another developer's work, and the receiving agent gets a contextless reply.

---

## 1. How OpenClaw Routes Slack Messages

### Single Bot, Multiple Agents

All 18+ agents share a **single Slack bot** (`@tob_kai`):

- **Bot token:** `xoxb-7586154609507-...` (configured at `channels.slack.botToken`)
- **App token:** `xapp-1-A0ALMV7AD0B-...` (Socket Mode)
- **No per-agent Slack apps** -- every agent appears as the same bot

### Inbound Routing: Bindings

When a Slack user sends a DM to @tob_kai, OpenClaw uses the `bindings` array in `openclaw.json` to decide which agent handles it:

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

**Routing logic:** Slack DM from user `<slack-id>` --> route to agent `dev1`.

Each of the 18 agents has a binding mapping their developer's Slack user ID to their agent ID. The `dmPolicy: "allowlist"` + `allowFrom` array controls which Slack users can DM at all.

**Session scoping:** `session.dmScope: "per-channel-peer"` means each Slack user gets a dedicated session per agent. Session keys follow the pattern: `agent:<agent-id>:slack:direct:<slack-user-id>`.

**Historical note:** Prior research (2026-03-25) found bindings were NOT being honored (all DMs went to `main` agent). This may have been fixed in OpenClaw 2026.3.28 via the updated binding format (`peer.kind`/`peer.id` vs old `accountId`). Current config uses the newer format.

### Outbound Sending: CLI Command

Agents send messages via:
```bash
openclaw message send --channel slack --target user:<SLACK_USER_ID> --message "<text>"
```

This goes through the gateway, which uses the shared bot token to call Slack's API. There is:
- **No `--agent` flag** on `message send` (no agent identity context)
- **No `--session-id` flag** (no session linking)
- **No `--on-behalf-of` flag** (no cross-agent attribution)
- **No metadata envelope** (recipient agent gets zero context about origin)

---

## 2. The Broken Flow: Step by Step

Here is exactly what happens in the scenario described:

### Step 1: PJ asks his agent to message dev1
```
PJ --> [Slack DM to @tob_kai] --> "Send a message to dev1 explaining the API change"
```

OpenClaw routes this to agent `dev10-jean` (binding: `<slack-id>` --> `dev10-jean`).

### Step 2: dev10-Jean's agent composes and sends
The `dev10-jean` agent processes the request within its own session (`agent:dev10-jean:slack:direct:u09r2aydckz`). It then executes:

```bash
openclaw message send --channel slack --target user:<slack-id> --message "Hey dev1, PJ wanted me to let you know about the API change..."
```

**Problems at this stage:**
- dev10-Jean's session now contains work context for dev1 (session pollution)
- The message is a plain Slack DM -- no metadata, no origin agent ID, no session reference

### Step 3: dev1 sees the message
dev1 sees a DM from `@tob_kai` in Slack. The message looks like it came from the bot itself. There is no visual indicator that it originated from dev10-Jean's agent.

### Step 4: dev1 replies
```
dev1 --> [Slack DM to @tob_kai] --> "Thanks, can you explain the breaking changes?"
```

OpenClaw routes this to agent `dev1` (binding: `<slack-id>` --> `dev1`).

### Step 5: dev1' agent has NO context
The `dev1` agent receives the reply in its session (`agent:dev1:slack:direct:u09l59gj3qt`). But this session has **zero knowledge** of:
- The original message from dev10-Jean's agent
- What "API change" was being discussed
- That this is a cross-agent conversation at all

The agent sees a message like "Thanks, can you explain the breaking changes?" with no prior context. It either hallucinates a response, asks dev1 for clarification, or responds generically.

---

## 3. What OpenClaw Supports for Inter-Agent Communication

### Available Mechanisms (None Solve the Problem Fully)

| Mechanism | What It Does | Solves Cross-Agent Context? |
|-----------|-------------|---------------------------|
| `openclaw message send` | Fire-and-forget Slack/Telegram/etc message | **No** -- no context injection |
| `openclaw agent --agent <id> --message "..."` | Run a single turn as another agent | **Partial** -- injects into agent's session, but sender gets no reply |
| `openclaw acp --session <key>` | Bridge into a specific session | **Potentially** -- could inject context into another agent's session |
| `openclaw system event --text "..."` | Enqueue system event for heartbeat | **No** -- fires into current agent only |
| Shared filesystem (`memory/` files) | Agents read each other's memory files | **Workaround** -- not real-time, requires polling |
| Shared Slack channel | Post to a channel both agents monitor | **Partial** -- context visible but not in agent sessions |

### The `openclaw agent` Command (Most Promising)

```bash
openclaw agent --agent dev1 --message "Context: PJ's agent sent you a message about the API change. Here's what was discussed: [details]" --session-id "agent:dev1:main"
```

This could theoretically inject a context message into dev1' main session. However:
- It triggers a full agent turn (not a silent context injection)
- It runs as the specified agent, consuming tokens
- There is no "system message" or "context injection" mode
- The sender (dev10-jean's agent) would need to know the target session ID

### The ACP Bridge (Most Flexible, Least Documented)

```bash
openclaw acp --session "agent:dev1:slack:direct:u09l59gj3qt" --message "..."
```

The ACP (Agent Control Protocol) bridge connects to a specific session via WebSocket. This could potentially be used to inject messages into another agent's session, but:
- It is designed for external tooling, not inter-agent use
- Documentation is sparse
- It requires the gateway token for authentication
- It may create a new turn rather than just adding context

---

## 4. Why This Is Hard to Fix

### Architectural Constraints

1. **Session isolation is by design.** OpenClaw intentionally isolates agent sessions. Cross-agent context sharing would need to be an explicit, opt-in feature.

2. **Single bot identity.** All agents share `@tob_kai`. The receiving user cannot tell which agent sent a message. Any cross-agent protocol would need to include origin metadata in the message itself.

3. **No message envelope.** `openclaw message send` has no way to attach metadata (origin agent, origin session, context summary) to a Slack message. It is a simple text/media delivery command.

4. **No callback mechanism.** When the receiving user replies, there is no way for the receiving agent to "call back" to the sending agent's session for context.

5. **Session keys are per-channel-peer.** dev1' Slack DM session is `agent:dev1:slack:direct:u09l59gj3qt`. Messages from @tob_kai (which is what the bot uses to send) would need to appear in this session, but they do not because the bot is sending outbound, not receiving inbound.

---

## 5. Potential Solutions

### Solution A: Context Prefix Convention (Simplest, No Code Changes)

**Approach:** Establish a convention where agents include full context in cross-agent messages.

Instead of:
```
"Hey dev1, PJ wanted me to let you know about the API change"
```

The sending agent would format:
```
"[Message from dev10-Jean's assistant]

dev10-Jean asked me to pass along this information:

**Topic:** API change in the user-service endpoint
**Details:** The /users/v2 endpoint now requires an Authorization header. The old /users/v1 endpoint is deprecated as of April 1st.
**Action needed:** Update your service's API calls before the v1 shutdown on April 15th.

If you have questions, please reply to dev10-Jean directly on Slack, or tell me and I'll relay your response back."
```

**Pros:**
- Zero code changes needed
- Can be implemented immediately via AGENTS.md instructions
- Receiving agent has full context in the message itself

**Cons:**
- Relies on agents following conventions (not enforced)
- Long messages for simple relay tasks
- No automatic context linking
- Replies still go to the receiving agent's session (not the sender's)

### Solution B: Context Injection via `openclaw agent` (Medium Effort)

**Approach:** Before sending the Slack DM, the sending agent also injects context into the receiving agent's session.

```bash
# Step 1: Inject context into dev1' main session
openclaw agent --agent dev1 --session-id "agent:dev1:main" \
  --message "[SYSTEM CONTEXT] dev10-Jean's assistant will send dev1 a Slack DM about API changes. Context: [full details]. When dev1 replies about this topic, this is the background."

# Step 2: Send the actual Slack DM
openclaw message send --channel slack --target user:<slack-id> \
  --message "Hey dev1, PJ wanted me to let you know about the API change..."
```

**Pros:**
- Receiving agent has context before the reply arrives
- Uses existing CLI tools
- Context persists in the session

**Cons:**
- Triggers a full agent turn (token cost, potential side effects)
- The context injection message will get a response from the agent (noise)
- Requires knowing the target session ID
- Session ID for Slack DMs is `agent:dev1:slack:direct:u09l59gj3qt`, not `agent:dev1:main`
- Race condition: context injection and user reply may arrive in different sessions

### Solution C: Shared Context via Memory Files (Medium Effort)

**Approach:** Sending agent writes a context file that the receiving agent reads.

```bash
# Sending agent writes context file
echo '{"from":"dev10-jean","to":"dev1","topic":"API change","details":"...","timestamp":"2026-04-01T10:00:00Z"}' \
  > ~/.openclaw/agents/dev1/memory/incoming-messages.json

# Then sends the Slack DM
openclaw message send --channel slack --target user:<slack-id> \
  --message "Hey dev1, PJ's agent here. Check your incoming-messages.json for context about the API change."
```

**Receiving agent's AGENTS.md would include:**
```
When you receive a message that references cross-agent context, check memory/incoming-messages.json for background information.
```

**Pros:**
- No token cost for context injection
- Context is persistent and inspectable
- Can include rich structured data

**Cons:**
- Requires AGENTS.md convention changes (sync + stow)
- Filesystem-based (not real-time notification)
- Receiving agent must be instructed to check the file
- No guarantee the agent will read it at the right time

### Solution D: Relay via Shared Slack Channel (Medium Effort)

**Approach:** Use a shared Slack channel (e.g., `#agent-relay`) where cross-agent messages are posted with full context. Both sending and receiving agents monitor this channel.

```bash
# Sending agent posts to shared channel
openclaw message send --channel slack --target channel:C0RELAY123 \
  --message "[dev10-jean -> dev1] API change: /users/v2 now requires auth header. Details: ..."

# Then DMs the user
openclaw message send --channel slack --target user:<slack-id> \
  --message "Hey dev1, I've posted context about an API change from PJ in #agent-relay."
```

**Pros:**
- Audit trail of all cross-agent messages
- Human-visible for oversight
- Could bind the channel to a manager agent for monitoring

**Cons:**
- Does not solve the session context problem
- Receiving agent needs to actively read the channel
- Additional channel infrastructure needed

### Solution E: OpenClaw Feature Request (Ideal, Requires Upstream Change)

**Approach:** Request/build a proper inter-agent messaging feature in OpenClaw.

Proposed API:
```bash
openclaw agent message \
  --from dev10-jean \
  --to dev1 \
  --context "PJ asked me to relay: API change details..." \
  --deliver-via slack \
  --inject-context  # Adds context to receiving agent's session
```

This would:
1. Inject context into the receiving agent's appropriate session
2. Send the Slack DM with proper attribution
3. Optionally set up a reply callback to forward responses back

**Pros:**
- Solves the problem completely
- Clean API
- Session context preserved

**Cons:**
- Requires OpenClaw upstream changes
- Development time unknown
- Not available today

---

## 6. Recommended Immediate Action

**Combine Solution A + C for a pragmatic fix:**

1. **Update AGENTS.md** with cross-agent messaging conventions:
   - Always include full context in cross-agent DMs (Solution A)
   - Write context files before sending DMs (Solution C)
   - Instruct agents to check `memory/incoming-messages.json` on startup

2. **Add to AGENTS.md a "Relaying Messages" section:**
   ```
   ## Relaying Messages to Other Developers

   When asked to send a message to another developer:
   1. NEVER just send a bare message. Always include full context.
   2. Write the context to the target agent's memory:
      ~/.openclaw/agents/<target-agent>/memory/incoming-context.json
   3. Format the Slack DM with:
      - Who it's from (your developer's name)
      - Full context of what's being communicated
      - Whether a reply is expected
      - Suggest they reply directly to the original person on Slack
   4. Tell your developer: "I sent the message, but [target] should reply
      directly to you on Slack rather than through me, since I can't relay
      their response back with full context."
   ```

3. **File a GitHub issue** on openclaw-agents for tracking the longer-term solution.

4. **Consider filing an OpenClaw feature request** for proper inter-agent messaging (Solution E).

---

## 7. Key Configuration References

| Config Key | Value | Purpose |
|-----------|-------|---------|
| `channels.slack.botToken` | `xoxb-...` (single, shared) | All agents use this one bot |
| `channels.slack.dmPolicy` | `"allowlist"` | Only allowlisted users can DM |
| `session.dmScope` | `"per-channel-peer"` | Each user gets own session per agent |
| `bindings[].type` | `"route"` | Maps Slack user ID to agent ID |
| `bindings[].match.peer.kind` | `"direct"` | DM routing (vs channel routing) |

---

## 8. Relevant File Paths

- **Runtime config:** `/Users/<hostname>/.openclaw/openclaw.json`
- **Agent operating manual:** `/Users/<hostname>/openclaw-agents/types/dev-pa/AGENTS.md`
- **Agent tools config:** `/Users/<hostname>/openclaw-agents/types/dev-pa/TOOLS.md`
- **Prior routing research:** `/Users/<hostname>/openclaw-agents/docs/research/openclaw-slack-routing-architecture-2026-03-25.md`
- **Prior cross-agent research:** `/Users/<hostname>/openclaw-agents/docs/research/openclaw-cross-agent-architecture-2026-03-26.md`
- **Prior multi-agent Slack research:** `/Users/<hostname>/openclaw-agents/docs/research/openclaw-slack-integration-multi-agent-2026-03-26.md`
