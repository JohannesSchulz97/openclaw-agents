# Unified Model Selection: One Model for Interactive + Cron

**Date:** 2026-03-26
**Status:** Actionable - Recommends unified model strategy
**Related:** Task #6 (Switch cron model), existing cron-model-comparison research

---

## Executive Summary

**Recommendation: Unify on Kimi K2.5 via Fireworks (`fw-kk25`) for both interactive Slack conversations and cron check-in jobs.**

Kimi K2.5 offers the best balance of intelligence, agentic tool use, cost, and speed for your specific workload. It is already registered in your OpenClaw config (`fw-kk25`), has 128K context configured, reasoning enabled, and costs roughly 75% less than GPT-5.4 while delivering competitive quality for personalized message composition.

If budget is not a constraint and you want the absolute highest quality for interactive conversations, GPT-5.4 remains the quality leader -- but at 4-10x the cost of Kimi K2.5, the marginal quality improvement does not justify the expense for 6 agents running continuous cron jobs.

---

## Current Setup

| Use Case | Model | Provider | Approx. Cost |
|----------|-------|----------|-------------|
| Interactive Slack | GPT-5.4 | OpenAI direct | $2.50/$15.00 per 1M tokens (in/out) |
| Cron check-ins | fw-mm25 (MiniMax M2.5) | Fireworks AI | ~$0.30/$1.20 per 1M tokens (in/out) |

**Problems with current dual-model setup:**
1. Personality inconsistency -- agents behave differently in cron vs interactive mode
2. fw-mm25 is misconfigured with only 16K context window in OpenClaw (actual model supports ~197K)
3. MiniMax M2.5 scores lowest on Intelligence Index (42) among Fireworks frontier models
4. Configuration complexity -- two model configs to manage per agent
5. GPT-5.4 for interactive is expensive for 6 agents with variable usage

---

## Cost Analysis

### Usage Assumptions

| Workload | Daily Volume | Input Tokens | Output Tokens |
|----------|-------------|-------------|--------------|
| Cron check-ins | 72 invocations/day (6 agents x 12/day) | ~20K per invocation | ~2K per invocation |
| Interactive Slack | ~50 conversations/day (all agents combined) | ~10K per conversation | ~2K per conversation |

**Monthly totals:**
- Cron: 72 x 30 = 2,160 invocations/month
  - Input: 2,160 x 20K = 43.2M tokens/month
  - Output: 2,160 x 2K = 4.32M tokens/month
- Interactive: 50 x 30 = 1,500 conversations/month
  - Input: 1,500 x 10K = 15M tokens/month
  - Output: 1,500 x 2K = 3M tokens/month
- **Combined monthly: ~58.2M input tokens, ~7.32M output tokens**

### Monthly Cost Comparison (All 6 Agents, Combined Workload)

| Model | Input Cost | Output Cost | Monthly Total | vs GPT-5.4 |
|-------|-----------|-------------|--------------|------------|
| **GPT-5.4** (OpenAI) | $145.50 | $109.80 | **$255.30** | baseline |
| **GPT-5.4 Nano** (OpenAI) | $11.64 | $9.15 | **$20.79** | -92% |
| **Kimi K2.5** (Fireworks) | $34.92 | $18.30 | **$53.22** | -79% |
| **GLM-5** (Fireworks) | $58.20 | $23.42 | **$81.62** | -68% |
| **MiniMax M2.5** (Fireworks) | $17.46 | $8.78 | **$26.24** | -90% |
| **DeepSeek V3.2** (Fireworks) | ~$29.10 | ~$14.64 | **~$43.74** | -83% |
| **Llama 4 Maverick** (Fireworks) | $12.80 | $6.44 | **$19.25** | -92% |
| **Qwen3 30B** (Fireworks) | $5.24 | $5.24 | **$10.48** | -96% |

**Notes:**
- GPT-5.4 costs calculated at $2.50/$15.00 per 1M tokens
- Fireworks pricing from their current catalog (March 2026)
- Kimi K2.5 at $0.60/$2.50 per 1M tokens on Fireworks
- GLM-5 at $1.00/$3.20 per 1M tokens on Fireworks
- MiniMax M2.5 at $0.30/$1.20 per 1M tokens on Fireworks
- Prompt caching can reduce input costs further (75% for OpenAI, varies by provider)

### Annual Savings Projection

| Switch From/To | Annual Savings |
|----------------|---------------|
| GPT-5.4 everywhere -> Kimi K2.5 everywhere | ~$2,425/year |
| GPT-5.4 interactive + fw-mm25 cron -> Kimi K2.5 unified | ~$1,900/year |
| GPT-5.4 everywhere -> GLM-5 everywhere | ~$2,085/year |

---

## Quality Comparison for Your Specific Tasks

Your agents need to:
1. Run shell scripts and parse JSON output (tool use)
2. Read markdown files (USER.md, IDENTITY.md)
3. Run github-activity.sh and parse structured output
4. Compose warm, personalized messages referencing specific PRs and conversations
5. Execute `openclaw message send` CLI commands
6. Update JSON state files

### Model Ranking by Capability

| Capability | Best | 2nd | 3rd | Notes |
|-----------|------|-----|-----|-------|
| **Tool use / function calling** | Kimi K2.5 | MiniMax M2.5 | GPT-5.4 | Kimi K2.5 top OSS for complex instruction + multi-tool use |
| **Personalized message quality** | GPT-5.4 | Kimi K2.5 | GLM-5 | GPT-5.4 still leads in linguistic nuance |
| **JSON parsing / structured output** | GPT-5.4 | Kimi K2.5 | MiniMax M2.5 | All strong; 16/17 Fireworks models support function calling |
| **Reasoning (complex tasks)** | GLM-5 (50) | Kimi K2.5 (47) | MiniMax M2.5 (42) | Intelligence Index scores from Artificial Analysis |
| **Context window** | GPT-5.4 (1.1M) | MiniMax M2.5 (197K) | Kimi K2.5 (128K) | All exceed your 30K+ requirement |
| **Speed (interactive latency)** | Kimi K2.5 (349 t/s) | MiniMax M2.5 (241 t/s) | GLM-5 (204 t/s) | On Fireworks; GPT-5.4 latency varies |
| **SWE-Bench Verified** | MiniMax M2.5 (80.2%) | Kimi K2.5 (76.8%) | GPT-5.4 (57.7% Pro) | Open-weight models lead here |

### Key Finding: Fireworks Real-World Leaderboard

From Fireworks' own benchmarks on complex instruction following and multi-tool use:
- **Claude Sonnet 4** is the hands-down leader (but not available on Fireworks for cron)
- Among OSS models, **Qwen 235B thinking** is top for reasoning models
- For instruct models, **Kimi K2** is the best for complex instructions
- **Qwen3 Coder** matches GPT-4.1 for simple tool-calling

---

## Candidate Deep Dive

### Option 1: Kimi K2.5 via Fireworks (`fw-kk25`) -- RECOMMENDED

**Pros:**
- Already registered in your OpenClaw config with 128K context and reasoning enabled
- Zero migration effort for cron (just change model field in jobs-config.json)
- Best-in-class for complex agentic instruction following among open-weight instruct models
- 349 tokens/second on Fireworks -- fast enough for interactive Slack
- $0.60/$2.50 per 1M tokens -- 79% cheaper than GPT-5.4
- 1.04T total parameters, 32B active -- large enough for nuanced message composition
- Strong vision capabilities (OCRBench 92.3%) if you add image understanding later
- Agent Swarm native training -- designed for exactly the kind of multi-step agentic work your check-ins do

**Cons:**
- 128K context (vs GPT-5.4's 1.1M) -- sufficient but not massive
- Slightly lower linguistic nuance than GPT-5.4 for creative writing
- Reasoning model means variable latency for complex tasks

**Monthly cost: ~$53/month for all 6 agents**

### Option 2: GLM-5 via Fireworks

**Pros:**
- Highest Intelligence Index (50) on Fireworks
- 744B MoE parameters, strong reasoning
- Good for complex systems engineering tasks

**Cons:**
- Not currently registered in your OpenClaw config (would need setup)
- More expensive ($1.00/$3.20) than Kimi K2.5
- Slower (204 t/s vs 349 t/s for K2.5) -- may feel sluggish for interactive
- Less proven for the specific "compose warm personal messages" task

**Monthly cost: ~$82/month for all 6 agents**

### Option 3: MiniMax M2.5 (`fw-mm25`) -- Keep Current Cron Model, Also Use for Interactive

**Pros:**
- Already configured (though with wrong context window)
- Cheapest frontier option ($0.30/$1.20)
- Top SWE-Bench score (80.2%)
- 241 t/s on Fireworks

**Cons:**
- Lowest Intelligence Index (42) among Fireworks frontier models
- Specialist model optimized for code -- weaker on general conversation and warmth
- The 16K context misconfiguration needs fixing regardless
- Less strong on complex multi-step instruction following vs Kimi K2.5

**Monthly cost: ~$26/month for all 6 agents**

### Option 4: GPT-5.4 for Everything

**Pros:**
- Highest quality for linguistic nuance and creative message composition
- 1.1M context window
- Mature tool ecosystem and plugin support
- Most reliable for zero-shot reasoning

**Cons:**
- $255/month -- 5x more than Kimi K2.5, 10x more than MiniMax M2.5
- Not on Fireworks -- would need separate OpenAI provider config for cron
- Check-in jobs do not need GPT-5.4 quality for parsing JSON and running shell scripts
- Overkill for the "if data.due == 0, output NO_ACTION" fast path (most cron invocations)

**Monthly cost: ~$255/month for all 6 agents**

### Option 5: GPT-5.4 Nano for Everything

**Pros:**
- Ultra-cheap ($0.20/$1.25 per 1M tokens)
- 400K context window
- Solid tool calling for lightweight agent scenarios
- OpenAI ecosystem

**Cons:**
- Designed for classification/extraction -- not creative message composition
- No deep reasoning or Computer Use
- Message quality would noticeably degrade for warm, personalized check-ins
- SWE-Bench Pro 52.4% -- significantly below frontier models

**Monthly cost: ~$21/month -- cheapest but quality trade-off is too steep for personalized messages**

---

## Can GPT-5.4 Be Used for Cron Too?

**Yes.** OpenClaw's cron job configuration accepts a `model` field per job (as seen in jobs-config.json), and the model catalog in `openclaw.json` under `agents.defaults.models` acts as the allowlist. If GPT-5.4 is registered in your model catalog, you can set it as the cron model.

However, per-agent defaults can override `agents.defaults.model` via `agents.list[].model`, and the `model` field in cron jobs-config.json takes precedence for cron invocations. This means you can use different models for interactive vs cron, or unify on one.

**To unify on one model**, you would:
1. Register the model in `openclaw.json` under `agents.defaults.models`
2. Set it as `agents.defaults.model.primary`
3. Update all cron jobs in `jobs-config.json` to use the same model alias
4. Changes hot-apply without restart

---

## Implementation Plan (for Kimi K2.5 Unification)

### Step 1: Update cron jobs-config.json (5 minutes)
Change `"model": "fw-mm25"` to `"model": "fw-kk25"` in all 6 job entries.

### Step 2: Update interactive default model in openclaw.json (5 minutes)
Set `agents.defaults.model.primary` to `"fw-kk25"` (or whatever alias maps to Kimi K2.5).
Keep GPT-5.4 as a fallback: `"fallbacks": ["openai/gpt-5.4"]`

### Step 3: Apply and verify (5 minutes)
```bash
bash scripts/apply-cron.sh
# OpenClaw hot-reloads openclaw.json automatically
```

### Step 4: Monitor quality (1 week)
- Watch check-in message quality for the first few days
- Compare interactive response quality to GPT-5.4 baseline
- If message warmth/personalization noticeably degrades, consider:
  - Keeping GPT-5.4 for interactive only (reverting to dual-model)
  - Adding more specific prompt guidance to SOUL.md for message tone

### Rollback
If Kimi K2.5 interactive quality is insufficient:
- Change `agents.defaults.model.primary` back to GPT-5.4
- Keep `fw-kk25` for cron only (still an improvement over fw-mm25)
- This would be the "best of both worlds" fallback

---

## Final Recommendation Matrix

| Priority | Recommendation | Model | Monthly Cost |
|----------|---------------|-------|-------------|
| **Best overall (recommended)** | Unify on Kimi K2.5 | `fw-kk25` | ~$53 |
| **Cheapest viable** | Unify on MiniMax M2.5 (fix context config) | `fw-mm25` | ~$26 |
| **Highest quality** | Unify on GPT-5.4 | `openai/gpt-5.4` | ~$255 |
| **Best hybrid (if K2.5 interactive disappoints)** | GPT-5.4 interactive + K2.5 cron | mixed | ~$150 |

**Bottom line:** Kimi K2.5 via Fireworks is the sweet spot. It is the top open-weight instruct model for complex agentic instruction following, fast enough for interactive chat (349 t/s), and costs 79% less than GPT-5.4. It is already in your OpenClaw config. The switch can be done in 15 minutes.

---

## Sources

- [OpenAI API Pricing](https://openai.com/api/pricing/) -- GPT-5.4 at $2.50/$15.00 per 1M tokens
- [GPT-5.4 Pricing Details](https://pricepertoken.com/pricing-page/model/openai-gpt-5.4) -- Variants and batch pricing
- [GPT-5.4 Nano Pricing](https://pricepertoken.com/pricing-page/model/openai-gpt-5.4-nano) -- $0.20/$1.25 per 1M tokens
- [Fireworks AI Pricing](https://fireworks.ai/pricing) -- Current model pricing tiers
- [Fireworks AI Models](https://fireworks.ai/models) -- Full model catalog
- [Fireworks Recommended Models](https://docs.fireworks.ai/guides/recommended-models) -- Model selection guide
- [Fireworks Real-World Leaderboard](https://fireworks.ai/blog/real-world-leaderboard) -- Agentic benchmark results
- [Kimi K2.5 on Fireworks](https://fireworks.ai/models/fireworks/kimi-k2p5) -- Model details
- [MiniMax M2.5 on Fireworks](https://fireworks.ai/models/fireworks/minimax-m2p5) -- Model details
- [Artificial Analysis - Fireworks Provider](https://artificialanalysis.ai/providers/fireworks) -- Intelligence and speed rankings
- [Artificial Analysis - MiniMax M2.5 Providers](https://artificialanalysis.ai/models/minimax-m2-5/providers) -- Speed benchmarks
- [MiniMax M2.5 Announcement](https://www.minimax.io/news/minimax-m25) -- Model capabilities
- [Kimi K2.5 vs MiniMax M2.5 Comparison](https://artificialanalysis.ai/models/comparisons/minimax-m2-5-vs-kimi-k2-5) -- Head-to-head
- [OpenClaw Configuration Guide](https://coclaw.com/guides/openclaw-configuration/) -- Model config in openclaw.json
- [OpenClaw Models CLI](https://openclaw-ai.com/en/docs/concepts/models) -- Model management
