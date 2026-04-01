# OpenClaw Session Lifecycle, Compaction, and Memory Summarization

**Date:** 2026-04-01
**Researcher:** dev1 (research agent)
**Classification:** Informational (reference material)

---

## Executive Summary

OpenClaw manages sessions through an idle-timeout reset policy (currently 7 days), with context compaction handled entirely by the **lossless-claw (LCM)** plugin -- a DAG-based summarization system that replaces OpenClaw's built-in sliding-window truncation. The QMD memory backend is a separate system for searching markdown memory files and is NOT involved in session compaction. Sessions do not have a hard size limit; instead, LCM triggers compaction when context usage reaches 75% of the model's context window.

---

## 1. Session Lifecycle

### Session Creation
- Sessions are created on first message to an agent for a given routing key (e.g., `agent:dev1:slack:direct:u09l59gj3qt`).
- Each session gets a UUID (`sessionId`) and a human-readable `key`.
- Sessions are stored as JSONL transcript files under `~/.openclaw/agents/<agentId>/sessions/`.
- A session metadata index lives at `~/.openclaw/agents/<agentId>/sessions/sessions.json`.

### Session Reset (Expiry/TTL)
- **Mode:** `idle` (configured in `openclaw.json` at `session.reset.mode`)
- **Idle timeout:** `10080` minutes = **7 days** (configured at `session.reset.idleMinutes`)
- When the idle timer expires, the session resets -- meaning a new session is created for subsequent messages.
- There is also a `daily` reset mode (not currently used) where sessions reset at a daily boundary.
- OpenClaw does NOT enforce a maximum `idleMinutes` -- it accepts any positive integer.
- Legacy key `session.idleMinutes` still works but `session.reset.idleMinutes` takes precedence.

### Session Cleanup
- `openclaw sessions cleanup` provides maintenance:
  - Removes stale sessions beyond configured retention
  - Can fix entries with missing transcript files (`--fix-missing`)
  - Supports `--dry-run` for preview
  - Can protect active sessions from eviction (`--active-key`)
- No automatic cleanup runs on a schedule -- it must be invoked manually or via cron.

### Current Session State (Live Data)
- 229 sessions across 19 agents
- `agent:main:main` is at 71.7% context utilization (145K/202K tokens) -- approaching compaction threshold
- Most sessions are well under threshold (4-35% usage)

---

## 2. Context Compaction (Lossless-Claw / LCM Plugin)

### What It Is
LCM is a plugin that replaces OpenClaw's built-in sliding-window compaction. Instead of truncating old messages, it:
1. **Persists every message** in a SQLite database (`~/.openclaw/lcm.db`)
2. **Summarizes chunks** of older messages into leaf summaries using an LLM
3. **Condenses summaries** into higher-level DAG nodes as they accumulate
4. **Assembles context** each turn by combining summaries + recent raw messages
5. **Provides tools** (`lcm_grep`, `lcm_describe`, `lcm_expand_query`) for agents to recall compacted details

### Compaction Trigger (When)
Compaction is **size-based**, triggered by context window usage:
- **Threshold:** 75% of model context window (`contextThreshold: 0.75`)
- **Check timing:** After every model turn (`afterTurn` hook)
- **Condition:** Raw tokens outside the "fresh tail" must exceed `leafChunkTokens` (20K tokens)
- NOT time-based. NOT on session close. NOT periodic.

### Fresh Tail Protection
- The last **32 messages** (`freshTailCount: 32`) are never compacted
- These raw messages give the model immediate conversational continuity
- For coding conversations with tool calls (many messages per logical turn), 32 is recommended

### Compaction Modes

**Incremental (automatic, after each turn):**
1. Check if raw tokens outside fresh tail exceed `leafChunkTokens` (20K)
2. If so, run one leaf pass (summarize oldest chunk of raw messages)
3. With `incrementalMaxDepth: -1` (current config), cascade condensation passes as deep as needed
4. Best-effort: failures do not break the conversation

**Full sweep (manual `/compact` command or overflow):**
1. Phase 1: Repeatedly run leaf passes until no more eligible chunks
2. Phase 2: Repeatedly run condensation passes from shallowest eligible depth
3. Each pass checks for progress; stops if no tokens saved

**Budget-targeted (`compactUntilUnder`):**
- Runs up to 10 rounds of full sweeps
- Stops when context is under target token count
- Used by overflow recovery path

### Three-Level Escalation
Every summarization attempt follows this escalation:
1. **Normal** -- Standard prompt, temperature 0.2
2. **Aggressive** -- Tighter prompt (only durable facts), temperature 0.1, lower target tokens
3. **Fallback** -- Deterministic truncation to ~512 tokens with `[Truncated for context management]` marker

This ensures compaction ALWAYS makes progress, even if the LLM produces poor output.

### DAG Structure
- **Leaf summaries** (depth 0): Created from raw message chunks, typically 800-1200 tokens
- **Condensed summaries** (depth 1+): Created from same-depth summaries, typically 1500-2000 tokens
- Minimum fanout: 8 raw messages per leaf, 4 summaries per condensed node

### Current LCM Database Stats
| Depth | Summary Count | Total Tokens | Avg Tokens |
|-------|--------------|-------------|-----------|
| 0 (leaf) | 7,127 | 3,130,391 | 439 |
| 1 | 525 | 234,686 | 447 |
| 2 | 93 | 47,649 | 512 |
| 3 | 17 | 10,382 | 611 |
| 4 | 2 | 613 | 307 |

Total: 7,764 summaries across 96 conversations, with a 5-level deep DAG.

### Context Assembly (Each Turn)
Before each model turn, the assembler builds:
```
[summary_1, summary_2, ..., summary_n, message_1, message_2, ..., message_m]
 |--- budget-constrained ---|  |---- fresh tail (always included) ----|
```
1. Fetch all context_items ordered by ordinal
2. Resolve items (summaries become XML-wrapped user messages; messages reconstructed from parts)
3. Split into evictable prefix and protected fresh tail
4. Fill remaining budget from evictable set, keeping newest, dropping oldest
5. Sanitize tool-use/result pairing

### Summarization Model
- Currently using: `fw-mm25/accounts/fireworks/models/qwen3-8b` (Qwen3 8B on Fireworks)
- This is a cheaper/faster model than the main agent model (GPT-5.4)
- Same model used for both compaction summarization and expansion sub-agents

### Session Exclusion
- Cron sessions (`agent:*:cron:**`) can be excluded via `ignoreSessionPatterns`
- Current config does NOT have `ignoreSessionPatterns` set -- all sessions participate in LCM
- Stateless session patterns available for sub-agents that should read but not write

---

## 3. Memory Backend (QMD)

### What It Is
QMD (Quick Markdown) is a **separate system** from session compaction. It provides:
- Full-text BM25 keyword search across markdown memory files
- Vector similarity search with embeddings
- Hybrid search with auto-expansion and reranking

### What It Does NOT Do
- QMD does NOT summarize sessions
- QMD does NOT compact context
- QMD does NOT interact with session data
- QMD does NOT write to or read from LCM's SQLite database

### How It Works
- Each agent has its own QMD index at `~/.openclaw/agents/<agentId>/qmd/xdg-cache/qmd/index.sqlite`
- It indexes markdown files from the agent's `memory/` directory
- The `openclaw memory` CLI provides search, index, and status commands
- Currently: most agents have 2-3 indexed memory files with 2-3 chunks each

### Relationship to Sessions
QMD and sessions are completely independent:
- Sessions store conversation transcripts (JSONL files)
- QMD indexes persistent markdown knowledge files (memory/*.md)
- LCM bridges both by persisting all session messages to its own SQLite DB

---

## 4. LCM Plugin Details

### Plugin Registration
- Installed as npm package: `@martian-engineering/lossless-claw@0.5.2`
- Registered as context engine slot: `plugins.slots.contextEngine: "lossless-claw"`
- Database: `~/.openclaw/lcm.db` (single SQLite file, shared across all agents)
- Auto-loaded on startup (log: `[lcm] Plugin loaded, db=lcm.db, threshold=0.75`)

### Plugin Lifecycle Hooks
LCM implements the `ContextEngine` interface with these hooks:
1. **bootstrap** -- On session start, reconciles JSONL transcript with LCM database (crash recovery)
2. **ingest / ingestBatch** -- Persists new messages to database, appends to context_items
3. **assemble** -- Before each model turn, builds context from summaries + recent messages
4. **afterTurn** -- After model responds, ingests new messages, evaluates compaction need
5. **compact** -- Manual compaction trigger (via `/compact` command)

### Agent Tools Provided
1. **lcm_grep** -- Search messages and summaries by regex or full-text
2. **lcm_describe** -- Inspect a specific summary's full content (cheap, no sub-agent)
3. **lcm_expand_query** -- Spawn sub-agent to walk DAG and answer focused questions (~30-120s)
4. **lcm_expand** -- Low-level DAG tool (sub-agent only)

### Large File Handling
Files exceeding 25K tokens are:
1. Stored separately in `~/.openclaw/lcm-files/<conversation_id>/`
2. Replaced with compact reference in the message
3. Given a ~200 token exploration summary
4. Retrievable via `lcm_describe(id: "file_xxx")`

---

## 5. Hooks for Monitoring and Mitigation

### What We Can Monitor

**Session level (via `openclaw sessions`):**
- Token usage per session (inputTokens, totalTokens, contextTokens)
- Context utilization percentage (totalTokens / contextTokens)
- Session age and activity timestamps
- Model and provider per session

**LCM level (via `sqlite3 ~/.openclaw/lcm.db`):**
- Conversation message counts and token totals
- Summary DAG depth and distribution
- Compaction history (summary creation timestamps)
- Context item counts per conversation

### What We Can Control

**Session reset policy:**
- `session.reset.idleMinutes` -- How long before session expires (currently 7 days)
- `session.reset.mode` -- `idle` or `daily`
- `openclaw sessions cleanup --enforce` -- Manual cleanup

**Compaction behavior:**
- `contextThreshold` (0.75) -- When to trigger compaction (lower = more aggressive)
- `freshTailCount` (32) -- How many recent messages to protect
- `incrementalMaxDepth` (-1) -- How deep auto-condensation goes
- `leafChunkTokens` (20000) -- Chunk size for leaf passes
- `leafTargetTokens` (1200) / `condensedTargetTokens` (2000) -- Summary size targets
- `summaryModel` -- Which model does summarization (cost/quality tradeoff)
- `LCM_AUTOCOMPACT_DISABLED` -- Disable automatic compaction entirely
- `ignoreSessionPatterns` -- Exclude low-value sessions (e.g., cron)

**Manual compaction:**
- Agents can use `/compact` command for full sweep
- `compactUntilUnder` for budget-targeted compaction

### Recommendations for Our Setup

1. **Add `ignoreSessionPatterns`** for cron sessions -- they create conversations in LCM unnecessarily:
   ```json
   "ignoreSessionPatterns": ["agent:*:cron:**"]
   ```

2. **Monitor context utilization** -- The `agent:main:main` session is at 71.7%, close to the 75% threshold. This is normal and means compaction will trigger soon.

3. **Session cleanup cron** -- Consider adding a periodic `openclaw sessions cleanup --all-agents --enforce` to clean stale sessions.

4. **LCM database monitoring** -- The DB has 7,764 summaries with a 5-level DAG. This is healthy. Watch for conversations with very high message counts or deep DAGs as indicators of potential issues.

5. **Summarization model quality** -- Currently using Qwen3 8B (cheap/fast). If summary quality degrades in deep condensation levels, consider upgrading to a stronger model for `summaryModel`.

---

## 6. Key Takeaways

| Question | Answer |
|----------|--------|
| When does compaction happen? | After each model turn, when context usage hits 75% of window |
| Is it automatic? | Yes, incremental after every turn. Full sweep on overflow or manual `/compact` |
| Time-based? | No. Size-based (context window utilization) |
| On session close? | No. Sessions expire via idle timeout (7 days), no compaction on close |
| Session TTL? | 7 days idle timeout (`session.reset.idleMinutes: 10080`) |
| Memory backend involvement? | QMD is separate -- indexes markdown files, NOT session data |
| What is LCM? | DAG-based summarization plugin replacing sliding-window truncation |
| What happens when sessions get too large? | LCM compacts automatically. Three-level escalation ensures progress. Overflow recovery runs budget-targeted sweeps. |
| Data loss? | None. Raw messages persist in LCM SQLite DB. Summaries link back to sources. Agents can drill into any summary via tools. |
