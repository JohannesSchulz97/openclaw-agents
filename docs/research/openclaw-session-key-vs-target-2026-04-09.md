# OpenClaw sessionKey vs sessionTarget in Cron Jobs

**Date:** 2026-04-09
**Status:** CONFIRMED -- sessionTarget overrides sessionKey for session identity

## Executive Summary

**The truth is more nuanced than either simple reading suggests:**

- `sessionKey` defines the **default** session identity (conversation history) for a cron job
- `sessionTarget` can **override** the session identity when it starts with `session:`
- When `sessionTarget` starts with `session:`, the value after the prefix **replaces** the sessionKey for session lookup
- Both fields independently affect session behavior, but `sessionTarget` takes precedence for session identity when in `session:` mode

## The Three sessionTarget Modes

OpenClaw supports three distinct `sessionTarget` modes for cron jobs:

### 1. `"main"` -- Main Session System Events
- Only valid for the default agent
- Requires `payload.kind: "systemEvent"`
- Injects a system event into the agent's main session
- Uses `job.sessionKey` as the target main session key (line 8210)

### 2. `"isolated"` -- Fresh Session Per Run
- Forces `forceNew: true` in session resolution (line 6182)
- Creates a **brand new session** every time the cron job runs
- No conversation history preserved between runs
- Used for one-shot tasks

### 3. `"session:<id>"` -- Named Persistent Session
- The `<id>` portion **replaces** sessionKey for session identity (line 9115)
- Session persists across runs (conversation history preserved)
- Treated as "isolated-like" for validation purposes (line 6837)

## Critical Code Evidence

### Evidence 1: sessionTarget overrides sessionKey (line 9112-9125)

```javascript
// server.impl-WjqjRArz.js line 9112-9125
runIsolatedAgentJob: async ({ job, message, abortSignal }) => {
    const { agentId, cfg: runtimeConfig } = resolveCronAgent(job.agentId);
    let sessionKey = `cron:${job.id}`;  // DEFAULT: use job ID as session key
    if (job.sessionTarget.startsWith("session:"))
        sessionKey = assertSafeCronSessionTargetId(job.sessionTarget.slice(8));
        // OVERRIDE: sessionTarget replaces sessionKey!
    try {
        return await runCronIsolatedAgentTurn({
            cfg: runtimeConfig,
            deps: params.deps,
            job,
            message,
            abortSignal,
            agentId,
            sessionKey,  // This is what determines conversation identity
            lane: "cron"
        });
    }
}
```

### Evidence 2: Session resolution uses sessionKey to look up conversation (line 6161-6183)

```javascript
// Inside prepareCronRunContext (line 6161)
const baseSessionKey = (input.sessionKey?.trim() || `cron:${input.job.id}`).trim();
const agentSessionKey = resolveCronAgentSessionKey({
    sessionKey: baseSessionKey,
    agentId,
    mainKey: input.cfg.session?.mainKey,
    cfg: input.cfg
});
// ...
const cronSession = resolveCronSession({
    cfg: input.cfg,
    sessionKey: agentSessionKey,  // THIS is the lookup key for conversation history
    agentId,
    nowMs: now,
    forceNew: input.job.sessionTarget === "isolated"  // Only "isolated" forces new
});
```

### Evidence 3: resolveCronSession uses sessionKey for store lookup (heartbeat-runner line 39-80)

```javascript
function resolveCronSession(params) {
    const storePath = resolveStorePath(sessionCfg?.store, { agentId: params.agentId });
    const store = loadSessionStore(storePath);
    const entry = store[params.sessionKey];  // Looks up by sessionKey in session store
    // If forceNew is false and entry exists and is fresh, REUSES the session
    if (!params.forceNew && entry?.sessionId) {
        // Check freshness, reuse if still fresh
        sessionId = entry.sessionId;  // SAME conversation continues
        isNewSession = false;
    } else {
        sessionId = crypto.randomUUID();  // NEW conversation
        isNewSession = true;
    }
}
```

### Evidence 4: sessionKey aliasing -- "main" maps to agent's main session (main-session.ts)

```javascript
function canonicalizeMainSessionAlias(params) {
    const isMainAlias = raw === "main" || raw === mainKey || ...;
    if (isMainAlias) return agentMainSessionKey;  // e.g., "agent:dev1:main"
    return raw;
}
```

## What This Means For Your Cron Jobs

### Current config pattern:

```json
{
    "sessionTarget": "session:main",
    "sessionKey": "agent:dev1:cron:morning"
}
```

**What actually happens:**

1. `executeDetachedCronJob` is called (because sessionTarget is not literally "main")
2. Inside `runIsolatedAgentJob`, because `sessionTarget.startsWith("session:")`:
   - sessionKey is set to `"main"` (the part after "session:")
3. `prepareCronRunContext` receives `sessionKey: "main"`
4. `toAgentStoreSessionKey` converts `"main"` to `"agent:dev1:main"`
5. `canonicalizeMainSessionAlias` confirms this maps to the agent's main session
6. `resolveCronSession` looks up `store["agent:dev1:main"]`

**Result: ALL cron jobs with `sessionTarget: "session:main"` share the SAME conversation history as the agent's main Slack DM session.**

### Session sharing matrix for current config:

| sessionTarget | sessionKey | Actual session used |
|---|---|---|
| `session:main` | `agent:X:cron:morning` | `agent:X:main` (shared with DM!) |
| `session:main` | `agent:X:cron:midday` | `agent:X:main` (shared with DM!) |
| `session:main` | `agent:X:cron:evening` | `agent:X:main` (shared with DM!) |
| `session:main` | `agent:X:cron:summary` | `agent:X:main` (shared with DM!) |
| `session:slack:direct:u09l59gj3qt` | `agent:X:cron:morning` | `agent:X:slack:direct:u09l59gj3qt` |
| `isolated` | `agent:X:cron:morning` | New UUID every run (no history) |

### Gateway log evidence confirming shared sessions:

The gateway log shows the context engine performing maintenance on `sessionKey=agent:dev1:slack:direct:u09l59gj3qt` -- this is the DM session. Since `session:main` canonicalizes to `agent:dev1:main`, and the MEMORY.md already notes that `--session-id` maps to main, this confirms the shared-session behavior.

## Critical Implication

**The `sessionKey` field in jobs-config.json is NOT determining the session identity when `sessionTarget` starts with `session:`.**

The `sessionKey` field serves TWO purposes:
1. **Cron scheduler matching** -- `apply-cron.sh` uses it to reconcile jobs
2. **Fallback session identity** -- Only used when sessionTarget does NOT start with `session:`

When `sessionTarget = "session:main"`, the sessionKey in the config is effectively ignored for session routing. All four of dev1's cron jobs (morning/midday/evening/summary) run in the same `agent:dev1:main` conversation.

## Recommendations

If you want **isolated cron sessions** (separate conversation per cron type):

```json
{
    "sessionTarget": "session:agent:dev1:cron:morning",
    "sessionKey": "agent:dev1:cron:morning"
}
```

Or use `"isolated"` for no-history one-shot runs:

```json
{
    "sessionTarget": "isolated",
    "sessionKey": "agent:dev1:cron:morning"
}
```

If you want cron jobs to share the **DM conversation context** (current behavior with `session:main`), keep the current config -- but be aware that cron job messages accumulate in the same conversation history as user DMs.

## Source Files Examined

- `/opt/homebrew/lib/node_modules/openclaw/dist/server.impl-WjqjRArz.js` (main server, lines 6161-9133)
- `/opt/homebrew/lib/node_modules/openclaw/dist/heartbeat-runner-CTjQ-eEh.js` (resolveCronSession, lines 39-80)
- `/opt/homebrew/lib/node_modules/openclaw/dist/session-key-CJfa_Nnz.js` (session key parsing/aliasing)
- `/opt/homebrew/lib/node_modules/openclaw/dist/main-session-DaD0xK0B.js` (canonicalizeMainSessionAlias)
- `~/.openclaw/logs/gateway.log` (runtime session evidence)
- `.openclaw/cron/jobs-config.json` (current configuration)
