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
THRESHOLD_HOURS=12
BASE_DIR="$HOME/.openclaw/agents"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agents)
            AGENTS="$2"
            shift 2
            ;;
        --threshold)
            THRESHOLD_HOURS="$2"
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

    # ── Availability check — skip if non-working day or time off ───────────
    AVAILABILITY_GUARD="$AGENT_DIR/scripts/availability-guard.sh"
    if [[ -f "$AVAILABILITY_GUARD" ]]; then
        GUARD_RESULT=$(bash "$AVAILABILITY_GUARD" 2>/dev/null || echo '{}')
        GUARD_STATUS=$(echo "$GUARD_RESULT" | jq -r '.data.status // "proceed"')
        if [[ "$GUARD_STATUS" != "proceed" ]]; then
            log "  SKIP: $agent not available today (status: $GUARD_STATUS)"
            continue
        fi
    fi

    # ── Get last human DM interaction ──────
    SESSIONS_FILE="$AGENT_DIR/sessions/sessions.json"
    LAST_HUMAN_EPOCH_S=""

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

    # ── Compute hours since interaction ────
    HOURS_SINCE=0
    SEVERITY="none"
    LAST_HUMAN_ISO=""

    if [[ -n "$LAST_HUMAN_EPOCH_S" ]]; then
        ELAPSED_S=$(( NOW_EPOCH - LAST_HUMAN_EPOCH_S ))
        HOURS_SINCE=$(( ELAPSED_S / 3600 ))
        LAST_HUMAN_ISO=$(epoch_to_iso "$LAST_HUMAN_EPOCH_S")
    fi

    # ── Determine severity ──────────────────
    if [[ "$HOURS_SINCE" -ge "$THRESHOLD_HOURS" ]]; then
        if [[ "$HOURS_SINCE" -ge $(( THRESHOLD_HOURS * 3 )) ]]; then
            SEVERITY="critical"
        elif [[ "$HOURS_SINCE" -ge $(( THRESHOLD_HOURS * 2 )) ]]; then
            SEVERITY="warning"
        else
            SEVERITY="info"
        fi

        ALERT=$(jq -n \
            --arg agent "$agent" \
            --arg last "${LAST_HUMAN_ISO:-}" \
            --argjson hours "$HOURS_SINCE" \
            --arg severity "$SEVERITY" \
            '{
                agent: $agent,
                last_interaction: (if $last == "" then null else $last end),
                hours_since_interaction: $hours,
                severity: $severity
            }')

        ALERTS=$(echo "$ALERTS" | jq --argjson alert "$ALERT" '. + [$alert]')
        log "  ALERT: $agent silent for ${HOURS_SINCE}h (severity: $SEVERITY)"
    else
        log "  OK: $agent last interacted ${HOURS_SINCE}h ago (below threshold ${THRESHOLD_HOURS}h)"
    fi
done

# ── Build output ────────────────────────────
ALERT_COUNT=$(echo "$ALERTS" | jq 'length')
ALL_CLEAR="true"
if [[ "$ALERT_COUNT" -gt 0 ]]; then
    ALL_CLEAR="false"
fi

DATA=$(jq -n \
    --argjson threshold "$THRESHOLD_HOURS" \
    --argjson alerts "$ALERTS" \
    --argjson all_clear "$ALL_CLEAR" \
    '{
        threshold_hours: $threshold,
        alerts: $alerts,
        all_clear: $all_clear
    }')

log "Missed check-in scan complete: $ALERT_COUNT alerts"

json_success "check-missed-checkins" "$DATA"
