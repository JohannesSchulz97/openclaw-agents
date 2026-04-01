# OpenClaw Session Model Pinning Research

**Date:** 2026-04-01
**Researcher:** Claude Code (research agent)
**Topic:** Session store architecture, model persistence, and failover interaction
**Status:** ACTIONABLE -- contains specific remediation steps

---

## Executive Summary

OpenClaw persists model state per-session in JSON files at `~/.openclaw/agents/<name>/sessions/sessions.json`. There are **two layers** of model state:

1. **Override fields** (`providerOverride`, `modelOverride`) -- explicit user-requested model pinning via `/model` command or UI buttons. These are the "sticky" fields that `resolveLiveSessionModelSelection()` reads.
2. **Runtime fields** (`model`, `modelProvider`) -- informational, written by the runtime after each run. These record what model was *actually used* (including fallback).

The failover system writes the fallback model into the **runtime fields** (`model`, `modelProvider`), but the `resolveLiveSessionModelSelection()` function that decides which model to use on the next run reads from the **override fields** first, falling back to the agent's configured default. Since no override fields are currently set on any session, the "pinning" is NOT coming from the session store override mechanism.

**Key finding:** The `model`/`modelProvider` runtime fields in the session store are being read by `openclaw sessions --json` for display purposes and by the session listing UI, but the actual model selection path goes through `resolveLiveSessionModelSelection()` which checks `providerOverride`/`modelOverride` first, then falls back to the agent's configured default from `openclaw.json`.

---

## Architecture

### Session Store Location

Each agent has its own session store:
```
~/.openclaw/agents/<agent-name>/sessions/sessions.json
```

This is a flat JSON object keyed by session key (e.g., `agent:dev1:main`, `agent:dev1:slack:direct:u09l59gj3qt`).

### Session Entry Fields (Model-Related)

| Field | Type | Purpose | Set By |
|-------|------|---------|--------|
| `providerOverride` | string | User-requested provider pin | `/model` command, UI buttons |
| `modelOverride` | string | User-requested model pin | `/model` command, UI buttons |
| `model` | string | Last-used model (runtime) | Runtime after each run |
| `modelProvider` | string | Last-used provider (runtime) | Runtime after each run |
| `authProfileOverride` | string | Auth profile pin | Auto or user |
| `authProfileOverrideSource` | string | Source of auth override | System |
| `fallbackNoticeSelectedModel` | string | Originally selected model | Failover system |
| `fallbackNoticeActiveModel` | string | Model actually used after failover | Failover system |
| `fallbackNoticeReason` | string | Why failover occurred | Failover system |
| `contextTokens` | number | Context window size | Runtime |

### Model Resolution Chain

Source: `auth-profiles-B5ypC5S-.js`, function `resolveLiveSessionModelSelection()` (line ~161503):

```
1. Load session entry from sessions.json (fresh read, skipCache: true)
2. provider = entry.providerOverride || defaultModelRef.provider
3. model    = entry.modelOverride    || defaultModelRef.model
4. Return { provider, model, authProfileId }
```

Where `defaultModelRef` comes from `resolveDefaultModelForAgent()` which reads the agent's config in `openclaw.json` (`agents.list[agentId].model` or `agents.defaults.model`).

### Override Application

Source: `auth-profiles-B5ypC5S-.js`, function `applyModelOverrideToSessionEntry()` (line ~3077):

- When `selection.isDefault === true`: **deletes** `providerOverride` and `modelOverride` (resets to default)
- When `selection.isDefault === false`: **sets** `providerOverride` and `modelOverride` to the new model
- In both cases: if runtime fields (`model`, `modelProvider`) are misaligned, they are **deleted** (cleaned up)
- Also deletes `fallbackNoticeSelectedModel`, `fallbackNoticeActiveModel`, `fallbackNoticeReason` on any update

### Failover Behavior

Source: `auth-profiles-B5ypC5S-.js` (line ~169324-169441):

The runtime run loop calls `resolvePersistedLiveSelection()` **before each attempt** and **after failed attempts**. If the persisted selection differs from the current live selection, it throws `LiveSessionModelSwitchError` to restart with the new model.

This means: if something writes `providerOverride`/`modelOverride` into the session store while a session is running, the next attempt will detect the switch and restart with the new model.

### What the Failover System Writes

When failover occurs (e.g., rate limit on gpt-5.4, falling back to glm-5), the runtime writes:
- `model: "accounts/fireworks/models/glm-5"` (runtime field)
- `modelProvider: "fw-mm25"` (runtime field)
- `fallbackNoticeSelectedModel: "openai-codex/gpt-5.4"` (what was selected)
- `fallbackNoticeActiveModel: "fw-mm25/accounts/fireworks/models/glm-5"` (what was used)
- `fallbackNoticeReason: "rate limit"` (why)

It does **NOT** write `providerOverride` or `modelOverride`, so the failover model is NOT pinned for future sessions.

---

## Current State (2026-04-01)

### dev1 Sessions

| Session Key | model (runtime) | modelProvider (runtime) | providerOverride | modelOverride |
|-------------|----------------|------------------------|-----------------|--------------|
| main | glm-5 | fw-mm25 | (none) | (none) |
| slack:direct | glm-5 | fw-mm25 | (none) | (none) |
| cron (3 checkins) | gpt-5.4 | openai-codex | (none) | (none) |
| cron (2 others) | glm-5 | fw-mm25 | (none) | (none) |

**No `providerOverride` or `modelOverride` fields exist on ANY session across ALL 19 agents.**

This means the model resolution will always fall back to the configured default in `openclaw.json`.

---

## Diagnosis: Where the "Pinning" Actually Comes From

Since no override fields exist, the model being used is determined by:

1. The agent's configured default model in `openclaw.json` -> `agents.list[agentId].model` or `agents.defaults.model`
2. Cron job `--model` flag (for cron-triggered sessions)

If sessions are showing `fw-mm25/glm-5` instead of `openai-codex/gpt-5.4`, the cause is one of:
- **The configured default model in openclaw.json** is set to fw-mm25
- **The failover system** routed to glm-5 due to rate limits on gpt-5.4, and the runtime fields reflect the last-used model (but this does NOT pin future runs)
- **The cron job model flag** in `jobs-config.json` specifies a different model

The runtime `model`/`modelProvider` fields are written after each run for display/diagnostics. They do NOT influence the next run's model selection (that goes through `resolveLiveSessionModelSelection()` which reads override fields, not runtime fields).

---

## Remediation Options

### Option 1: Clear Runtime Model Fields (Cosmetic)

To clear stale runtime model state so the `openclaw sessions` display shows the correct configured model:

```bash
# For a specific agent
python3 -c "
import json
path = '/Users/<hostname>/.openclaw/agents/dev1/sessions/sessions.json'
with open(path) as f: data = json.load(f)
for key, entry in data.items():
    if isinstance(entry, dict):
        for field in ['model', 'modelProvider', 'fallbackNoticeSelectedModel', 'fallbackNoticeActiveModel', 'fallbackNoticeReason']:
            entry.pop(field, None)
with open(path, 'w') as f: json.dump(data, f, indent=2)
print('Cleared runtime model fields')
"
```

### Option 2: Delete Session Entries (Nuclear)

To fully reset sessions for an agent:
```bash
echo '{}' > ~/.openclaw/agents/dev1/sessions/sessions.json
```

### Option 3: Use `openclaw sessions cleanup`

```bash
openclaw sessions cleanup --agent dev1 --enforce
```
This runs built-in maintenance but focuses on stale/cap cleanup, not model field clearing.

### Option 4: Verify openclaw.json Default Model

Check what model is actually configured as default:
```bash
cat ~/.openclaw/openclaw.json | python3 -c "import sys,json; cfg=json.load(sys.stdin); print(json.dumps(cfg.get('agents',{}).get('defaults',{}).get('model','NOT SET'),indent=2)); print(); [print(f'{k}: {v.get(\"model\",\"NOT SET\")}') for k,v in cfg.get('agents',{}).get('list',{}).items()]"
```

---

## Key Source Files

| File | Location | Purpose |
|------|----------|---------|
| Session store | `~/.openclaw/agents/<name>/sessions/sessions.json` | Per-session state (JSON) |
| Model overrides | `dist/auth-profiles-B5ypC5S-.js:3077` | `applyModelOverrideToSessionEntry()` |
| Live selection | `dist/auth-profiles-B5ypC5S-.js:161503` | `resolveLiveSessionModelSelection()` |
| Reset model | `dist/session-reset-model.runtime-BB5o_hD1.js` | `/model` command handler |
| Model selection | `dist/model-selection-CMtvxDDg.js` | Model key/ref utilities |
| LCM database | `~/.openclaw/lcm.db` | Conversation history (SQLite + WAL) |
| Memory databases | `~/.openclaw/memory/<agent>.sqlite` | Per-agent memory (QMD) |

---

## Conclusion

The session model "pinning" is NOT caused by persisted override fields in the session store. The override mechanism (`providerOverride`/`modelOverride`) is clean across all agents. The runtime `model`/`modelProvider` fields are informational only and reflect the last-used model (which may have been a failover target). The actual model for the next run is determined by the agent's configured default in `openclaw.json`, not by these runtime fields.

**Next steps:**
1. Verify the configured default model in `openclaw.json` for the affected agents
2. If the configured default is correct (openai-codex/gpt-5.4), the failover to glm-5 is working as designed during rate limits
3. If you want to force a specific model on a session, use the `/model` command which writes `providerOverride`/`modelOverride`
