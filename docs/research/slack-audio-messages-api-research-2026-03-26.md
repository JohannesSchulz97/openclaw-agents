# Slack Audio Messages API Research

**Date:** 2026-03-26
**Objective:** Determine how to send audio messages in Slack programmatically, including native voice clips, file uploads, and bot limitations. Assess feasibility for OpenClaw agents.

---

## Executive Summary

Slack does NOT provide a public API endpoint to create native voice clips (the inline audio recorder feature). The only viable programmatic approach is to **generate audio externally (e.g., via TTS) and upload it as an audio file** using Slack's new two-step upload API. Uploaded audio files (MP3, WAV, OGG, M4A) render as **inline playable audio players** in Slack -- not identical to native voice clips visually, but functionally equivalent.

For OpenClaw agents, the implementation path would be: **TTS generation (ElevenLabs/OpenAI) -> local audio file -> Slack upload via `openclaw message send` or direct API**.

---

## 1. Slack Native Audio/Voice Clips API

### What Are Voice Clips?

Slack introduced audio and video clips (up to 5 minutes) allowing users to record directly in the message composer. These appear as a distinctive embedded player with waveform visualization.

### API Availability: NONE

- There is **no Slack API endpoint** for creating native voice clips programmatically
- The `chat.postMessage` API does not support a voice clip attachment type
- The `calls.add` API is for managing live calls/huddles, not voice messages
- Slack's voice clip feature is **UI-only** -- the recording and encoding happen client-side
- No Slack changelog entries or developer docs reference a voice clip creation API

### Slack Huddles API: Also No Audio Access

Slack Huddles have no API access for recordings, transcripts, or metadata. Third-party services like Recall.ai have built workarounds for huddle recording, but these are not relevant for sending audio messages.

---

## 2. Uploading Audio Files via Slack API

### The Working Approach

Uploading audio files (MP3, WAV, OGG, M4A, FLAC, AAC) to Slack renders them as **inline playable audio** with a standard audio player widget. This is the most viable programmatic approach.

### New Upload API (Required -- Old API Deprecated)

The `files.upload` method was **fully sunset on November 12, 2025**. All apps must use the new two-step upload flow:

#### Step 1: Get Upload URL
```
POST https://slack.com/api/files.getUploadURLExternal
```
**Parameters:**
- `token` (required): Bot token with `files:write` scope
- `filename` (required): e.g., `message.mp3`
- `length` (required): File size in bytes

**Response:**
```json
{
  "ok": true,
  "upload_url": "https://files.slack.com/upload/v1/ABC123...",
  "file_id": "F123ABC456"
}
```

#### Step 2: Upload the file binary
```
POST <upload_url from step 1>
Content-Type: application/octet-stream
Body: <raw file bytes>
```

#### Step 3: Complete the upload and share to channel
```
POST https://slack.com/api/files.completeUploadExternal
```
**Parameters:**
- `token` (required): Bot token with `files:write` scope
- `files` (required): `[{"id": "F123ABC456", "title": "Voice Message"}]`
- `channel_id` (optional): Channel to share in (file stays private if omitted)
- `thread_ts` (optional): Reply in a thread
- `initial_comment` (optional): Text message accompanying the file

### SDK Convenience Methods

The SDKs wrap the three-step flow into a single call:

**Python (slack-sdk):**
```python
from slack_sdk import WebClient

client = WebClient(token="xoxb-...")
response = client.files_upload_v2(
    channel="C123456",
    file="/path/to/audio.mp3",
    title="Voice Message",
    initial_comment="Here's an audio update:"
)
```

**Node.js (@slack/web-api):**
```javascript
const { WebClient } = require('@slack/web-api');
const client = new WebClient('xoxb-...');

await client.filesUploadV2({
  channel_id: 'C123456',
  file: '/path/to/audio.mp3',
  filename: 'voice-message.mp3',
  title: 'Voice Message',
  initial_comment: 'Here is an audio update:',
});
```

### Required Bot Token Scopes
- `files:write` (required for upload)
- `chat:write` (required if posting to channels)
- `channels:read` or `groups:read` (if resolving channel names)

### Audio Formats That Render Inline

Slack renders an inline audio player for these formats:
- **MP3** (recommended -- universal support, small size)
- **WAV** (larger files, lossless)
- **OGG/Vorbis**
- **M4A/AAC**
- **FLAC**

MP3 is recommended for voice messages due to compact size and universal playback.

---

## 3. Bot Limitations

### What Bots CAN Do
- Upload audio files to channels they are members of
- Upload audio files to DMs with users who have the app installed
- Upload to threads using `thread_ts`
- Set `initial_comment` text alongside the audio file
- Upload to up to 100 channels in a single `completeUploadExternal` call

### What Bots CANNOT Do
- Create native voice clips (no API exists)
- Access or create Huddle recordings
- Upload files larger than workspace limits (varies by plan)
- Upload to channels the bot is not a member of
- Create the waveform visualization seen in native voice clips

### Bot vs. Human Differences
- Native voice clips are available to humans only (via the UI recorder)
- Bots can only upload audio as file attachments
- The visual presentation differs: file attachment player vs. native clip player
- Functionally, both are playable inline audio -- the difference is cosmetic

---

## 4. Alternative Approaches

### Approach A: TTS + File Upload (RECOMMENDED)

**Flow:**
1. Generate audio from text using a TTS API
2. Save to local file (MP3)
3. Upload to Slack via the file upload API

**TTS Options:**

| Provider | Quality | Latency | Cost | Notes |
|----------|---------|---------|------|-------|
| ElevenLabs | Excellent, natural | ~1-3s | $5-99/mo | Already referenced in agent config (`sag` tool) |
| OpenAI TTS | Very good | ~1-2s | $15/1M chars | `tts-1` or `tts-1-hd` models |
| Google Cloud TTS | Good | ~1s | Free tier + $4/1M chars | WaveNet voices |
| Amazon Polly | Good | ~1s | $4/1M chars | Neural voices |
| Azure Speech | Very good | ~1s | $15/1M chars | Neural voices |

**ElevenLabs Example (Python):**
```python
from elevenlabs import generate, save

audio = generate(
    text="Hey team, just a quick update on the project...",
    voice="Rachel",
    model="eleven_multilingual_v2"
)
save(audio, "voice_message.mp3")
```

**OpenAI TTS Example (Python):**
```python
from openai import OpenAI

client = OpenAI()
response = client.audio.speech.create(
    model="tts-1",
    voice="nova",
    input="Hey team, just a quick update on the project..."
)
response.stream_to_file("voice_message.mp3")
```

### Approach B: Pre-recorded Audio Library

For common messages (greetings, acknowledgments), pre-record audio clips and upload as needed. Lower cost but limited flexibility.

### Approach C: Third-Party Slack Apps

- **Voice Message App** (Slack Marketplace): Free, allows recording in Slack, but not API-controllable
- **Yac**: Voice messaging tool with Slack integration
- These are human-facing tools, not programmable by bots

### Approach D: Unfurl with Audio URL

Post a message containing a URL to a hosted audio file. Slack may unfurl it with a player depending on the hosting service. Less reliable than direct upload.

---

## 5. Current OpenClaw Agent Slack Integration

### How Agents Currently Send Messages

Based on prior research (`openclaw-slack-tool-investigation-2026-03-25.md`):

1. **Primary method:** `openclaw message send --channel slack --target <user-id> --message "text"`
2. **Fallback (used in cron):** Direct `curl` to Slack API with extracted bot token (security concern)
3. **No native `slack` tool** exists in the agent runtime -- the `slack` skill documents a tool that is not implemented

### Voice/Audio Capabilities

- AGENTS.md references `sag` (ElevenLabs TTS) for "voice storytelling"
- TOOLS.md templates mention TTS voice preferences
- The `sag` binary is **not currently installed** on the system
- No existing audio file upload workflow exists in the agent configuration

### Gap Analysis

| Capability | Current State | Needed |
|------------|--------------|--------|
| Send text to Slack | Working (`openclaw message send`) | Already available |
| Generate audio (TTS) | Referenced but not installed (`sag`) | Install TTS tool |
| Upload files to Slack | Not implemented | New capability needed |
| Native voice clips | Impossible (no API) | Accept file upload alternative |

---

## 6. Implementation Plan

### Phase 1: TTS Infrastructure (Prerequisite)

1. **Install a TTS tool.** Options:
   - Install `sag` (ElevenLabs CLI) -- already referenced in agent config
   - Use OpenAI TTS API via `curl` or Python script
   - Create a simple wrapper script in `types/dev-pa/scripts/`

2. **Configure API keys** in a secure location (not in agent-readable config files)

### Phase 2: Audio Upload to Slack

**Option A: Direct Slack API via curl (agent-driven)**

Create a script at `types/dev-pa/scripts/slack-audio-send.sh`:

```bash
#!/bin/bash
# Usage: slack-audio-send.sh <channel-or-user-id> <audio-file-path> [comment]
SLACK_TOKEN="${SLACK_BOT_TOKEN}"
CHANNEL="$1"
FILE_PATH="$2"
COMMENT="${3:-}"

FILE_SIZE=$(stat -f%z "$FILE_PATH" 2>/dev/null || stat -c%s "$FILE_PATH")
FILENAME=$(basename "$FILE_PATH")

# Step 1: Get upload URL
UPLOAD_RESPONSE=$(curl -s -X POST 'https://slack.com/api/files.getUploadURLExternal' \
  -H "Authorization: Bearer $SLACK_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"filename\": \"$FILENAME\", \"length\": $FILE_SIZE}")

UPLOAD_URL=$(echo "$UPLOAD_RESPONSE" | jq -r '.upload_url')
FILE_ID=$(echo "$UPLOAD_RESPONSE" | jq -r '.file_id')

# Step 2: Upload file
curl -s -X POST "$UPLOAD_URL" \
  -H 'Content-Type: application/octet-stream' \
  --data-binary "@$FILE_PATH"

# Step 3: Complete upload and share
curl -s -X POST 'https://slack.com/api/files.completeUploadExternal' \
  -H "Authorization: Bearer $SLACK_TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"files\": [{\"id\": \"$FILE_ID\", \"title\": \"Voice Message\"}], \"channel_id\": \"$CHANNEL\", \"initial_comment\": \"$COMMENT\"}"
```

**Option B: Extend OpenClaw messaging (preferred long-term)**

Check if `openclaw message send` supports file attachments. If not, file a feature request or use the direct API approach.

### Phase 3: End-to-End Agent Workflow

Update agent instructions to enable audio messaging:

```
To send a voice message:
1. Generate audio: openai-tts "Your message text" --voice nova --output /tmp/voice_msg.mp3
2. Upload to Slack: bash scripts/slack-audio-send.sh <slack-id> /tmp/voice_msg.mp3 "Voice update"
3. Clean up: rm /tmp/voice_msg.mp3
```

### Security Considerations

- The Slack bot token must be available to the upload script
- Currently, agents can extract the token from `~/.openclaw/openclaw.json` (documented security concern)
- Preferred: Use `openclaw` CLI if it supports file upload, or use environment variables set by the gateway
- Audio files in `/tmp/` should be cleaned up after upload

---

## 7. Comparison: Native Voice Clip vs. Uploaded Audio

| Feature | Native Voice Clip | Uploaded Audio File |
|---------|-------------------|---------------------|
| **API available** | No | Yes (files.upload v2) |
| **Visual appearance** | Waveform player, compact | Standard audio player widget |
| **Playback** | Inline | Inline |
| **Max duration** | 5 minutes | Workspace file size limit |
| **Transcription** | Auto-transcribed by Slack | Not auto-transcribed |
| **Bot-accessible** | No | Yes |
| **Mobile playback** | Native player | Standard player |

---

## 8. Recommendations

1. **Accept the file upload approach** -- native voice clips are not API-accessible and unlikely to become so
2. **Start with OpenAI TTS** -- lowest friction, no new account needed if OpenAI is already configured, high-quality `nova` voice matches the agent template preference
3. **Create a reusable script** in `types/dev-pa/scripts/` for TTS generation + Slack upload
4. **Address the token access pattern** -- either use `openclaw message send` with file attachment support (check if available), or establish a secure environment variable approach
5. **Update AGENTS.md and TOOLS.md** to document the audio message capability once implemented
6. **Consider Opus/ElevenLabs for premium quality** if the use case warrants it (storytelling, presentations)

---

## Sources

- [Slack: Send or schedule a message](https://api.slack.com/messaging/sending)
- [Slack: files.getUploadURLExternal](https://docs.slack.dev/reference/methods/files.getUploadURLExternal/)
- [Slack: files.completeUploadExternal](https://docs.slack.dev/reference/methods/files.completeUploadExternal/)
- [Slack: files.upload deprecation changelog](https://api.slack.com/changelog/2024-04-a-better-way-to-upload-files-is-here-to-stay)
- [Slack: Working with files](https://api.slack.com/messaging/files)
- [Slack: Create audio and video clips](https://slack.com/help/articles/4406235165587-Record-audio-and-video-clips-in-Slack)
- [Recall.ai: Slack Huddles recordings](https://www.recall.ai/blog/get-recordings-and-transcripts-from-slack-huddles-api)
- [api.audio: Create an Audio Message and Share on Slack](https://docs.api.audio/docs/create-an-audio-message-and-share-it-on-slack)
- [Voice Message Slack App](https://slack.com/marketplace/AE79QUZF0-voice-message)
- [slack-voice-messages (GitHub)](https://github.com/vadimdemedes/slack-voice-messages)
- Internal: `docs/research/openclaw-slack-tool-investigation-2026-03-25.md`
- Internal: `docs/research/openclaw-slack-routing-architecture-2026-03-25.md`
