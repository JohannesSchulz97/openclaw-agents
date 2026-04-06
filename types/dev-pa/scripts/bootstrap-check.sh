#!/usr/bin/env bash
set -euo pipefail

# bootstrap-check.sh — Deterministic bootstrap state manager.
# Handles all mechanical state; the model only extracts values from conversation.
#
# Usage:
#   bootstrap-check.sh prepare                          → JSON with missing fields
#   bootstrap-check.sh update --field <key> --value <v> → updates a field, returns new state
#   bootstrap-check.sh identity-asked                   → increments agent_identity ask_count
#   bootstrap-check.sh identity-declined                → marks identity as completed (skipped)
#
# Output: JSON via json-response.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency check ─────────────────────────
if ! command -v jq &>/dev/null; then
    echo '{"success":false,"operation":"bootstrap-check","error":{"code":"MISSING_DEP","message":"jq is required but not found"}}' >&2
    exit 1
fi

# ── Args ──────────────────────────────────────
PHASE="${1:-}"
case "$PHASE" in
    prepare|update|identity-asked|identity-declined) ;;
    *)
        json_error "bootstrap-check" "INVALID_PHASE" "Usage: bootstrap-check.sh <prepare|update|identity-asked|identity-declined>"
        exit 1
        ;;
esac
shift || true

# ── Config ────────────────────────────────────
AGENT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT_NAME="$(basename "$AGENT_DIR")"
STATE_FILE="$AGENT_DIR/bootstrap-state.json"
IDENTITY_FILE="$AGENT_DIR/IDENTITY.md"
USER_FILE="$AGENT_DIR/USER.md"
WORK_SCHEDULE_FILE="$AGENT_DIR/work-schedule.json"

# ── Ensure bootstrap-state.json exists ────────
if [[ ! -f "$STATE_FILE" ]]; then
    TEMPLATE="$AGENT_DIR/bootstrap-state.json.template"
    if [[ -f "$TEMPLATE" ]]; then
        cp "$TEMPLATE" "$STATE_FILE"
        log "Created bootstrap-state.json from template"
    else
        # Fallback: create minimal state
        log "WARNING: No template found, creating minimal bootstrap-state.json"
        jq -n '{version:1, bootstrap_complete:false, fields:{}}' > "$STATE_FILE"
    fi
fi

# ── Auto-detection ────────────────────────────
auto_detect() {
    local changed=false

    # Slack ID from IDENTITY.md
    if [[ "$(jq -r '.fields.slack_id.completed' "$STATE_FILE")" == "false" ]]; then
        local slack_id=""
        if [[ -f "$IDENTITY_FILE" ]]; then
            slack_id=$(sed -n 's/.*\*\*Slack User ID:\*\* \(U[A-Z0-9]*\).*/\1/p' "$IDENTITY_FILE" 2>/dev/null | head -1 || true)
        fi
        if [[ -n "$slack_id" ]]; then
            local tmp; tmp=$(mktemp)
            jq --arg v "$slack_id" '.fields.slack_id.completed=true | .fields.slack_id.auto_detected=true | .fields.slack_id.value=$v' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
            log "Auto-detected slack_id: $slack_id"
            changed=true
        fi
    fi

    # GitHub usernames from USER.md
    if [[ "$(jq -r '.fields.github_usernames.completed' "$STATE_FILE")" == "false" ]]; then
        local github=""
        if [[ -f "$USER_FILE" ]]; then
            github=$(sed -n 's/.*\*\*GitHub:\*\* \(.*\)/\1/p' "$USER_FILE" 2>/dev/null | head -1 || true)
            # Skip template placeholders
            if [[ "$github" == *"<"* || -z "$github" ]]; then
                github=""
            fi
        fi
        if [[ -n "$github" ]]; then
            local tmp; tmp=$(mktemp)
            jq --arg v "$github" '.fields.github_usernames.completed=true | .fields.github_usernames.auto_detected=true | .fields.github_usernames.value=$v' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
            log "Auto-detected github_usernames: $github"
            changed=true
        fi
    fi

    # Work schedule from work-schedule.json
    if [[ "$(jq -r '.fields.work_schedule.completed' "$STATE_FILE")" == "false" ]]; then
        if [[ -f "$WORK_SCHEDULE_FILE" ]]; then
            local ws_value
            ws_value=$(jq -c '.' "$WORK_SCHEDULE_FILE" 2>/dev/null || true)
            if [[ -n "$ws_value" && "$ws_value" != "null" ]]; then
                local tmp; tmp=$(mktemp)
                jq --argjson v "$ws_value" '.fields.work_schedule.completed=true | .fields.work_schedule.auto_detected=true | .fields.work_schedule.value=$v' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                log "Auto-detected work_schedule from work-schedule.json"
                changed=true
            fi
        fi
    fi

    # Developer timezone from work-schedule.json
    if [[ "$(jq -r '.fields.developer_timezone.completed' "$STATE_FILE")" == "false" ]]; then
        if [[ -f "$WORK_SCHEDULE_FILE" ]]; then
            local tz
            tz=$(jq -r '.timezone // empty' "$WORK_SCHEDULE_FILE" 2>/dev/null || true)
            if [[ -n "$tz" ]]; then
                local tmp; tmp=$(mktemp)
                jq --arg v "$tz" '.fields.developer_timezone.completed=true | .fields.developer_timezone.auto_detected=true | .fields.developer_timezone.value=$v' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
                log "Auto-detected developer_timezone: $tz"
                changed=true
            fi
        fi
    fi

    # Agent identity from IDENTITY.md (non-empty Name: field)
    if [[ "$(jq -r '.fields.agent_identity.completed' "$STATE_FILE")" == "false" ]]; then
        local identity_name=""
        if [[ -f "$IDENTITY_FILE" ]]; then
            identity_name=$(sed -n 's/.*\*\*Name:\*\* \(.\+\)/\1/p' "$IDENTITY_FILE" 2>/dev/null | head -1 || true)
            # Skip empty or placeholder values
            if [[ "$identity_name" == "_" || -z "$identity_name" ]]; then
                identity_name=""
            fi
        fi
        if [[ -n "$identity_name" ]]; then
            local tmp; tmp=$(mktemp)
            jq --arg v "$identity_name" '.fields.agent_identity.completed=true | .fields.agent_identity.auto_detected=true | .fields.agent_identity.value=$v' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
            log "Auto-detected agent_identity: $identity_name"
            changed=true
        fi
    fi

    echo "$changed"
}

# ── Check bootstrap completeness ──────────────
check_completeness() {
    # Bootstrap is complete when all required fields are done
    # AND agent_identity is either done or max_asks reached
    local all_required_done identity_resolved
    all_required_done=$(jq '[.fields | to_entries[] | select(.value.required == true) | .value.completed] | all' "$STATE_FILE")
    identity_resolved=$(jq '
        .fields.agent_identity.completed == true or
        (.fields.agent_identity.ask_count // 0) >= (.fields.agent_identity.max_asks // 2)
    ' "$STATE_FILE")

    if [[ "$all_required_done" == "true" && "$identity_resolved" == "true" ]]; then
        local tmp; tmp=$(mktemp)
        jq '.bootstrap_complete = true' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
    fi
}

# ══════════════════════════════════════════════
# PREPARE phase
# ══════════════════════════════════════════════
if [[ "$PHASE" == "prepare" ]]; then

    auto_detect > /dev/null
    check_completeness

    BOOTSTRAP_COMPLETE=$(jq -r '.bootstrap_complete' "$STATE_FILE")

    # Build missing required fields list
    MISSING_REQUIRED=$(jq '[.fields | to_entries[] | select(.value.required == true and .value.completed == false) | {key: .key, description: .value.description}]' "$STATE_FILE")

    # Check identity status
    IDENTITY_COMPLETED=$(jq -r '.fields.agent_identity.completed' "$STATE_FILE")
    IDENTITY_ASK_COUNT=$(jq -r '.fields.agent_identity.ask_count // 0' "$STATE_FILE")
    IDENTITY_MAX_ASKS=$(jq -r '.fields.agent_identity.max_asks // 2' "$STATE_FILE")
    IDENTITY_AVAILABLE="false"
    if [[ "$IDENTITY_COMPLETED" == "false" && "$IDENTITY_ASK_COUNT" -lt "$IDENTITY_MAX_ASKS" ]]; then
        IDENTITY_AVAILABLE="true"
    fi

    log "Agent: $AGENT_NAME, complete: $BOOTSTRAP_COMPLETE, missing_required: $(echo "$MISSING_REQUIRED" | jq length), identity_available: $IDENTITY_AVAILABLE"

    json_success "bootstrap-check:prepare" "$(jq -n \
        --argjson bootstrap_complete "$BOOTSTRAP_COMPLETE" \
        --argjson missing_required "$MISSING_REQUIRED" \
        --argjson identity_ask_available "$IDENTITY_AVAILABLE" \
        --argjson identity_ask_count "$IDENTITY_ASK_COUNT" \
        --arg agent "$AGENT_NAME" \
        '{
            bootstrap_complete: $bootstrap_complete,
            missing_required: $missing_required,
            identity_ask_available: $identity_ask_available,
            identity_ask_count: $identity_ask_count,
            agent_name: $agent
        }')"
    exit 0
fi

# ══════════════════════════════════════════════
# UPDATE phase
# ══════════════════════════════════════════════
if [[ "$PHASE" == "update" ]]; then

    FIELD=""
    VALUE=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --field) FIELD="$2"; shift 2 ;;
            --value) VALUE="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ -z "$FIELD" || -z "$VALUE" ]]; then
        json_error "bootstrap-check" "MISSING_ARGS" "Usage: bootstrap-check.sh update --field <key> --value <value>"
        exit 1
    fi

    # Verify field exists
    if [[ "$(jq --arg f "$FIELD" '.fields[$f] // null' "$STATE_FILE")" == "null" ]]; then
        json_error "bootstrap-check" "UNKNOWN_FIELD" "Field '$FIELD' not found in bootstrap-state.json"
        exit 1
    fi

    # Update the field
    tmp=$(mktemp)
    trap "rm -f '$tmp'" EXIT
    jq --arg f "$FIELD" --arg v "$VALUE" \
        '.fields[$f].completed = true | .fields[$f].value = $v' \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"

    check_completeness

    log "Agent: $AGENT_NAME, updated field: $FIELD"

    json_success "bootstrap-check:update" "$(jq -n \
        --arg field "$FIELD" \
        --arg value "$VALUE" \
        --argjson bootstrap_complete "$(jq -r '.bootstrap_complete' "$STATE_FILE")" \
        --arg agent "$AGENT_NAME" \
        '{field: $field, value: $value, bootstrap_complete: $bootstrap_complete, agent_name: $agent}')"
    exit 0
fi

# ══════════════════════════════════════════════
# IDENTITY-ASKED phase
# ══════════════════════════════════════════════
if [[ "$PHASE" == "identity-asked" ]]; then

    tmp=$(mktemp)
    trap "rm -f '$tmp'" EXIT
    jq '.fields.agent_identity.ask_count = ((.fields.agent_identity.ask_count // 0) + 1)' \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"

    check_completeness

    ASK_COUNT=$(jq -r '.fields.agent_identity.ask_count' "$STATE_FILE")
    log "Agent: $AGENT_NAME, identity ask_count: $ASK_COUNT"

    json_success "bootstrap-check:identity-asked" "$(jq -n \
        --argjson ask_count "$ASK_COUNT" \
        --argjson bootstrap_complete "$(jq -r '.bootstrap_complete' "$STATE_FILE")" \
        --arg agent "$AGENT_NAME" \
        '{ask_count: $ask_count, bootstrap_complete: $bootstrap_complete, agent_name: $agent}')"
    exit 0
fi

# ══════════════════════════════════════════════
# IDENTITY-DECLINED phase
# ══════════════════════════════════════════════
if [[ "$PHASE" == "identity-declined" ]]; then

    tmp=$(mktemp)
    trap "rm -f '$tmp'" EXIT
    jq '.fields.agent_identity.completed = true | .fields.agent_identity.value = "declined"' \
        "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"

    check_completeness

    log "Agent: $AGENT_NAME, identity declined"

    json_success "bootstrap-check:identity-declined" "$(jq -n \
        --argjson bootstrap_complete "$(jq -r '.bootstrap_complete' "$STATE_FILE")" \
        --arg agent "$AGENT_NAME" \
        '{declined: true, bootstrap_complete: $bootstrap_complete, agent_name: $agent}')"
    exit 0
fi
