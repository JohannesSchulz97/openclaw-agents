# OpenClaw Slack Streaming Modes

**Date:** 2026-03-26
**Type:** Informational Research
**Status:** Complete

## Summary

The `channels.slack.streaming` setting controls **live preview behavior** -- how the
user sees the response while the model is still generating. There is a separate
`channels.slack.nativeStreaming` boolean that controls whether Slack's native
streaming API is used for the `partial` mode.

**Important caveat from OpenClaw docs:** "There is no true token-delta streaming to
channel messages today. Preview streaming is message-based (send + edits/appends)."

---

## The Six Valid Values

### Canonical Enum Values (current)

| Value | Behavior | UX Description |
|------------|-------------------------------------------------------|--------------------------------------------------|
| `"off"` | No live preview. User waits for the complete response. | Nothing visible until full reply lands. |
| `"partial"` | Single preview message, continuously replaced with the latest partial output. | User sees a single message bubble that keeps updating in-place as tokens arrive. Feels like watching someone type. **Default.** |
| `"block"` | Preview updates in chunked/appended steps. | User sees text appended in bursts (chunks), not a smooth stream. Multiple preview updates rather than one continuously replacing message. |
| `"progress"` | Status/progress text displayed during generation, then replaced with the final answer. | User sees a "thinking..." or status indicator, then the complete answer appears all at once. Slack-only feature (Telegram/Discord map this to `partial`). |

### Legacy Boolean Values (auto-migrated)

| Value | Maps To | Notes |
|---------|-----------|----------------------------------------------|
| `true` | `"partial"` | Legacy config compatibility. |
| `false` | `"off"` | Legacy config compatibility. Also sets `nativeStreaming: false`. |

Source code confirms the migration logic:

```javascript
// From openclaw dist/reply-Bm8VrLQh.js
if (typeof params.streaming === "boolean")
  return params.streaming ? "partial" : "off";
```

### Legacy `streamMode` Values (auto-migrated)

The old `channels.slack.streamMode` key used different names:

| Legacy `streamMode` | Maps To (new `streaming`) |
|----------------------|---------------------------|
| `"replace"` | `"partial"` |
| `"status_final"` | `"progress"` |
| `"append"` | `"block"` |

---

## Detailed Mode Behavior

### `"off"` -- No Preview

- The user sees nothing until the complete response is ready.
- No typing indicator, no preview, no streaming.
- Useful for suppressing visual noise on automated/cron-triggered messages.
- Avoids known bugs with native streaming in threads (Issue #52536).

### `"partial"` -- Continuous In-Place Replacement (Default)

- A single preview message is posted when the first text chunk arrives.
- That same message is continuously updated/replaced with the latest accumulated text.
- When `nativeStreaming: true` (the default), this uses Slack's native Agents & AI Apps
  streaming API:
  - `chat.startStream` -- initiates the stream on first chunk
  - `chat.appendStream` -- appends subsequent chunks to the same stream
  - `chat.stopStream` -- finalizes the stream when the reply is complete
- When `nativeStreaming: false`, the preview is done via regular message send + edit
  (less smooth, more API calls, but avoids native streaming prerequisites).
- **Requirements for native streaming:**
  1. Agents and AI Apps enabled in Slack app settings
  2. Bot must have `assistant:write` scope
  3. Reply thread must be available (governed by `replyToMode`)
- Media and non-text payloads fall back to normal delivery.
- If streaming fails mid-reply, OpenClaw falls back to normal delivery.

**This is the closest thing to "real-time typing" available.** The user sees text
appearing progressively in a single message bubble.

### `"block"` -- Chunked/Appended Preview

- Instead of continuously replacing a single message, text is appended in distinct
  chunks as the model generates.
- Uses append-style draft previews.
- Chunk size is controlled by `draftChunk` settings (minChars, maxChars).
- Default coalesce `minChars` is 1500 for Slack to reduce "single-line spam."
- Creates a different UX than `partial`: instead of smooth updates, the user sees
  bursts of text added.
- **Known issue:** When `blockStreamingDefault: "on"` is enabled, messages in Slack
  can be deleted after the stream completes (Issue #20814).

### `"progress"` -- Status Then Final (Slack-Only)

- During generation, the user sees a progress/status indicator text.
- Once the model finishes, the status text is replaced with the final complete answer.
- This is a Slack-specific feature. On Telegram and Discord, `"progress"` maps to
  `"partial"` at runtime.
- Good for long-running generations where partial text would be confusing.

---

## The `nativeStreaming` Setting

Separate from the `streaming` mode, `channels.slack.nativeStreaming` (boolean,
default: `true`) controls whether Slack's native streaming API is used **specifically
when `streaming` is `"partial"`**.

| `streaming` | `nativeStreaming` | Effect |
|-------------|-------------------|--------|
| `"partial"` | `true` (default) | Uses Slack native API (startStream/appendStream/stopStream). Smoothest UX. |
| `"partial"` | `false` | Uses message send + edit fallback. Works without Agents & AI Apps. |
| `"block"` | (ignored) | Block mode does not use native streaming. |
| `"progress"` | (ignored) | Progress mode does not use native streaming. |
| `"off"` | (ignored) | No streaming at all. |

---

## Recommendation for Real-Time Slack Conversations

**Best UX for seeing the response as it generates:**

```yaml
channels:
  slack:
    streaming: partial
    nativeStreaming: true
```

This is already the default configuration. It provides:

- Continuous in-place message updates as tokens arrive
- Uses Slack's native streaming API for the smoothest experience
- The closest approximation to "watching someone type"

**There is no "full" or token-level streaming mode.** All preview streaming in
OpenClaw is message-based (send + edits/appends), not true token-delta streaming.
The `"partial"` mode with `nativeStreaming: true` is as real-time as it gets.

If `partial` with native streaming is already configured (which it is for our
agents), the primary levers for improving perceived responsiveness are:

1. Reducing model latency (faster time-to-first-token)
2. Ensuring Agents & AI Apps is properly enabled in Slack
3. Ensuring `assistant:write` scope is granted
4. Keeping `nativeStreaming: true` (avoid the send+edit fallback)

---

## Current Agent Configuration

Our agents are currently configured with `"streaming": "partial"` in the Slack
channel config (confirmed in `openclaw.json`). This is already the optimal setting
for real-time conversational UX.

---

## Sources

- OpenClaw source: `/Users/<hostname>/Library/pnpm/global/5/node_modules/openclaw/docs/channels/slack.md` (lines 541-581)
- OpenClaw source: `/Users/<hostname>/Library/pnpm/global/5/node_modules/openclaw/docs/concepts/streaming.md` (full file)
- OpenClaw source: `/Users/<hostname>/Library/pnpm/global/5/node_modules/openclaw/dist/reply-Bm8VrLQh.js` (migration logic, lines 3008-3049)
- OpenClaw source: `/Users/<hostname>/Library/pnpm/global/5/node_modules/openclaw/dist/redact-snapshot-3SwEUYfq.js` (config descriptions, lines 872-874)
- [Slack - OpenClaw Docs](https://docs.openclaw.ai/channels/slack)
- [Streaming and Chunking | OpenClaw Docs](https://openclaws.io/docs/concepts/streaming)
- [Configuration Reference | OpenClaw Docs](https://openclaws.io/docs/gateway/configuration-reference)
- [GitHub Issue #20814 - Block streaming messages deleted](https://github.com/openclaw/openclaw/issues/20814)
- [GitHub Issue #52536 - Thread streaming bug](https://github.com/openclaw/openclaw/issues/52536)
