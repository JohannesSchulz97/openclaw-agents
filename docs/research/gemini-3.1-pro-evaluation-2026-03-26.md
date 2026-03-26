# Gemini 3.1 Pro Evaluation for OpenClaw Agents

**Date:** 2026-03-26
**Status:** Informational research
**Classification:** Actionable (model migration candidate)

---

## 1. Current Config (openclaw.json)

The Google provider is already configured and working:

```
Provider: google
Base URL: https://generativelanguage.googleapis.com/v1beta
API: google-generative-ai
Model ID: gemini-3.1-pro
Context Window (configured): 200,000 tokens
Max Output (configured): 8,192 tokens
Reasoning: false
Input types: text, image
Cost tracking: all zeros (not configured)
```

**Issues with current config:**
- Context window is set to 200K but Gemini 3.1 Pro actually supports **1M tokens**
- Max output is set to 8,192 but the model supports **65,536 tokens**
- `reasoning: false` -- the model actually supports 3 thinking levels (Low/Medium/High)
- Cost fields are all zero -- should reflect actual pricing for tracking

**Current agent defaults:** All 6 agents use `openai-codex/gpt-5.4` as primary. The `fw-mm25` provider has MiniMax M2P5 (16K context) and Kimi K2.5 (128K context, reasoning). Google/Gemini is configured but not assigned to any agent.

---

## 2. Gemini 3.1 Pro Specs

| Attribute | Value |
|---|---|
| Release | February 19, 2026 |
| Context window | 1,000,000 tokens |
| Max output | 65,536 tokens |
| Input types | Text, image, video |
| Thinking modes | Low, Medium, High |
| Output speed | ~116 tokens/sec |
| TTFT | ~31s (reasoning mode) |
| API | Google Generative AI (direct) |

---

## 3. Pricing

### Standard Tier (prompts <= 200K tokens)

| | Input/1M | Output/1M | Cache Read/1M | Cache Storage |
|---|---|---|---|---|
| **Gemini 3.1 Pro** | $2.00 | $12.00 | $0.20 | $4.50/hr/1M |

### Standard Tier (prompts > 200K tokens)

| | Input/1M | Output/1M |
|---|---|---|
| **Gemini 3.1 Pro** | $4.00 | $18.00 |

### Batch API (50% discount)

| | Input/1M | Output/1M |
|---|---|---|
| **Gemini 3.1 Pro** | $1.00 | $6.00 |

### Comparison Table

| Model | Input/1M | Output/1M | Notes |
|---|---|---|---|
| **Gemini 3.1 Pro** | $2.00 | $12.00 | Best price-to-performance |
| **GPT-5.4** | ~$3.75 | ~$22.50 | (estimated from search data) |
| **Kimi K2.5** | ~$0.31 | ~$1.85 | Open-source, via Fireworks |
| **Claude Opus 4.6** | $15.00 | $75.00 | Reference only |
| **Gemini 2.5 Flash** | $0.30 | $2.50 | Free tier available |

---

## 4. Quality Benchmarks

| Benchmark | Gemini 3.1 Pro | GPT-5.4 | Kimi K2.5 |
|---|---|---|---|
| AA Intelligence Index | **57** | **57** | 47 |
| GPQA Diamond | **94.3%** | 92.8% | -- |
| ARC-AGI-2 | **77.1%** | 73.3% | -- |
| SWE-Bench Verified | **80.6%** | ~80% | 76.8% |
| SWE-Bench Pro | 54.2% | **57.7%** | -- |
| LiveCodeBench Pro | **2887 Elo** | -- | -- |
| MCP Atlas (tool use) | 69.2% | -- | -- |
| Context window | 1M | 1.05M | 262K |

**Bottom line:** Gemini 3.1 Pro ties with GPT-5.4 on overall intelligence, wins on reasoning benchmarks, and costs roughly 47% less.

---

## 5. Cost Estimate: Your Workload

### Workload Profile
- 6 agents, 72 cron invocations/day (~20K in + 2K out each)
- 50 interactive conversations/day (~10K in + 2K out each)

### Daily Token Usage

| Category | Count | Input Tokens | Output Tokens |
|---|---|---|---|
| Cron jobs | 72 | 1,440,000 | 144,000 |
| Interactive | 50 | 500,000 | 100,000 |
| **Total/day** | 122 | **1,940,000** | **244,000** |

### Monthly Cost Comparison (30 days)

| Model | Monthly Input | Monthly Output | **Total/Month** |
|---|---|---|---|
| **Gemini 3.1 Pro** | $116.40 | $87.84 | **$204.24** |
| **GPT-5.4** (est.) | $218.25 | $164.70 | **$382.95** |
| **Kimi K2.5** (Fireworks) | $18.04 | $13.54 | **$31.58** |
| **Gemini 2.5 Flash** | $17.46 | $18.30 | **$35.76** |

Gemini 3.1 Pro would cost roughly **$204/month** -- about 47% cheaper than GPT-5.4 but 6.5x more than Kimi K2.5.

With **context caching** (cron jobs reuse system prompts), input costs could drop ~80-90% for cached content. Estimated savings: $80-100/month, bringing effective cost to ~$100-120/month.

---

## 6. Google AI Studio Free Tier

**Gemini 3.1 Pro is NOT on the free tier.** It is a preview model with paid-only access.

Free tier is available for stable models only:
- Gemini 2.5 Pro: 5 RPM, 100 requests/day
- Gemini 2.5 Flash: 10 RPM, 250 requests/day
- Gemini 2.5 Flash-Lite: 15 RPM, 1,000 requests/day

**Paid Tier 1** (billing account linked, no minimum spend):
- 150-300 RPM depending on model
- 250K TPM for Gemini 3.1 Pro
- Preview models have more restrictive/changing limits

**Verdict:** The free tier is irrelevant for Gemini 3.1 Pro. With 72 cron + 50 interactive = 122 requests/day, the Tier 1 paid limits (250 RPD) are sufficient but tight. Tier 2 ($250 cumulative spend, 30 days) would be needed for headroom.

---

## 7. Fireworks vs Google Direct

**Gemini is NOT available on Fireworks.** Fireworks only hosts open-source models (Llama, Mistral, MiniMax, Kimi, etc.). Gemini is proprietary and only available via:
- Google AI Studio / Gemini API (what you have configured)
- Vertex AI
- Firebase AI Logic

Your `openclaw.json` already uses the Google API directly, which is the correct and only way to access Gemini 3.1 Pro.

---

## 8. Agentic / Tool-Use Capabilities

- **MCP Atlas score:** 69.2% (multi-tool coordination)
- **Thinking levels:** Low/Medium/High -- can tune reasoning depth per task
- **Native tool use:** Supported via Google's function calling API
- **OpenAI-compatible?** The `google-generative-ai` API adapter in OpenClaw handles the translation

Key consideration: OpenClaw uses `api: "google-generative-ai"` which means it handles the Google-specific API format. Tool calling works but uses Google's schema (slightly different from OpenAI function calling).

---

## 9. Viability as Unified Model

### Pros
- Ties GPT-5.4 on intelligence at ~47% lower cost
- 1M context window (largest practical window)
- Thinking levels allow cost-quality tradeoff per task
- Batch API at 50% discount for async workloads
- Context caching could dramatically reduce cron costs
- Image + video input for multimodal tasks
- Already configured in your openclaw.json

### Cons
- Not on Fireworks -- cannot be used as `fw-mm25` provider replacement
- Preview model -- rate limits may change, no GA pricing locked in
- TTFT of ~31s is slow for interactive use (reasoning mode)
- No free tier for Gemini 3.1 Pro
- Tier 1 rate limits (250 RPD) are tight for 122 requests/day across 6 agents
- GA pricing expected to settle at $1.50/$10 in Q2 2026 -- may be worth waiting

### Verdict

**Gemini 3.1 Pro is a strong candidate as primary model**, especially once it hits GA with stable pricing and higher rate limits. At $204/month it is significantly cheaper than GPT-5.4 ($383/month) with equivalent quality.

**Recommended approach:**
1. Fix the config: Update contextWindow to 1000000 and maxTokens to 65536
2. Trial: Assign 1-2 agents to `google/gemini-3.1-pro` as primary model
3. Monitor: Track quality, latency, and rate limit hits
4. Wait for GA: Lock in stable pricing before full migration
5. Keep Kimi K2.5 as budget fallback ($32/month) for less critical tasks

---

## Sources

- [Artificial Analysis - Gemini 3.1 Pro Preview](https://artificialanalysis.ai/models/gemini-3-1-pro-preview)
- [OpenRouter - Gemini 3.1 Pro Pricing](https://openrouter.ai/google/gemini-3.1-pro-preview)
- [Google Gemini API Pricing](https://ai.google.dev/gemini-api/docs/pricing)
- [Google Rate Limits](https://ai.google.dev/gemini-api/docs/rate-limits)
- [Gemini 3.1 Pro vs GPT-5.4](https://www.buildfastwithai.com/blogs/gpt-5-4-vs-gemini-3-1-pro-2026)
- [Gemini 3.1 Pro vs Kimi K2.5](https://artificialanalysis.ai/models/comparisons/gemini-3-1-pro-preview-vs-kimi-k2-5)
- [AI Free API - Gemini Free Tier Guide](https://www.aifreeapi.com/en/posts/google-gemini-api-free-tier)
- [NxCode - Gemini 3.1 Pro Complete Guide](https://www.nxcode.io/en/resources/news/gemini-3-1-pro-complete-guide-benchmarks-pricing-api-2026)
