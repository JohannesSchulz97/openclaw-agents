#!/usr/bin/env bash
set -euo pipefail

# checkin-guard.sh — Lightweight guard for time-of-day check-ins.
# Usage: checkin-guard.sh <morning|midday|evening> [--quiet]
# Output: JSON via json-response.sh
#
# Stateless: reads sessions.json for last DM interaction, outputs decision.
# No poll-state.json dependency.

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

QUIET=false
for arg in "$@"; do
    case "$arg" in
        --quiet) QUIET=true ;;
    esac
done

# ── Config ────────────────────────────────────
AGENT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT_NAME="$(basename "$AGENT_DIR")"
SKIP_IF_ACTIVE_MINUTES=20
SESSIONS_FILE="$AGENT_DIR/sessions/sessions.json"

# ── Query last human DM interaction ───────────
LAST_HUMAN_EPOCH_S=""
NOW_EPOCH=$(date -u +%s)

if [[ -f "$SESSIONS_FILE" ]]; then
    LAST_HUMAN_EPOCH_MS=$(jq -r '
        to_entries
        | map(select(.key | test("slack:direct:")))
        | map(.value.updatedAt // 0)
        | max // 0
    ' "$SESSIONS_FILE" 2>/dev/null || echo "0")

    if [[ "$LAST_HUMAN_EPOCH_MS" != "0" && "$LAST_HUMAN_EPOCH_MS" != "null" ]]; then
        LAST_HUMAN_EPOCH_S=$(( LAST_HUMAN_EPOCH_MS / 1000 ))
    fi
fi

# ── Compute hours since last interaction ──────
HOURS_SINCE_INTERACTION=0
LAST_INTERACTION=""

if [[ -n "$LAST_HUMAN_EPOCH_S" ]]; then
    ELAPSED_S=$(( NOW_EPOCH - LAST_HUMAN_EPOCH_S ))
    HOURS_SINCE_INTERACTION=$(( ELAPSED_S / 3600 ))

    # ISO timestamp (macOS + GNU compatible)
    if date -u -r "$LAST_HUMAN_EPOCH_S" '+%Y-%m-%dT%H:%M:%SZ' &>/dev/null; then
        LAST_INTERACTION=$(date -u -r "$LAST_HUMAN_EPOCH_S" '+%Y-%m-%dT%H:%M:%SZ')
    else
        LAST_INTERACTION=$(date -u -d "@$LAST_HUMAN_EPOCH_S" '+%Y-%m-%dT%H:%M:%SZ')
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
fi

log "Agent: $AGENT_NAME, type: $CHECKIN_TYPE, skip: $SKIP, reason: ${REASON:-none}, hours_since: $HOURS_SINCE_INTERACTION, last: ${LAST_INTERACTION:-never}"

# ── Output ────────────────────────────────────
json_success "checkin-guard" "$(jq -n \
    --argjson skip "$SKIP" \
    --arg reason "$REASON" \
    --arg type "$CHECKIN_TYPE" \
    --arg last_interaction "$LAST_INTERACTION" \
    --argjson hours_since "$HOURS_SINCE_INTERACTION" \
    --arg agent "$AGENT_NAME" \
    '{skip: $skip, reason: $reason, checkin_type: $type, last_interaction: (if $last_interaction == "" then null else $last_interaction end), hours_since_interaction: $hours_since, agent_name: $agent}')"
