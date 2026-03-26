# OpenAI Rate Limits & OpenClaw Fallback Analysis

**Date:** 2026-03-26
**Type:** Informational Research
**Status:** Complete

---

## 1. OpenAI GPT-5.4 / Codex Rate Limits (March 2026)

### Rate Limit Dimensions

OpenAI enforces four independent limits -- hitting any one triggers a 429 error:
- **RPM** (Requests Per Minute)
- **TPM** (Tokens Per Minute) -- input + output tokens combined
- **RPD** (Requests Per Day)
- **TPD** (Tokens Per Day)

Limits are **per organization** (all API keys share the same pool) and **per model** (GPT-5.4 has its own pool separate from GPT-4.1, o3, etc.).

### GPT-5.4 Estimated Rate Limits by Tier

Exact numbers should be verified at platform.openai.com > Settings > Limits. Based on the GPT-5 series patterns (recently doubled):

| Tier | Approx TPM | Approx RPM | Notes |
|------|-----------|-----------|-------|
| Tier 1 | ~500K | ~1,000 | Auto-assigned at low spend |
| Tier 2 | ~1M | ~2,000 | |
| Tier 3 | ~2M | ~4,000 | |
| Tier 4 | ~4M | ~8,000 | |
| Tier 5 | ~10M+ | ~10,000+ | Requires manual review |

**Important caveats:**
- GPT-5.4 has a 1.05M context window. Prompts over 272K input tokens are priced at 2x input / 1.5x output.
- The `max_tokens` parameter counts toward TPM even if the model produces fewer tokens.
- Codex-specific endpoints (gpt-5.2-codex) have been reported with much lower limits (10K TPM), suggesting Codex may have separate, tighter limits.

### Tier Advancement

Tiers advance automatically based on payment history. No ticket required until Tier 5.

---

## 2. OpenClaw Fallback Mechanism

### Current Configuration (from ~/.openclaw/openclaw.json)

**Primary model for all agents:** `openai-codex/gpt-5.4`

**Registered providers:**
- `openai-codex` -- GPT-5.4 (OAuth auth)
- `fw-mm25` -- Fireworks AI (API key auth)
  - `accounts/fireworks/models/minimax-m2p5` (alias: fw-mm25, 16K context)
  - `fireworks/kimi-k2p5` (alias: fw-kk25, 128K context, reasoning)
- `google` -- Gemini 3.1 Pro (API key auth, 200K context)

**Current gap:** There is NO `fallbacks` array configured in `agents.defaults.model`. Only `primary` is set. This means fallback is effectively disabled.

### How OpenClaw Fallbacks Are Supposed to Work

1. **Auth profile rotation first** -- OpenClaw round-robins OAuth profiles before API keys within the same provider.
2. **Model fallback second** -- If all profiles for the primary provider fail, OpenClaw moves to the next model in `agents.defaults.model.fallbacks`.
3. **Triggers:** Auth failures, rate limits (429), and timeouts that exhaust profile rotation.

### Known Bugs (as of March 2026)

- **429 does not always trigger fallback** (GitHub issues #19249, #28925) -- OpenClaw may retry the primary model repeatedly instead of switching.
- **Overloaded errors bypass fallback** (issue #24378) -- `isFailoverAssistantError` is never triggered for overloaded errors.
- **Provider-wide cooldown** -- When one model from a provider hits a limit, OpenClaw marks the entire provider as in cooldown (so all models from that provider are blocked).
- **Exponential backoff broken** (issue #5159) -- Documented intervals (1m, 5m, 25m, 60m) do not match actual behavior (1-27 second retries).

### Cron Jobs Use fw-mm25, Not GPT-5.4

All 6 cron jobs explicitly set `"model": "fw-mm25"` (MiniMax M2P5 on Fireworks). This means cron invocations do NOT hit OpenAI at all. Only interactive conversations use GPT-5.4.

---

## 3. Practical Impact Assessment

### Traffic Breakdown

| Source | Model | Daily Volume | Per-Minute Peak |
|--------|-------|-------------|----------------|
| Cron check-ins | fw-mm25 (Fireworks) | 6 agents x 12/day = 72 | ~1 every 10 min |
| Interactive conversations | openai-codex/gpt-5.4 | ~50 estimated | Bursty, up to 6 concurrent |

**Key finding:** Cron traffic is entirely on Fireworks (fw-mm25), not OpenAI. Only interactive traffic hits GPT-5.4.

### Will You Hit OpenAI Rate Limits?

**RPM analysis:** 50 interactive conversations/day spread over ~10 working hours = ~5 requests/min average. Each conversation may involve multiple API calls (subagents configured at maxConcurrent=8). Peak burst could reach 20-40 RPM. At Tier 1 (1,000 RPM), this is well within limits.

**TPM analysis:** GPT-5.4 has a 1.05M context window. If agents accumulate long conversation histories, a single request could consume 50K-200K tokens. With 6 agents potentially active simultaneously, burst TPM could reach 300K-1.2M tokens/minute. At Tier 1 (500K TPM), you could hit limits during peak concurrent usage with long contexts.

**RPD analysis:** 50 interactive conversations with ~5-10 API calls each = 250-500 requests/day. Well within any tier's RPD limits.

### Risk Assessment

| Risk | Likelihood | Impact |
|------|-----------|--------|
| RPM limit hit | Low | Low (well within Tier 1) |
| TPM limit hit | Medium | High (long-context sessions with 6 concurrent agents) |
| RPD limit hit | Very Low | Low |
| Fallback not working on 429 | High | High (known bugs, no fallback configured) |

**The biggest risk is not the rate limits themselves but that fallback is not configured, so any 429 will cause retries against the same provider until timeout.**

---

## 4. GLM-5 on Fireworks

### Availability

GLM-5 is available on Fireworks AI as of February 2026:
- Model ID: `fireworks/glm-5`
- Context: 202.8K tokens
- Pricing: $1.00 / $0.20 / $3.20 per 1M tokens (input/cached/output)
- Speed: 203.9 tokens/sec (fastest provider for GLM-5)
- License: MIT (open source)
- Supports: function calling, reasoning

### Current Status in openclaw.json

GLM-5 is **NOT registered** in the configuration. Only MiniMax M2P5 and Kimi K2P5 are registered under the `fw-mm25` provider.

### Recommended Fallback Configuration

Add to `agents.defaults.model` in `~/.openclaw/openclaw.json`:

```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "openai-codex/gpt-5.4",
        "fallbacks": [
          "google/gemini-3.1-pro",
          "fw-mm25/fireworks/glm-5"
        ]
      }
    }
  }
}
```

And register GLM-5 in the `fw-mm25` provider's models array:

```json
{
  "id": "fireworks/glm-5",
  "name": "GLM-5 (Fireworks)",
  "reasoning": true,
  "input": ["text"],
  "cost": {
    "input": 1.0,
    "output": 3.2,
    "cacheRead": 0.2,
    "cacheWrite": 0
  },
  "contextWindow": 202800,
  "maxTokens": 16384
}
```

**Why this order:**
1. GPT-5.4 (primary) -- best quality, OAuth auth
2. Gemini 3.1 Pro (fallback 1) -- different provider (avoids provider-wide cooldown bug), 200K context, already registered
3. GLM-5 on Fireworks (fallback 2) -- different provider group effectively (though same Fireworks API key as fw-mm25, so may share cooldown with Kimi/MiniMax)

**Caveat on provider-wide cooldown:** Since GLM-5 would be under the same `fw-mm25` provider as MiniMax and Kimi, a rate limit on any Fireworks model could block GLM-5 too. Consider registering GLM-5 under a separate provider entry (e.g., `fw-glm5`) with its own API key to avoid this.

---

## Summary of Recommendations

1. **Add `fallbacks` array** to `agents.defaults.model` -- currently missing entirely.
2. **Register GLM-5** in openclaw.json under Fireworks (or as a separate provider to avoid cooldown coupling).
3. **Put Gemini 3.1 Pro as first fallback** since it is a different provider entirely (no cooldown coupling with OpenAI).
4. **Monitor TPM usage** -- with 6 concurrent agents on long contexts, Tier 1 TPM (500K) could be tight. Consider requesting Tier 2+ if you see 429s.
5. **Be aware of known fallback bugs** -- 429 errors may not trigger fallback reliably (issues #19249, #28925). Test fallback behavior before relying on it in production.

---

## Sources

- [OpenAI Rate Limits Documentation](https://developers.openai.com/api/docs/guides/rate-limits)
- [OpenAI API Rate Limits 2026 Update (scriptbyai.com)](https://www.scriptbyai.com/rate-limits-openai-api/)
- [OpenAI Rate Limits Complete Guide (inference.net)](https://inference.net/content/openai-rate-limits-guide/)
- [OpenClaw Model Failover Documentation](https://docs.openclaw.ai/concepts/model-failover)
- [OpenClaw Rate Limit Handling Guide](https://www.getopenclaw.ai/en/help/rate-limits-quota-management)
- [Bug: 429 does not trigger fallback (issue #28925)](https://github.com/openclaw/openclaw/issues/28925)
- [Bug: Overloaded error bypasses fallback (issue #24378)](https://github.com/openclaw/openclaw/issues/24378)
- [GLM-5 on Fireworks AI](https://fireworks.ai/models/fireworks/glm-5)
- [GPT-5.4 Model Documentation](https://developers.openai.com/api/docs/models/gpt-5.4)
