#!/usr/bin/env bash
set -euo pipefail

# checkin-guard.sh — Lightweight guard for time-of-day check-ins.
# Usage: checkin-guard.sh <morning|midday|evening> [--quiet]
# Output: JSON via json-response.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency check ─────────────────────────
if ! command -v jq &>/dev/null; then
    echo '{"success":false,"operation":"checkin-guard","error":{"code":"MISSING_DEP","message":"jq is required but not found"}}' >&2
    exit 1
fi

# ── Args ──────────────────────────────────────
CHECKIN_TYPE="${1:-unknown}"
shift || true

case "$CHECKIN_TYPE" in
    morning|midday|evening) ;;
    *)
        json_error "checkin-guard" "INVALID_TYPE" "checkin_type must be morning, midday, or evening (got: $CHECKIN_TYPE)"
        exit 1
        ;;
esac

REMAINING_ARGS=()
QUIET=false
for arg in "$@"; do
    case "$arg" in
        --quiet)
            QUIET=true
            ;;
        *)
            REMAINING_ARGS+=("$arg")
            ;;
    esac
done

# ── Config ────────────────────────────────────
AGENT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT_NAME="$(basename "$AGENT_DIR")"
SKIP_IF_ACTIVE_MINUTES=20
SESSIONS_FILE="$AGENT_DIR/sessions/sessions.json"
POLL_STATE_FILE="$AGENT_DIR/memory/poll-state.json"

# ── Ensure poll-state.json exists ─────────────
if [[ ! -f "$POLL_STATE_FILE" ]]; then
    log "Creating default poll state..."
    mkdir -p "$(dirname "$POLL_STATE_FILE")"
    jq -n '{
        morning_responded: false,
        midday_responded: false,
        evening_responded: false,
        last_morning_epoch: 0,
        last_midday_epoch: 0,
        last_evening_epoch: 0,
        missed_checkins: 0,
        checkin_dispatched: false,
        last_state_date: ""
    }' > "$POLL_STATE_FILE"
fi

# ── Query last human interaction ──────────────
LAST_HUMAN_EPOCH_S=""
NOW_EPOCH=$(date -u +%s)

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

# ── Check if developer was recently active ────
SKIP=false
REASON=""

if [[ -n "$LAST_HUMAN_EPOCH_S" ]]; then
    MINUTES_AGO=$(( (NOW_EPOCH - LAST_HUMAN_EPOCH_S) / 60 ))
    if (( MINUTES_AGO < SKIP_IF_ACTIVE_MINUTES )); then
        SKIP=true
        REASON="Developer active ${MINUTES_AGO} min ago"
    fi
else
    MINUTES_AGO=0
fi

# ── Response tracking via poll-state.json ─────
# Read current state (with fallback defaults for missing keys)
MORNING_RESPONDED=$(jq -r '.morning_responded // false' "$POLL_STATE_FILE" 2>/dev/null || echo "false")
MIDDAY_RESPONDED=$(jq -r '.midday_responded // false' "$POLL_STATE_FILE" 2>/dev/null || echo "false")
EVENING_RESPONDED=$(jq -r '.evening_responded // false' "$POLL_STATE_FILE" 2>/dev/null || echo "false")
LAST_MORNING_EPOCH=$(jq -r '.last_morning_epoch // 0' "$POLL_STATE_FILE" 2>/dev/null || echo "0")
LAST_MIDDAY_EPOCH=$(jq -r '.last_midday_epoch // 0' "$POLL_STATE_FILE" 2>/dev/null || echo "0")
LAST_EVENING_EPOCH=$(jq -r '.last_evening_epoch // 0' "$POLL_STATE_FILE" 2>/dev/null || echo "0")
MISSED_CHECKINS=$(jq -r '.missed_checkins // 0' "$POLL_STATE_FILE" 2>/dev/null || echo "0")
LAST_STATE_DATE=$(jq -r '.last_state_date // ""' "$POLL_STATE_FILE" 2>/dev/null || echo "")

# ── Bug 1: State consistency validation ──────
# If X_responded is true but last_X_epoch is 0, the state is inconsistent — reset the flag
if [[ "$MORNING_RESPONDED" == "true" && "$LAST_MORNING_EPOCH" == "0" ]]; then
    log "State inconsistency: morning_responded=true but last_morning_epoch=0, resetting flag"
    MORNING_RESPONDED=false
fi
if [[ "$MIDDAY_RESPONDED" == "true" && "$LAST_MIDDAY_EPOCH" == "0" ]]; then
    log "State inconsistency: midday_responded=true but last_midday_epoch=0, resetting flag"
    MIDDAY_RESPONDED=false
fi
if [[ "$EVENING_RESPONDED" == "true" && "$LAST_EVENING_EPOCH" == "0" ]]; then
    log "State inconsistency: evening_responded=true but last_evening_epoch=0, resetting flag"
    EVENING_RESPONDED=false
fi

# ── Bug 3: Inter-day state hygiene ───────────
TODAY_DATE=$(date -u +%Y-%m-%d)
if [[ -n "$LAST_STATE_DATE" && "$LAST_STATE_DATE" != "$TODAY_DATE" ]]; then
    log "Day-boundary reset: last_state_date=$LAST_STATE_DATE, today=$TODAY_DATE — resetting daily state"
    MORNING_RESPONDED=false
    MIDDAY_RESPONDED=false
    EVENING_RESPONDED=false
    LAST_MORNING_EPOCH=0
    LAST_MIDDAY_EPOCH=0
    LAST_EVENING_EPOCH=0
    MISSED_CHECKINS=0
fi

# Determine if any human session is newer than the last check-in of each type
# If so, mark that type as responded
if [[ -n "$LAST_HUMAN_EPOCH_S" ]]; then
    if (( LAST_HUMAN_EPOCH_S > LAST_MORNING_EPOCH && LAST_MORNING_EPOCH > 0 )); then
        MORNING_RESPONDED=true
    fi
    if (( LAST_HUMAN_EPOCH_S > LAST_MIDDAY_EPOCH && LAST_MIDDAY_EPOCH > 0 )); then
        MIDDAY_RESPONDED=true
    fi
    if (( LAST_HUMAN_EPOCH_S > LAST_EVENING_EPOCH && LAST_EVENING_EPOCH > 0 )); then
        EVENING_RESPONDED=true
    fi
fi

# Determine if the PREVIOUS check-in was unanswered
# morning checks evening (yesterday), midday checks morning, evening checks midday
PREV_UNANSWERED=false
case "$CHECKIN_TYPE" in
    morning)
        if [[ "$EVENING_RESPONDED" == "false" && "$LAST_EVENING_EPOCH" -gt 0 ]]; then
            PREV_UNANSWERED=true
        fi
        ;;
    midday)
        if [[ "$MORNING_RESPONDED" == "false" && "$LAST_MORNING_EPOCH" -gt 0 ]]; then
            PREV_UNANSWERED=true
        fi
        ;;
    evening)
        if [[ "$MIDDAY_RESPONDED" == "false" && "$LAST_MIDDAY_EPOCH" -gt 0 ]]; then
            PREV_UNANSWERED=true
        fi
        ;;
esac

# Update missed_checkins counter
if [[ "$PREV_UNANSWERED" == "true" ]]; then
    MISSED_CHECKINS=$(( MISSED_CHECKINS + 1 ))
fi

# If any response was detected since last state, reset missed counter
ANY_RESPONSE=false
if [[ "$MORNING_RESPONDED" == "true" || "$MIDDAY_RESPONDED" == "true" || "$EVENING_RESPONDED" == "true" ]]; then
    ANY_RESPONSE=true
fi
if [[ "$ANY_RESPONSE" == "true" && "$PREV_UNANSWERED" == "false" ]]; then
    MISSED_CHECKINS=0
fi

# Record this check-in and reset its responded flag
# (The current type just fired, so mark it as not-yet-responded)
case "$CHECKIN_TYPE" in
    morning)
        LAST_MORNING_EPOCH=$NOW_EPOCH
        MORNING_RESPONDED=false
        ;;
    midday)
        LAST_MIDDAY_EPOCH=$NOW_EPOCH
        MIDDAY_RESPONDED=false
        ;;
    evening)
        LAST_EVENING_EPOCH=$NOW_EPOCH
        EVENING_RESPONDED=false
        ;;
esac

# ── Write updated poll-state.json ─────────────
tmp_state=$(mktemp)
trap "rm -f '$tmp_state'" EXIT

jq -n \
    --argjson morning_responded "$MORNING_RESPONDED" \
    --argjson midday_responded "$MIDDAY_RESPONDED" \
    --argjson evening_responded "$EVENING_RESPONDED" \
    --argjson last_morning "$LAST_MORNING_EPOCH" \
    --argjson last_midday "$LAST_MIDDAY_EPOCH" \
    --argjson last_evening "$LAST_EVENING_EPOCH" \
    --argjson missed "$MISSED_CHECKINS" \
    --argjson awaiting "$(if [[ "$SKIP" == "true" ]]; then echo false; else echo true; fi)" \
    --arg state_date "$TODAY_DATE" \
    '{
        morning_responded: $morning_responded,
        midday_responded: $midday_responded,
        evening_responded: $evening_responded,
        last_morning_epoch: $last_morning,
        last_midday_epoch: $last_midday,
        last_evening_epoch: $last_evening,
        missed_checkins: $missed,
        checkin_dispatched: $awaiting,
        last_state_date: $state_date
    }' > "$tmp_state" 2>/dev/null && mv "$tmp_state" "$POLL_STATE_FILE"

log "Agent: $AGENT_NAME, type: $CHECKIN_TYPE, skip: $SKIP, reason: ${REASON:-none}, prev_unanswered: $PREV_UNANSWERED, missed: $MISSED_CHECKINS"

# ── Output ────────────────────────────────────
json_success "checkin-guard" "$(jq -n \
    --argjson skip "$SKIP" \
    --arg reason "$REASON" \
    --arg type "$CHECKIN_TYPE" \
    --argjson prev_unanswered "$PREV_UNANSWERED" \
    --argjson missed "$MISSED_CHECKINS" \
    --arg agent "$AGENT_NAME" \
    '{skip: $skip, reason: $reason, checkin_type: $type, prev_unanswered: $prev_unanswered, missed_checkins: $missed, agent_name: $agent}')"
