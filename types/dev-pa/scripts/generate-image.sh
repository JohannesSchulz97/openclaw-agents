#!/usr/bin/env bash
# generate-image.sh - Generate images via Gemini Nano Banana API
# Dependencies: curl, jq, base64

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

OPERATION="generate-image"
CREDS_FILE="$HOME/.openclaw/credentials/gemini-nano-banana.json"

# --- Detect agent name from script path ---
# Expected path: ~/.openclaw/agents/<agent-name>/scripts/generate-image.sh
AGENT_NAME="$(basename "$(dirname "$SCRIPT_DIR")")"

# --- Detect platform for base64 decode flag ---
if [[ "$(uname)" == "Darwin" ]]; then
    BASE64_DECODE="base64 -D"
else
    BASE64_DECODE="base64 -d"
fi

# --- Parse arguments ---
PROMPT=""
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prompt)   PROMPT="$2"; shift 2 ;;
        --output)   OUTPUT="$2"; shift 2 ;;
        --agent)    AGENT_NAME="$2"; shift 2 ;;
        *)          log "Unknown argument: $1"; shift ;;
    esac
done

# --- Validate ---
if [[ -z "$PROMPT" ]]; then
    json_error "$OPERATION" "MISSING_PROMPT" "Required: --prompt \"description\""
    exit 1
fi

if [[ ! -f "$CREDS_FILE" ]]; then
    json_error "$OPERATION" "NO_<channel-id>" "Credentials not found at $CREDS_FILE"
    exit 1
fi

# --- Read credentials ---
API_KEY="$(jq -r '.api_key' "$CREDS_FILE")"
MODEL_DEFAULT="$(jq -r '.model_default' "$CREDS_FILE")"
MODEL_FALLBACK="$(jq -r '.model_fallback' "$CREDS_FILE")"

if [[ -z "$API_KEY" || "$API_KEY" == "null" ]]; then
    json_error "$OPERATION" "INVALID_<channel-id>" "api_key missing from credentials file"
    exit 1
fi

# --- Prepare output ---
OUTPUT_DIR="$HOME/.openclaw/media/$AGENT_NAME/images"
mkdir -p "$OUTPUT_DIR"

OUTPUT_FILENAME="$OUTPUT"

# --- Build request body ---
REQUEST_BODY="$(jq -n \
    --arg prompt "$PROMPT" \
    '{
        contents: [{parts: [{text: $prompt}]}],
        generationConfig: {
            responseModalities: ["image", "text"]
        }
    }')"

# --- API call with fallback ---
call_api() {
    local model_id="$1"
    local url="https://generativelanguage.googleapis.com/v1beta/models/${model_id}:generateContent?key=${API_KEY}"

    curl -s -w "\n%{http_code}" \
        -X POST "$url" \
        -H "Content-Type: application/json" \
        -d "$REQUEST_BODY"
}

extract_image_data() {
    local response="$1"
    jq -r '.candidates[0].content.parts[] | select(.inlineData) | .inlineData.data // empty' <<< "$response"
}

extract_image_mime() {
    local response="$1"
    jq -r '.candidates[0].content.parts[] | select(.inlineData) | .inlineData.mimeType // empty' <<< "$response"
}

mime_to_ext() {
    case "$1" in
        image/jpeg) echo ".jpg" ;;
        image/png)  echo ".png" ;;
        image/webp) echo ".webp" ;;
        *)          echo ".png" ;;
    esac
}

try_model() {
    local model_id="$1"
    local model_label="$2"

    log "Trying model: $model_label ($model_id)"

    local raw_response
    raw_response="$(call_api "$model_id")"

    # Split response body and HTTP status
    local http_code
    http_code="$(tail -n1 <<< "$raw_response")"
    local response_body
    response_body="$(sed '$d' <<< "$raw_response")"

    if [[ "$http_code" -ne 200 ]]; then
        log "HTTP $http_code from $model_label"
        return 1
    fi

    local image_data
    image_data="$(extract_image_data "$response_body")"

    if [[ -z "$image_data" ]]; then
        log "No image data in response from $model_label"
        return 1
    fi

    # Detect extension from MIME type
    local mime_type ext output_path
    mime_type="$(extract_image_mime "$response_body")"
    ext="$(mime_to_ext "$mime_type")"

    if [[ -n "$OUTPUT_FILENAME" ]]; then
        output_path="$OUTPUT_DIR/$OUTPUT_FILENAME"
    else
        output_path="$OUTPUT_DIR/image-$(date '+%Y%m%d-%H%M%S')${ext}"
    fi

    # Decode and save
    echo "$image_data" | $BASE64_DECODE > "$output_path"

    if [[ ! -s "$output_path" ]]; then
        log "Decoded file is empty"
        rm -f "$output_path"
        return 1
    fi

    json_success "$OPERATION" "$(jq -n \
        --arg path "$output_path" \
        --arg model "$model_label" \
        --arg prompt "$PROMPT" \
        '{path: $path, model: $model, prompt: $prompt}')"
    return 0
}

# Try default model, fall back if needed
if try_model "$MODEL_DEFAULT" "nano-banana-2"; then
    exit 0
fi

log "Default model failed, trying fallback..."

if try_model "$MODEL_FALLBACK" "nano-banana-pro"; then
    exit 0
fi

# Both models failed
json_error "$OPERATION" "GENERATION_FAILED" "Both models failed to generate image" "Tried $MODEL_DEFAULT and $MODEL_FALLBACK"
exit 1
