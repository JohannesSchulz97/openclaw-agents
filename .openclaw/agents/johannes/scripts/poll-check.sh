#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Args ──────────────────────────────────────
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
[[ ${#REMAINING_ARGS[@]} -gt 0 ]] && set -- "${REMAINING_ARGS[@]}" || true

# ── Config ────────────────────────────────────
AGENT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
POLL_STATE_FILE="$AGENT_DIR/memory/poll-state.json"

# ── Main Logic ───────────────────────────────
log "Checking poll state..."

# Create default poll state if not exists
if [[ ! -f "$POLL_STATE_FILE" ]]; then
    log "Creating default poll state..."
    mkdir -p "$(dirname "$POLL_STATE_FILE")"
    jq -n \
        --arg ts "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        '{interval_minutes: 240, last_interaction: $ts}' > "$POLL_STATE_FILE"
fi

# Read poll state
INTERVAL_MINUTES=$(jq -r '.interval_minutes // 240' "$POLL_STATE_FILE")
LAST_INTERACTION=$(jq -r '.last_interaction // empty' "$POLL_STATE_FILE")

if [[ -z "$LAST_INTERACTION" ]]; then
    json_error "poll-check" "NO_LAST_INTERACTION" "No last_interaction in poll-state.json"
    exit 1
fi

# Calculate if poll is due
LAST_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_INTERACTION" +%s 2>/dev/null || echo "0")
NOW_EPOCH=$(date -u +%s)
ELAPSED_MINUTES=$(( (NOW_EPOCH - LAST_EPOCH) / 60 ))
DUE=$((ELAPSED_MINUTES >= INTERVAL_MINUTES))

log "Last interaction: $LAST_INTERACTION (${ELAPSED_MINUTES}m ago), interval: ${INTERVAL_MINUTES}m, due: $DUE"

# ── Output ────────────────────────────────────
json_success "poll-check" "$(jq -n \
    --argjson due "$DUE" \
    --argjson interval "$INTERVAL_MINUTES" \
    --arg last "$LAST_INTERACTION" \
    --argjson elapsed "$ELAPSED_MINUTES" \
    '{due: $due, interval_minutes: $interval, last_interaction: $last, elapsed_minutes: $elapsed}')"