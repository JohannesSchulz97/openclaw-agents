# OpenClaw Session Isolation Research

**Date:** 2026-04-07
**Context:** Evening report script using `openclaw agent --session-id` for isolated cron-like prompts
**Key Question:** Does `openclaw agent --agent dev10 --session-id "agent:dev10:cron:evening-report"` leak into dev10's Slack DM session?

## Executive Summary

**The `openclaw agent --session-id` flag DOES create a separate session** under normal gateway operation. Custom session keys like `agent:dev10:cron:evening-report` are NOT aliased to `agent:dev10:main` -- they remain as distinct keys in the session store. However, the testing incident where `--session-id` resolved to `agent:dev10:main` was caused by **embedded mode fallback** during gateway crash-looping, which has different session routing behavior.

**Answer to the key question: No, the prompt/response will NOT appear in dev10's Slack DM conversation**, provided the gateway is running normally. The Slack DM session uses a different session key (`agent:dev10:slack:direct:u0998266edq`), and the cron session uses its own key.

## Evidence

### Finding 1: Session Key Architecture

OpenClaw sessions are keyed by **session key** strings in the format `agent:<agentId>:<rest>`. The session store (`sessions.json`) maps session keys to session entries (with `sessionId`, `updatedAt`, `origin`, etc.).

**Key function: `canonicalizeMainSessionAlias`** (from `main-session-DaD0xK0B.js`):

```javascript
function canonicalizeMainSessionAlias(params) {
  const agentMainSessionKey = buildMainSessionKey(agentId, mainKey);  // e.g. "agent:dev10:main"
  const agentMainAliasKey = buildMainSessionKey(agentId, "main");
  const legacyMainKey = buildMainSessionKey("main", mainKey);
  const legacyMainAliasKey = buildMainSessionKey("main", "main");
  
  const isMainAlias = raw === "main" || raw === mainKey 
    || raw === agentMainSessionKey || raw === agentMainAliasKey 
    || raw === legacyMainKey || raw === legacyMainAliasKey;
  
  if (isMainAlias) return agentMainSessionKey;
  return raw;  // <-- Custom keys pass through unchanged
}
```

**Conclusion:** Only the literal values `"main"`, the configured `mainKey`, or full `agent:NAME:main` keys get aliased to the main session. Any other key (like `agent:dev10:cron:evening-report`) passes through as-is and gets its own session entry.

### Finding 2: Session Store Evidence

dev10's `sessions.json` shows clear separation between session types:

| Session Key | Session ID (UUID) | Label |
|---|---|---|
| `agent:dev10:slack:direct:u0998266edq` | `cf739c2b-...` | (Slack DM) |
| `agent:dev10:cron:6631afef-...` | `5462d34d-...` | Cron: dev10 Midday Check-in |
| `agent:dev10:cron:c9ab4665-...` | `c549a53e-...` | Cron: dev10 Evening Check-in |
| `agent:dev10:cron:e095a7d0-...` | `30949df8-...` | Cron: dev10 Morning Check-in |

Each cron job creates its own session key and its own session ID (UUID). The Slack DM session is completely separate.

### Finding 3: The `agent:dev10:main` Corruption

**Critical finding:** Both dev10 and dev10 have their `agent:NAME:main` entry corrupted:

- `agent:dev10:main` has `sessionId: "agent:dev10:cron:evening-report"` (updatedAt: 1775634431308)
- `agent:dev10:main` has `sessionId: "agent:dev10:evening-debug-1775636863"` (updatedAt: 1775636901080)

The `sessionId` field should be a UUID like `cf739c2b-ff93-4533-8288-f50a830771c4`, but instead it contains the literal string from `--session-id`. This means:

**When the gateway was crash-looping, `openclaw agent` fell back to embedded mode.** In embedded mode, the `--session-id` value was stored as the `sessionId` rather than being used as the `sessionKey`. This is a bug in embedded-mode session handling -- it conflates session key and session ID.

**This does NOT happen during normal gateway operation** (when the gateway processes the request through its proper session routing).

### Finding 4: Cron Jobs Use Separate Sessions by Design

From `jobs-config.json`, cron jobs have two session-related fields:

- **`sessionKey`**: Determines which session the job runs in (e.g., `agent:dev10:cron:morning`)
- **`sessionTarget`**: Determines the Slack conversation binding (e.g., `session:slack:direct:u07lthhbbl2` or `session:main`)

CLAUDE.md documents: "Cron sessions are separate from chat sessions. A cron job with sessionKey `agent:dev10:cron:morning` runs in its own session, not in the developer's DM chat session."

### Finding 5: `--session isolated` vs Custom Session Key

From the cron CLI source (`cron-cli-DRdEYv67.js`):

```
--session <target>    Session target (main|isolated)
--session-key <key>   Session key for job routing
```

There are two orthogonal concepts:
1. **Session target** (`main` or `isolated`): Controls whether the session binds to the main conversation or creates an ephemeral isolated session
2. **Session key**: The routing key that determines which session entry is used

For `openclaw agent --session-id`, the value is used as a **session key** (not a session target). When the value follows the `agent:NAME:SOMETHING` pattern and `SOMETHING` is not `main`, it creates/reuses a session with that distinct key.

The special value `"isolated"` for the `--session` flag in cron CLI creates a one-off session that doesn't persist. This is different from `--session-id` which is a persistent named session.

### Finding 6: Session Entry Structure

Each session entry in `sessions.json` tracks:
- `sessionId` (UUID): The actual transcript/log file identifier
- `updatedAt`: Last update timestamp
- `origin`: The Slack conversation metadata (provider, chatType, from, to, nativeChannelId)
- `skillsSnapshot`: Frozen skill state at session creation
- `modelProvider`/`model`: Model used
- `systemPromptReport`: System prompt metadata

The `origin` field in cron session entries still carries Slack metadata from the `sessionTarget` configuration, but this is for **delivery routing** (where to send messages), not for session sharing. The cron session's conversation log is stored in a separate `.jsonl` file identified by its own UUID.

## Implications for Evening Report Script

### Safe Approach (Recommended)

Using `openclaw agent --agent dev10 --session-id "agent:dev10:cron:evening-report"` is safe:

1. The session key `agent:dev10:cron:evening-report` will NOT alias to `agent:dev10:main`
2. It creates a separate session entry with its own transcript
3. dev10 will NOT see the prompt/response in his Slack DM
4. The agent CAN still send Slack messages to dev10 using `openclaw message send` from within the session (this is agent-initiated, not session leakage)

### Risk: Embedded Mode Fallback

If the gateway is down when the script runs, `openclaw agent` falls back to embedded mode, which has a bug where:
- The `--session-id` value gets stored as the `sessionId` field of `agent:NAME:main`
- This corrupts the main session entry

**Mitigation:** Ensure gateway health before running the evening report. The `session watchdog` (launchd, every 5 min) monitors gateway health and could be used as a pre-check.

### Risk: Main Session Key in Config

Our cron `jobs-config.json` uses `sessionTarget: "session:main"` for some jobs (tech-manager monitoring, update-check). This binds the cron session to the main conversation context. For evening reports, we should use either:
- `sessionTarget: "session:slack:direct:<slack-id>"` (binds to developer's DM for delivery)
- Or no sessionTarget / `delivery.mode: "none"` (agent decides whether to message)

## Comparison: Session Isolation Methods

| Method | Creates Separate Session | Persists | Visible in DM | Use Case |
|---|---|---|---|---|
| `--session-id "agent:X:cron:Y"` | Yes | Yes | No | Named recurring tasks |
| `--session isolated` (cron flag) | Yes | No (ephemeral) | No | One-shot tasks |
| `--session main` (cron flag) | No (uses main) | Yes | Yes | System events |
| Slack DM message | Uses DM session | Yes | Yes | Interactive chat |

## Recommendations

1. **Use `agent:dev10:cron:evening-report` as the session key** -- this correctly isolates from both the main session and the Slack DM session
2. **Add gateway health check** before running the evening report to avoid embedded mode fallback
3. **Monitor for the `sessionId` corruption bug** -- check if `agent:NAME:main` entries have non-UUID sessionId values (indicates embedded mode fallback occurred)
4. **Fix existing corruption** -- dev10 and dev10's `agent:NAME:main` entries need repair (the sessionId field contains string values instead of UUIDs)
