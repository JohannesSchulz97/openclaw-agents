# dev1 Session Reset Procedure: Stale model_change Events

**Date:** 2026-04-01
**Status:** READ-ONLY research -- no files modified
**Related:** Task #6, OpenClaw issue #58751 (failover bug), openclaw-agents #84

---

## Executive Summary

There are **5 stale cron sessions** (not 3) in dev1's sessions.json with `openai-codex/gpt-5.4` model references. The originally reported sessions `c462ff30` and `cc0a7f88` are **not** the problem:

- `c462ff30` is an orphan JSONL file (not referenced in sessions.json; main session now uses `isolated.jsonl`)
- `cc0a7f88` belongs to **dev10-jean**, not dev1

The actual stale sessions are all **old cron job sessions** that last ran before the model switch to `fw-mm25/glm-5`.

## Session Inventory

### Current State (sessions.json)

| Session Key | Session ID | Model | Status |
|---|---|---|---|
| agent:dev1:main | isolated | fw-mm25/glm-5 | OK |
| agent:dev1:slack:direct:u09l59gj3qt | c9fdfb95 | fw-mm25/glm-5 | OK |
| agent:dev1:cron:e1e1bf73 (Morning) | d5a2d886 | fw-mm25/glm-5 | OK |
| agent:dev1:cron:6ead3e77 (Midday) | a64120d4 | fw-mm25/glm-5 | OK |
| **agent:dev1:cron:1e14ae94** | 17798b33 | **openai-codex/gpt-5.4** | **STALE** |
| **agent:dev1:cron:2d459e93** (Morning) | 8e688761 | **openai-codex/gpt-5.4** | **STALE** |
| **agent:dev1:cron:93c69c8f** (Evening) | 1e3bba06 | **openai-codex/gpt-5.4** | **STALE** |
| **agent:dev1:cron:64ec643d** | 49ebf808 | **openai-codex/gpt-5.4** | **STALE** |
| **agent:dev1:cron:1edf1c49** (Evening) | 927a8e0f | **openai-codex/gpt-5.4** | **STALE** |

### Key Finding: sessions.json Is Authoritative

The `model`/`modelProvider` fields in `sessions.json` are what OpenClaw's `resolvePersistedLiveSelection` reads. The `model_change` event on line 2 of each JSONL file is a **historical creation record**, not the live model reference. Evidence:

- Session `a64120d4` (OK): JSONL line 2 has `openai-codex/gpt-5.4`, but sessions.json has `fw-mm25/glm-5`. No later model_change was appended to the JSONL.
- This proves sessions.json model fields are updated independently from JSONL events when the gateway resolves the model for a session.

### Orphan Files

- `c462ff30-4eb3-444f-b31d-3481288e4922.jsonl` -- orphan; not in sessions.json. The `main` session's `sessionFile` points to it but `sessionId` is `isolated`. This file can be safely archived/deleted.

## Why Stale Sessions Cause LiveSessionModelSwitchError

Per the failover bug analysis (openclaw/openclaw#58751):

1. Cron triggers a stale session (e.g., `agent:dev1:cron:1e14ae94`)
2. sessions.json says `model: gpt-5.4, modelProvider: openai-codex`
3. `resolvePersistedLiveSelection` reads the **persisted model** = `openai-codex/gpt-5.4`
4. Config says `agents.defaults.model.primary` = `fw-mm25/glm-5`
5. Mismatch detected between persisted selection and config primary
6. OpenClaw throws `LiveSessionModelSwitchError`

The 5 stale cron sessions never ran after the model switch, so their sessions.json model fields were never updated.

## OpenClaw CLI Session Reset Options

### Available Commands

1. **`openclaw reset --scope config+creds+sessions`** -- TOO DESTRUCTIVE. Wipes all sessions for all agents.

2. **`openclaw acp --reset-session --session <key>`** -- Resets a specific session by key. This is the most targeted CLI option.

3. **No dedicated `openclaw session reset` or `openclaw session delete` command exists** in version 2026.3.28.

### Manual File Operations

OpenClaw already uses file-based session management patterns:

- `.deleted.<timestamp>` suffix: Marks sessions as deleted (JSONL files renamed)
- `.reset.<timestamp>` suffix: Marks sessions as reset (existing example: `baeec8b3...jsonl.reset.2026-03-26T05-25-52.920Z`)

## Recommended Reset Procedure

### Option A: Let Stale Cron Sessions Self-Heal (Safest, Passive)

The 5 stale cron sessions map to **old cron job IDs** that are likely no longer scheduled. The current cron config has different job IDs that already created fresh sessions (the OK ones). Check if these old cron job IDs still exist:

```bash
# Check current cron jobs
openclaw cron list
```

If the stale cron job IDs (`1e14ae94`, `2d459e93`, `93c69c8f`, `64ec643d`, `1edf1c49`) are NOT in the current cron config, these sessions are dead and harmless -- they will never be triggered.

### Option B: Update sessions.json Model Fields (Targeted)

Edit `sessions.json` to update the 5 stale entries' `model` and `modelProvider` fields:

```bash
# 1. Stop the gateway
openclaw gateway restart  # or kill existing

# 2. Back up sessions.json
cp ~/.openclaw/agents/dev1/sessions/sessions.json \
   ~/.openclaw/agents/dev1/sessions/sessions.json.bak.$(date +%s)

# 3. Update stale model references (use jq or python)
cd ~/.openclaw/agents/dev1/sessions
python3 -c "
import json
with open('sessions.json') as f:
    data = json.load(f)

for key, session in data.items():
    if session.get('modelProvider') == 'openai-codex':
        session['modelProvider'] = 'fw-mm25'
        session['model'] = 'accounts/fireworks/models/glm-5'
        print(f'Updated: {key}')

with open('sessions.json', 'w') as f:
    json.dump(data, f, indent=2)
"

# 4. Restart the gateway
openclaw gateway restart
```

### Option C: Delete Stale Session Files + Remove from sessions.json (Cleanest)

Rename the stale JSONL files and remove their entries from sessions.json:

```bash
# 1. Stop the gateway

# 2. Back up sessions.json
cp ~/.openclaw/agents/dev1/sessions/sessions.json \
   ~/.openclaw/agents/dev1/sessions/sessions.json.bak.$(date +%s)

# 3. Rename stale JSONL files (following OpenClaw's .deleted convention)
cd ~/.openclaw/agents/dev1/sessions
TS=$(date -u +%Y-%m-%dT%H-%M-%S.000Z)
mv 17798b33-dd15-433e-b32c-fc5164386931.jsonl \
   17798b33-dd15-433e-b32c-fc5164386931.jsonl.deleted.${TS}
mv 8e688761-6bd9-4683-9204-f40f5d1190dd.jsonl \
   8e688761-6bd9-4683-9204-f40f5d1190dd.jsonl.deleted.${TS}
mv 1e3bba06-f7e2-423d-b634-1d275b3bee32.jsonl \
   1e3bba06-f7e2-423d-b634-1d275b3bee32.jsonl.deleted.${TS}
mv 49ebf808-616d-478a-85b8-e8373335d43c.jsonl \
   49ebf808-616d-478a-85b8-e8373335d43c.jsonl.deleted.${TS}
mv 927a8e0f-39bb-4ef7-bcce-6406aca6a3d2.jsonl \
   927a8e0f-39bb-4ef7-bcce-6406aca6a3d2.jsonl.deleted.${TS}

# 4. Also archive the orphan c462ff30 file
mv c462ff30-4eb3-444f-b31d-3481288e4922.jsonl \
   c462ff30-4eb3-444f-b31d-3481288e4922.jsonl.deleted.${TS}

# 5. Remove stale entries from sessions.json
python3 -c "
import json
with open('sessions.json') as f:
    data = json.load(f)

stale_keys = [k for k, v in data.items() if v.get('modelProvider') == 'openai-codex']
for key in stale_keys:
    del data[key]
    print(f'Removed: {key}')

with open('sessions.json', 'w') as f:
    json.dump(data, f, indent=2)
"

# 6. Restart gateway
openclaw gateway restart
```

### Option D: Use ACP Reset (Per-Session)

```bash
# Reset each stale session via ACP
openclaw acp --reset-session --session "agent:dev1:cron:1e14ae94-94b2-4ab3-81d0-d36814d90eaf"
openclaw acp --reset-session --session "agent:dev1:cron:2d459e93-75a7-42eb-ab7c-f63d7737208c"
openclaw acp --reset-session --session "agent:dev1:cron:93c69c8f-c431-45a3-9401-6696471e1e72"
openclaw acp --reset-session --session "agent:dev1:cron:64ec643d-7518-4290-b9a2-f280d617c718"
openclaw acp --reset-session --session "agent:dev1:cron:1edf1c49-8292-4ce4-b14f-200154a09a34"
```

**Caveat:** ACP `--reset-session` behavior is not fully documented. It may reset the session but the gateway needs to be running for ACP to work.

## Recommendation

**First: Run Option A** -- check if the stale cron job IDs are still active. If they are not in the current cron config, no action is needed; the sessions are dead references.

**If action is needed: Use Option B** (update sessions.json model fields). This is the least disruptive approach -- it preserves session history while fixing the model reference. No JSONL editing is needed because the JSONL model_change is not authoritative.

**Do NOT** edit JSONL line 2 (the `model_change` event). It is a historical record, not the live model reference. Editing it accomplishes nothing and risks corrupting the session log.

## JSONL vs sessions.json: Model Authority

| Source | Purpose | Model Authority |
|---|---|---|
| JSONL line 2 (`model_change`) | Historical record of model at session creation | NOT authoritative |
| sessions.json `model`/`modelProvider` | Live session state, used by gateway for routing | A<slack-id>E |
| `agents.defaults.model.primary` in openclaw.json | Global default for new sessions | Reference only |

The gateway's `resolvePersistedLiveSelection` reads `sessions.json` model fields and compares against the config primary. The JSONL model_change is only used to initialize a new session's model context -- it is never re-read for routing decisions.

## Files Examined

- `/Users/<hostname>/.openclaw/agents/dev1/sessions/sessions.json` (session state DB)
- `/Users/<hostname>/.openclaw/agents/dev1/sessions/c462ff30-*.jsonl` (orphan main session)
- `/Users/<hostname>/.openclaw/agents/dev1/sessions/c9fdfb95-*.jsonl` (slack DM session -- OK)
- `/Users/<hostname>/.openclaw/agents/dev1/sessions/isolated.jsonl` (current main -- OK)
- `/Users/<hostname>/.openclaw/agents/dev1/sessions/*.jsonl` (all session files)
- `/Users/<hostname>/.openclaw/agents/dev10-jean/sessions/cc0a7f88-*.jsonl` (NOT dev1)
