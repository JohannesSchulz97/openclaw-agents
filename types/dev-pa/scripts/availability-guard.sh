#!/usr/bin/env bash
set -euo pipefail

# availability-guard.sh — Check whether the developer is available today.
# Reads work-schedule.json: working_days, works_weekends (fallback), and time_off intervals.
# Cleans up past time_off entries on every run.
#
# Usage: availability-guard.sh [--quiet]
# Output: JSON via json-response.sh
#   data.status: "proceed" | "non_working_day" | "off_time"
#   data.reason: human-readable string

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

if ! command -v jq &>/dev/null; then
    echo '{"success":false,"operation":"availability-guard","error":{"code":"MISSING_DEP","message":"jq is required but not found"}}' >&2
    exit 1
fi

parse_quiet_flag "$@"

AGENT_DIR="$(dirname "$SCRIPT_DIR")"
SCHEDULE_FILE="$AGENT_DIR/work-schedule.json"

if [[ ! -f "$SCHEDULE_FILE" ]]; then
    json_error "availability-guard" "MISSING_FILE" "work-schedule.json not found at $SCHEDULE_FILE"
    exit 1
fi

# ── Read schedule ─────────────────────────────
TIMEZONE=$(jq -r '.timezone // "UTC"' "$SCHEDULE_FILE")
WORKS_WEEKENDS=$(jq -r '.works_weekends // false' "$SCHEDULE_FILE")

# ── Today in agent timezone ───────────────────
TODAY=$(TZ="$TIMEZONE" date '+%Y-%m-%d')
TODAY_DOW=$(TZ="$TIMEZONE" date '+%u')  # 1=Mon ... 7=Sun
TODAY_DOW_NAME=$(TZ="$TIMEZONE" date '+%a' | tr '[:upper:]' '[:lower:]')  # mon, tue, ...

log "availability-guard: agent=$AGENT_DIR, today=$TODAY ($TODAY_DOW_NAME), tz=$TIMEZONE"

# ── Check working_days (falls back to works_weekends) ────────────────────────
WORKING_DAYS=$(jq -r '.working_days // empty' "$SCHEDULE_FILE" 2>/dev/null)

IS_WORKING_DAY=true
if [[ -n "$WORKING_DAYS" ]]; then
    MATCH=$(jq -r --arg dow "$TODAY_DOW_NAME" '.working_days | map(ascii_downcase) | contains([$dow])' "$SCHEDULE_FILE" 2>/dev/null || echo "false")
    if [[ "$MATCH" != "true" ]]; then
        IS_WORKING_DAY=false
    fi
else
    # Legacy fallback: works_weekends boolean
    if [[ "$WORKS_WEEKENDS" == "false" && "$TODAY_DOW" -ge 6 ]]; then
        IS_WORKING_DAY=false
    fi
fi

if [[ "$IS_WORKING_DAY" == "false" ]]; then
    log "Non-working day: $TODAY_DOW_NAME"
    json_success "availability-guard" "$(jq -n \
        --arg status "non_working_day" \
        --arg reason "Today ($TODAY_DOW_NAME) is not a working day" \
        --arg today "$TODAY" \
        '{status: $status, reason: $reason, today: $today}')"
    exit 0
fi

# ── Check time_off intervals + clean stale entries ───────────────────────────
STATUS="proceed"
REASON=""

STALE_COUNT=$(jq --arg today "$TODAY" '[.time_off // [] | .[] | select(.end < $today)] | length' "$SCHEDULE_FILE")
KEPT_INTERVALS=$(jq --arg today "$TODAY" '[.time_off // [] | .[] | select(.end >= $today)]' "$SCHEDULE_FILE")

if [[ "$STALE_COUNT" -gt 0 ]]; then
    log "Removing $STALE_COUNT stale time_off entries"
    tmp=$(mktemp)
    trap "rm -f '$tmp'" EXIT
    jq --argjson kept "$KEPT_INTERVALS" '.time_off = $kept' "$SCHEDULE_FILE" > "$tmp" && mv "$tmp" "$SCHEDULE_FILE"
fi

OFF_INTERVAL=$(echo "$KEPT_INTERVALS" | jq -r --arg today "$TODAY" \
    'first(.[] | select(.start <= $today and .end >= $today) | "\(.start)|\(.end)") // ""')

if [[ -n "$OFF_INTERVAL" ]]; then
    OFF_START="${OFF_INTERVAL%%|*}"
    OFF_END="${OFF_INTERVAL##*|}"
    STATUS="off_time"
    REASON="Developer on approved time off ($OFF_START to $OFF_END)"
    log "Off time: $OFF_START to $OFF_END"
fi

if [[ "$STATUS" == "proceed" ]]; then
    REASON="Working day, no time off"
fi

log "Result: $STATUS — $REASON"

json_success "availability-guard" "$(jq -n \
    --arg status "$STATUS" \
    --arg reason "$REASON" \
    --arg today "$TODAY" \
    '{status: $status, reason: $reason, today: $today}')"
