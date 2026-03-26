#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency check ─────────────────────────
if ! command -v jq &>/dev/null; then
    echo '{"success":false,"operation":"check-status","error":{"code":"MISSING_DEP","message":"jq is required but not found"}}' >&2
    exit 1
fi

# ── Args ─────────────────────────────────────
AGENTS=""
BASE_DIR="$HOME/.openclaw/agents"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agents)
            AGENTS="$2"
            shift 2
            ;;
        --base-dir)
            BASE_DIR="$2"
            shift 2
            ;;
        *)
            json_error "check-status" "BAD_ARG" "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$AGENTS" ]]; then
    json_error "check-status" "MISSING_ARG" "--agents AGENT1,AGENT2,... is required"
    exit 1
fi

# ── Helper: epoch to ISO (macOS + GNU) ──────
epoch_to_iso() {
    local epoch_s="$1"
    if date -u -r "$epoch_s" '+%Y-%m-%dT%H:%M:%SZ' &>/dev/null; then
        date -u -r "$epoch_s" '+%Y-%m-%dT%H:%M:%SZ'
    else
        date -u -d "@$epoch_s" '+%Y-%m-%dT%H:%M:%SZ'
    fi
}

# ── Collect session data ────────────────────
SESSIONS_JSON="[]"
if command -v openclaw &>/dev/null; then
    SESSIONS_JSON=$(openclaw sessions --all-agents --json 2>/dev/null || echo "[]")
fi

# ── Process each agent ──────────────────────
IFS=',' read -ra AGENT_LIST <<< "$AGENTS"
NOW_EPOCH=$(date -u +%s)
TODAY=$(date -u '+%Y-%m-%d')

AGENT_RESULTS="[]"
TOTAL=0
ACTIVE_TODAY=0
AWAITING_COUNT=0
INACTIVE=0

for agent in "${AGENT_LIST[@]}"; do
    agent=$(echo "$agent" | xargs)  # trim whitespace
    TOTAL=$((TOTAL + 1))
    AGENT_DIR="$BASE_DIR/$agent"

    log "Processing agent: $agent"

    # ── Session activity ────────────────────
    LAST_SESSION_ACTIVITY=""
    SESSIONS_TODAY=0

    if [[ "$SESSIONS_JSON" != "[]" ]]; then
        # Filter sessions for this agent
        AGENT_SESSIONS=$(echo "$SESSIONS_JSON" | jq -r \
            --arg agent "$agent" \
            '[.[] | select(.agent == $agent)]' 2>/dev/null || echo "[]")

        if [[ "$AGENT_SESSIONS" != "[]" && "$AGENT_SESSIONS" != "null" ]]; then
            LAST_SESSION_ACTIVITY=$(echo "$AGENT_SESSIONS" | jq -r \
                '[.[].updatedAt // ""] | map(select(. != "")) | sort | reverse | .[0] // ""' 2>/dev/null || echo "")

            SESSIONS_TODAY=$(echo "$AGENT_SESSIONS" | jq -r \
                --arg today "$TODAY" \
                '[.[] | select((.updatedAt // "") | startswith($today))] | length' 2>/dev/null || echo "0")
        fi
    fi

    # Fallback: check sessions.json in agent directory
    SESSIONS_FILE="$AGENT_DIR/sessions/sessions.json"
    if [[ -z "$LAST_SESSION_ACTIVITY" && -f "$SESSIONS_FILE" ]]; then
        LAST_EPOCH_MS=$(jq -r '
            to_entries
            | map(select(.key | test("cron") | not))
            | map(.value.updatedAt // 0)
            | max // 0
        ' "$SESSIONS_FILE" 2>/dev/null || echo "0")

        if [[ "$LAST_EPOCH_MS" != "0" && "$LAST_EPOCH_MS" != "null" ]]; then
            LAST_EPOCH_S=$(( LAST_EPOCH_MS / 1000 ))
            LAST_SESSION_ACTIVITY=$(epoch_to_iso "$LAST_EPOCH_S")

            # Count today's sessions
            TODAY_START_EPOCH=$(date -u -j -f '%Y-%m-%d' "$TODAY" '+%s' 2>/dev/null || date -u -d "$TODAY" '+%s' 2>/dev/null || echo "0")
            if [[ "$TODAY_START_EPOCH" != "0" ]]; then
                TODAY_START_MS=$(( TODAY_START_EPOCH * 1000 ))
                SESSIONS_TODAY=$(jq -r \
                    --argjson start "$TODAY_START_MS" \
                    'to_entries | map(select(.key | test("cron") | not) | select((.value.updatedAt // 0) >= $start)) | length' \
                    "$SESSIONS_FILE" 2>/dev/null || echo "0")
            fi
        fi
    fi

    if [[ "$SESSIONS_TODAY" -gt 0 ]]; then
        ACTIVE_TODAY=$((ACTIVE_TODAY + 1))
    fi

    # ── Poll state ──────────────────────────
    POLL_STATE_FILE="$AGENT_DIR/memory/poll-state.json"
    AWAITING_RESPONSE="false"
    LAST_CHECK_IN=""
    POLL_STATE="{}"

    if [[ -f "$POLL_STATE_FILE" ]]; then
        POLL_STATE=$(jq '.' "$POLL_STATE_FILE" 2>/dev/null || echo "{}")
        AWAITING_RESPONSE=$(echo "$POLL_STATE" | jq -r '.awaiting_response // false')
        LAST_CHECK_IN=$(echo "$POLL_STATE" | jq -r '.last_check_in // ""')
    else
        log "  WARNING: poll-state.json not found for $agent, skipping poll state"
    fi

    if [[ "$AWAITING_RESPONSE" == "true" ]]; then
        AWAITING_COUNT=$((AWAITING_COUNT + 1))
    fi

    # ── Recent daily notes ──────────────────
    MEMORY_DIR="$AGENT_DIR/memory"
    HAS_RECENT_NOTES="false"
    LATEST_NOTE_DATE=""

    if [[ -d "$MEMORY_DIR" ]]; then
        # Find most recent YYYY-MM-DD.md file
        LATEST_NOTE=$(find "$MEMORY_DIR" -maxdepth 1 -name '????-??-??.md' -type f 2>/dev/null \
            | sort -r | head -1 || true)

        if [[ -n "$LATEST_NOTE" ]]; then
            LATEST_NOTE_DATE=$(basename "$LATEST_NOTE" .md)
            HAS_RECENT_NOTES="true"
        fi
    fi

    # ── Track inactive ──────────────────────
    if [[ -z "$LAST_SESSION_ACTIVITY" && "$SESSIONS_TODAY" -eq 0 ]]; then
        INACTIVE=$((INACTIVE + 1))
    fi

    # ── Build agent JSON ────────────────────
    AGENT_ENTRY=$(jq -n \
        --arg name "$agent" \
        --arg last_activity "${LAST_SESSION_ACTIVITY:-}" \
        --argjson sessions_today "$SESSIONS_TODAY" \
        --argjson awaiting "$AWAITING_RESPONSE" \
        --argjson poll_state "$POLL_STATE" \
        --argjson has_notes "$HAS_RECENT_NOTES" \
        --arg note_date "${LATEST_NOTE_DATE:-}" \
        '{
            name: $name,
            last_session_activity: (if $last_activity == "" then null else $last_activity end),
            sessions_today: $sessions_today,
            awaiting_response: $awaiting,
            poll_state: $poll_state,
            has_recent_notes: $has_notes,
            latest_note_date: (if $note_date == "" then null else $note_date end)
        }')

    AGENT_RESULTS=$(echo "$AGENT_RESULTS" | jq --argjson entry "$AGENT_ENTRY" '. + [$entry]')
done

# ── Build output ────────────────────────────
DATA=$(jq -n \
    --argjson agents "$AGENT_RESULTS" \
    --argjson total "$TOTAL" \
    --argjson active "$ACTIVE_TODAY" \
    --argjson awaiting "$AWAITING_COUNT" \
    --argjson inactive "$INACTIVE" \
    '{
        agents: $agents,
        summary: {
            total_agents: $total,
            active_today: $active,
            awaiting_response: $awaiting,
            inactive: $inactive
        }
    }')

log "Status check complete: $TOTAL agents, $ACTIVE_TODAY active today, $AWAITING_COUNT awaiting response"

json_success "check-status" "$DATA"
