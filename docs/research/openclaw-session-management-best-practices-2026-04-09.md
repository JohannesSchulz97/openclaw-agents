# OpenClaw Session Management Best Practices

**Date:** 2026-04-09
**Researcher:** Claude Code (Research Agent)
**Classification:** Informational (reference material)
**Scope:** Session isolation, cross-session context, cron patterns, LCM compaction, community practices

---

## Executive Summary

OpenClaw's session system is built around **per-agent, per-routing-key isolation** with sessions stored as JSONL transcript files keyed by session keys like `agent:<agentId>:<rest>`. There is **no built-in cross-session context reading API** that allows one session to transparently access another session's conversation history. However, the `sessions_history` tool provides bounded, sanitized access to other sessions' transcripts when configured with appropriate visibility scopes. For cron jobs, session bloat is a real and documented problem with active bugs in the `isolated` sessionTarget mode. LCM (Lossless Context Management) operates strictly within a single conversation's DAG and provides no cross-session query capability.

### Key Findings

1. **Cross-session reading**: The `sessions_history` tool is the primary mechanism. Requires `agent` or `all` visibility scope. Returns sanitized, bounded transcripts.
2. **Session isolation for cron**: Three modes exist (`isolated`, `session:<id>`, `main`), but `isolated` has a known regression bug (openclaw/openclaw#61426) where messages accumulate in the main session.
3. **LCM has no cross-session API**: Each conversation has its own DAG. No mechanism to query another session's compacted history.
4. **Session bloat is a systemic risk**: Multiple open issues (openclaw#45488, #45717, #61426) document session bloat from cron accumulation, skillsSnapshot duplication, and broken isolation.
5. **`sessions_send` enables inter-session messaging**: Fire-and-forget or wait-for-reply patterns, but it requires the target session to already exist.
6. **Community consensus**: Cron sessions should use isolation or named persistent sessions; sharing the main DM session is an anti-pattern for most use cases.

---

## 1. Reading Conversation History from Another Session

### 1.1 The `sessions_history` Tool

**Source:** https://docs.openclaw.ai/concepts/session-tool

The `sessions_history` tool is the officially supported mechanism for reading another session's transcript from within an agent session.

**Capabilities:**
- Accepts session key or session ID as input
- Returns sanitized transcript (strips thinking tags, tool scaffolding, control tokens, malformed XML)
- Supports `includeTools: true` flag to include tool results
- Reports flags: `truncated`, `droppedMessages`, `contentRedacted`
- Bounded output (does not dump entire raw transcripts)

**Access Control via Visibility Scopes:**

| Scope | Access | Use Case |
|-------|--------|----------|
| `self` | Current session only | Default for sandboxed sessions |
| `tree` | Current session + spawned sub-agents | Default for normal sessions |
| `agent` | All sessions for this agent | Cross-session reading within same agent |
| `all` | All sessions across agents | Cross-agent reading (if configured) |

**Configuration:**
```json
{
  "agents": {
    "defaults": {
      "tools": {
        "sessions_history": {
          "visibility": "agent"
        }
      }
    }
  }
}
```

**Limitations:**
- Returns sanitized text, not structured data
- No semantic search within retrieved history
- Bounded output means very long sessions may be truncated
- No way to query LCM's compacted summaries from another session
- Requires knowing the target session key

### 1.2 The `sessions_send` Tool

**Source:** https://docs.openclaw.ai/concepts/session-tool

Enables inter-session communication with two modes:

| Mode | How | Use Case |
|------|-----|----------|
| Fire-and-forget | `timeoutSeconds: 0` | Inject context into another session asynchronously |
| Wait-for-reply | `timeoutSeconds: N` | Request information from another session and wait |

Supports up to 5-turn reply-back loops. Target can send `REPLY_SKIP` to exit early.

**Known Bug (openclaw#52875):** `sessions_send` returns "No session found" when the target agent has no active session. It does NOT create a session on demand.

### 1.3 The `sessions_spawn` Tool

Creates isolated sub-agent sessions for background work. Returns `runId` and `childSessionKey`. Useful for delegating context-gathering tasks to a sub-agent that can read the parent's history (within `tree` scope).

**Key Parameters:**
- `runtime`: "subagent" (default) or "acp"
- `model` and `thinking` overrides
- `thread: true` for chat-bound spawning
- `sandbox: "require"` for enforced sandboxing

### 1.4 Community Workarounds for Cross-Session Context

Since there is no transparent cross-session context sharing, the community uses these patterns:

**Pattern A: Memory File Bridge**
- Agent writes context to `memory/` directory as markdown
- Other sessions/agents read from `memory/` using file system tools
- Indexed by QMD for search

**Pattern B: Context Prefix Convention**
- When sending messages cross-session, include full context in the message body
- Receiving session gets all needed context without needing to read the sender's history

**Pattern C: Shared Slack Channel**
- Post cross-session context to a shared monitoring channel
- Both sessions can reference the channel history

**Pattern D: `sessions_send` with Context Injection**
- Before triggering work in another session, use `sessions_send` to inject context
- The receiving session gets the context as an incoming message

---

## 2. Session Isolation Patterns for Cron Jobs

### 2.1 The Three sessionTarget Modes

**Source:** Internal research (openclaw-session-key-vs-target-2026-04-09.md), OpenClaw source code analysis

| sessionTarget | Behavior | Session Persistence | Conversation History |
|---------------|----------|--------------------|--------------------|
| `"isolated"` | Fresh session every run | No (ephemeral) | None between runs |
| `"session:<id>"` | Named persistent session | Yes | Preserved across runs |
| `"main"` | Injects into main session | Yes (shared) | Shared with DMs |

### 2.2 How sessionTarget Overrides sessionKey

**Critical finding from source code analysis:**

When `sessionTarget` starts with `"session:"`, the `<id>` portion **replaces** the `sessionKey` for session identity lookup. The `sessionKey` field in jobs-config.json then serves only as a cron scheduler matching identifier for `apply-cron.sh`.

```
sessionTarget: "session:main"     --> uses agent's main session (agent:X:main)
sessionTarget: "session:agent:X:cron:morning" --> uses dedicated cron session
sessionTarget: "isolated"         --> new UUID session every run
```

### 2.3 Session Bloat from Cron: Known Problems

**Problem 1: All cron jobs sharing main session (by design when using `session:main`)**

With `sessionTarget: "session:main"`, all cron jobs (morning/midday/evening/summary) share the same conversation as the agent's Slack DM session. Each cron run adds messages to the same growing transcript.

**Impact:** Session grows unboundedly. LCM compaction helps but adds overhead. Agent context becomes polluted with cron messages mixed with user conversations.

**Problem 2: `isolated` mode not honored (openclaw#61426 -- REGRESSION BUG)**

As of OpenClaw 2026.4.1, cron jobs configured with `sessionTarget: "isolated"` still accumulate messages in the main session. This has caused:
- Context overflow crashes
- Agent resets with loss of in-progress work
- Silent accumulation with no warnings in logs
- Affects all cron jobs using `isolated` mode

**Workaround:** Manual LCM database cleanup:
```bash
sqlite3 ~/.openclaw/lcm.db "DELETE FROM messages WHERE conversation_id = <ID>;"
```

**Problem 3: Session store bloat from skillsSnapshot (openclaw#45717)**

Every cron run writes a new `skillsSnapshot` and `systemPromptReport` to the session store entry, causing the sessions.json file itself to grow.

### 2.4 Best Practices for Cron Session Isolation

**Recommended: Named persistent sessions per cron type**
```json
{
  "sessionTarget": "session:agent:dev1:cron:morning",
  "sessionKey": "agent:dev1:cron:morning"
}
```

This creates a dedicated session per cron job type that:
- Preserves conversation history across runs (agent has context from previous check-ins)
- Does NOT pollute the DM session
- Does NOT create a new session every run (avoids session store bloat)
- Is separate from other cron job types

**Acceptable: Isolated sessions for one-shot tasks**
```json
{
  "sessionTarget": "isolated",
  "sessionKey": "agent:dev1:cron:summary"
}
```

Good for daily summaries or one-shot tasks where history is not needed. BUT: **currently broken by openclaw#61426** -- verify the fix is deployed before relying on this.

**Anti-pattern: Sharing the main DM session**
```json
{
  "sessionTarget": "session:main",
  "sessionKey": "agent:dev1:cron:morning"
}
```

This is the current openclaw-agents configuration. While it means cron jobs have full conversational context with the user, it causes:
- Session bloat (cron messages mixed with user messages)
- Context pollution (agent sees cron prompts in DM history)
- Compaction overhead (LCM must compact cron messages too)
- Potential confusion (agent may respond to cron prompts as if they were user messages)

### 2.5 LCM Session Exclusion for Cron

LCM supports excluding sessions from its database via `ignoreSessionPatterns`:

```json
{
  "plugins": {
    "lossless-claw": {
      "ignoreSessionPatterns": ["agent:*:cron:**"]
    }
  }
}
```

This prevents cron sessions from consuming LCM database space and compaction cycles. Useful when cron sessions are truly ephemeral and their history is not needed.

**Stateless session patterns** allow read-only participation:
```json
{
  "statelessSessionPatterns": ["agent:*:subagent:**"]
}
```

Sessions matching this pattern can read existing conversation data but never write or trigger compaction.

---

## 3. sessionTarget Options and Conversation Context Interaction

### 3.1 Complete sessionTarget Behavior Matrix

| sessionTarget | Session Identity | Conversation Context | Delivery Behavior | Use Case |
|---------------|-----------------|---------------------|-------------------|----------|
| `"main"` | Main session key | Shared with main session | System event only | System notifications |
| `"isolated"` | New UUID per run | No history | Fresh each run | One-shot tasks |
| `"session:main"` | `agent:X:main` | Shared with DM session | Agent-controlled | Context-aware check-ins |
| `"session:slack:direct:<id>"` | Slack DM session key | Shared with specific DM | Agent-controlled | User-facing cron |
| `"session:agent:X:cron:Y"` | Dedicated cron key | Own history, separate from DM | Agent-controlled | Isolated recurring tasks |

### 3.2 delivery.mode Interaction

The `delivery.mode` field controls whether the cron job's output is delivered to the user:

| delivery.mode | Behavior |
|---------------|----------|
| `"none"` | Response stays in cron session only; agent decides whether to notify user |
| `"always"` | Response is always delivered to the user via the configured channel |
| (default) | Same as `"always"` |

**Best practice:** Use `delivery.mode: "none"` for all cron jobs. Let the agent decide whether to send a Slack message using `openclaw message send`. This prevents noise from cron runs that have nothing important to report.

### 3.3 wakeMode Interaction

| wakeMode | Behavior |
|----------|----------|
| `"now"` | Execute immediately when cron fires |
| `"next-heartbeat"` | Queue for next heartbeat cycle |

**Important:** `wakeMode` does NOT affect restart catch-up behavior (openclaw#60083). Both modes behave identically during gateway restarts.

---

## 4. Cross-Session Context Reading: Built-in Mechanisms

### 4.1 What Exists

| Mechanism | Type | Cross-Session? | Cross-Agent? | Real-Time? |
|-----------|------|---------------|-------------|-----------|
| `sessions_history` | Tool | Yes (with scope) | Yes (with `all` scope) | Yes |
| `sessions_send` | Tool | Yes | Yes | Yes (async) |
| `sessions_spawn` | Tool | Creates new | No | Yes |
| `sessions_list` | Tool | Lists metadata | Yes (with scope) | Yes |
| `session_status` | Tool | Current session | No | Yes |
| `sessions_yield` | Tool | Waits for sub-agent | No | Yes |
| `lcm_grep` | LCM Tool | Current session only | No | Yes |
| `lcm_expand_query` | LCM Tool | Current session only | No | Yes |
| QMD memory search | Memory | Searches memory/ files | Configurable | No (index-based) |
| File system | Direct | Via shared files | Via shared files | No (polling) |

### 4.2 What Does NOT Exist

- **No session export API**: There is no `openclaw sessions export` command that produces a structured dump of a session's history
- **No session digest API**: There is no tool that produces a summary of another session's conversation
- **No cross-session LCM query**: LCM's DAG is per-conversation; you cannot query another session's compacted summaries
- **No session:end hook**: Planned but not yet implemented (openclaw#56842). Would enable automatic session summary on close
- **No session:start hook**: Also planned; would enable context bootstrapping on session resume
- **No inter-session provenance surfacing**: Requested in openclaw#57593 but not yet implemented

### 4.3 Feature Requests in Progress

| Issue | Title | Status | Relevance |
|-------|-------|--------|-----------|
| openclaw#57593 | Expose recent inter-session activity in session history | Open | Would surface cross-session provenance metadata |
| openclaw#56842 | session:end hook event for session summary automation | Open | Would enable auto-summary on session close |
| openclaw#57053 | Expose remaining session budget as structured data | Open | Would enable budget-aware session management |
| openclaw#63492 | Support external unified session storage | Open | Would enable shared session state across instances |
| openclaw#45501 | session.resetPrompt for configurable startup message | Open | Would enable context bootstrapping on session reset |

---

## 5. LCM (Lossless Context Management) and Session Compaction

### 5.1 How LCM Handles Compaction

LCM replaces OpenClaw's built-in sliding-window truncation with a DAG-based summarization system:

1. **Every message persisted** in SQLite (`~/.openclaw/lcm.db`)
2. **Incremental compaction** after each model turn when context usage hits 75% threshold
3. **Fresh tail protection**: Last 32-64 messages never compacted (configurable via `freshTailCount`)
4. **Three-level escalation**: Normal -> Aggressive -> Deterministic truncation (always makes progress)
5. **DAG structure**: Leaf summaries (depth 0) -> Condensed summaries (depth 1+)

### 5.2 LCM API for Reading Compressed Context

**Within the same session**, LCM provides three tools:

| Tool | Purpose | Cross-Session? |
|------|---------|---------------|
| `lcm_grep` | Search messages and summaries by regex/full-text | No |
| `lcm_describe` | Inspect a specific summary's content | No |
| `lcm_expand_query` | Spawn sub-agent to walk DAG and answer questions | No |

**All tools are scoped to the current conversation's DAG. There is no mechanism to query another session's LCM data.**

### 5.3 LCM Session Configuration Options

| Setting | Default | Purpose |
|---------|---------|---------|
| `contextThreshold` | 0.75 | Trigger compaction at this % of context window |
| `freshTailCount` | 32 | Messages protected from compaction |
| `incrementalMaxDepth` | -1 | Auto-condensation depth (-1 = unlimited) |
| `leafChunkTokens` | 20000 | Chunk size for leaf passes |
| `leafTargetTokens` | 1200 | Target size for leaf summaries |
| `condensedTargetTokens` | 2000 | Target size for condensed summaries |
| `summaryModel` | (configurable) | Model for summarization |
| `expansionModel` | (configurable) | Model for expansion queries |
| `ignoreSessionPatterns` | [] | Sessions excluded from LCM entirely |
| `statelessSessionPatterns` | [] | Sessions that can read but not write |
| `newSessionRetainDepth` | 2 | Summary layers retained on `/new` |

### 5.4 OpenClaw Built-in Compaction (without LCM)

If LCM is not installed, OpenClaw uses built-in compaction:

- **Trigger**: Context window near/exceeded, or model returns overflow error
- **Behavior**: Summarizes older turns, preserves recent messages and tool-call pairs
- **Pre-compaction memory flush**: Silent `NO_REPLY` turn to save important state to workspace files
- **Configuration**: `agents.defaults.compaction.model` (can use cheaper model for summarization)
- **Manual trigger**: `/compact` command (with optional guidance)

### 5.5 Session Pruning (Complementary to Compaction)

OpenClaw also performs **session pruning** -- removing outdated tool outputs from context:

- **In-memory only**: Does not modify on-disk transcripts
- **Targets**: Tool results, file read outputs, search results
- **Preserves**: Conversation text, 3 most recent completed turns
- **Trigger**: Cache TTL expiration (default 5 minutes)
- **Configuration**: `contextPruning: { mode: "cache-ttl", ttl: "5m" }`

---

## 6. Separating "Read Context" from "Write Context"

### 6.1 The Problem

Many workflows need an agent running in one session to read context from another session without polluting either session's history. Examples:
- Evening report agent needs to read each developer's daily notes session
- Tech-manager monitoring needs to read agent status without writing to agent sessions
- Cron job needs context from the user's DM session but should not add messages to it

### 6.2 Available Patterns

**Pattern 1: `sessions_history` Tool (Recommended)**

The cleanest approach for read-only cross-session access:
```
From cron session (write context):
  1. Use sessions_history to read DM session transcript (read context)
  2. Process the information
  3. Write results to cron session or memory files
  4. Optionally notify user via openclaw message send
```

Requires `visibility: "agent"` or `visibility: "all"` scope.

**Pattern 2: LCM Stateless Sessions**

LCM's `statelessSessionPatterns` allows sessions to read from existing conversations without writing:
```json
{
  "statelessSessionPatterns": ["agent:*:cron:report:**"]
}
```

Matching sessions can participate in LCM context assembly (reading summaries) but never trigger compaction or write new messages to the LCM database.

**Pattern 3: Memory File Layer**

Agents write structured data to `memory/` directory:
- Daily notes: `memory/YYYY-MM-DD.md`
- Status files: `memory/status.json`
- Incoming messages: `memory/incoming-context.json`

Other sessions read these files directly. Indexed by QMD for search. This is the most reliable cross-session and cross-agent pattern but is not real-time.

**Pattern 4: Sub-Agent Delegation**

Spawn a sub-agent in the target session's tree:
```
sessions_spawn(
  agentId: "dev1",
  message: "Summarize today's activity",
  runtime: "subagent"
)
```

The sub-agent runs within the target agent's context and can access its session history (within `tree` scope). Results returned asynchronously.

### 6.3 Recommended Architecture for openclaw-agents

For the evening report use case (tech-manager reading developer sessions):

```
                   +---------------------------+
                   | Tech Manager Cron Session  |
                   | (write context)            |
                   +---------------------------+
                            |
                   uses sessions_history
                   (visibility: "all")
                            |
            +---------------+---------------+
            |               |               |
    +-------v------+ +-----v--------+ +----v---------+
    | dev1 DM   | | dev10 DM     | | dev10 DM     |
    | session       | | session      | | session      |
    | (read only)   | | (read only)  | | (read only)  |
    +---------------+ +--------------+ +--------------+
```

For developer check-in cron jobs:

```
    +---------------------------+
    | Developer DM Session      |
    | (user conversations)      |
    +---------------------------+
            ^
            | sessions_history (read)
            |
    +---------------------------+
    | Dedicated Cron Session    |
    | agent:X:cron:morning      |
    | (cron writes here)        |
    +---------------------------+
            |
            | openclaw message send (notify)
            v
    +---------------------------+
    | Slack DM to Developer     |
    +---------------------------+
```

---

## 7. Known Bugs and Active Issues

### Session-Related Bugs

| Issue | Title | Severity | Workaround |
|-------|-------|----------|------------|
| openclaw#61426 | `sessionTarget: isolated` not honored -- cron messages accumulate in main | **HIGH** | Manual LCM DB cleanup |
| openclaw#63383 | Cron runtime crashes when `sessionTarget` is missing | Medium | Always set sessionTarget |
| openclaw#58304 | Non-isolated sessionTarget causes sessionId/sessionFile mismatch | Medium | Use consistent session targeting |
| openclaw#52875 | `sessions_send` gives "no session found" | Medium | Ensure target session exists first |
| openclaw#45488 | System prompt copying causes session bloat | Medium | Awaiting upstream fix |
| openclaw#45717 | skillsSnapshot bloat in session store | Medium | Periodic session cleanup |
| openclaw#60083 | Cron scheduler catch-up fires duplicate jobs on restart | Medium | Application-layer guards |

### Session-Related Feature Requests

| Issue | Title | Priority |
|-------|-------|----------|
| openclaw#56842 | `session:end` hook for session summary automation | High |
| openclaw#57593 | Expose inter-session provenance in history | Medium |
| openclaw#57053 | Expose session budget as structured data | Medium |
| openclaw#63492 | External unified session storage | Low (for our setup) |
| openclaw#45501 | Configurable session startup message | Low |

---

## 8. Recommendations for openclaw-agents

### Immediate Actions

1. **Migrate cron jobs to named persistent sessions**
   Change from `sessionTarget: "session:main"` to `sessionTarget: "session:agent:X:cron:<type>"` for all check-in cron jobs. This stops polluting the DM session with cron messages.

2. **Add LCM `ignoreSessionPatterns` for ephemeral cron sessions**
   ```json
   "ignoreSessionPatterns": ["agent:*:cron:summary"]
   ```
   Exclude daily summary sessions (which are one-shot) from LCM to reduce database growth.

3. **Configure `sessions_history` visibility scope**
   Set `visibility: "agent"` for tech-manager to enable cross-session reading for monitoring and evening reports.

4. **Implement session size monitoring**
   Add a periodic check (via launchd or tech-manager cron) that monitors session transcript sizes and alerts on growth.

### Short-Term (After Verifying Upstream Fixes)

5. **Test `isolated` sessionTarget after openclaw#61426 fix**
   Once the regression is fixed, use `isolated` for truly one-shot cron tasks like daily summaries.

6. **Add session rotation for long-running cron sessions**
   Named persistent cron sessions will grow over time. Implement periodic session reset (e.g., weekly) via `openclaw sessions cleanup` or manual reset.

7. **Enable LCM stateless patterns for reporting sessions**
   Configure `statelessSessionPatterns` for evening report sessions to allow reading without writing.

### Long-Term

8. **Watch for `session:end` hook (openclaw#56842)**
   When implemented, use it to automatically write session summaries to memory files, enabling seamless cross-session context.

9. **Watch for inter-session provenance (openclaw#57593)**
   When implemented, leverage structured provenance data for cross-agent communication context.

10. **Consider ACP bridge for advanced cross-session patterns**
    The ACP (Agent Control Protocol) provides WebSocket-based session access that could enable more sophisticated cross-session workflows, but documentation is sparse.

---

## 9. Source URLs and References

### Official Documentation
- https://docs.openclaw.ai (homepage)
- https://docs.openclaw.ai/concepts/session (session management)
- https://docs.openclaw.ai/concepts/session-tool (session tools)
- https://docs.openclaw.ai/concepts/session-pruning (session pruning)
- https://docs.openclaw.ai/concepts/compaction (compaction)
- https://docs.openclaw.ai/concepts/multi-agent (multi-agent sessions)
- https://docs.openclaw.ai/reference/session-management-compaction (deep dive)
- https://docs.openclaw.ai/cli/sessions (sessions CLI)

### GitHub Issues (openclaw/openclaw)
- #61426 -- sessionTarget: isolated not honored (REGRESSION)
- #63383 -- Cron crashes when sessionTarget missing
- #58304 -- sessionId/sessionFile mismatch
- #52875 -- sessions_send "no session found"
- #45488 -- Session bloat from system prompt copying
- #45717 -- skillsSnapshot bloat
- #60083 -- Cron scheduler catch-up bug
- #56842 -- Feature: session:end hook
- #57593 -- Feature: inter-session provenance
- #57053 -- Feature: session budget structured data
- #63492 -- Feature: external session storage
- #45501 -- Feature: session.resetPrompt

### LCM (Lossless Claw)
- https://github.com/Martian-Engineering/lossless-claw (source)
- npm: @martian-engineering/lossless-claw

### Internal Research (openclaw-agents/docs/research/)
- openclaw-session-key-vs-target-2026-04-09.md (source code analysis of sessionKey vs sessionTarget)
- openclaw-session-isolation-2026-04-07.md (session isolation verification)
- openclaw-session-lifecycle-compaction-2026-04-01.md (session lifecycle and LCM details)
- oversized-sessions-investigation-2026-04-01.md (session bloat case studies)
- cross-agent-slack-messaging-context-loss-2026-04-01.md (cross-agent communication gaps)
- openclaw-production-best-practices-2026-04-01.md (community patterns)
- lossless-claw-research-2026-03-27.md (LCM capabilities)
