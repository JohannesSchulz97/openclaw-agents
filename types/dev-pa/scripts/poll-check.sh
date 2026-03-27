#!/usr/bin/env bash
# DEPRECATED: This script is replaced by checkin-guard.sh for time-of-day check-ins.
# Kept for backward compatibility. Will be removed in a future release.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency check ─────────────────────────
if ! command -v jq &>/dev/null; then
    echo '{"success":false,"operation":"poll-check","error":{"code":"MISSING_DEP","message":"jq is required but not found"}}' >&2
    exit 1
fi

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
AGENT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT_NAME="$(basename "$AGENT_DIR")"
POLL_CONFIG_FILE="$AGENT_DIR/poll-config.json"
POLL_STATE_FILE="$AGENT_DIR/memory/poll-state.json"
SESSIONS_FILE="$HOME/.openclaw/agents/$AGENT_NAME/sessions/sessions.json"

# ── Ensure poll-config.json exists ────────────
if [[ ! -f "$POLL_CONFIG_FILE" ]]; then
    log "Creating default poll config..."
    jq -n '{interval_minutes: 240}' > "$POLL_CONFIG_FILE"
fi

# ── Ensure poll-state.json exists ─────────────
if [[ ! -f "$POLL_STATE_FILE" ]]; then
    log "Creating default poll state..."
    mkdir -p "$(dirname "$POLL_STATE_FILE")"
    jq -n '{awaiting_response: false}' > "$POLL_STATE_FILE"
fi

# Read config and state from separate files
INTERVAL_MINUTES=$(jq -r '.interval_minutes // 240' "$POLL_CONFIG_FILE")
AWAITING_RESPONSE=$(jq -r '.awaiting_response // false' "$POLL_STATE_FILE")

# ── Query last human interaction ──────────────
LAST_HUMAN_EPOCH_S=""
LAST_HUMAN_ISO=""

if [[ ! -f "$SESSIONS_FILE" ]]; then
    log "WARNING: sessions.json not found at $SESSIONS_FILE"
else
    # Filter out cron sessions, get max updatedAt (epoch ms), convert to seconds
    LAST_HUMAN_EPOCH_MS=$(jq -r '
        to_entries
        | map(select(.key | test("cron") | not))
        | map(.value.updatedAt // 0)
        | max // 0
    ' "$SESSIONS_FILE" 2>/dev/null || echo "0")

    if [[ "$LAST_HUMAN_EPOCH_MS" != "0" && "$LAST_HUMAN_EPOCH_MS" != "null" ]]; then
        LAST_HUMAN_EPOCH_S=$(( LAST_HUMAN_EPOCH_MS / 1000 ))
        LAST_HUMAN_ISO=$(date -u -r "$LAST_HUMAN_EPOCH_S" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo "")
    fi
fi

# ── Decision logic ────────────────────────────
NOW_EPOCH=$(date -u +%s)

if [[ "$AWAITING_RESPONSE" == "true" ]]; then
    DUE=0
    if [[ -n "$LAST_HUMAN_EPOCH_S" ]]; then
        ELAPSED_MINUTES=$(( (NOW_EPOCH - LAST_HUMAN_EPOCH_S) / 60 ))
    else
        ELAPSED_MINUTES=0
    fi
elif [[ -z "$LAST_HUMAN_EPOCH_S" ]]; then
    # No human sessions found - should check in
    DUE=1
    ELAPSED_MINUTES=0
else
    ELAPSED_MINUTES=$(( (NOW_EPOCH - LAST_HUMAN_EPOCH_S) / 60 ))
    if (( ELAPSED_MINUTES >= INTERVAL_MINUTES )); then
        DUE=1
    else
        DUE=0
    fi
fi

log "Agent: $AGENT_NAME, last human interaction: ${LAST_HUMAN_ISO:-none} (${ELAPSED_MINUTES}m ago), interval: ${INTERVAL_MINUTES}m, awaiting: $AWAITING_RESPONSE, due: $DUE"

# ── Output ────────────────────────────────────
json_success "poll-check" "$(jq -n \
    --argjson due "$DUE" \
    --argjson interval "$INTERVAL_MINUTES" \
    --argjson elapsed "$ELAPSED_MINUTES" \
    --argjson awaiting "$AWAITING_RESPONSE" \
    --arg last "${LAST_HUMAN_ISO:-}" \
    --arg agent "$AGENT_NAME" \
    '{due: $due, interval_minutes: $interval, elapsed_minutes: $elapsed, awaiting_response: $awaiting, last_human_interaction: $last, agent_name: $agent}')"
