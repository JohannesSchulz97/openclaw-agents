# Cron Check-in Model Comparison: fw-mm25 vs fw-kk25

**Date:** 2026-03-26
**Status:** Actionable - Recommends model switch
**Related Task:** #6 - Switch cron model from fw-mm25 to fw-kk25

---

## Executive Summary

**Recommendation: Switch all cron check-in jobs from `fw-mm25` to `fw-kk25` immediately.**

The current `fw-mm25` (MiniMax M2P5) configuration has an artificially low 16K context window configured in OpenClaw, causing "low context window" warnings. Meanwhile, `fw-kk25` (Kimi K2.5 via Fireworks) is already registered on the same provider with 128K context, reasoning capability enabled, and is better suited for the agentic check-in workflow.

---

## Model Registry (from openclaw.json)

Both models are registered under the **same Fireworks provider** (`fw-mm25` provider block), sharing a single API key:

| Property | fw-mm25 (MiniMax M2P5) | fw-kk25 (Kimi K2.5) |
|----------|------------------------|----------------------|
| **Model ID** | `accounts/fireworks/models/minimax-m2p5` | `fireworks/kimi-k2p5` |
| **Alias** | `fw-mm25` | `fw-kk25` |
| **Context Window (configured)** | 16,000 tokens | 128,000 tokens |
| **Max Output Tokens** | 4,096 | 16,384 |
| **Reasoning** | false | true |
| **Input Types** | text | text |
| **Cost (configured)** | $0 (all fields) | $0 (all fields) |

**Key Finding:** The fw-mm25 context window is configured at 16K in OpenClaw, but the actual MiniMax M2.5 model supports ~197K tokens on Fireworks. This misconfiguration is the root cause of the "low context window" warnings.

---

## Actual Model Specifications

### MiniMax M2.5 (fw-mm25)

| Spec | Value |
|------|-------|
| **Architecture** | MoE, 228.7B params |
| **Native Context** | 196,608 tokens (~197K) |
| **Max Output** | 65,536 tokens |
| **Reasoning** | No native reasoning mode |
| **Fireworks Price** | $0.30 / $0.03 (cached) / $1.20 per 1M tokens |
| **Speed (Fireworks)** | 241 tokens/sec |
| **Release** | Feb 12, 2026 |
| **SWE-Bench** | 80.2% |
| **AIME 2025** | 78% |

### Kimi K2.5 (fw-kk25)

| Spec | Value |
|------|-------|
| **Architecture** | MoE, 1T total / 32B activated |
| **Native Context** | 262,144 tokens (~256K) |
| **Max Output** | 262,144 tokens |
| **Reasoning** | Yes - native thinking/reasoning mode |
| **Fireworks Price** | $0.60 / $0.10 (cached) / $3.00 per 1M tokens |
| **Speed (Fireworks)** | 349 tokens/sec |
| **Release** | Jan 27, 2026 |
| **Notable** | Powers Cursor Composer 2; Agent Swarm technology |

### Google Gemini 3.1 Pro (also registered)

| Spec | Value |
|------|-------|
| **Context Window** | 200,000 tokens |
| **Max Output** | 8,192 tokens |
| **Reasoning** | false |
| **Input Types** | text, image |
| **Cost (configured)** | $0 |

---

## Check-in Job Requirements Analysis

The cron check-in payload (from jobs-config.json) requires:

1. **Run shell script** (`poll-check.sh`) and **parse JSON output** - Simple, any model handles this
2. **Read markdown files** (`USER.md`, `IDENTITY.md`) - Adds ~500-2000 tokens to context
3. **Run GitHub activity script** and parse output - Adds ~1000-5000 tokens (variable)
4. **Review conversation history and memory** - This is the BIG one: could easily be 5K-15K+ tokens
5. **Compose personalized check-in message** - Requires reasoning and creativity
6. **Execute CLI command** (`openclaw message send`) - Simple tool use
7. **Update JSON state file** - Simple

### Total context budget estimate per check-in:
- System prompt + cron payload: ~2K tokens
- USER.md + IDENTITY.md: ~1-2K tokens
- GitHub activity output: ~2-5K tokens
- Conversation history/memory: ~5-15K tokens
- Reasoning/composition space: ~2-4K tokens
- **Total needed: ~12-28K tokens**

### Why 16K fails:
The configured 16K context window for fw-mm25 is barely sufficient for the minimal case and completely insufficient when conversation history or GitHub activity is substantial. This explains the "low context window" warnings.

---

## What Matters Most for Check-ins?

| Factor | Importance | Why |
|--------|-----------|-----|
| **Context Window** | CRITICAL | Must fit system prompt + markdown files + GitHub activity + conversation history. 16K is too small; 128K provides ample room. |
| **Reasoning Quality** | HIGH | Must compose thoughtful, personalized messages that reference specific GitHub PRs and weave in conversation context. Generic messages defeat the purpose. |
| **Cost** | LOW | Check-ins run 6 agents x ~12 times/day = ~72 invocations. Even at worst case ~5K tokens each, total daily usage is ~360K tokens. At Kimi K2.5 pricing ($0.60/$3.00 per 1M), that is less than $1.50/day. |
| **Speed** | LOW | 180-second timeout is generous. Both models complete well within this. Kimi K2.5 is actually faster (349 t/s vs 241 t/s on Fireworks). |
| **Tool/Agent Use** | MEDIUM | Must parse JSON, run CLI commands. Kimi K2.5 is specifically designed for agentic workflows. |

---

## Recommendation

### Primary: Switch to fw-kk25 (Kimi K2.5)

**Rationale:**
1. **8x more context window** (128K configured vs 16K) - eliminates the "low context window" warnings entirely
2. **Reasoning enabled** - better at composing thoughtful, personalized messages
3. **Agentic design** - Kimi K2.5 is specifically built for tool-use and multi-step agent workflows, exactly matching the check-in job pattern
4. **Faster** - 349 t/s vs 241 t/s on Fireworks
5. **Already registered** - No configuration changes needed beyond updating the model field in jobs-config.json
6. **Marginal cost increase** - ~$1-2/day additional cost, trivial for the quality improvement

### Implementation:
Change `"model": "fw-mm25"` to `"model": "fw-kk25"` in all 6 jobs in `.openclaw/cron/jobs-config.json`, then run `bash scripts/apply-cron.sh`.

### Alternative: Fix fw-mm25 context window configuration

If cost is a major concern, the configured context window for MiniMax M2.5 could be increased from 16K to its actual 197K capability. However, this still leaves reasoning disabled and uses a model not optimized for agentic workflows.

### Alternative: Use Gemini 3.1 Pro

Already registered with 200K context. However, it is on a different provider (Google), and maxTokens is only 8,192. Could work but Kimi K2.5 is better suited.

---

## Sources

- [Fireworks AI - Kimi K2.5 Model Page](https://fireworks.ai/models/fireworks/kimi-k2p5)
- [Fireworks AI - MiniMax M2.5 Model Page](https://fireworks.ai/models/fireworks/minimax-m2p5)
- [Kimi K2.5 on Fireworks Blog](https://fireworks.ai/blog/kimi-k2p5)
- [MiniMax M2.5 Specs - Galaxy.ai](https://blog.galaxy.ai/model/minimax-m2-5)
- [Kimi K2.5 Guide - Codecademy](https://www.codecademy.com/article/kimi-k-2-5-complete-guide-to-moonshots-ai-model)
- [Kimi K2.5 Pricing - OpenRouter](https://openrouter.ai/moonshotai/kimi-k2.5)
- [MiniMax M2.5 Pricing - OpenRouter](https://openrouter.ai/minimax/minimax-m2.5)
- [Artificial Analysis - MiniMax M2.5](https://artificialanalysis.ai/models/minimax-m2-5)
- [Artificial Analysis - Kimi K2.5](https://artificialanalysis.ai/models/kimi-k2-5)
- Local config: `~/.openclaw/openclaw.json` (model registry)
- Local config: `.openclaw/cron/jobs-config.json` (cron jobs)
