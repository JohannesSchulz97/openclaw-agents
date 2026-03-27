# Lossless Claw Research

**Date:** 2026-03-27
**Context:** GitHub Issue #20 (<your-org>/openclaw-agents)
**Classification:** Actionable (integration required)

---

## What is Lossless Claw?

Lossless Claw is a **Lossless Context Management (LCM)** plugin for OpenClaw, developed by **Martian Engineering** and based on the LCM paper from Voltropy. It replaces OpenClaw's built-in sliding-window compaction with a **DAG-based summarization system** that preserves every message while keeping active context within model token limits.

- **GitHub:** https://github.com/Martian-Engineering/lossless-claw
- **npm:** `@martian-engineering/lossless-claw` (v0.5.1, 606 kB, MIT license)

## The Problem It Solves

OpenClaw's default compaction is **permanent and lossy** -- when a conversation grows beyond the model's context window, older messages are truncated/rewritten into a summary. Critical instructions can vanish during this process.

**Real-world failure example:** An agent pointed at an inbox with thousands of messages had its context compacted. A "don't do anything until I say so" instruction was lost in the summary. The agent reverted to autonomous mode and started deleting emails.

Lossless Claw addresses this by ensuring **no message is ever permanently deleted** from the conversation history.

## How It Works

1. **Persists every message** in a SQLite database (nothing is lost)
2. **Summarizes chunks** of older messages into summaries using a configured LLM
3. **Condenses summaries** into higher-level DAG (Directed Acyclic Graph) nodes
4. **Assembles context** each turn by combining summaries + recent raw messages
5. **Provides agent tools** (`lcm_grep`, `lcm_describe`, `lcm_expand`) so agents can search and recall details from compacted history

## Key Configuration

| Setting | Value | Purpose |
|---------|-------|---------|
| `freshTailCount` | 32 | Protects last 32 messages from compaction |
| `incrementalMaxDepth` | -1 | Unlimited automatic DAG condensation depth |
| `contextThreshold` | 0.75 | Triggers compaction at 75% of context window |
| `summaryModel` | (configurable) | Pin summarization to cheaper model (e.g., claude-haiku-4-5) |
| `expansionModel` | (configurable) | Pin expansion queries to cheaper model |

## Lossless Claw vs. Memory Systems

- **Memory systems** (like QMD, local memory) are for searching information **external** to the current context window, and sharing memories between agents
- **Lossless Claw** manages what happens **within** a conversation -- preventing information loss during context compaction
- Both can be used together; they solve different problems

## Installation

```bash
# From npm
npm i @martian-engineering/lossless-claw

# Or via OpenClaw plugin system
openclaw plugins install --link /path/to/lossless-claw
```

The install command records the plugin, enables it, and applies compatible slot selection. No manual JSON edits needed in most cases.

## Issue #20 Proposal

Issue #20 proposes integrating Lossless Claw into the openclaw-agents setup to improve context management across agent sessions. The tasks are:

1. Research Lossless Claw capabilities and requirements (this document)
2. Evaluate compatibility with current OpenClaw agent setup
3. Plan integration approach for dev-pa agent type
4. Implement integration for a pilot agent
5. Roll out to all agents if pilot succeeds
6. Document configuration and usage

## Relevance to openclaw-agents

Currently, openclaw-agents uses:
- **Memory backend:** local (or QMD, though QMD has known issues)
- **Agent type:** dev-pa with MEMORY.md for durable state
- **Model:** openai-codex/gpt-5.4 for all agents
- **Cron check-ins:** every 2 hours

Lossless Claw would be particularly valuable because:
- Agents run long sessions with heartbeat polling every 10 minutes
- Context can grow large during active work periods
- Critical instructions in AGENTS.md and SOUL.md could be lost during compaction
- The DAG-based approach would let agents recall earlier conversation details on demand

## Compatibility Considerations

- Lossless Claw is an npm package (compatible with OpenClaw's Node.js ecosystem)
- Uses SQLite for persistence (no external DB required)
- Plugin system integration via `openclaw plugins install`
- Model overrides allow using cheaper models for summarization (cost management for 19 agents)
- Need to verify compatibility with the current OpenClaw version in use

## Recommendations

1. **Pilot with one agent** (e.g., dev1 or <your-org>) before rolling out
2. **Configure `summaryModel`** to use a cheaper model to control costs across 19 agents
3. **Set `contextThreshold=0.75`** as recommended default
4. **Keep `freshTailCount=32`** to ensure recent context continuity
5. **Test with heartbeat/cron workflows** to ensure LCM does not interfere with periodic tasks
6. **Monitor SQLite DB growth** -- with 19 agents running continuously, storage could grow

---

## Sources

- [Martian-Engineering/lossless-claw (GitHub)](https://github.com/Martian-Engineering/lossless-claw)
- [@martian-engineering/lossless-claw (npm)](https://www.npmjs.com/package/@martian-engineering/lossless-claw)
- [OpenClaw Memory Documentation](https://docs.openclaw.ai/concepts/memory)
- [OpenClaw Plugins Documentation](https://docs.openclaw.ai/tools/plugin)
- [Josh Lehman on Lossless Claw vs Memory Systems](https://x.com/jlehman_/status/2033319118343184725)
