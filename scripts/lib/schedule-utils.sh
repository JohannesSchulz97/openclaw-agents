#!/usr/bin/env bash
# schedule-utils.sh — Schedule computation library for cron check-in timing.
# Sourced by scripts that need to compute check-in schedules from work-schedule.json.
#
# Functions:
#   compute_checkin_times  — derive morning/midday/evening hours from work window
#   build_cron_expr        — produce a 5-field cron expression
#   validate_timezone      — test whether a string is a valid IANA timezone
#   parse_work_schedule    — read work-schedule.json and export schedule vars

set -euo pipefail

# --------------------------------------------------------------------------- #
# Source guard — prevent direct execution
# --------------------------------------------------------------------------- #
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: schedule-utils.sh is a library and must be sourced, not executed directly." >&2
    echo "Usage: source \"\$(dirname \"\$0\")/lib/schedule-utils.sh\"" >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# compute_checkin_times <start_hour> <end_hour>
#
# Sets: MORNING_HOUR, MORNING_MIN, MIDDAY_HOUR, MIDDAY_MIN,
#       EVENING_HOUR, EVENING_MIN
#
# - morning  = start_hour:00
# - midday   = start + floor((end - start) / 2), rounded to :00 or :30
# - evening  = end_hour minus 30 min
# --------------------------------------------------------------------------- #
compute_checkin_times() {
    local start_hour="${1:?Usage: compute_checkin_times <start_hour> <end_hour>}"
    local end_hour="${2:?Missing end_hour}"

    if (( end_hour <= start_hour )); then
        echo "Error: end_hour ($end_hour) must be greater than start_hour ($start_hour). Overnight schedules are not yet supported." >&2
        return 1
    fi

    # Morning: exactly at start
    MORNING_HOUR=$start_hour
    MORNING_MIN=0

    # Midday: start + floor((end - start) / 2)
    local span=$(( end_hour - start_hour ))
    local half=$(( span / 2 ))
    # Round to nearest :00 or :30
    # If span is odd, half has a .5 component — use :30
    if (( span % 2 == 1 )); then
        MIDDAY_HOUR=$(( start_hour + half ))
        MIDDAY_MIN=30
    else
        MIDDAY_HOUR=$(( start_hour + half ))
        MIDDAY_MIN=0
    fi

    # Evening: end_hour minus 30 min
    if (( end_hour > 0 )); then
        EVENING_HOUR=$(( end_hour - 1 ))
        EVENING_MIN=30
    else
        # Edge case: end_hour is 0 (midnight) → 23:30
        EVENING_HOUR=23
        EVENING_MIN=30
    fi
}

# --------------------------------------------------------------------------- #
# build_cron_expr <hour> <minute> <works_weekends>
#
# Returns a 5-field cron expression string.
#   works_weekends = true  → "MIN HOUR * * *"
#   works_weekends = false → "MIN HOUR * * 1-5"
# --------------------------------------------------------------------------- #
build_cron_expr() {
    local hour="${1:?Usage: build_cron_expr <hour> <minute> <works_weekends>}"
    local minute="${2:?Missing minute}"
    local works_weekends="${3:?Missing works_weekends}"

    local dow="1-5"
    if [[ "$works_weekends" == "true" ]]; then
        dow="*"
    fi

    echo "$minute $hour * * $dow"
}

# --------------------------------------------------------------------------- #
# validate_timezone <tz>
#
# Returns 0 if valid IANA timezone, 1 if invalid.
# --------------------------------------------------------------------------- #
validate_timezone() {
    local tz="${1:?Usage: validate_timezone <tz>}"

    # Use TZ= date to test validity; invalid TZ produces an error on some
    # systems or silently falls back to UTC. Check that the zone is recognised
    # by comparing output with a known-bad zone.
    if TZ="$tz" date '+%Z' &>/dev/null; then
        # Additional check: reject obviously invalid zones by testing if
        # the timezone file exists in the zoneinfo database
        local zoneinfo_paths=(
            "/usr/share/zoneinfo/$tz"
            "/usr/share/lib/zoneinfo/$tz"
            "/usr/lib/locale/TZ/$tz"
        )
        for path in "${zoneinfo_paths[@]}"; do
            if [[ -f "$path" ]]; then
                return 0
            fi
        done
        # macOS: zoneinfo is at /var/db/timezone/zoneinfo/
        if [[ -f "/var/db/timezone/zoneinfo/$tz" ]]; then
            return 0
        fi
        # If no zoneinfo file found, fall back to accepting "UTC" explicitly
        if [[ "$tz" == "UTC" || "$tz" == "GMT" ]]; then
            return 0
        fi
        return 1
    else
        return 1
    fi
}

# --------------------------------------------------------------------------- #
# parse_work_schedule <json_file>
#
# Reads work-schedule.json and sets:
#   WS_TIMEZONE, WS_START_HOUR, WS_END_HOUR, WS_WORKS_WEEKENDS,
#   WS_HOURS_PER_DAY (empty string if not set in JSON)
#
# Returns 1 if file missing or invalid.
# --------------------------------------------------------------------------- #
parse_work_schedule() {
    local json_file="${1:?Usage: parse_work_schedule <json_file>}"

    if [[ ! -f "$json_file" ]]; then
        echo "Error: Work schedule file not found: $json_file" >&2
        return 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required but not installed." >&2
        return 1
    fi

    # Parse all fields in one jq call
    local parsed
    parsed=$(jq -r '[
        .timezone // "UTC",
        (.working_hours.start // "09:00" | split(":")[0] | tonumber),
        (.working_hours.end // "18:00" | split(":")[0] | tonumber),
        (.works_weekends // false | tostring),
        (.hours_per_day // empty | tostring)
    ] | @tsv' "$json_file" 2>/dev/null) || {
        echo "Error: Failed to parse work schedule: $json_file" >&2
        return 1
    }

    # Read tab-separated values
    IFS=$'\t' read -r WS_TIMEZONE WS_START_HOUR WS_END_HOUR WS_WORKS_WEEKENDS WS_HOURS_PER_DAY <<< "$parsed"

    # Validate that we got numeric hours
    if ! [[ "$WS_START_HOUR" =~ ^[0-9]+$ ]] || ! [[ "$WS_END_HOUR" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid hours in work schedule: start=$WS_START_HOUR end=$WS_END_HOUR" >&2
        return 1
    fi
}
