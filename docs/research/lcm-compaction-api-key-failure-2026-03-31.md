# LCM Compaction API Key Failure Analysis

**Date:** 2026-03-31
**Status:** Actionable - Fix Required
**Impact:** 10-30s wasted per compaction attempt, degraded context management

---

## Executive Summary

The `lossless-claw` plugin (LCM - Lossless Context Management) is configured to use `accounts/fireworks/models/qwen3-8b` for context summarization/compaction, but the model's provider is being resolved as `"accounts"` instead of `"fw-mm25"`. Since no API key exists for a provider called `"accounts"`, every compaction attempt fails twice (initial + retry), then falls back to simple truncation.

## Root Cause

**Provider resolution mismatch.** The lossless-claw plugin config specifies:

```json
"summaryModel": "accounts/fireworks/models/qwen3-8b",
"summaryProvider": "fw-mm25"
```

However, the LCM internals are resolving the provider from the model ID string (`accounts/fireworks/models/qwen3-8b`) rather than using the configured `summaryProvider` value. The model ID starts with `accounts/`, so OpenClaw's model auth system interprets `"accounts"` as the provider name. No API key is registered for a provider called `"accounts"` -- the Fireworks API key is registered under provider `"fw-mm25"`.

This is likely a bug in the lossless-claw plugin (v0.5.2) where it passes the raw model ID to the auth system without mapping it through the configured provider.

## Exact Error Messages

**Auth failure (repeated 108 times in log):**
```
[lcm] modelAuth.getApiKeyForModel FAILED: No API key found for provider "accounts".
Auth store: /Users/<hostname>/.openclaw/agents/main/agent/auth-profiles.json
(agentDir: /Users/<hostname>/.openclaw/agents/main/agent).
Configure auth for this agent (openclaw agents add <id>) or copy auth-profiles.json
from the main agentDir.
```

**First attempt failure:**
```
[lcm] empty normalized summary on first attempt; provider=accounts;
model=fireworks/models/qwen3-8b; [...] finish=error;
error_message=No API key for provider: accounts; retrying with conservative settings
```

**Retry failure:**
```
[lcm] retry also returned empty summary; provider=accounts;
model=fireworks/models/qwen3-8b; [...] finish=error;
error_message=No API key for provider: accounts; falling back to truncation
```

**Final exhaustion:**
```
[lcm] all extraction attempts exhausted; provider=accounts;
model=fireworks/models/qwen3-8b; source=fallback
```

## Frequency and Impact

- **108 auth failures** logged since 2026-03-27 (when lossless-claw v0.5.2 was installed)
- **54 fallback-to-truncation events** (each involves 2 auth failures: initial + retry)
- Pattern: every ~30 minutes during active agent sessions (aligns with cron heartbeats)
- Each failure cycle takes approximately **15-20 seconds** (auth lookup + retry + fallback)
- Context management degrades to simple truncation instead of intelligent summarization

## What is LCM / Lossless-Claw?

LCM (Lossless Context Management) is a context window compression plugin for OpenClaw. It:

1. **Monitors context window usage** against a threshold (configured at 75%)
2. **Summarizes older conversation turns** using a cheap/fast model (qwen3-8b) to compress them
3. **Preserves recent turns verbatim** (freshTailCount: 32 most recent messages)
4. **Falls back to truncation** when summarization fails (the current degraded state)

The plugin is `@martian-engineering/lossless-claw` v0.5.2, installed as an OpenClaw extension.

## Current Configuration

**In `openclaw.json` -> `plugins.entries.lossless-claw`:**
```json
{
  "enabled": true,
  "config": {
    "freshTailCount": 32,
    "contextThreshold": 0.75,
    "incrementalMaxDepth": -1,
    "summaryModel": "accounts/fireworks/models/qwen3-8b",
    "summaryProvider": "fw-mm25",
    "expansionModel": "accounts/fireworks/models/qwen3-8b",
    "expansionProvider": "fw-mm25"
  }
}
```

**The Fireworks provider config (working for other models):**
```json
"fw-mm25": {
  "baseUrl": "https://api.fireworks.ai/inference/v1",
  "apiKey": "fw_QXGscgRZhyeGd3K1SSaFjk",
  "api": "openai-completions",
  "models": [
    { "id": "accounts/fireworks/models/qwen3-8b", ... }
  ]
}
```

**Auth profiles (agents):** Only contain `openai-codex` OAuth credentials. No Fireworks API key in auth-profiles.json.

## Why Other Fireworks Models Work

The model fallback system (`fw-mm25/accounts/fireworks/models/glm-5`) works because it uses the prefixed format `fw-mm25/...` which correctly routes to the `fw-mm25` provider. The LCM plugin passes the bare model ID `accounts/fireworks/models/qwen3-8b` without the provider prefix.

## Proposed Fixes

### Fix 1: Change summaryModel to use provider-prefixed format (RECOMMENDED)

```bash
openclaw config set plugins.entries.lossless-claw.config.summaryModel \
  "fw-mm25/accounts/fireworks/models/qwen3-8b"

openclaw config set plugins.entries.lossless-claw.config.expansionModel \
  "fw-mm25/accounts/fireworks/models/qwen3-8b"

openclaw gateway restart
```

This mirrors the format used by the working model-fallback system.

### Fix 2: Use the model alias

If lossless-claw supports alias resolution:
```bash
openclaw config set plugins.entries.lossless-claw.config.summaryModel "fw-qwen3-8b"
openclaw config set plugins.entries.lossless-claw.config.expansionModel "fw-qwen3-8b"
openclaw gateway restart
```

(Note: the qwen3-8b model has `"name": "fw-qwen3-8b"` in the provider config, but no alias is defined in `agents.defaults.models`.)

### Fix 3: Report bug to lossless-claw maintainers

The plugin should respect the `summaryProvider` field when resolving API keys for the `summaryModel`, rather than parsing the provider from the model ID string.

## Secondary Finding: Persistent Rate Limiting

The logs also show a separate pattern: `openai-codex/gpt-5.4` hits rate limits every ~30 minutes and falls back to `fw-mm25/accounts/fireworks/models/glm-5`. This fallback works correctly but indicates OpenAI Codex rate limits are being hit consistently by the 17+ agent cron jobs.

## Verification After Fix

After applying Fix 1, verify with:
```bash
# Watch for LCM errors (should stop appearing)
tail -f ~/.openclaw/logs/gateway.err.log | grep -i lcm

# Trigger a compaction by running an agent session
openclaw cron run <any-job-id>

# Confirm successful summarization (should see no "FAILED" lines)
grep 'lcm.*summary' ~/.openclaw/logs/gateway.err.log | tail -5
```
