#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency checks ────────────────────────
if ! command -v jq &>/dev/null; then
    json_error "collect-github-activity" "MISSING_DEP" "jq is required but not found"
    exit 1
fi

# ── Args ─────────────────────────────────────
SINCE_HOURS=12
BASE_DIR="$HOME/.openclaw/agents"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --since)
            SINCE_HOURS="$2"
            shift 2
            ;;
        --base-dir)
            BASE_DIR="$2"
            shift 2
            ;;
        *)
            json_error "collect-github-activity" "BAD_ARG" "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ── Helper: extract GitHub username(s) from USER.md ──
extract_github_usernames() {
    local user_file="$1"
    local usernames=""

    if [[ -f "$user_file" ]]; then
        usernames=$(sed -n 's/.*\*\*GitHub Usernames\?\*\*:[[:space:]]*//p' "$user_file" \
            | head -1 \
            | sed 's/[[:space:]]*$//' || true)
    fi

    # Return empty if placeholder or missing
    if [[ -z "$usernames" || "$usernames" == *"<"*">"* ]]; then
        echo ""
    else
        echo "$usernames"
    fi
}

# ── Collect activity for all dev-pa agents ───
AGENT_RESULTS="[]"
TOTAL=0
COLLECTED=0
SKIPPED_NO_USERNAME=0
SKIPPED_NO_SCRIPT=0
FAILED=0

for agent_dir in "$BASE_DIR"/*/; do
    [[ -d "$agent_dir" ]] || continue

    # Only process dev-pa agents
    agent_type_file="$agent_dir/.agent-type"
    [[ -f "$agent_type_file" ]] || continue
    agent_type=$(cat "$agent_type_file" 2>/dev/null | tr -d '[:space:]')
    [[ "$agent_type" == "dev-pa" ]] || continue

    agent_name=$(basename "$agent_dir")
    TOTAL=$((TOTAL + 1))

    log "Processing $agent_name"

    # Check for github-activity.sh
    ACTIVITY_SCRIPT="$agent_dir/scripts/github-activity.sh"
    if [[ ! -f "$ACTIVITY_SCRIPT" ]]; then
        log "  SKIP: no github-activity.sh script"
        SKIPPED_NO_SCRIPT=$((SKIPPED_NO_SCRIPT + 1))
        AGENT_RESULTS=$(echo "$AGENT_RESULTS" | jq \
            --arg name "$agent_name" \
            '. + [{"agent": $name, "status": "no_script", "activity": null}]')
        continue
    fi

    # Extract GitHub username(s) from USER.md
    GITHUB_USERS=$(extract_github_usernames "$agent_dir/USER.md")
    if [[ -z "$GITHUB_USERS" ]]; then
        log "  SKIP: no GitHub username in USER.md"
        SKIPPED_NO_USERNAME=$((SKIPPED_NO_USERNAME + 1))
        AGENT_RESULTS=$(echo "$AGENT_RESULTS" | jq \
            --arg name "$agent_name" \
            '. + [{"agent": $name, "status": "no_github_username", "activity": null}]')
        continue
    fi

    # Run github-activity.sh
    log "  Fetching activity for $GITHUB_USERS (--since $SINCE_HOURS)"
    ACTIVITY_OUTPUT=""
    if ACTIVITY_OUTPUT=$(bash "$ACTIVITY_SCRIPT" --user "$GITHUB_USERS" --since "$SINCE_HOURS" 2>/dev/null); then
        # Extract the data field from the script's json_success output
        ACTIVITY_DATA=$(echo "$ACTIVITY_OUTPUT" | jq '.data // empty' 2>/dev/null || echo "null")
        if [[ "$ACTIVITY_DATA" != "null" && -n "$ACTIVITY_DATA" ]]; then
            COLLECTED=$((COLLECTED + 1))
            AGENT_RESULTS=$(echo "$AGENT_RESULTS" | jq \
                --arg name "$agent_name" \
                --argjson activity "$ACTIVITY_DATA" \
                '. + [{"agent": $name, "status": "ok", "activity": $activity}]')
            log "  Collected $(echo "$ACTIVITY_DATA" | jq '.summary.total_events // 0') events"
        else
            COLLECTED=$((COLLECTED + 1))
            AGENT_RESULTS=$(echo "$AGENT_RESULTS" | jq \
                --arg name "$agent_name" \
                '. + [{"agent": $name, "status": "ok", "activity": null}]')
            log "  No activity data returned"
        fi
    else
        log "  FAILED: github-activity.sh returned error"
        FAILED=$((FAILED + 1))
        AGENT_RESULTS=$(echo "$AGENT_RESULTS" | jq \
            --arg name "$agent_name" \
            '. + [{"agent": $name, "status": "script_error", "activity": null}]')
    fi
done

# ── Build output ─────────────────────────────
DATA=$(jq -n \
    --argjson agents "$AGENT_RESULTS" \
    --argjson since_hours "$SINCE_HOURS" \
    --argjson total "$TOTAL" \
    --argjson collected "$COLLECTED" \
    --argjson skipped_no_username "$SKIPPED_NO_USERNAME" \
    --argjson skipped_no_script "$SKIPPED_NO_SCRIPT" \
    --argjson failed "$FAILED" \
    '{
        agents: $agents,
        since_hours: $since_hours,
        summary: {
            total_agents: $total,
            collected: $collected,
            skipped_no_github_username: $skipped_no_username,
            skipped_no_script: $skipped_no_script,
            failed: $failed
        }
    }')

log "GitHub activity collection complete: $TOTAL agents, $COLLECTED collected, $SKIPPED_NO_USERNAME no username, $SKIPPED_NO_SCRIPT no script, $FAILED failed"

json_success "collect-github-activity" "$DATA"
