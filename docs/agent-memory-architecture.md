# Agent Memory Architecture

## Overview

Agent memory has three layers with distinct responsibilities:

| Layer | Mechanism | Scope | Tooling |
|-------|-----------|-------|---------|
| **Durable memory** | Markdown files under `memory/` | Persistent, cross-session | `memory_search` (QMD) |
| **In-session recall** | LCM conversation DAG | Current session only | `lcm_grep`, `lcm_expand_query` |
| **Legacy compatibility** | Root `MEMORY.md` / `memory.md` | Indexed if present | `memory_search` (QMD) |

## Durable memory files

Two cron jobs write durable memory files for each agent every day:

- **Daily summary** (`memory/YYYY-MM-DD.md`) — conversation context: what the developer worked on, discussed, decided, and was blocked on. Written by `scripts/daily-summary.sh` from the DM session digest.
- **Work report** (`memory/reports/YYYY-MM-DD.md`) — work output: GitHub activity, PRs merged, issues closed. Written by `scripts/work-report.sh`.

Both paths match the QMD collection pattern `memory/**/*.md` and are indexed automatically.

## QMD — cross-session memory search

QMD is the memory backend powering `memory_search`. Each agent has its own QMD index under `~/.openclaw/agents/<agent>/qmd/`.

**What QMD indexes per agent:**
- `memory/**/*.md` — all dated notes and reports
- `MEMORY.md` at the agent workspace root (if present — legacy)
- `memory.md` at the agent workspace root (if present — legacy)

**Search modes:**

| Mode | How | Notes |
|------|-----|-------|
| `search` | Lexical BM25 | Default. Fast, cheap. Fails on natural-language queries. |
| `vsearch` | Vector similarity | Uses pre-embedded vectors. Handles natural-language well. No model download required. |
| `query` | Full hybrid + rerank | Best quality. Triggers per-agent download of `qmd-query-expansion` model (~1.28 GB each). Not used. |

**Current config:** `memory.qmd.searchMode = "vsearch"` in `openclaw.json`. This was chosen over `query` to avoid the per-agent model download cost while still enabling semantic retrieval from the existing embedded vectors.

**Query guidance for agents:** Write a focused sentence describing what you're looking for. Natural language works with vsearch. Avoid padding with unrelated metadata (dates, names, session context words) — they dilute the semantic signal.

- Good: `"subscription feature blocker"` or `"what was dev1 working on last week"`
- Avoid: `"dev1 today April 22 2026 work progress blockers carry over evening check-in"`

## LCM — session history management

LCM (Lossless Claw) replaces OpenClaw's sliding-window compaction with a DAG-based summarization system. It preserves every message in the current conversation while keeping the active context within model token limits.

LCM is **session history management**, not a knowledge store. It manages what was said in the conversation. QMD manages what was intentionally written down to be remembered. The distinction is intent: a message being sent is not the same as knowledge being captured.

**What LCM does:**
- Compacts old conversation turns into DAG summaries as context fills
- Exposes `lcm_grep`, `lcm_describe`, `lcm_expand_query` for recalling compacted parts of the current conversation

**What LCM does not do:**
- It does not read or write `memory/` files
- It does not index knowledge for later retrieval
- It cannot substitute for `memory_search` — if something was never written to a `memory/` file, LCM is the only way to reach it, but only within the current session

LCM state lives in `~/.openclaw/lcm.db` and `~/.openclaw/lcm-files`. It is not per-agent.

## When to use each tool

- **`memory_search`** — when you need to recall something specific: past decisions, blockers, what was worked on, what the developer told you. Use it any time precision matters, including mid-session when old context may have been compacted.
- **`lcm_grep` / `lcm_expand_query`** — when you need to find something said earlier in the current conversation that LCM may have compacted.
- **Read `memory/YYYY-MM-DD.md` directly** — for today's and yesterday's notes at session startup (startup sequence in AGENTS.md). Prefer `memory_search` for older recall.

## Root MEMORY.md — legacy pattern

Earlier versions of the agent instructions centered a root-level `MEMORY.md` file as the primary long-term memory mechanism. This pattern does not scale:

- Token bloat as it grows
- Manual curation burden on the agent during live sessions
- Single file creates merge/churn risk

Root `MEMORY.md` is still indexed by QMD if present (for backwards compatibility), but it is no longer the primary durable-memory strategy. The scalable pattern is dated files under `memory/` written by crons.

## Operational notes

- The standalone `qmd` CLI is currently broken under Node.js v25+ when using path-style `--index` values (`ERR_AMBIGUOUS_MODULE_SYNTAX`). This does not affect agents — OpenClaw uses the QMD internal module API, not the CLI. It only affects manual host-side diagnostics.
- To verify per-agent QMD health: compare markdown file count under `~/.openclaw/agents/<agent>/memory/` against document count in `~/.openclaw/agents/<agent>/qmd/xdg-cache/qmd/index.sqlite`.
