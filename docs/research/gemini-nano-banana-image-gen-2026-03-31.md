# Research: Gemini Nano Banana Image Generation (Issue #40)

**Date:** 2026-03-31
**Status:** Actionable - Implementation planning
**Related Issue:** #40

---

## 1. Credentials File Structure

**Location:** `~/.openclaw/credentials/gemini-nano-banana.json`

**Structure (4 fields):**
```json
{
  "provider": "gemini",
  "model_default": "nano-banana-2",
  "model_fallback": "nano-banana-pro",
  "api_key": "<REDACTED>"
}
```

- `provider` - Fixed string "gemini"
- `model_default` - Friendly name "nano-banana-2" (maps to model ID `gemini-3.1-flash-image-preview`)
- `model_fallback` - Friendly name "nano-banana-pro" (maps to model ID `gemini-3-pro-image-preview`)
- `api_key` - Google AI API key (AIza... format)

**Model ID Mapping (required for API calls):**
| Friendly Name | API Model ID | Price/Image | Speed |
|---|---|---|---|
| nano-banana-2 | `gemini-3.1-flash-image-preview` | ~$0.05 (std) / ~$0.15 (4K) | 4-6s |
| nano-banana-pro | `gemini-3-pro-image-preview` | ~$0.134 | Slower, higher quality |

---

## 2. Existing Image Generation Code in Codebase

**Finding: NONE.** There are zero existing image generation scripts, utilities, or references in:
- `types/dev-pa/scripts/` - Only has `github-activity.sh`, `poll-check.sh`, `checkin-guard.sh`
- `scripts/` (repo-level) - Only agent management scripts
- `.openclaw/` - No image generation code (only node_modules from lossless-claw extension)

The only reference to "Nano Banana" is the CLAUDE.md documentation section (lines 309-311) noting the credential location and default/fallback models.

**This is a greenfield implementation.**

---

## 3. Current Tool Configuration (TOOLS.md)

`types/dev-pa/TOOLS.md` is a lightweight template for agent-specific environment notes (camera names, SSH hosts, TTS voices, etc.). It is NOT a tool registry or plugin configuration file. It contains no executable tool definitions.

**Implication:** TOOLS.md is not where image generation capability would be registered. Tool/skill capabilities are handled through:
- Agent scripts in `types/<type>/scripts/`
- OpenClaw skills (via `nativeSkills: "auto"` in openclaw.json)
- OpenClaw plugins (via `plugins` section in openclaw.json)

---

## 4. OpenClaw Plugin/Tool Mechanism

**openclaw.json plugins section:**
```json
"plugins": {
  "slots": {
    "contextEngine": "lossless-claw"
  },
  "entries": {
    "telegram": { "enabled": true },
    "lossless-claw": {
      "enabled": true,
      "config": { ... },
      "installPath": "~/.openclaw/extensions/lossless-claw",
      "version": "0.5.2"
    }
  }
}
```

**Other relevant config:**
- `nativeSkills: "auto"` - Agents auto-discover skills
- Models config supports `"image"` modality (seen in models.json entries)

**Options for exposing image generation to agents:**
1. **Shell script in `types/dev-pa/scripts/`** - Simplest, consistent with existing patterns (like `github-activity.sh`)
2. **OpenClaw native skill** - More integrated but requires OpenClaw skill framework knowledge
3. **OpenClaw plugin** - Heavyweight, not appropriate for a single API call

**Recommendation: Shell script** - matches existing patterns, agents already know how to call scripts.

---

## 5. Gemini Image Generation API Details

### Endpoint
```
POST https://generativelanguage.googleapis.com/v1beta/models/{MODEL_ID}:generateContent?key={API_KEY}
```

### Request Format (curl)
```bash
curl -X POST \
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-image-preview:generateContent?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "contents": [{
      "parts": [{"text": "Generate a professional headshot avatar of a young software developer"}]
    }],
    "generationConfig": {
      "responseModalities": ["image", "text"],
      "imageConfig": {
        "aspectRatio": "1:1",
        "imageSize": "1024"
      }
    }
  }'
```

### Request Format (Python SDK)
```python
from google import genai
from google.genai import types

client = genai.Client(api_key=API_KEY)

response = client.models.generate_content(
    model="gemini-3.1-flash-image-preview",
    contents="Generate a professional headshot avatar",
    config=types.GenerateContentConfig(
        response_modalities=["IMAGE"],
        image_config=types.ImageConfig(
            aspect_ratio="1:1",
            image_size="1024"
        )
    )
)

for part in response.candidates[0].content.parts:
    if part.inline_data:
        # part.inline_data.mime_type = "image/png"
        # part.inline_data.data = base64-encoded image bytes
        with open("output.png", "wb") as f:
            f.write(part.inline_data.data)
```

### Response Structure
```json
{
  "candidates": [{
    "content": {
      "parts": [
        {
          "inlineData": {
            "mimeType": "image/png",
            "data": "<base64-encoded-image>"
          }
        },
        {
          "text": "Here is the generated image..."
        }
      ]
    }
  }]
}
```

**Key points:**
- Response parts can contain BOTH image and text - iterate over parts, check for `inlineData`
- Image data is base64-encoded PNG or JPEG
- All generated images include SynthID watermark
- Free tier: ~500 requests/day via Google AI Studio
- `imageSize` options: 512, 1024, 2048, 4096 (Nano Banana 2 supports up to 4K)
- `aspectRatio` options: "1:1", "3:4", "4:3", "9:16", "16:9", and ultra-wide ratios

### Fallback Strategy
1. Try `gemini-3.1-flash-image-preview` (nano-banana-2, default)
2. On failure, try `gemini-3-pro-image-preview` (nano-banana-pro, fallback)
3. Both use the same API endpoint pattern and request format

---

## 6. Implementation Plan

### Recommended Approach: Shell Script

Create `types/dev-pa/scripts/generate-image.sh` following the pattern of `github-activity.sh`:

**Script responsibilities:**
1. Read credentials from `~/.openclaw/credentials/gemini-nano-banana.json`
2. Accept `--prompt`, `--output`, `--aspect-ratio`, `--size` arguments
3. Call Gemini API via curl (no Python dependency needed)
4. Decode base64 response and save to output file
5. Return JSON response with success/error status (using `lib/json-response.sh`)
6. Implement fallback: try default model, on failure try fallback model

**Dependencies:**
- `jq` (already required by other scripts)
- `curl` (standard)
- `base64` (standard)

**File structure:**
```
types/dev-pa/scripts/
  generate-image.sh    # NEW - Image generation script
  lib/
    json-response.sh   # EXISTING - Reuse for structured output
```

### Primary Use Cases (from issue #40)
1. **Agent profile pictures** (issues #38, #39) - Square avatars for Slack profiles
2. **Ad-hoc image generation** - Agents can generate images when users request them
3. **Document illustrations** - Supporting visual content in reports/docs

### Open Questions
- **Delivery mechanism:** How do agents deliver generated images to users? (Related to issue #48: "Can agents return/send documents?")
- **Storage location:** Where should generated images be saved? (`~/.openclaw/agents/<name>/media/`?)
- **Slack upload:** Need to verify if OpenClaw supports file upload to Slack channels/DMs
- **Rate limits:** 500 req/day free tier - sufficient for 17 agents? May need monitoring
- **Chrome MCP for Slack profile:** Issue #39 mentions Chrome MCP for setting profile pictures - is that still the plan or can we use Slack API directly?

---

## Sources

- [Google AI Nano Banana Image Generation Docs](https://ai.google.dev/gemini-api/docs/image-generation)
- [Firebase AI Logic - Generate Images with Gemini](https://firebase.google.com/docs/ai-logic/generate-images-gemini)
- [Nano Banana 2 API Guide (Medium)](https://medium.com/@GrsAi.com/nano-banana-2-api-guide-ultra-fast-4k-image-generation-with-gemini-3-1-flash-only-0-065-image-c1eff36ac404)
- [Code Examples: JS, Python, cURL](https://www.aifreeapi.com/en/posts/gemini-image-generation-code-examples)
- [Nano Banana Pro Announcement (Google Blog)](https://blog.google/innovation-and-ai/products/nano-banana-pro/)
- [Complete Gemini Image API Guide 2026](https://blog.laozhang.ai/en/posts/gemini-image-api-guide-2026)
