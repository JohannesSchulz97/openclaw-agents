# OpenClaw Agent Response Latency Analysis

**Date:** 2026-03-26
**Type:** Investigative Research (Informational)
**Status:** Complete

---

## Executive Summary

Agent text message responses are slow due to a combination of five compounding factors. The dominant contributors are: (1) the Slack socket connection going stale every ~35 minutes requiring reconnection, (2) the per-agent session bootstrap overhead from reading multiple markdown files on every turn, and (3) LLM inference time through the Fireworks AI proxy for cron jobs using a model with only 16K context window. There is no single silver bullet -- latency accumulates across the entire pipeline.

---

## Latency Breakdown: Where Time Is Spent

### 1. Slack Socket Instability (CRITICAL -- estimated 0-120s added latency)

**Finding:** The Slack WebSocket connection is declared stale and restarted approximately every 35 minutes. During the reconnection window, inbound messages may be delayed or missed entirely.

**Evidence:**
- 291 stale-socket restart events across 8 days in gateway.log
- Consistent ~35-40 per day (e.g., 35 on Mar 25, 41 on Mar 22)
- Pong timeout warnings: `A pong wasn't received from the server before the timeout of 5000ms!`
- Some reconnections take over 1 minute (e.g., 00:28:59 restart -> 00:30:49 reconnected = **110 seconds**)
- Health monitor interval is 300s (5 minutes), so stale sockets may go undetected for up to 5 minutes before being restarted

**Impact:** If a user sends a message while the socket is stale (before the health monitor detects it), the message sits undelivered until the socket reconnects. Worst case: **up to 5 minutes of dead time** before the health monitor even notices, plus reconnection time.

**Config:**
```json
"slack": {
  "mode": "socket",
  "streaming": "partial",
  "nativeStreaming": true
}
```

### 2. LLM Inference Time (HIGH -- estimated 5-30s per turn)

**Finding:** Agents use `openai-codex/gpt-5.4` for interactive sessions (configured in `openclaw.json` agents.defaults.model.primary). Cron jobs use `fw-mm25` which routes to `accounts/fireworks/models/minimax-m2p5` via the Fireworks AI proxy.

**Key concerns:**
- **MiniMax M2P5 via Fireworks:** Only 16K context window, maxTokens 4096. The logs repeatedly warn: `low context window: fw-mm25/accounts/fireworks/models/minimax-m2p5 ctx=16000 (warn<32000)`
- **GPT-5.4 for interactive:** Inference time depends on OpenAI Codex API latency, which is external and uncontrollable
- **Thinking enabled:** Cron jobs have `"thinking": "on"` which adds reasoning tokens before the visible response
- **thinkingDefault: "low"** is set globally, but cron overrides with `"on"` -- meaning cron check-in jobs pay full thinking overhead

**Subagent config:** `maxConcurrent: 8` subagents with `thinking: "low"` -- if multiple agents process simultaneously, they compete for the same local gateway resources.

### 3. Session Bootstrap Overhead (MEDIUM -- estimated 3-10s per new session)

**Finding:** Every session startup requires reading 4+ files according to AGENTS.md:
1. `SOUL.md` (36 lines)
2. `USER.md` (per-agent)
3. `memory/YYYY-MM-DD.md` (today + yesterday)
4. `MEMORY.md` (in main sessions)

Plus the agent reads `TOOLS.md` (40 lines), `AGENTS.md` (216 lines), and `HEARTBEAT.md`.

**Total bootstrap payload:** ~350+ lines of markdown loaded into context before any user message is processed. With memory files this could be significantly larger.

**Compaction safeguard:** Logs show repeated `Compaction safeguard: cancelling compaction with no real conversation messages to summarize` -- sessions are being created and torn down without meaningful conversation, wasting startup cycles.

### 4. Cron Check-in Architecture (MEDIUM -- adds structural delay)

**Finding:** The cron jobs are check-in timers, not message polling. They run every 7200000ms (2 hours) and only check if the agent should proactively reach out. They do NOT poll for new inbound messages.

**Message delivery path for interactive messages:**
1. User sends Slack message
2. Slack delivers via WebSocket to gateway (depends on socket health -- see issue #1)
3. Gateway routes to agent based on binding config (peer ID matching)
4. Agent session bootstraps (reads files -- see issue #3)
5. LLM inference begins (see issue #2)
6. Response streams back through gateway to Slack

The cron jobs (`poll-check.sh`) are purely for proactive outreach -- they check `sessions.json` for last human interaction time and decide whether to send a check-in message. They do not affect inbound message responsiveness.

### 5. Gateway Processing Overhead (LOW -- 400-700ms per request)

**Finding:** Gateway websocket responses show 400-700ms processing time:
```
channels.status 620ms
doctor.memory.status 532ms
channels.status 699ms
doctor.memory.status 433ms
```

This is relatively minor compared to the other factors but adds up.

---

## Configuration Summary

| Setting | Value | Location | Concern |
|---------|-------|----------|---------|
| Interactive model | `openai-codex/gpt-5.4` | openclaw.json agents.defaults | External API latency |
| Cron model | `fw-mm25` (MiniMax M2P5) | jobs-config.json | 16K context, low quality |
| Cron model alt | `fireworks/kimi-k2p5` | openclaw.json (registered) | 128K context, reasoning, **not used by cron** |
| Thinking (global) | `"low"` | openclaw.json | Adds reasoning tokens |
| Thinking (cron) | `"on"` | jobs-config.json | Full thinking on check-ins |
| Compaction | `"safeguard"` | openclaw.json | Attempts compaction on every session |
| Slack mode | `"socket"` | openclaw.json | WebSocket with stale-socket issues |
| Slack streaming | `"partial"` + nativeStreaming | openclaw.json | Partial streaming, not full |
| Health monitor | 300s interval | gateway startup log | 5min detection delay for stale sockets |
| Max concurrent agents | 4 | openclaw.json | Contention under load |
| Max concurrent subagents | 8 | openclaw.json | Additional contention |
| Cron timeout | 120s | jobs-config.json | 2min timeout per cron job |

---

## Concrete Recommendations (Prioritized)

### Priority 1: Fix Slack Socket Stability

**Problem:** Socket goes stale every ~35 min, health monitor only checks every 5 min.

**Suggestions:**
- Reduce health monitor interval from 300s to 60-120s to detect stale sockets faster
- Investigate why the socket goes stale so frequently -- 35-40 times/day is abnormal. This may be a network issue, a Slack API rate limit, or a keep-alive misconfiguration
- Consider adding a Slack events API webhook fallback (`"webhookPath": "/slack/events"` is configured but socket mode is primary) so messages arrive via HTTP POST if the socket is down
- Check if OpenClaw has a config for Slack socket ping interval or timeout

### Priority 2: Reduce Session Bootstrap Cost

**Problem:** Every turn loads 350+ lines of context files before processing.

**Suggestions:**
- Keep `SOUL.md`, `AGENTS.md`, and `TOOLS.md` as lean as possible (they are currently reasonable at ~290 lines combined, but memory files can grow unbounded)
- Implement memory file size limits or summarization
- Consider setting `dmScope` to `"per-channel-peer"` (already set) and ensure sessions persist to avoid repeated bootstrap

### Priority 3: Optimize Cron Job Model Choice

**Problem:** Cron uses MiniMax M2P5 with 16K context window, generating low-context warnings.

**Suggestions:**
- Switch cron model from `fw-mm25` (MiniMax M2P5, 16K ctx) to `fw-kk25` (Kimi K2P5, 128K ctx) which is already registered in openclaw.json as an alias
- Alternatively, use the same `openai-codex/gpt-5.4` for cron if cost permits
- Reduce thinking from `"on"` to `"low"` or `"off"` for cron check-ins -- they only need to parse a JSON output and decide whether to send a message

### Priority 4: Deduplicate Cron Jobs

**Problem:** Runtime `jobs.json` contains duplicate entries: dev10 has 3 check-in jobs, dev10 has 3 check-in jobs.

**Evidence from runtime output:**
```
dev10 Check-in: every 7200s = 120min, model=fw-mm25
dev10 Check-in: every 7200s = 120min, model=fw-mm25
dev10 Check-in: every 7200s = 120min, model=fw-mm25
dev10 Check-in: every 7200s = 120min, model=fw-mm25
dev10 Check-in: every 7200s = 120min, model=fw-mm25
dev10 Check-in: every 7200s = 120min, model=fw-mm25
```

This wastes LLM API calls (3x per agent per cycle) and could cause resource contention. Clean up `jobs.json` or re-run `apply-cron.sh` after clearing stale entries.

### Priority 5: Enable Full Streaming

**Problem:** Slack streaming is set to `"partial"`. Users see nothing until a partial chunk is ready.

**Suggestion:**
- Change `"streaming": "partial"` to `"streaming": "full"` in the Slack channel config to show responses as they generate, reducing perceived latency even if actual latency is unchanged

### Priority 6: Address Compaction Churn

**Problem:** Compaction safeguard fires repeatedly on empty sessions, wasting cycles.

**Suggestion:**
- Investigate why sessions are being created without conversation messages (likely from cron jobs that output `NO_ACTION`)
- Consider `"compaction": { "mode": "off" }` for cron sessions, or use `sessionTarget: "isolated"` (already set) to prevent these from triggering compaction

---

## Latency Budget Estimate (Typical Interactive Message)

| Phase | Best Case | Worst Case | Notes |
|-------|-----------|------------|-------|
| Slack socket delivery | 50ms | 300s+ | Stale socket = missed entirely until reconnect |
| Gateway routing | 100ms | 700ms | Based on observed ws response times |
| Session bootstrap | 1s | 10s | Depends on memory file sizes |
| LLM inference (GPT-5.4) | 3s | 30s | Depends on prompt size and response length |
| Response streaming to Slack | 500ms | 5s | Partial streaming mode |
| **Total** | **~5s** | **~350s** | Huge variance due to socket issues |

**Typical case (no socket issues):** 5-15 seconds
**With stale socket:** Could be minutes of silence before any response

---

## Files Examined

- `/Users/<hostname>/.openclaw/openclaw.json` -- Global config
- `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json` -- Cron config source of truth
- `/Users/<hostname>/.openclaw/cron/jobs.json` -- Runtime cron (has duplicates)
- `/Users/<hostname>/.openclaw/logs/gateway.log` -- Gateway event log
- `/Users/<hostname>/.openclaw/logs/gateway.err.log` -- Gateway error/warning log
- `/tmp/openclaw/openclaw-2026-03-25.log` -- Detailed runtime log
- `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/poll-check.sh` -- Polling mechanism
- `/Users/<hostname>/openclaw-agents/types/dev-pa/HEARTBEAT.md` -- Heartbeat config (empty)
- `/Users/<hostname>/openclaw-agents/types/dev-pa/AGENTS.md` -- Agent operating manual
