#!/usr/bin/env bash
# zoom-transcript.sh — Fetch Zoom transcript and verify developer participation
#
# Usage: scripts/zoom-transcript.sh --uuid UUID --meeting-id ID --token TOKEN --agent NAME
#
# Outputs one of:
#   "not-participant"     Developer was not in this meeting — caller should discard
#   "/tmp/zoom-transcript-<uuid>.vtt"   Path to downloaded transcript file
#
# The caller (agent) is responsible for reading and deleting the transcript file.
# Exits non-zero on unexpected errors.
#
# Required scopes on the Zoom S2S app:
#   - recording:read:list_user_recordings (or recording:read:admin)
#   - meeting:read:list_past_meeting_participants

set -euo pipefail

ZOOM_CREDS="$HOME/.openclaw/credentials/zoom-s2s.json"

UUID=""
MEETING_ID=""
DOWNLOAD_TOKEN=""
AGENT_NAME=""

while [ $# -gt 0 ]; do
  case "$1" in
    --uuid)       UUID="$2"; shift 2 ;;
    --meeting-id) MEETING_ID="$2"; shift 2 ;;
    --token)      DOWNLOAD_TOKEN="$2"; shift 2 ;;
    --agent)      AGENT_NAME="$2"; shift 2 ;;
    *)            echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

ERRORS=()
[ -z "$UUID" ]           && ERRORS+=("--uuid is required")
[ -z "$MEETING_ID" ]     && ERRORS+=("--meeting-id is required")
[ -z "$DOWNLOAD_TOKEN" ] && ERRORS+=("--token is required")
[ -z "$AGENT_NAME" ]     && ERRORS+=("--agent is required")
[ ! -f "$ZOOM_CREDS" ]   && ERRORS+=("Zoom S2S credentials not found: $ZOOM_CREDS")

if [ ${#ERRORS[@]} -gt 0 ]; then
  for err in "${ERRORS[@]}"; do echo "ERROR: $err" >&2; done
  exit 1
fi

ZOOM_CONFIG="$HOME/.openclaw/agents/$AGENT_NAME/zoom-config.json"
if [ ! -f "$ZOOM_CONFIG" ]; then
  echo "ERROR: zoom-config.json not found for agent '$AGENT_NAME'. Run enable-zoom-transcripts.sh first." >&2
  exit 1
fi

DEVELOPER_EMAIL=$(jq -r '.zoomEmail' "$ZOOM_CONFIG")
if [ -z "$DEVELOPER_EMAIL" ]; then
  echo "ERROR: zoomEmail missing in zoom-config.json for agent '$AGENT_NAME'" >&2
  exit 1
fi

# Get S2S access token
ACCOUNT_ID=$(jq -r '.accountId' "$ZOOM_CREDS")
CLIENT_ID=$(jq -r '.clientId' "$ZOOM_CREDS")
CLIENT_SECRET=$(jq -r '.clientSecret' "$ZOOM_CREDS")

TOKEN_RESPONSE=$(curl -sf -X POST \
  "https://zoom.us/oauth/token?grant_type=account_credentials&account_id=$ACCOUNT_ID" \
  -H "Authorization: Basic $(printf '%s:%s' "$CLIENT_ID" "$CLIENT_SECRET" | base64 | tr -d '\n')" \
  -H "Content-Type: application/x-www-form-urlencoded" 2>&1) || true

ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null || true)
if [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: Failed to get Zoom access token" >&2
  exit 1
fi

# Check if developer was a participant
PARTICIPANTS_RESPONSE=$(curl -sf \
  "https://api.zoom.us/v2/past_meetings/$MEETING_ID/participants?page_size=300" \
  -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null) || true

PARTICIPATED=$(echo "$PARTICIPANTS_RESPONSE" | \
  jq --arg email "$DEVELOPER_EMAIL" \
  '[(.participants // [])[] | select(.user_email == $email)] | length' 2>/dev/null || echo "0")

if [ "$PARTICIPATED" -eq 0 ]; then
  echo "not-participant"
  exit 0
fi

# Get recording files for this meeting
RECORDINGS_RESPONSE=$(curl -sf \
  "https://api.zoom.us/v2/meetings/$MEETING_ID/recordings" \
  -H "Authorization: Bearer $ACCESS_TOKEN" 2>/dev/null) || true

TRANSCRIPT_URL=$(echo "$RECORDINGS_RESPONSE" | \
  jq -r '(.recording_files // [])[] | select(.file_type == "TRANSCRIPT") | .download_url' \
  2>/dev/null | head -1)

if [ -z "$TRANSCRIPT_URL" ]; then
  echo "ERROR: No transcript file found for meeting $MEETING_ID (transcript may still be processing)" >&2
  exit 1
fi

# Download transcript using download_token as Bearer auth
# Sanitize UUID for use in filename (UUIDs can contain '/')
UUID_SAFE="${UUID//\//_}"
OUT_FILE="/tmp/zoom-transcript-$UUID_SAFE.vtt"

curl -s -L \
  -H "Authorization: Bearer $DOWNLOAD_TOKEN" \
  "$TRANSCRIPT_URL" \
  -o "$OUT_FILE" 2>/dev/null || true

if [ ! -s "$OUT_FILE" ]; then
  rm -f "$OUT_FILE"
  echo "ERROR: Downloaded transcript is empty or download failed" >&2
  exit 1
fi

echo "$OUT_FILE"
