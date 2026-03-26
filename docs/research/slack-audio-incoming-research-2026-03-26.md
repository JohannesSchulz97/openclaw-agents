# Slack Audio Incoming Messages: Why Agents Cannot Access Voice Clips

**Date:** 2026-03-26
**Objective:** Determine why OpenClaw agents cannot access Slack voice clip (audio message) file bytes, and identify the minimal fix.

---

## Executive Summary

OpenClaw **already has full infrastructure** to download Slack file attachments (including audio), resolve their MIME types correctly for voice clips, and route audio through a transcription pipeline. The problem is that **audio transcription is not configured**. The `tools.media.audio` config section is entirely absent from `openclaw.json`, which means the media-understanding pipeline has no transcription provider to use. When a Slack voice clip arrives, OpenClaw downloads the file to `~/.openclaw/media/inbound/` but cannot transcribe it because no audio model is configured.

**The minimal fix is a single config change:**

```bash
openclaw config set tools.media.audio.enabled true
openclaw config set tools.media.audio.models '[{"provider":"openai","model":"gpt-4o-mini-transcribe"}]'
```

Or, if preferring local transcription via the already-installed Whisper CLI:

```bash
openclaw config set tools.media.audio.enabled true
openclaw config set tools.media.audio.models '[{"provider":"cli","command":"whisper","args":["{{MediaPath}}","--model","turbo","--output_format","txt","--output_dir","{{OutputDir}}"]}]'
```

---

## 1. How OpenClaw Receives Slack Messages

### Message Flow

1. **Socket Mode connection**: OpenClaw connects to Slack via Socket Mode (`channels.slack.mode: "socket"`, `appToken` configured). This receives all events in real time without a public webhook endpoint.

2. **Routing**: `openclaw.json` contains `bindings` that route DMs from specific Slack users to specific agents. For example, messages from `<slack-id>` are routed to agent `dev1`.

3. **Message normalization**: When a Slack message arrives, `resolveSlackMessageContent()` processes it:
   - Extracts message text
   - Calls `resolveSlackMedia()` to download any attached files
   - Generates placeholders like `[media attached: audio_message.m4a]`
   - Passes the combined content to the agent session

4. **File download**: `resolveSlackMedia()` handles file attachments by:
   - Reading `url_private_download` or `url_private` from each file object
   - Fetching the file bytes using the bot token for authentication
   - Saving to `~/.openclaw/media/inbound/` with a UUID-based filename
   - Resolving MIME type (with special handling for Slack audio -- see below)

### Slack Voice Clip Special Handling

OpenClaw has explicit code for Slack voice messages:

```javascript
// From dist/reply-Bm8VrLQh.js line 45500-45507
// Slack voice messages (audio clips, huddle recordings) carry a `subtype` of
// `"slack_audio"` but are served with a `video/*` MIME type (e.g. `video/mp4`,
// `video/webm`).  Override the primary type to `audio/` so the
// media-understanding pipeline routes them to transcription.
function resolveSlackMediaMimetype(file, fetchedContentType) {
    const mime = fetchedContentType ?? file.mimetype;
    if (file.subtype === "slack_audio" && mime?.startsWith("video/"))
        return mime.replace("video/", "audio/");
    return mime;
}
```

This means OpenClaw already knows about Slack voice clips and correctly reclassifies them as audio (not video) so the transcription pipeline handles them.

---

## 2. The Media Understanding Pipeline

OpenClaw has a sophisticated media-understanding system that can process images, audio, and video attachments:

### Audio Transcription Providers (Built-in)

| Provider | Default Model | Requirements |
|----------|--------------|--------------|
| `openai` | `gpt-4o-mini-transcribe` | OpenAI API key |
| `groq` | `whisper-large-v3-turbo` | Groq API key |
| `deepgram` | `nova-3` | Deepgram API key |
| `google` | (via Generative AI) | Google API key |
| `mistral` | `voxtral-mini-latest` | Mistral API key |
| `cli` (whisper) | Local whisper binary | `whisper` installed locally |

### Auto-detection

OpenClaw has a list of `AUTO_AUDIO_KEY_PROVIDERS` (`openai`, `groq`, `deepgram`, `google`, `mistral`) that it can potentially auto-configure if API keys are present. However, the auto-detection requires `tools.media.audio.enabled` to be set.

### CLI Entry (Local Whisper)

The pipeline also supports CLI-based transcription. For the `whisper` command, it:
1. Saves the media to a temp path
2. Runs `whisper {{MediaPath}} --model turbo --output_format txt --output_dir {{OutputDir}}`
3. Reads the output file
4. Returns the transcription text

The `whisper` binary **is already installed** at `/opt/homebrew/bin/whisper` (confirmed).

---

## 3. Current Configuration State

### What is configured (working)

- Slack channel: `enabled: true`, Socket Mode active, bot token present
- Slack routing bindings: All 6 agents correctly routed
- Media inbound directory: `~/.openclaw/media/inbound/` exists, has previously downloaded files (JPGs)
- Whisper CLI: Installed at `/opt/homebrew/bin/whisper`
- openai-whisper skill: Installed at `/Users/<hostname>/openclaw/skills/openai-whisper/`

### What is NOT configured (the gap)

```bash
$ openclaw config get tools.media.audio
Config path not found: tools.media.audio
```

The entire `tools.media.audio` section is missing from `openclaw.json`. Current tools config:

```json
{
  "profile": "coding",
  "web": {
    "search": {
      "enabled": true,
      "provider": "brave"
    }
  }
}
```

No `media` key exists at all. This means:
- Audio files are **downloaded** (the Slack adapter does this automatically)
- Audio files are **correctly typed** as audio (the MIME override works)
- Audio files are **NOT transcribed** (no provider configured)
- The agent sees a placeholder like `[media attached: audio_message.m4a]` but gets no transcription
- The agent may also have the file path in `~/.openclaw/media/inbound/` but without transcription, the content is inaccessible to a text-only LLM

---

## 4. The Agent's Perspective

### What the agent currently sees

When a user sends a Slack voice clip, the agent receives something like:

```
[media attached: audio_message.m4a]
```

Or possibly:

```
[Slack file: audio_message.m4a]
```

The agent has no transcription, no readable text content from the audio.

### Available tools for the agent

The agent **does** have access to:

1. **`downloadFile` Slack action**: A built-in tool that can download a Slack file by ID to local storage. This is registered in `slack-actions.ts` and takes `fileId`, `channelId`, and `threadId` parameters. However, this only gives the agent the raw file -- not a transcription.

2. **`whisper` CLI**: Installed locally, the agent could theoretically run `whisper /path/to/audio.m4a --model turbo --output_format txt` to transcribe it manually. But this is a manual workaround, not the intended flow.

3. **`openclaw message send --media`**: The send command supports `--media <path-or-url>` for outbound messages, but this is for sending, not receiving.

### What the agent cannot do

- The agent does not know the Slack bot token (it is redacted by `openclaw config get`)
- The agent cannot directly call `url_private` to download files (the token is needed)
- Without `tools.media.audio` configured, the automatic transcription pipeline is dormant

---

## 5. The `downloadFile` Tool

OpenClaw exposes a `downloadFile` action as part of the Slack tools available to agents:

```javascript
case "downloadFile": {
    const fileId = readStringParam(params, "fileId", { required: true });
    // ... resolves channel context, downloads file via files.info API
    const downloaded = await downloadSlackFile(fileId, { ...readOpts, maxBytes, channelId, threadId });
    // Returns the file as an image/media result with local path
}
```

This tool:
- Fetches a fresh download URL via `files.info` (avoids stale `url_private` URLs)
- Downloads the file using the bot token (handled internally)
- Saves to local media storage
- Returns the result to the agent (path + placeholder)

However, for audio files, the agent still gets a file path -- not a transcription. The agent would need to run `whisper` on it manually.

---

## 6. End-to-End Fix Options

### Option A: Configure tools.media.audio (RECOMMENDED -- Minimal Fix)

This enables the automatic transcription pipeline. When a Slack message with an audio attachment arrives, OpenClaw will:
1. Download the file (already working)
2. Detect it as audio (already working, including the `slack_audio` MIME fix)
3. Send it to the configured transcription provider
4. Include the transcription text in the message delivered to the agent

**Using OpenAI API (if OpenAI key available):**

```bash
openclaw config set tools.media.audio.enabled true
openclaw config set tools.media.audio.models '[{"provider":"openai","model":"gpt-4o-mini-transcribe"}]'
```

**Using Groq (fast, free tier available):**

```bash
openclaw config set tools.media.audio.enabled true
openclaw config set tools.media.audio.models '[{"provider":"groq","model":"whisper-large-v3-turbo"}]'
```

**Using local Whisper CLI (no API key, already installed):**

```bash
openclaw config set tools.media.audio.enabled true
openclaw config set tools.media.audio.models '[{"provider":"cli","command":"whisper","args":["{{MediaPath}}","--model","turbo","--output_format","txt","--output_dir","{{OutputDir}}"]}]'
```

**Using Google Gemini (key already in openclaw.json):**

```bash
openclaw config set tools.media.audio.enabled true
openclaw config set tools.media.audio.models '[{"provider":"google"}]'
```

After setting this, restart the OpenClaw gateway (`openclaw gateway restart` or equivalent).

### Option B: Agent-side manual transcription (workaround)

Without configuring the pipeline, the agent can work around the issue:

1. When receiving `[media attached: audio_message.m4a]`, use the `downloadFile` Slack action to get the file locally
2. Run `whisper <path> --model turbo --output_format txt --output_dir /tmp/` to transcribe
3. Read the output text file

This is fragile and requires the agent to know the `fileId` (which may not be in the message metadata it receives). Not recommended as a permanent solution.

### Option C: Hook/middleware for auto-transcription (unnecessary)

A pre-processing hook that intercepts audio messages and transcribes them before passing to the agent. This is exactly what `tools.media.audio` already does -- no custom middleware needed.

---

## 7. API Key Availability for Transcription

Checking what keys are already configured that could power transcription:

| Provider | Key Available | Notes |
|----------|--------------|-------|
| OpenAI (via openai-codex) | Yes (OAuth) | `auth.profiles.openai-codex:default` is configured. May need separate API key for audio endpoint. |
| Google | Yes | `AIzaSyB...` key in `models.providers.google` section |
| Groq | Unknown | No key visible in config |
| Deepgram | Unknown | No key visible in config |
| Local Whisper | Yes (installed) | `/opt/homebrew/bin/whisper` -- no API key needed |

**Recommended provider priority:**
1. **Local Whisper CLI** -- zero cost, already installed, no API key needed
2. **Google** -- key already configured, good quality
3. **OpenAI** -- excellent quality, may need explicit API key setup

---

## 8. Verification Steps After Fix

After applying the config change:

1. **Restart OpenClaw gateway** to pick up config changes
2. **Send a voice clip** via Slack to one of the agent DMs
3. **Check the agent's received message** -- it should now include transcription text alongside the media placeholder
4. **Check logs** for any transcription errors: `openclaw logs --level debug | grep -i audio`
5. **Verify the media/inbound directory** has the downloaded audio file

---

## 9. Summary of Findings

| Question | Answer |
|----------|--------|
| Does OpenClaw download Slack file attachments? | **Yes** -- automatically via `resolveSlackMedia()` |
| Does it handle Slack voice clips specifically? | **Yes** -- `resolveSlackMediaMimetype()` fixes MIME type for `slack_audio` subtype |
| Why can't agents access audio content? | **`tools.media.audio` is not configured** -- transcription pipeline is dormant |
| Is Whisper installed? | **Yes** -- `/opt/homebrew/bin/whisper` |
| What is the minimal fix? | **Single config change**: enable `tools.media.audio` with a provider |
| Does the agent need a script to download files? | **No** -- OpenClaw handles download automatically; agent also has `downloadFile` tool as fallback |
| Is a hook/middleware needed? | **No** -- the built-in media understanding pipeline handles this |
| Where is the bot token? | In `openclaw.json` under `channels.slack.botToken` -- agents cannot read it directly (redacted by `config get`) but OpenClaw uses it internally |

---

## 10. Recommended Action

**Immediate (5 minutes):** Add `tools.media.audio` config using local Whisper CLI:

```bash
openclaw config set tools.media.audio '{"enabled":true,"models":[{"provider":"cli","command":"whisper","args":["{{MediaPath}}","--model","turbo","--output_format","txt","--output_dir","{{OutputDir}}"]}]}'
```

Then restart the gateway. Voice clips will be automatically transcribed and the text delivered to agents.

**Follow-up:** Consider adding a cloud provider (OpenAI, Google) as fallback for faster transcription or when the machine is under load from local Whisper inference.

---

## Sources

- OpenClaw source: `dist/reply-Bm8VrLQh.js` (v2026.3.13) -- Slack media resolution, audio MIME fix, transcription pipeline, downloadFile tool
- OpenClaw config: `~/.openclaw/openclaw.json` -- current configuration state
- OpenClaw CLI: `openclaw config get tools` -- confirmed `tools.media.audio` is absent
- Local system: `which whisper` confirmed at `/opt/homebrew/bin/whisper`
- Whisper skill: `/Users/<hostname>/openclaw/skills/openai-whisper/SKILL.md`
- Related research: `docs/research/slack-audio-messages-api-research-2026-03-26.md` (outbound audio -- complementary)
