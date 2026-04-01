# OpenClaw Failover Bug Analysis

**Date:** 2026-04-01
**Analyst:** dev1 (research agent)
**Version Analyzed:** OpenClaw 2026.3.28 (f9b1079)
**Verdict:** OpenClaw platform bug (HIGH confidence)

---

## Executive Summary

The failover infinite loop is caused by a design conflict in OpenClaw where the
**live-session model switch detection** reads the agent's **configured default
model** from `openclaw.json`, not the runtime fallback model chosen by
`runWithModelFallback`. When the fallback model (glm-5) differs from the
configured default (gpt-5.4), the pre-attempt check in
`resolvePersistedLiveSelection()` detects a "mismatch" and throws
`LiveSessionModelSwitchError` to switch back to the configured default --
which is rate-limited -- creating an infinite loop.

**This is NOT a configuration mistake. It is an OpenClaw platform bug.**

---

## Root Cause: Code-Level Evidence

### The Two Systems That Conflict

**System 1: Model Fallback** (`runWithModelFallback`)
- Located in `auth-profiles-B5ypC5S-.js:65267`
- When primary model (gpt-5.4) fails with rate-limit/auth/timeout, tries next
  candidate from `agents.defaults.model.fallbacks`
- Calls the embedded run with `(provider="glm-provider", model="glm-5")`
- The fallback choice is passed as function arguments -- it is NOT persisted
  anywhere the session layer can read

**System 2: Live Session Model Switch** (`resolveLiveSessionModelSelection`)
- Located in `auth-profiles-B5ypC5S-.js:161503`
- Designed for `/model` command during active sessions
- Reads the "intended" model from session store OR agent config defaults
- Throws `LiveSessionModelSwitchError` if current runtime model differs from
  the persisted/configured model

### The Conflict Path (Step by Step)

1. Agent configured with `primary: openai-codex/gpt-5.4`, `fallbacks: [glm-5]`

2. User sends message. `runWithModelFallback` tries gpt-5.4 first.

3. gpt-5.4 is rate-limited. `FailoverError` thrown from embedded run (line 169763).

4. `runWithModelFallback` catches it, moves to next candidate: glm-5.

5. `runWithModelFallback` calls its `run` callback with `(provider="fw-mm25", model="glm-5")`.

6. Inside `runEmbeddedPiAgent`, closure variables are set:
   ```js
   // Line 169162-169174
   const resolveCurrentLiveSelection = () => ({
       provider,      // "fw-mm25" (the fallback)
       model: modelId // "glm-5"  (the fallback)
   });

   const resolvePersistedLiveSelection = () => resolveLiveSessionModelSelection({
       cfg: params.config,
       sessionKey: params.sessionKey,
       agentId: workspaceResolution.agentId,
       defaultProvider: provider,  // "fw-mm25" (ignored when agentId exists!)
       defaultModel: modelId       // "glm-5"  (ignored when agentId exists!)
   });
   ```

7. **THE BUG**: `resolveLiveSessionModelSelection` (line 161508) does:
   ```js
   const defaultModelRef = agentId
       ? resolveDefaultModelForAgent({ cfg, agentId })  // <-- reads CONFIG, returns gpt-5.4
       : { provider: params.defaultProvider, model: params.defaultModel };
   ```
   When `agentId` is present (which it always is for our agents), it calls
   `resolveDefaultModelForAgent` which reads `agents.defaults.model.primary`
   from `openclaw.json` -- returning `openai-codex/gpt-5.4`.

8. At line 169324-169327, before each attempt:
   ```js
   const nextSelection = resolvePersistedLiveSelection();
   // nextSelection = { provider: "openai-codex", model: "gpt-5.4" } (from config!)

   if (hasDifferentLiveSessionModelSelection(resolveCurrentLiveSelection(), nextSelection)) {
       // current = { provider: "fw-mm25", model: "glm-5" }  (the fallback)
       // next    = { provider: "openai-codex", model: "gpt-5.4" } (from config)
       // THEY DIFFER! -> throws LiveSessionModelSwitchError
       throw new LiveSessionModelSwitchError(nextSelection);
   }
   ```

9. `LiveSessionModelSwitchError` propagates up through `runWithModelFallback`
   (it is not a `FailoverError`, so it is not caught as a fallback attempt --
   it propagates all the way out).

10. In the outer agent-runner loop (line 522-529):
    ```js
    if (err instanceof LiveSessionModelSwitchError) {
        params.followupRun.run.provider = err.provider;  // "openai-codex"
        params.followupRun.run.model = err.model;        // "gpt-5.4"
        continue;  // restart the whole run with gpt-5.4
    }
    ```

11. **LOOP**: gpt-5.4 is still rate-limited -> FailoverError -> try glm-5 ->
    LiveSessionModelSwitchError(gpt-5.4) -> restart with gpt-5.4 -> rate-limited ->
    repeat until `MAX_RUN_LOOP_ITERATIONS` exhausted.

### Why `resolveDefaultModelForAgent` Is The Root Cause

`resolveDefaultModelForAgent` (in `model-selection-CMtvxDDg.js:252`):
```js
function resolveDefaultModelForAgent(params) {
    const agentModelOverride = params.agentId
        ? resolveAgentEffectiveModelPrimary(params.cfg, params.agentId)
        : void 0;
    return resolveConfiguredModelRef({ cfg: ..., ... });
}
```

This reads `agents.defaults.model.primary` from config (or per-agent override).
It has NO awareness of runtime fallback state. The `defaultProvider` and
`defaultModel` parameters passed to `resolveLiveSessionModelSelection` are
ignored when `agentId` is set.

### No Failover State Communication Mechanism

There is no mechanism for `runWithModelFallback` to tell the session layer
"I chose this model as a fallback, don't treat it as a mismatch." The fallback
system communicates via function arguments only. The live-session switch
detection reads from config/session-store only. These two systems operate on
different state sources with no bridge between them.

---

## Evidence Assessment

### Evidence It Is an OpenClaw Bug (STRONG)

1. **Code path proves the conflict**: `resolveDefaultModelForAgent` ignores
   the runtime provider/model when `agentId` exists (always true for agents).
   The `defaultProvider`/`defaultModel` params in `resolveLiveSessionModelSelection`
   are dead code in the agent path.

2. **No failover state bridge**: There is zero code that persists or
   communicates the fallback model choice to the session-level model switch
   detection. The two systems are architecturally isolated.

3. **The fix is impossible from config**: No `openclaw.json` setting can
   prevent `resolveDefaultModelForAgent` from returning the configured primary
   when comparing against the runtime fallback model.

4. **The changelog confirms related bugs**: OpenClaw 2026.3.x fixed
   `LiveSessionModelSwitchError` for isolated/cron runs (transient model
   overrides misread as live switches). Our bug is the same class of issue
   but triggered by fallback model selection instead of cron overrides.

5. **Known pattern of failover bugs**: Multiple GitHub issues document
   failover loop problems (#40989 infinite cooldown, #5744 per-model rate
   limit triggers full provider cooldown, #17478 fallback doesn't recover).

### Evidence It Is Our Config Issue (WEAK/NONE)

1. **We could remove fallbacks entirely** -- but that defeats the purpose of
   failover and is not a "fix," it is a workaround.

2. **We could use same-provider fallbacks** -- but `resolveDefaultModelForAgent`
   would still return the configured primary, not the fallback. Same bug.

3. **No misconfiguration was found**: Our `openclaw.json` follows documented
   patterns. The `agents.defaults.model.primary` and `fallbacks` are set
   correctly per OpenClaw docs.

---

## Workarounds (Until Fix)

1. **Current workaround (already applied)**: Use glm-5 as primary with NO
   fallbacks. If glm-5 fails, there is no fallback to trigger the loop.
   Downside: no resilience.

2. **Per-session model override**: If the session store has a `providerOverride`
   matching the fallback, the check would pass. But this requires manual
   intervention per session and is impractical.

3. **Isolated sessions only**: The 2026.3.x fix addressed isolated runs.
   If all runs used `--session-id isolated`, the `agentId` path might not
   trigger. But our cron jobs use named session keys.

---

## Recommended Actions

1. **File a GitHub issue** on openclaw/openclaw describing the bug with the
   code paths documented above. Title: "Model fallback triggers
   LiveSessionModelSwitchError loop when agentId is set"

2. **Keep glm-5 as primary with no fallbacks** until the fix ships.

3. **Monitor OpenClaw releases** for a fix to `resolveLiveSessionModelSelection`
   that accounts for runtime fallback state (e.g., by checking whether the
   current model was selected by `runWithModelFallback` before comparing
   against config defaults).

---

## Conclusion

**Confidence: HIGH -- This is an OpenClaw platform bug.**

The failover system (`runWithModelFallback`) and the live-session model switch
detection (`resolveLiveSessionModelSelection`) operate on completely different
state sources. The fallback system passes the chosen model via function
arguments. The live-switch detector reads the configured default via
`resolveDefaultModelForAgent`, which ignores the runtime fallback. When these
disagree (which they always will during a fallback), `LiveSessionModelSwitchError`
forces a switch back to the rate-limited primary, creating an infinite loop.

The fix must come from OpenClaw: either suppress the live-switch check when
a fallback is in progress, or have `resolvePersistedLiveSelection` use the
runtime provider/model (the `defaultProvider`/`defaultModel` params it already
receives but ignores) instead of calling `resolveDefaultModelForAgent`.

---

## Files Analyzed

- `dist/auth-profiles-B5ypC5S-.js` (main agent runtime, 338K+ lines)
  - `runWithModelFallback`: line 65267
  - `LiveSessionModelSwitchError` class: line 161493
  - `resolveLiveSessionModelSelection`: line 161503
  - `hasDifferentLiveSessionModelSelection`: line 161536
  - `resolvePersistedLiveSelection` closure: line 169168
  - `resolveCurrentLiveSelection` closure: line 169162
  - Pre-attempt switch check: line 169324
  - Catch block in outer loop: line 522 (agent-runner.runtime)
- `dist/model-selection-CMtvxDDg.js`
  - `resolveDefaultModelForAgent`: line 252
- `dist/plugin-sdk/src/agents/live-model-switch.d.ts` (type definitions)
- `dist/plugin-sdk/src/agents/model-fallback.d.ts` (type definitions)

## Sources

- [OpenClaw Changelog](https://github.com/openclaw/openclaw/blob/main/CHANGELOG.md)
- [Model Failover Documentation](https://docs.openclaw.ai/concepts/model-failover)
- [ZAI infinite cooldown loop - Issue #40989](https://github.com/openclaw/openclaw/issues/40989)
- [Per-model rate limit triggers full provider cooldown - Issue #5744](https://github.com/openclaw/openclaw/issues/5744)
- [Rate limit fallback doesn't auto-recover - Issue #17478](https://github.com/openclaw/openclaw/issues/17478)
