#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency check ─────────────────────────
if ! command -v jq &>/dev/null; then
    echo '{"success":false,"operation":"check-missed-checkins","error":{"code":"MISSING_DEP","message":"jq is required but not found"}}' >&2
    exit 1
fi

# ── Args ─────────────────────────────────────
AGENTS=""
THRESHOLD=3
BASE_DIR="$HOME/.openclaw/agents"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agents)
            AGENTS="$2"
            shift 2
            ;;
        --threshold)
            THRESHOLD="$2"
            shift 2
            ;;
        --base-dir)
            BASE_DIR="$2"
            shift 2
            ;;
        *)
            json_error "check-missed-checkins" "BAD_ARG" "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$AGENTS" ]]; then
    json_error "check-missed-checkins" "MISSING_ARG" "--agents AGENT1,AGENT2,... is required"
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

# ── Process each agent ──────────────────────
IFS=',' read -ra AGENT_LIST <<< "$AGENTS"
NOW_EPOCH=$(date -u +%s)
ALERTS="[]"

for agent in "${AGENT_LIST[@]}"; do
    agent=$(echo "$agent" | xargs)
    AGENT_DIR="$BASE_DIR/$agent"

    log "Checking missed check-ins for: $agent"

    # ── Read poll config ────────────────────
    POLL_CONFIG_FILE="$AGENT_DIR/poll-config.json"
    INTERVAL_MINUTES=240

    if [[ -f "$POLL_CONFIG_FILE" ]]; then
        INTERVAL_MINUTES=$(jq -r '.interval_minutes // 240' "$POLL_CONFIG_FILE" 2>/dev/null || echo "240")
    else
        log "  WARNING: poll-config.json not found for $agent, using default ${INTERVAL_MINUTES}m"
    fi

    # ── Skip agents not yet bootstrapped ────
    WORK_SCHEDULE_FILE="$AGENT_DIR/work-schedule.json"
    POLL_STATE_FILE="$AGENT_DIR/memory/poll-state.json"

    if [[ ! -f "$POLL_STATE_FILE" ]] || [[ ! -f "$WORK_SCHEDULE_FILE" ]]; then
        log "  SKIP: $agent not yet bootstrapped"
        continue
    fi

    # ── Read poll state (new + old schema) ──
    AWAITING_RESPONSE="false"
    LAST_CHECK_IN=""
    MISSED_FROM_STATE=0

    # Detect schema: new schema has last_morning_epoch
    HAS_NEW_SCHEMA=$(jq 'has("last_morning_epoch")' "$POLL_STATE_FILE" 2>/dev/null || echo "false")

    if [[ "$HAS_NEW_SCHEMA" == "true" ]]; then
        # New schema: check if any check-in is unresponded
        ANY_<slack-id>=$(jq '
            (if .morning_responded == false then 1 else 0 end) +
            (if .midday_responded == false then 1 else 0 end) +
            (if .evening_responded == false then 1 else 0 end)
        ' "$POLL_STATE_FILE" 2>/dev/null || echo "0")
        if [[ "$ANY_<slack-id>" -gt 0 ]]; then
            AWAITING_RESPONSE="true"
        fi
        MISSED_FROM_STATE=$(jq -r '.missed_checkins // 0' "$POLL_STATE_FILE" 2>/dev/null || echo "0")
        # last_check_in equivalent: max of the three epoch fields
        LAST_CHECKIN_EPOCH=$(jq '[.last_morning_epoch, .last_midday_epoch, .last_evening_epoch] | map(select(. > 0)) | max // 0' "$POLL_STATE_FILE" 2>/dev/null || echo "0")
        if [[ "$LAST_CHECKIN_EPOCH" != "0" ]]; then
            LAST_CHECK_IN=$(epoch_to_iso "$LAST_CHECKIN_EPOCH")
        fi
    else
        # Old schema: use original field names
        AWAITING_RESPONSE=$(jq -r '.awaiting_response // false' "$POLL_STATE_FILE" 2>/dev/null || echo "false")
        LAST_CHECK_IN=$(jq -r '.last_check_in // ""' "$POLL_STATE_FILE" 2>/dev/null || echo "")
        MISSED_FROM_STATE=$(jq -r '.missed_checkins // 0' "$POLL_STATE_FILE" 2>/dev/null || echo "0")
    fi

    # ── Get last human interaction ──────────
    SESSIONS_FILE="$AGENT_DIR/sessions/sessions.json"
    LAST_HUMAN_EPOCH_S=""

    if [[ -f "$SESSIONS_FILE" ]]; then
        LAST_HUMAN_EPOCH_MS=$(jq -r '
            to_entries
            | map(select(.key | test("cron") | not))
            | map(.value.updatedAt // 0)
            | max // 0
        ' "$SESSIONS_FILE" 2>/dev/null || echo "0")

        if [[ "$LAST_HUMAN_EPOCH_MS" != "0" && "$LAST_HUMAN_EPOCH_MS" != "null" ]]; then
            LAST_HUMAN_EPOCH_S=$(( LAST_HUMAN_EPOCH_MS / 1000 ))
        fi
    fi

    # ── Determine missed check-ins ──────────
    MISSED_COUNT=0
    HOURS_SINCE=0
    SEVERITY="none"
    LAST_HUMAN_ISO=""

    if [[ -n "$LAST_HUMAN_EPOCH_S" ]]; then
        ELAPSED_S=$(( NOW_EPOCH - LAST_HUMAN_EPOCH_S ))
        HOURS_SINCE=$(( ELAPSED_S / 3600 ))
        LAST_HUMAN_ISO=$(epoch_to_iso "$LAST_HUMAN_EPOCH_S")
    fi

    if [[ "$HAS_NEW_SCHEMA" == "true" ]]; then
        # New schema: checkin-guard.sh already tracks missed_checkins accurately
        MISSED_COUNT=$MISSED_FROM_STATE
    else
        # Old schema: fall back to elapsed-time calculation
        if [[ -n "$LAST_HUMAN_EPOCH_S" ]]; then
            ELAPSED_S=$(( NOW_EPOCH - LAST_HUMAN_EPOCH_S ))
            ELAPSED_MINUTES=$(( ELAPSED_S / 60 ))

            # Calculate how many check-in intervals have passed without human interaction
            if [[ "$INTERVAL_MINUTES" -gt 0 ]]; then
                MISSED_COUNT=$(( ELAPSED_MINUTES / INTERVAL_MINUTES ))
            fi
        else
            # No session data at all -- treat as potentially missed
            log "  No session data found for $agent"
            if [[ "$AWAITING_RESPONSE" == "true" ]]; then
                MISSED_COUNT=$((THRESHOLD))
            fi
        fi

        # Check if alert threshold is met
        # Case 1: awaiting_response is true and time since check-in exceeds interval
        if [[ "$AWAITING_RESPONSE" == "true" && -n "$LAST_CHECK_IN" ]]; then
            # Parse last_check_in timestamp to epoch
            CHECK_IN_EPOCH=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$LAST_CHECK_IN" '+%s' 2>/dev/null \
                || date -u -d "$LAST_CHECK_IN" '+%s' 2>/dev/null \
                || echo "0")

            if [[ "$CHECK_IN_EPOCH" != "0" ]]; then
                SINCE_CHECKIN_MIN=$(( (NOW_EPOCH - CHECK_IN_EPOCH) / 60 ))
                if [[ "$SINCE_CHECKIN_MIN" -ge "$INTERVAL_MINUTES" ]]; then
                    MISSED_COUNT=$(( SINCE_CHECKIN_MIN / INTERVAL_MINUTES ))
                fi
            fi
        fi

        # Case 2: no activity for longer than (poll_interval * threshold)
        MAX_SILENCE=$(( INTERVAL_MINUTES * THRESHOLD ))
        if [[ -n "$LAST_HUMAN_EPOCH_S" ]]; then
            ELAPSED_MINUTES=$(( (NOW_EPOCH - LAST_HUMAN_EPOCH_S) / 60 ))
            if [[ "$ELAPSED_MINUTES" -ge "$MAX_SILENCE" ]]; then
                POTENTIAL_MISSED=$(( ELAPSED_MINUTES / INTERVAL_MINUTES ))
                if [[ "$POTENTIAL_MISSED" -gt "$MISSED_COUNT" ]]; then
                    MISSED_COUNT=$POTENTIAL_MISSED
                fi
            fi
        fi
    fi

    # ── Determine severity ──────────────────
    if [[ "$MISSED_COUNT" -ge "$THRESHOLD" ]]; then
        if [[ "$MISSED_COUNT" -ge $(( THRESHOLD * 2 )) ]]; then
            SEVERITY="critical"
        else
            SEVERITY="warning"
        fi

        ALERT=$(jq -n \
            --arg agent "$agent" \
            --arg developer "$agent" \
            --argjson missed "$MISSED_COUNT" \
            --arg last "${LAST_HUMAN_ISO:-}" \
            --argjson hours "$HOURS_SINCE" \
            --arg severity "$SEVERITY" \
            '{
                agent: $agent,
                developer: $developer,
                missed_count: $missed,
                last_human_interaction: (if $last == "" then null else $last end),
                hours_since_interaction: $hours,
                severity: $severity
            }')

        ALERTS=$(echo "$ALERTS" | jq --argjson alert "$ALERT" '. + [$alert]')
        log "  ALERT: $agent missed $MISSED_COUNT check-ins (severity: $SEVERITY)"
    else
        log "  OK: $agent missed $MISSED_COUNT check-ins (below threshold $THRESHOLD)"
    fi
done

# ── Build output ────────────────────────────
ALERT_COUNT=$(echo "$ALERTS" | jq 'length')
ALL_CLEAR="true"
if [[ "$ALERT_COUNT" -gt 0 ]]; then
    ALL_CLEAR="false"
fi

DATA=$(jq -n \
    --argjson threshold "$THRESHOLD" \
    --argjson alerts "$ALERTS" \
    --argjson all_clear "$ALL_CLEAR" \
    '{
        threshold: $threshold,
        alerts: $alerts,
        all_clear: $all_clear
    }')

log "Missed check-in scan complete: $ALERT_COUNT alerts"

json_success "check-missed-checkins" "$DATA"
