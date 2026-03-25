#!/usr/bin/env bash
# apply-cron.sh — Apply cron config from jobs-config.json to the gateway
#
# Usage: ./scripts/apply-cron.sh
#
# Reads .openclaw/cron/jobs-config.json and applies each job's config fields
# to the live cron system. Existing jobs are updated via `openclaw cron edit`;
# new jobs (not yet on the gateway) are created via `openclaw cron add`.
# Note: newly created jobs get gateway-assigned IDs that differ from the config.
#
# Fields NOT settable via `openclaw cron edit`:
#   - delivery.mode (no CLI flag; use openclaw cron edit <id> --no-deliver to disable)
#   - payload.kind (implicitly set by --message for agentTurn)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/.openclaw/cron/jobs-config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "ERROR: jq is required but not installed" >&2
  exit 1
fi

if ! command -v openclaw &>/dev/null; then
  echo "ERROR: openclaw is required but not installed" >&2
  exit 1
fi

JOB_COUNT=$(jq '.jobs | length' "$CONFIG_FILE")
echo "Applying $JOB_COUNT job(s) from $CONFIG_FILE"

# Fetch the full gateway job list as JSON once for agentId-based matching.
# The config's .id field is informational only — the gateway owns job IDs.
GATEWAY_JOBS=$(openclaw cron list --json 2>/dev/null || echo '{"jobs":[]}')

for i in $(seq 0 $((JOB_COUNT - 1))); do
  JOB=$(jq ".jobs[$i]" "$CONFIG_FILE")

  NAME=$(echo "$JOB" | jq -r '.name')
  AGENT_ID=$(echo "$JOB" | jq -r '.agentId // empty')
  ENABLED=$(echo "$JOB" | jq -r '.enabled')
  EVERY_MS=$(echo "$JOB" | jq -r '.schedule.everyMs // empty')
  SESSION_TARGET=$(echo "$JOB" | jq -r '.sessionTarget // empty')
  WAKE_MODE=$(echo "$JOB" | jq -r '.wakeMode // empty')
  MESSAGE=$(echo "$JOB" | jq -r '.payload.message // empty')
  MODEL=$(echo "$JOB" | jq -r '.payload.model // empty')
  THINKING=$(echo "$JOB" | jq -r '.payload.thinking // empty')
  TIMEOUT_SEC=$(echo "$JOB" | jq -r '.payload.timeoutSeconds // empty')
  SESSION_KEY=$(echo "$JOB" | jq -r '.sessionKey // empty')

  # Convert everyMs to human-readable duration for --every flag
  # openclaw accepts durations like "120m", "2h", etc.
  EVERY_HUMAN=""
  if [ -n "$EVERY_MS" ]; then
    EVERY_MIN=$((EVERY_MS / 60000))
    EVERY_HUMAN="${EVERY_MIN}m"
  fi

  echo ""

  # Match by agentId: look up the gateway job's real ID
  GATEWAY_ID=""
  if [ -n "$AGENT_ID" ]; then
    GATEWAY_ID=$(echo "$GATEWAY_JOBS" | jq -r --arg aid "$AGENT_ID" \
      '.jobs[] | select(.agentId == $aid) | .id' 2>/dev/null | head -1)
  fi

  if [ -n "$GATEWAY_ID" ]; then
    echo "--- [$((i + 1))/$JOB_COUNT] EDIT: $NAME (agentId=$AGENT_ID, gateway=$GATEWAY_ID)"
    CMD=(openclaw cron edit "$GATEWAY_ID")
  else
    echo "--- [$((i + 1))/$JOB_COUNT] CREATE: $NAME (agentId=$AGENT_ID, new)"
    CMD=(openclaw cron add)
  fi

  CMD+=(--name "$NAME")

  if [ -n "$AGENT_ID" ]; then
    CMD+=(--agent "$AGENT_ID")
  fi

  if [ -n "$GATEWAY_ID" ]; then
    # edit uses --enable/--disable
    if [ "$ENABLED" = "true" ]; then
      CMD+=(--enable)
    else
      CMD+=(--disable)
    fi
  else
    # add creates enabled by default; use --disabled to override
    if [ "$ENABLED" != "true" ]; then
      CMD+=(--disabled)
    fi
  fi

  if [ -n "$EVERY_HUMAN" ]; then
    CMD+=(--every "$EVERY_HUMAN")
  fi

  if [ -n "$SESSION_TARGET" ]; then
    CMD+=(--session "$SESSION_TARGET")
  fi

  if [ -n "$WAKE_MODE" ]; then
    CMD+=(--wake "$WAKE_MODE")
  fi

  if [ -n "$MESSAGE" ]; then
    CMD+=(--message "$MESSAGE")
  fi

  if [ -n "$MODEL" ]; then
    CMD+=(--model "$MODEL")
  fi

  if [ -n "$THINKING" ]; then
    CMD+=(--thinking "$THINKING")
  fi

  if [ -n "$TIMEOUT_SEC" ]; then
    CMD+=(--timeout-seconds "$TIMEOUT_SEC")
  fi

  if [ -n "$SESSION_KEY" ]; then
    CMD+=(--session-key "$SESSION_KEY")
  fi

  # delivery.mode=none -> --no-deliver
  DELIVERY_MODE=$(echo "$JOB" | jq -r '.delivery.mode // empty')
  if [ "$DELIVERY_MODE" = "none" ]; then
    CMD+=(--no-deliver)
  fi

  echo "Running: ${CMD[*]}"
  "${CMD[@]}"
  echo "OK"
done

echo ""
echo "All jobs applied successfully."
