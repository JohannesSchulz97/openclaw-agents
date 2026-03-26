#!/usr/bin/env bash
# json-response.sh - Standard library for deterministic scripts
# Provides: log, json_timestamp, json_success, json_error, parse_quiet_flag

# Log to stderr (use for all human-readable output)
log() {
    echo "[$(date '+%Y-%m-%dT%H:%M:%S')] $*" >&2
}

# ISO 8601 UTC timestamp
json_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# Success response: json_success <operation> <data_json>
json_success() {
    local operation="$1"
    local data="$2"
    jq -n \
        --arg op "$operation" \
        --arg ts "$(json_timestamp)" \
        --argjson d "$data" \
        '{success: true, operation: $op, timestamp: $ts, data: $d}'
}

# Error response: json_error <operation> <code> <message> [details]
json_error() {
    local operation="$1"
    local code="$2"
    local message="$3"
    local details="${4:-}"

    if [[ -n "$details" ]]; then
        jq -n \
            --arg op "$operation" \
            --arg ts "$(json_timestamp)" \
            --arg c "$code" \
            --arg m "$message" \
            --arg d "$details" \
            '{success: false, operation: $op, timestamp: $ts, error: {code: $c, message: $m, details: $d}}'
    else
        jq -n \
            --arg op "$operation" \
            --arg ts "$(json_timestamp)" \
            --arg c "$code" \
            --arg m "$message" \
            '{success: false, operation: $op, timestamp: $ts, error: {code: $c, message: $m}}'
    fi
}

# Parse --quiet flag from args
parse_quiet_flag() {
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
}
