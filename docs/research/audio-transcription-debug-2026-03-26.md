# Audio Transcription Config Debug Report

**Date:** 2026-03-26
**Status:** Research only -- no changes made

---

## Executive Summary

The audio transcription config (`tools.media.audio`) is correctly structured and present in `openclaw.json`. The whisper CLI is installed and functional. However, **no audio files have ever been downloaded to the media inbound directory** -- only two JPEG images from March 18 exist there. The gateway logs show zero evidence of audio file processing, transcription attempts, or file download errors for audio content.

The root cause is most likely one of two issues (ranked by probability):

1. **The Slack bot token lacks `files:read` scope** -- Slack audio/voice messages require this scope to download file content via `url_private_download`. Without it, OpenClaw silently fails to download the audio file, and the agent sees only a placeholder.
2. **The gateway was not fully restarted after the config change** -- The runtime log shows the config was applied dynamically (`[reload] config change applied ... tools.media`), but the audio-preflight pipeline may require a full process restart rather than a hot reload.

---

## Findings

### 1. Config Structure -- CORRECT

The audio config in `/Users/<hostname>/.openclaw/openclaw.json` (lines 170-189) is correctly structured:

```json
"tools": {
  "media": {
    "audio": {
      "enabled": true,
      "models": [
        {
          "provider": "cli",
          "command": "whisper",
          "args": ["{{MediaPath}}", "--model", "turbo", "--output_format", "txt", "--output_dir", "{{OutputDir}}"]
        }
      ]
    }
  }
}
```

`openclaw config get tools.media` confirms the config is read correctly. The `audio-preflight` source code (line 15-16) checks `cfg.tools?.media?.audio` and `audioConfig.enabled === false` -- both conditions are satisfied correctly.

There is **no separate top-level `tools.media.enabled` toggle** required. The config paths `tools.media.enabled`, `tools.media.download`, and `tools.media.inbound` all return "Config path not found", confirming these do not exist as config keys.

### 2. Whisper CLI -- INSTALLED AND FUNCTIONAL

```
/opt/homebrew/bin/whisper
```

The `whisper` binary is installed via Homebrew and responds to `--help` with the expected usage output including `--model`, `--output_format`, and `--output_dir` flags that match the config.

### 3. Media Inbound Directory -- NO AUDIO FILES

`/Users/<hostname>/.openclaw/media/inbound/` contains only two JPEG images from March 18:

```
file_0---596e6c11-8ebe-4dad-b15b-3e65a05b8b7f.jpg  (94KB, JPEG)
file_0---c3b9a56c-7093-4514-8639-387279f96187.jpg  (94KB, JPEG)
```

A recursive search for audio file extensions (`.ogg`, `.mp3`, `.m4a`, `.opus`, `.wav`, `.webm`, `.mp4`) across the entire `~/.openclaw/media/` directory returned zero results. **No audio file has ever been downloaded.**

### 4. Gateway Logs -- NO AUDIO/MEDIA ERRORS

**gateway.log:** The only media-related entry is the config reload:
```
2026-03-26T02:47:27.469+01:00 [reload] config change detected; evaluating reload (meta.lastTouchedAt, tools.media)
2026-03-26T02:47:27.475+01:00 [reload] config change applied (dynamic reads: meta.lastTouchedAt, tools.media)
```

**gateway.err.log:** Zero entries matching media, audio, whisper, transcription, voice, or file download. The error log contains unrelated web search provider errors (`mergeScopedSearchConfig is not a function`) and missing Slack skill files.

**Runtime logs (`/tmp/openclaw/openclaw-2026-03-26.log`):** The config set command was logged:
```
"Updated tools.media.audio. Restart the gateway to apply."
```

Note: The message says "Restart the gateway to apply" -- this was the CLI output when the config was set. The gateway.log shows the reload was applied dynamically, but this may not be sufficient for the full media pipeline.

**No `hasMedia: true` entries found** in any runtime log, meaning no inbound message was recognized as containing media that needed processing.

### 5. Slack Bot Token Scope -- CANNOT VERIFY DIRECTLY

The bot token (`xoxb-7586154609507-...`) is present in the config. The `files:read` scope cannot be verified from the config alone -- it must be checked in the Slack App management console at https://api.slack.com/apps.

**Why this matters:** The `resolveSlackMedia` function (found in the OpenClaw source) downloads files using:
```javascript
const url = file.url_private_download ?? file.url_private;
// ...
headers.set("Authorization", `Bearer ${token}`);
return fetch(parsed.href, { headers, redirect: "manual" });
```

If the bot token lacks `files:read`, the Slack API will either:
- Not include `url_private_download` in the file object
- Return an HTML error page when the download URL is fetched (OpenClaw checks for this and silently returns `null`)

The function has a catch-all `catch { return null; }` that silently swallows download failures, which explains why there are no error logs.

### 6. Slack Voice Message Handling -- SOURCE CODE ANALYSIS

The OpenClaw source has explicit handling for Slack voice messages:

```javascript
// Slack voice messages carry subtype "slack_audio" but are served with video/* MIME
if (file.subtype === "slack_audio" && mime?.startsWith("video/"))
    return mime.replace("video/", "audio/");
```

This means the code path exists and should work IF the file is downloadable. The `isAudioAttachment` function checks the MIME type and file extension to classify attachments.

### 7. Config Reload vs Full Restart

The gateway log shows the config was applied via dynamic reload. However, the `audio-preflight` module is imported at startup and may not be re-initialized on hot reload. The runtime log message explicitly stated "Restart the gateway to apply."

---

## Diagnosis

The pipeline for audio transcription is:

```
Slack message with audio
  -> Slack event received (message subtype: file_share)
  -> resolveSlackMessageContent() extracts files from message
  -> resolveSlackMedia() downloads each file via url_private_download
  -> saveMediaBuffer() saves to ~/.openclaw/media/inbound/
  -> Context built with MediaPath, MediaType, MediaUrls
  -> audio-preflight: transcribeFirstAudio() called
  -> isAudioAttachment() matches by MIME/extension
  -> runAudioTranscription() invokes whisper CLI
  -> Transcript injected into agent context
```

The pipeline is breaking at step 3 (file download). No audio files reach the inbound directory, so nothing downstream can run. The silent `catch { return null; }` in `resolveSlackMedia` means failures are invisible.

---

## Concrete Next Steps (prioritized)

### Step 1: Verify Slack bot token scopes (HIGH PRIORITY)

Go to https://api.slack.com/apps, find the app using bot token `xoxb-7586154609507-*`, and check that these OAuth scopes are present:

- `files:read` -- **required** to download file content from Slack
- `files:write` -- needed if agents will upload files

If `files:read` is missing, add it under "OAuth & Permissions" and reinstall the app to the workspace.

### Step 2: Full gateway restart (HIGH PRIORITY)

The `openclaw gateway restart` command was run, but confirm it was a full process restart and not just a SIGHUP/reload:

```bash
# Kill and restart fully
openclaw gateway stop
openclaw gateway start
```

Or check if the gateway PID changed after the restart.

### Step 3: Enable verbose logging and test (MEDIUM PRIORITY)

Enable verbose logging to see the audio-preflight pipeline in action:

```bash
# Set verbose logging
export OPENCLAW_VERBOSE=1
# Or in config
openclaw config set gateway.verbose true
```

Then send a voice message in Slack and look for:
- `audio-preflight: transcribing attachment`
- `slack: filtered ... inherited parent file(s)`
- Any fetch errors for `slack-files.com` URLs

### Step 4: Test file download manually (MEDIUM PRIORITY)

Send any file (not just audio) in a Slack DM to an agent and check if it appears in `~/.openclaw/media/inbound/`. If regular files also fail to download, the issue is definitely the bot token scope, not audio-specific.

### Step 5: Check Slack event payload (LOW PRIORITY)

If scopes are correct and files still don't download, inspect the raw Slack event to verify the `files` array is present in the message payload and contains `url_private_download`. This can be done via the Slack API Event Subscriptions debug view or by adding temporary logging.

---

## Related Observations

- The two JPEG files in `media/inbound/` are from March 18 (before the audio config was applied on March 26), confirming that image file downloads DO work, which suggests `files:read` scope IS present for at least some file types.
- However, Slack voice messages (`slack_audio` subtype) may require additional event subscriptions or behave differently from regular file uploads.
- OpenClaw version 2026.3.13 is installed, which is the current version per CLAUDE.md.
