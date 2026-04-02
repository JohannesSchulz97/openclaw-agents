#!/usr/bin/env bash
set -euo pipefail
# update-cron-schedule.sh — Update check-in cron jobs based on developer's work schedule
# Called after bootstrap when work-schedule.json is created, or when schedule changes.
#
# Usage: scripts/update-cron-schedule.sh --agent <name>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

source "$SCRIPT_DIR/lib/cron-utils.sh"
source "$SCRIPT_DIR/lib/schedule-utils.sh"

# Parse args
AGENT_NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --agent) AGENT_NAME="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$AGENT_NAME" ]]; then
    echo "Usage: $0 --agent <name>" >&2
    exit 1
fi

# Find work-schedule.json (check live dir first, then repo)
SCHEDULE_FILE="$HOME/.openclaw/agents/$AGENT_NAME/work-schedule.json"
if [[ ! -f "$SCHEDULE_FILE" ]]; then
    SCHEDULE_FILE="$REPO_ROOT/.openclaw/agents/$AGENT_NAME/work-schedule.json"
fi
if [[ ! -f "$SCHEDULE_FILE" ]]; then
    echo "Error: No work-schedule.json found for agent '$AGENT_NAME'" >&2
    exit 1
fi

# Parse schedule
parse_work_schedule "$SCHEDULE_FILE" || exit 1

CRON_CONFIG="$REPO_ROOT/.openclaw/cron/jobs-config.json"

# Get display name from agent's IDENTITY.md or derive from agent name
DISPLAY_NAME=$(echo "$AGENT_NAME" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1))substr($i,2)}1')

# Get model from existing job if any, otherwise default
MODEL=$(jq -r --arg aid "$AGENT_NAME" '.jobs[] | select(.agentId == $aid) | .payload.model' "$CRON_CONFIG" 2>/dev/null | head -1)
MODEL="${MODEL:-glm-5}"

# Remove existing jobs for this agent
echo "Removing existing cron jobs for '$AGENT_NAME'..."
remove_cron_job "$CRON_CONFIG" "$AGENT_NAME" 2>/dev/null || true

# Add new 3-job schedule
echo "Adding 3 time-of-day check-in jobs for '$AGENT_NAME'..."
echo "  Schedule: ${WS_START_HOUR}:00-${WS_END_HOUR}:00 ${WS_TIMEZONE} (weekends: ${WS_WORKS_WEEKENDS})"
add_cron_jobs "$CRON_CONFIG" "$AGENT_NAME" "$DISPLAY_NAME" "$MODEL" \
    "$WS_START_HOUR" "$WS_END_HOUR" "$WS_TIMEZONE" "$WS_WORKS_WEEKENDS"

# Apply to gateway
echo "Applying cron changes to gateway..."
bash "$SCRIPT_DIR/apply-cron.sh"

echo "Done. Check-in schedule updated for '$AGENT_NAME'."
