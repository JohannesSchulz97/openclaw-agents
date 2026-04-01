# OpenClaw Failover Bug Investigation

**Date:** 2026-04-01
**Investigator:** Research Agent (Claude Opus 4.6)
**Version Analyzed:** openclaw@2026.3.28
**Classification:** Actionable -- OpenClaw platform bug (confirmed)

---

## Executive Summary

**This is an OpenClaw platform bug, not a configuration mistake.**

The failover mechanism and the live-session-model-switch detection operate at two
different architectural layers that do not communicate. When `runWithModelFallback`
selects a fallback model (e.g., glm-5), the inner embedded run still checks
`resolvePersistedLiveSelection()` which reads the *configured default* (gpt-5.4),
detects a mismatch with the currently-running fallback model, and throws
`LiveSessionModelSwitchError` -- causing an infinite retry loop.

**Confidence Level: HIGH** -- confirmed by source code analysis of the exact code
paths involved.

---

## Architecture of the Conflict

### Two Independent Systems

**System A: Model Fallback (`runWithModelFallback`)**
- Location: `auth-profiles-B5ypC5S-.js:65267`
- Purpose: When primary model fails (rate limit, overload), iterate through
  configured `fallbacks` list and try each candidate.
- Mechanism: Calls `params.run(provider, model)` with the fallback provider/model.
- State: Tracks attempts in a local `attempts[]` array. Does NOT persist the
  fallback choice to any session store.

**System B: Live Session Model Switch Detection**
- Location: `auth-profiles-B5ypC5S-.js:169324`
- Purpose: Detect when a user changes model via `/model` command mid-run, so the
  active run restarts with the new model.
- Mechanism: Before each run loop iteration, calls `resolvePersistedLiveSelection()`
  which reads the session store + config defaults, then compares against
  `resolveCurrentLiveSelection()` (the model currently being used).
- Action on mismatch: Throws `LiveSessionModelSwitchError`.

### The Conflict (Exact Code Path)

```
1. Primary model (gpt-5.4) is rate-limited
2. runWithModelFallback catches the error, advances to fallback candidate (glm-5)
3. runWithModelFallback calls: params.run("zhipu", "glm-5")
4. Inside the run callback, runEmbeddedPiAgent starts with provider="zhipu", modelId="glm-5"
5. The run loop begins a new iteration (line 169323):
   - resolvePersistedLiveSelection() is called
   - It reads session store: no providerOverride/modelOverride set
   - Falls back to defaultModelRef = resolveDefaultModelForAgent(cfg, agentId)
   - Returns { provider: "openai-codex", model: "gpt-5.4" }  <-- the CONFIG default
6. hasDifferentLiveSessionModelSelection() compares:
   - current: { provider: "zhipu", model: "glm-5" }       <-- what failover chose
   - next:    { provider: "openai-codex", model: "gpt-5.4" } <-- what config says
   - Result: TRUE (they differ!)
7. LiveSessionModelSwitchError is thrown with { provider: "openai-codex", model: "gpt-5.4" }
8. The outer agent runner catches it (agent-runner.runtime:522):
   - Sets followupRun.run.provider = "openai-codex"
   - Sets followupRun.run.model = "gpt-5.4"
   - Continues the loop
9. Now running gpt-5.4 again -- which is still rate-limited
10. runWithModelFallback catches the rate limit, advances to glm-5 again
11. GOTO step 3 -- infinite loop
```

### Key Evidence: `resolvePersistedLiveSelection` Does Not Know About Failover

```javascript
// Line 169168-169174: defaultProvider and defaultModel come from the
// CURRENT run's provider/model variables
const resolvePersistedLiveSelection = () => resolveLiveSessionModelSelection({
    cfg: params.config,
    sessionKey: params.sessionKey,
    agentId: workspaceResolution.agentId,
    defaultProvider: provider,   // <-- This is the failover model's provider
    defaultModel: modelId        // <-- This is the failover model's ID
});
```

Wait -- this actually passes the *current* provider/model as defaults. Let me
re-examine...

```javascript
// Line 161516-161517: Inside resolveLiveSessionModelSelection:
const provider = entry?.providerOverride?.trim() || defaultModelRef.provider;
const model = entry?.modelOverride?.trim() || defaultModelRef.model;
```

If `entry?.providerOverride` is empty (no `/model` override), it falls back to
`defaultModelRef`. And `defaultModelRef` is:

```javascript
// Line 161508-161514:
const defaultModelRef = agentId ? resolveDefaultModelForAgent({ cfg, agentId })
    : { provider: params.defaultProvider, model: params.defaultModel };
```

**Critical finding:** When `agentId` is set (which it is for our agents),
`resolveDefaultModelForAgent` reads from config (`agents.defaults.model` or
`agents.list[agentId].model`), completely ignoring the `defaultProvider` and
`defaultModel` parameters passed in.

This means:
- `resolvePersistedLiveSelection()` always returns the CONFIG default (gpt-5.4)
  when no session override exists
- Even though the failover system passed glm-5 as the current model
- The `defaultProvider`/`defaultModel` parameters are dead code when `agentId`
  is present

### No Failover State Communication

Searched for any mechanism where `runWithModelFallback` persists its choice:
- No `failoverState`, `failoverInProgress`, `setFallbackModel`, or similar
  identifiers exist
- The fallback decision lives entirely in the local scope of
  `runWithModelFallback`'s for-loop
- The session store is never updated with the failover model
- There is no flag to suppress live-session-switch detection during failover

---

## Evidence Summary

### Evidence It Is an OpenClaw Bug

1. **No failover state propagation**: `runWithModelFallback` does not persist its
   model choice anywhere the session layer can read. The failover decision is
   ephemeral (local variable in a for-loop).

2. **`resolveDefaultModelForAgent` ignores passed defaults**: When `agentId` is
   set, line 161508 calls `resolveDefaultModelForAgent({cfg, agentId})` which
   reads from openclaw.json config, completely bypassing the `defaultProvider`
   and `defaultModel` parameters that were intended to carry the current model.

3. **The before-attempt check has no failover awareness**: Line 169324 checks
   `resolvePersistedLiveSelection()` unconditionally on every run-loop iteration,
   with no guard for "am I running as a failover candidate right now?"

4. **Known pattern of similar bugs**: The CHANGELOG contains multiple entries
   about failover/session interaction bugs:
   - "Agents/model switching: apply /model changes to active embedded runs at
     the next safe retry boundary"
   - "Subagents/Models: preserve agents.defaults.model.fallbacks when subagent
     sessions carry a model override"
   - "Agents/overload failover handling: classify overloaded provider failures
     separately from rate limits"
   - The web search found a similar fix was made for "transient cron and subagent
     model overrides" that were "misread as persisted live-session switches"

5. **Multiple open GitHub issues** document failover failures:
   - #24378: Overloaded error does not trigger fallback
   - #11218: Agent-level fallbacks ignored
   - #49696: overloaded_error does not trigger fallback
   - #32533: Fallback does not escalate to different provider

### Evidence It Could Be Our Config (Weak/Refuted)

1. **Session store override**: If our sessions had `providerOverride`/`modelOverride`
   set in the session store, that would take precedence. But this is not the case --
   we never use `/model` to override; the conflict comes from the config default
   vs. the failover model.

2. **Fallbacks configuration**: Our fallbacks were correctly configured
   (`agents.defaults.model.fallbacks` including glm-5). The fallback selection
   itself works -- it is the live-switch detection that interferes.

---

## Why the Current Workaround Works

Setting glm-5 as the primary with no fallbacks avoids the bug entirely because:
- There is only one model candidate, so `runWithModelFallback` never switches
- `resolvePersistedLiveSelection()` returns glm-5 (the config default)
- `resolveCurrentLiveSelection()` also returns glm-5
- `hasDifferentLiveSessionModelSelection()` returns false
- No `LiveSessionModelSwitchError` is ever thrown

---

## Recommendations

### Immediate (No Action Needed)
The current workaround (glm-5 as primary, no fallbacks) is stable and agents are
working. Keep this configuration until the bug is fixed upstream.

### Short-Term
1. **File a GitHub issue** on openclaw/openclaw describing this exact bug with the
   code path analysis above. The fix would be one of:
   - Add a `isFailoverAttempt` flag to `runEmbeddedPiAgent` params that suppresses
     the before-attempt live-switch check
   - Have `runWithModelFallback` temporarily write the failover model to the session
     store (and clean up on completion)
   - Make `resolvePersistedLiveSelection` accept the current run's model as the
     "expected default" when no session override exists

2. **Check for newer versions**: Our version is 2026.3.28. The web search found a
   fix was made for a similar issue ("transient cron and subagent model overrides
   were being misread as persisted live-session switches"). This fix may be in a
   version newer than ours.

### Medium-Term
Once the bug is fixed upstream:
1. Update openclaw to the fixed version
2. Restore gpt-5.4 as primary with glm-5 as fallback
3. Test failover by temporarily rate-limiting the primary

---

## Sources

- [OpenClaw CHANGELOG](https://github.com/openclaw/openclaw/blob/main/CHANGELOG.md)
- [Model Failover Documentation](https://docs.openclaw.ai/concepts/model-failover)
- [Issue #24378: Overloaded error does not trigger fallback](https://github.com/openclaw/openclaw/issues/24378)
- [Issue #11218: Agent-level fallbacks ignored](https://github.com/openclaw/openclaw/issues/11218)
- [Issue #49696: overloaded_error does not trigger fallback](https://github.com/openclaw/openclaw/issues/49696)
- [Issue #32533: Fallback does not escalate to different provider](https://github.com/openclaw/openclaw/issues/32533)
- [Issue #29429: network_error not triggering failover](https://github.com/openclaw/openclaw/issues/29429)
- [Issue #11418: Unavailable model not triggering failover](https://github.com/openclaw/openclaw/issues/11418)
- Source code: `openclaw@2026.3.28/dist/auth-profiles-B5ypC5S-.js`
- Source code: `openclaw@2026.3.28/dist/agent-runner.runtime-C-sR1PRP.js`
