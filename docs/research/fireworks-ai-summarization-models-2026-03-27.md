# Fireworks AI Models for Lossless Claw Summarization

**Date:** 2026-03-27
**Research Type:** Technology Evaluation
**Status:** Actionable

## Executive Summary

Fireworks AI is already configured as a custom provider (`fw-mm25`) in the openclaw-agents OpenClaw setup. Several cheap, fast models on Fireworks are suitable for context summarization via Lossless Claw. The cheapest option is **gpt-oss-20b** at $0.07/1M input tokens. Lossless Claw supports non-Anthropic models through its `summaryModel`/`summaryProvider` configuration, inheriting whatever providers OpenClaw has configured.

## Recommended Models

### Tier 1: Best Value for Summarization

| Model | Model ID | Input $/1M | Output $/1M | Speed | Notes |
|-------|----------|-----------|-------------|-------|-------|
| **gpt-oss-20b** | `accounts/fireworks/models/gpt-oss-20b` | $0.07 | $0.30 | Fast | Cheapest option, 20B params, good enough for summaries |
| **Qwen3 8B** | `accounts/fireworks/models/qwen3-8b` | $0.20 | $0.20 | Very fast | Strong multilingual, great for summarization |
| **Qwen3 4B** | `accounts/fireworks/models/qwen3-4b` | ~$0.10 | ~$0.10 | Fastest | Smallest tracked model, cheapest per-token |

### Tier 2: Better Quality (Still Cheap)

| Model | Model ID | Input $/1M | Output $/1M | Speed | Notes |
|-------|----------|-----------|-------------|-------|-------|
| **gpt-oss-120b** | `accounts/fireworks/models/gpt-oss-120b` | $0.15 | $0.60 | 714 t/s (fastest) | High quality + fast, reasoning capable |
| **Qwen3 30B** | `accounts/fireworks/models/qwen3-30b` | ~$0.90 | ~$0.90 | 0.39s TTFT | Fireworks recommends for long context |
| **Llama 3.3 70B** | `accounts/fireworks/models/llama-v3p3-70b-instruct` | ~$0.90 | ~$0.90 | Good | Proven summarization quality |

### Tier 3: Ultra-Cheap (Tiny Models)

| Model | Model ID | Notes |
|-------|----------|-------|
| **Llama 3.2 3B** | `accounts/fireworks/models/llama-v3p2-3b-instruct` | Very cheap, may struggle with complex summaries |
| **Llama 3.2 1B** | `accounts/fireworks/models/llama-v3p2-1b-instruct` | Cheapest possible, quality tradeoff |

### Primary Recommendation

**gpt-oss-20b** (`accounts/fireworks/models/gpt-oss-20b`) at $0.07/1M input tokens.

Rationale:
- 3.5x cheaper than Qwen3 8B for input tokens (summarization is input-heavy)
- 20B parameters is sufficient for generating conversation summaries
- Fast inference on Fireworks' optimized stack
- Cached input tokens at 50% discount ($0.035/1M)

**Runner-up:** Qwen3 8B for better multilingual support and balanced input/output pricing.

## Fireworks AI Model ID Format

All serverless models use the format:
```
accounts/fireworks/models/<model-name>
```

Examples:
- `accounts/fireworks/models/gpt-oss-20b`
- `accounts/fireworks/models/qwen3-8b`
- `accounts/fireworks/models/llama-v3p2-3b-instruct`

When referenced through OpenClaw's custom provider (`fw-mm25`), the full reference becomes:
```
fw-mm25/accounts/fireworks/models/<model-name>
```

## Fireworks Provider Pricing Tiers (Base Models)

| Parameter Size | Input $/1M | Output $/1M |
|---------------|-----------|-------------|
| Less than 4B | $0.10 | $0.10 |
| 4B - 16B | $0.20 | $0.20 |
| More than 16B | $0.90 | $0.90 |

Note: Cached input tokens are 50% off. Batch inference is 50% off both input and output.

## Lossless Claw Compatibility

### Does Lossless Claw Support Fireworks?

**Yes.** Lossless Claw inherits OpenClaw's provider infrastructure. Since Fireworks is already configured as the `fw-mm25` custom provider using the `openai-completions` API format, Lossless Claw can use it.

### Configuration

Lossless Claw supports configuring a dedicated summarization model via:

**Environment Variables (highest priority):**
```bash
LCM_SUMMARY_MODEL=fw-mm25/accounts/fireworks/models/gpt-oss-20b
LCM_SUMMARY_PROVIDER=fw-mm25
```

**Plugin Config (in openclaw.json):**
```json
{
  "plugins": {
    "entries": {
      "lossless-claw": {
        "enabled": true,
        "summaryModel": "accounts/fireworks/models/gpt-oss-20b",
        "summaryProvider": "fw-mm25"
      }
    }
  }
}
```

If the model reference includes a provider prefix (e.g., `fw-mm25/accounts/fireworks/models/gpt-oss-20b`), the separate `summaryProvider` setting is bypassed.

### Installation

Lossless Claw is NOT currently installed. To install:
```bash
openclaw plugins install @martian-engineering/lossless-claw
```

Or from source:
```bash
git clone https://github.com/Martian-Engineering/lossless-claw.git
openclaw plugins install --link /path/to/lossless-claw
```

Requires Node.js 22+.

## Current OpenClaw Provider Configuration

Fireworks is already configured as custom provider `fw-mm25`:
- Base URL: `https://api.fireworks.ai/inference/v1`
- API format: `openai-completions` (OpenAI-compatible)
- API key: Configured (redacted)
- Currently registered models: minimax-m2p5, kimi-k2p5, glm-5

To add a summarization model, a new model entry needs to be added to the `fw-mm25` provider's models array in `openclaw.json`.

## Cost Comparison

For context: Claude Haiku (the typical "cheap summarizer") costs:
- Input: $0.80/1M tokens
- Output: $4.00/1M tokens

Using gpt-oss-20b on Fireworks instead:
- Input: $0.07/1M tokens (11x cheaper)
- Output: $0.30/1M tokens (13x cheaper)

For a heavy summarization workload (1M input tokens/day):
- Claude Haiku: ~$0.80/day
- Fireworks gpt-oss-20b: ~$0.07/day
- **Savings: ~91%**

## Action Items

1. **Install Lossless Claw plugin** if not already installed
2. **Add gpt-oss-20b to fw-mm25 provider models** in openclaw.json
3. **Configure LCM_SUMMARY_MODEL** environment variable or plugin config
4. **Test summarization quality** with gpt-oss-20b on real conversations
5. **Fallback plan:** If quality is insufficient, move to Qwen3 8B or gpt-oss-120b

## Sources

- [Fireworks AI Pricing](https://fireworks.ai/pricing)
- [Fireworks AI Models](https://fireworks.ai/models)
- [Fireworks Recommended Models Guide](https://docs.fireworks.ai/guides/recommended-models)
- [Fireworks Text Models API Docs](https://docs.fireworks.ai/guides/querying-text-models)
- [Lossless Claw GitHub](https://github.com/Martian-Engineering/lossless-claw)
- [Lossless Claw README](https://github.com/Martian-Engineering/lossless-claw/blob/main/README.md)
- [OpenClaw Compaction Docs](https://docs.openclaw.ai/concepts/compaction)
- [LiteLLM Fireworks Provider](https://docs.litellm.ai/docs/providers/fireworks_ai)
- [Artificial Analysis - Fireworks](https://artificialanalysis.ai/providers/fireworks)
