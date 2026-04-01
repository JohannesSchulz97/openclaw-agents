# OpenClaw Failover: LiveSessionModelSwitchError Investigation

**Date:** 2026-04-01
**Status:** Root cause identified -- configuration issue on our side
**OpenClaw Version:** 2026.3.28 (f9b1079)

## Root Cause

The failover system is working correctly. The problem is that **cron jobs explicitly hardcode `openai-codex/gpt-5.4` as the model**, which overrides the fallback model that OpenClaw selected after a failover.

### The Conflict Loop

1. Primary model `openai-codex/gpt-5.4` fails (rate limit, timeout, etc.)
2. OpenClaw failover correctly switches session to fallback `fw-mm25/accounts/fireworks/models/glm-5`
3. Session store records the switch: `modelProvider: fw-mm25`, `model: accounts/fireworks/models/glm-5`
4. Next cron job fires with `payload.model: "openai-codex/gpt-5.4"` (hardcoded)
5. OpenClaw detects a "live session model switch" -- the session is on glm-5 but the new run requests gpt-5.4
6. Throws `LiveSessionModelSwitchError` to reconcile
7. This forces the session back to gpt-5.4, which may fail again, restarting the loop

### Evidence from Session Store

```
Session: agent:dev1:main
  model: accounts/fireworks/models/glm-5    <-- failover succeeded
  modelProvider: fw-mm25

Session: agent:dev1:cron:*
  model: gpt-5.4                            <-- cron forcing primary back
  modelProvider: openai-codex
```

The error message exactly matches this flow:
```
live session model switch detected before attempt for isolated:
  fw-mm25/accounts/fireworks/models/glm-5 -> openai-codex/gpt-5.4
```

## How LiveSessionModelSwitchError Works

Source: `src/agents/live-model-switch.ts` and `src/agents/pi-embedded-runner/`

At the start of each run loop iteration, OpenClaw:
1. Calls `resolvePersistedLiveSelection()` to read the session store's current model
2. Compares it to `resolveCurrentLiveSelection()` (the model this run is using)
3. If they differ, throws `LiveSessionModelSwitchError` to abort the current run and restart with the session's model

This is a safety mechanism to prevent model drift when a user or system changes the model mid-session. It is NOT a bug -- it is working as designed.

## Configuration Issues Found

### Issue 1: Cron jobs hardcode the primary model (ROOT CAUSE)

All cron jobs in `jobs-config.json` specify:
```json
"payload": {
  "model": "openai-codex/gpt-5.4"
}
```

**Fix:** Remove the `model` field from cron job payloads. When omitted, OpenClaw uses `agents.defaults.model.primary` which is already `openai-codex/gpt-5.4`. The difference is that without an explicit override, OpenClaw respects the failover state and will use the fallback model when the primary is in cooldown.

### Issue 2: dev1 cron jobs use `session:main` (not `isolated`)

```
dev1/dev1 Evening Check-in: session=session:main
```

Other agents correctly use `session=isolated`:
```
dev10/dev10 Morning Check-in: session=isolated
```

Using `session:main` means cron jobs share session state with interactive conversations, which causes model conflicts when failover changes the interactive session's model.

**Fix:** Change `sessionTarget` from `"session:main"` to `"isolated"` for dev1 cron jobs. Then add `sessionKey` fields (like other agents have).

### Issue 3: Duplicate dev1 cron jobs in runtime

Three identical "dev1 Evening Check-in" jobs exist in `jobs.json` with different UUIDs. The morning and midday check-ins are missing entirely from runtime. This suggests `apply-cron.sh` was run multiple times without cleaning up, or the jobs-config was modified after initial apply.

**Fix:** Clear and re-apply cron jobs:
```bash
# Remove all dev1 jobs
openclaw cron list --agent dev1 --json | jq -r '.[].id' | while read id; do
  openclaw cron remove "$id"
done

# Re-apply from config
bash /Users/<hostname>/openclaw-agents/scripts/apply-cron.sh
```

### Issue 4: `thinking: "on"` in cron config

The cron payloads use `"thinking": "on"` but OpenClaw CLI only accepts: `off | minimal | low | medium | high | xhigh`. The value `"on"` may be silently ignored or cause unexpected behavior.

**Fix:** Change to a valid level, e.g., `"thinking": "low"` (matches `agents.defaults.thinkingDefault`).

## Failover Configuration (Verified Working)

The failover chain is correctly configured:

```
Primary:   openai-codex/gpt-5.4
Fallback:  fw-glm5 -> fw-mm25/accounts/fireworks/models/glm-5
```

- Alias resolution: `fw-glm5` correctly resolves to `fw-mm25/accounts/fireworks/models/glm-5`
- Auth: fw-mm25 provider has API key configured via models.json
- Allowlist: glm-5 is in the allowed models list
- Fallback policy: `resolveFallbackCandidates()` correctly builds candidate list from defaults

## Recommended Fix (Minimal)

### Step 1: Remove model override from cron payloads

In `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json`, for ALL jobs, remove the `"model"` field from `payload`:

```diff
  "payload": {
    "kind": "agentTurn",
    "message": "...",
    "timeoutSeconds": 180,
-   "thinking": "on",
-   "model": "openai-codex/gpt-5.4"
+   "thinking": "low"
  }
```

This lets OpenClaw use the configured default (same model) but respects failover state.

### Step 2: Fix dev1 session targeting

Change dev1 jobs from `"sessionTarget": "session:main"` to `"sessionTarget": "isolated"` and add `sessionKey` fields matching the convention used by other agents:

```diff
- "sessionTarget": "session:main",
+ "sessionTarget": "isolated",
+ "sessionKey": "agent:dev1:cron:morning",
```

### Step 3: Re-apply cron config

```bash
bash /Users/<hostname>/openclaw-agents/scripts/apply-cron.sh
```

### Step 4: Clear stale session model overrides

After fixing the cron config, the session store entries with stale model overrides should resolve naturally on the next run. If not, a gateway restart will clear them:

```bash
openclaw gateway restart
```

## Additional Notes

- No `resolve` subcommand exists for `openclaw models` (alias resolution is internal)
- No `--model` flag on `openclaw agent` command (model selection is config-driven)
- The `lossless-claw` plugin is loaded (non-bundled) -- verify it does not interfere with model selection
- `anthropic` provider is listed as "missing" in auth -- not an issue since it is not in the active model list
