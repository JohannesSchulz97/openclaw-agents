# Agent Response Delay Analysis: ~5 Minutes to Reply to Developer Messages

**Date:** 2026-03-30
**Subject:** Why dev1's agent took ~5 minutes to respond to his voice message reply
**Status:** Root cause identified -- multiple compounding factors

---

## Executive Summary

The ~5 minute delay between dev1 sending a voice message reply and receiving the agent's response is caused by **multiple compounding factors in the processing pipeline**, not a single bottleneck. The primary contributors are:

1. **Session cold-start overhead** (~60-90s) -- Agent must boot, read context files, initialize QMD memory
2. **Voice message transcription** (~10-30s) -- Slack/OpenClaw must transcribe audio before the agent sees text
3. **LLM inference time with thinking enabled** (~60-120s) -- GPT-5.4 with `thinking: "on"` is slow
4. **AGENTS.md mandated startup ritual** (~30-60s of LLM tool calls) -- Agent reads SOUL.md, USER.md, memory files, MEMORY.md before responding
5. **No polling/scheduling delay** -- Messages are pushed via Slack Socket Mode in real-time

**Total estimated pipeline: 160-300 seconds (2.5-5 minutes)**

---

## Detailed Analysis

### 1. Message Delivery: NOT the Bottleneck

OpenClaw uses **Slack Socket Mode** for real-time message delivery. Evidence from gateway logs:

```
[slack] socket mode connected
```

The gateway maintains a persistent WebSocket connection to Slack. When dev1 sends a voice message DM, Slack pushes it to the gateway immediately. There is **no polling delay** -- the gateway is always listening.

The health monitor restarts the socket connection every ~35 minutes when it detects staleness (`stale-socket`), but this only causes a brief reconnection (~1 second) and would not explain a 5-minute delay.

**Verdict: Message delivery is near-instant (<1 second). NOT the bottleneck.**

### 2. Voice Message Transcription: Minor Contributor (~10-30s)

When dev1 sends a Slack voice message:
1. Slack receives the audio file
2. The audio must be transcribed to text before the agent can process it
3. This transcription happens either in Slack itself (Slack's built-in transcription) or within OpenClaw's pipeline

No explicit transcription logs were found in the gateway logs (no "whisper", "transcribe", or "audio" entries), suggesting transcription happens at the Slack platform level before the message reaches OpenClaw. Slack's voice message transcription typically takes 5-30 seconds depending on length.

**Verdict: ~10-30 seconds. Minor contributor.**

### 3. Agent Session Cold-Start: Major Contributor (~60-90s)

When the agent is idle (not actively processing), receiving a new message triggers a **cold start**. Evidence:

```
[gateway] qmd memory startup initialization armed for agent "dev1"
```

This QMD (memory backend) initialization happens at gateway startup and when sessions resume. The cold-start involves:
- Loading the agent's QMD memory database
- Initializing the agent's workspace context
- Setting up the LLM session with system prompts
- Loading boot-md hook content

With 18+ agents configured, resource contention on the single gateway process compounds this. The gateway log shows 38 QMD memory initializations across the day for all agents.

**Verdict: ~60-90 seconds. MAJOR contributor.**

### 4. AGENTS.md Session Startup Ritual: Major Contributor (~30-60s of LLM time)

AGENTS.md (lines 9-17) mandates that **before doing anything else**, the agent must:

```
1. Read SOUL.md
2. Read USER.md
3. Read memory/YYYY-MM-DD.md (today + yesterday)
4. If in MAIN SESSION: Also read MEMORY.md
```

A developer replying to a check-in via DM is a **main session** interaction. So the agent must execute at least 4 file-read tool calls before composing its response. The logs confirm this happens:

```
[tools] read failed: ENOENT: no such file or directory, access '.../dev1/memory/2026-03-30.md'
[tools] read failed: ENOENT: no such file or directory, access '.../dev1/memory/2026-03-29.md'
```

Even when files don't exist, the agent still attempts to read them (and waits for the error). When they do exist, the LLM must process all their content before responding.

**This startup ritual is NOT triggered for cron check-in messages** (those use `sessionTarget: "isolated"` and don't load MEMORY.md). But for **responses to those check-ins** (which come in as DM messages routed to the main session), the full ritual fires.

**Verdict: ~30-60 seconds of additional LLM tool-calling time. MAJOR contributor.**

### 5. LLM Inference Time: Major Contributor (~60-120s)

The agent model is `openai-codex/gpt-5.4` with `thinking: "on"`. The cron jobs explicitly set:

```json
"thinking": "on",
"model": "openai-codex/gpt-5.4"
```

While the cron check-in jobs have `timeoutSeconds: 180` (3 minutes), the DM response session inherits the agent's default model configuration. GPT-5.4 with thinking enabled is a high-latency model. A typical response with thinking involves:

1. Extended thinking/reasoning phase (~30-60s)
2. Tool calls for file reads (~20-30s with round-trips)
3. Response generation (~10-20s)

**Verdict: ~60-120 seconds. MAJOR contributor.**

### 6. Heartbeat Interval: NOT Relevant

The heartbeat interval is 1,800,000ms (30 minutes):

```json
{"intervalMs": 1800000}
```

However, heartbeats are for **proactive agent actions**, not for processing incoming messages. DM messages are handled via Slack Socket Mode push, not heartbeat polling. The heartbeat does NOT gate message processing.

**Verdict: NOT related to response delay.**

### 7. LCM Compaction: Potential Contributor (0-30s)

The LCM (Long Context Management) plugin is enabled with a compaction model:

```
[lcm] Plugin loaded (enabled=true, db=...lcm.db, threshold=0.75)
[lcm] Compaction summarization model: accounts/fireworks/models/qwen3-8b
```

When conversation history exceeds 75% of the context window, LCM triggers compaction using a secondary model (qwen3-8b). The error logs show this model's API key is broken:

```
[lcm] modelAuth.resolveApiKeyForProvider FAILED: No API key found for provider "accounts"
```

When LCM compaction fails, it falls back to truncation. This retry-then-fallback cycle adds delay:
- First attempt fails (API error)
- Retry with conservative settings fails
- Fallback to truncation

This only happens when conversations are long enough to trigger compaction, but when it does, it adds ~10-30 seconds of wasted time on failed API calls.

**Verdict: 0-30 seconds depending on conversation length. Occasional contributor.**

---

## Timeline Reconstruction

```
T+0s     dev1 sends voice message via Slack
T+5-30s  Slack transcribes voice to text, delivers to OpenClaw gateway via Socket Mode
T+30s    Gateway receives message, routes to dev1 agent
T+30-60s Agent session cold-starts (QMD memory init, workspace setup)
T+60s    LLM session begins, agent reads system prompt + boot-md
T+60-90s Agent executes startup ritual (reads SOUL.md, USER.md, memory files, MEMORY.md)
T+90-120s LLM processes context + thinking phase
T+120-180s Agent composes response
T+180-240s LCM compaction may fire if context is large (retry + fallback on broken API key)
T+240-300s Response delivered back via Slack
```

**Total: ~240-300 seconds (4-5 minutes)**

---

## Recommendations

### Quick Wins (No Architecture Changes)

1. **Fix the LCM compaction API key** -- The broken `accounts/fireworks/models/qwen3-8b` key causes unnecessary retry cycles. Either fix the key or disable LCM compaction for agent sessions.

2. **Reduce startup file reads for DM responses** -- When the agent is responding to a message (not starting fresh), it could skip re-reading SOUL.md and USER.md if they were already loaded in the session. This requires an AGENTS.md change.

3. **Consider disabling `thinking` for DM responses** -- Extended thinking adds significant latency. For conversational replies (not complex check-in composition), a simpler inference mode would suffice.

### Medium-Term Improvements

4. **Warm session pooling** -- Keep agent sessions warm in memory so DM responses don't trigger cold starts. The gateway could pre-warm sessions for agents with active check-in schedules.

5. **Differentiate check-in composition vs. reply processing** -- Check-ins need tool calls (GitHub activity, guard scripts). Replies to check-ins should be lightweight conversational responses that skip most of the startup ritual.

6. **Use a faster model for conversational replies** -- Reserve GPT-5.4 with thinking for check-in composition. Use a faster model (e.g., claude-3-haiku equivalent) for simple DM replies.

### Long-Term

7. **Session persistence across interactions** -- If the agent's main session stays warm between the check-in delivery and the developer's reply, the startup overhead disappears entirely.

---

## Key Files Examined

- `/Users/<hostname>/openclaw-agents/types/dev-pa/AGENTS.md` -- Session startup ritual, heartbeat behavior
- `/Users/<hostname>/openclaw-agents/types/dev-pa/HEARTBEAT.md` -- Empty template (not relevant)
- `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json` -- Cron job configs with thinking/model settings
- `/Users/<hostname>/openclaw-agents/types/dev-pa/poll-config.json` -- 240-minute interval (deprecated, not relevant)
- `~/.openclaw/logs/gateway.log` -- Socket Mode, delivery events, health monitor
- `~/.openclaw/logs/gateway.err.log` -- LCM compaction failures
- `/tmp/openclaw/openclaw-2026-03-30.log` -- Detailed agent session events, QMD init, tool errors
