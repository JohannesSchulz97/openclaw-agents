#!/usr/bin/env bash
# enable-zoom-transcripts.sh — Enable automatic Zoom transcript delivery for a developer
#
# Usage: scripts/enable-zoom-transcripts.sh --agent NAME --zoom-email EMAIL [OPTIONS]
#
# Adds a hooks.mappings entry to openclaw.json for the agent and stores the
# developer's Zoom email for participant verification. Run once per developer
# who opts in to the feature.
#
# Requires:
#   - ~/.openclaw/credentials/zoom-s2s.json with Zoom S2S app credentials
#   - ~/.openclaw/openclaw.json with hooks.publicUrl set
#   - Agent must already exist at ~/.openclaw/agents/<name>/
#
# Runs on the OpenClaw host after deployment.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OPENCLAW_UTILS="$REPO_ROOT/scripts/lib/openclaw-utils.sh"
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
ZOOM_CREDS="$HOME/.openclaw/credentials/zoom-s2s.json"

AGENT=""
ZOOM_EMAIL=""
HOST_URL=""
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: scripts/enable-zoom-transcripts.sh --agent NAME --zoom-email EMAIL [OPTIONS]

Required:
  --agent NAME         Agent name, kebab-case (must already exist)
  --zoom-email EMAIL   Developer's Zoom account email (for participant verification)

Optional:
  --host-url URL       OpenClaw public base URL (e.g., https://kai.example.com)
                       Falls back to hooks.publicUrl in openclaw.json
  --dry-run            Print what would be done without making changes
  --help               Show this help message
EOF
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --agent)      AGENT="$2"; shift 2 ;;
    --zoom-email) ZOOM_EMAIL="$2"; shift 2 ;;
    --host-url)   HOST_URL="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --help)       usage 0 ;;
    *)            echo "ERROR: Unknown argument: $1" >&2; usage 1 ;;
  esac
done

log_action() {
  if [ "$DRY_RUN" = true ]; then echo "[DRY RUN] $1"; else echo "$1"; fi
}

# Validate
ERRORS=()
[ -z "$AGENT" ]      && ERRORS+=("--agent is required")
[ -z "$ZOOM_EMAIL" ] && ERRORS+=("--zoom-email is required")
! command -v jq   &>/dev/null && ERRORS+=("jq is required but not installed")
! command -v curl &>/dev/null && ERRORS+=("curl is required but not installed")
[ ! -f "$OPENCLAW_CONFIG" ] && ERRORS+=("openclaw.json not found: $OPENCLAW_CONFIG")
[ ! -f "$ZOOM_CREDS" ]      && ERRORS+=("Zoom S2S credentials not found: $ZOOM_CREDS (create via openclaw-add-secret skill)")
[ ! -f "$OPENCLAW_UTILS" ]  && ERRORS+=("openclaw-utils.sh not found: $OPENCLAW_UTILS")

if [ -n "$AGENT" ] && [ ! -d "$HOME/.openclaw/agents/$AGENT" ]; then
  ERRORS+=("Agent '$AGENT' does not exist at ~/.openclaw/agents/$AGENT")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "ERROR: Validation failed:" >&2
  for err in "${ERRORS[@]}"; do echo "  - $err" >&2; done
  exit 1
fi

# Read S2S credentials (stderr only — never echo credentials to stdout)
ACCOUNT_ID=$(jq -r '.accountId' "$ZOOM_CREDS")
CLIENT_ID=$(jq -r '.clientId' "$ZOOM_CREDS")
CLIENT_SECRET=$(jq -r '.clientSecret' "$ZOOM_CREDS")

if [ -z "$ACCOUNT_ID" ] || [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
  echo "ERROR: zoom-s2s.json must contain accountId, clientId, clientSecret" >&2
  exit 1
fi

# Resolve host URL
if [ -z "$HOST_URL" ]; then
  HOST_URL=$(jq -r '.hooks.publicUrl // empty' "$OPENCLAW_CONFIG")
  if [ -z "$HOST_URL" ]; then
    echo "ERROR: --host-url not provided and hooks.publicUrl not set in openclaw.json" >&2
    exit 1
  fi
fi
HOST_URL="${HOST_URL%/}"
WEBHOOK_URL="$HOST_URL/hooks/zoom-$AGENT"

# Title-case helper
to_title_case() {
  echo "$1" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
}
DISPLAY_NAME="$(to_title_case "$AGENT")"

echo "Enabling Zoom transcripts for: $AGENT ($DISPLAY_NAME)"
echo "  Zoom email:  $ZOOM_EMAIL"
echo "  Webhook URL: $WEBHOOK_URL"
echo ""

# Verify credentials work
log_action "Verifying Zoom S2S credentials..."
if [ "$DRY_RUN" = false ]; then
  TOKEN_RESPONSE=$(curl -sf -X POST \
    "https://zoom.us/oauth/token?grant_type=account_credentials&account_id=$ACCOUNT_ID" \
    -H "Authorization: Basic $(printf '%s:%s' "$CLIENT_ID" "$CLIENT_SECRET" | base64 | tr -d '\n')" \
    -H "Content-Type: application/x-www-form-urlencoded" 2>&1) || true

  ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token // empty' 2>/dev/null || true)
  if [ -z "$ACCESS_TOKEN" ]; then
    echo "ERROR: Failed to get Zoom access token — check credentials in zoom-s2s.json" >&2
    exit 1
  fi
  echo "  Credentials OK."
fi

# Source utils for _atomic_write
# shellcheck source=lib/openclaw-utils.sh
source "$OPENCLAW_UTILS"

# Step 1: Add hooks.mappings entry
MESSAGE_TEMPLATE="Zoom recording ready.

Meeting: {{payload.object.topic}}
UUID: {{payload.object.uuid}}
Meeting ID: {{payload.object.id}}
Host: {{payload.object.host_email}}
Start: {{payload.object.start_time}}
Duration: {{payload.object.duration}} minutes
Download token: {{download_token}}

Run: bash scripts/zoom-transcript.sh --uuid '{{payload.object.uuid}}' --meeting-id '{{payload.object.id}}' --token '{{download_token}}' --agent $AGENT

If the script prints 'not-participant', the developer was not in this meeting — stop and do nothing.
If it prints a file path, the developer attended. Read the transcript, write a concise AI summary, then:
1. Send a Slack DM with the summary as the main message
2. Upload the transcript file as a thread reply to that message"

log_action "Adding hooks.mappings entry for 'zoom-$AGENT'..."
if [ "$DRY_RUN" = false ]; then
  EXISTS=$(jq --arg path "zoom-$AGENT" \
    '[(.hooks.mappings // [])[] | select(.match.path == $path)] | length' \
    "$OPENCLAW_CONFIG")

  if [ "$EXISTS" -gt 0 ]; then
    echo "  Mapping 'zoom-$AGENT' already exists in openclaw.json — skipping."
  else
    _atomic_write "$OPENCLAW_CONFIG" \
      '.hooks.mappings = ((.hooks.mappings // []) + [{
        "match": {"path": $path},
        "action": "agent",
        "agentId": $agentId,
        "wakeMode": "now",
        "name": $name,
        "sessionKey": $sessionKey,
        "messageTemplate": $msgTemplate,
        "deliver": false
      }])' \
      --arg path "zoom-$AGENT" \
      --arg agentId "$AGENT" \
      --arg name "Zoom Transcript - $DISPLAY_NAME" \
      --arg sessionKey "agent:$AGENT:hook:zoom:{{payload.object.uuid}}" \
      --arg msgTemplate "$MESSAGE_TEMPLATE"
    echo "  Added mapping 'zoom-$AGENT' to openclaw.json."
  fi
fi

# Step 2: Write developer's Zoom email to per-agent config
ZOOM_CONFIG_FILE="$HOME/.openclaw/agents/$AGENT/zoom-config.json"
log_action "Writing zoom-config.json for agent '$AGENT'..."
if [ "$DRY_RUN" = false ]; then
  printf '{\n  "zoomEmail": "%s"\n}\n' "$ZOOM_EMAIL" > "$ZOOM_CONFIG_FILE"
  chmod 600 "$ZOOM_CONFIG_FILE"
  echo "  Written: $ZOOM_CONFIG_FILE"
fi

# Step 3: Validate config
log_action "Validating openclaw.json..."
if [ "$DRY_RUN" = false ]; then
  openclaw config validate
fi

echo ""
echo "=========================================="
echo "Zoom transcripts enabled for: $AGENT"
echo "=========================================="
echo ""
echo "Next steps:"
echo ""
echo "  1. Restart the gateway to apply hooks config:"
echo "     openclaw gateway restart"
echo ""
echo "  2. Register the Zoom event subscription (manual — requires Zoom developer role):"
echo "     a. Go to Zoom Marketplace → your S2S app → Feature → Event Subscriptions"
echo "     b. Add a new subscription with endpoint URL:"
echo "        $WEBHOOK_URL"
echo "     c. Subscribe to event: recording.completed"
echo "     d. Validate the endpoint when prompted (OpenClaw handles the challenge)"
echo ""
echo "  Required S2S app scopes (verify in Zoom Marketplace):"
echo "    - recording:read:list_user_recordings (or recording:read:admin)"
echo "    - meeting:read:list_past_meeting_participants"
