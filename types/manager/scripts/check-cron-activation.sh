#!/usr/bin/env bash
set -euo pipefail
# check-cron-activation.sh — Detect newly bootstrapped agents and activate their check-in schedules
#
# Scans agents for work-schedule.json without corresponding morning/midday/evening cron jobs.
# When found, runs update-cron-schedule.sh to create the 3 time-of-day check-in jobs.
#
# Usage: check-cron-activation.sh --agents <comma-separated-list>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency check ─────────────────────────
if ! command -v jq &>/dev/null; then
    json_error "check-cron-activation" "MISSING_DEP" "jq is required but not found"
    exit 1
fi

# ── Find repo root (needed for update-cron-schedule.sh) ──
AGENT_DIR_BASE="$HOME/.openclaw/agents"
REPO_ROOT=""

for candidate in "$HOME/openclaw-agents" "$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"; do
    if [[ -f "$candidate/scripts/update-cron-schedule.sh" ]]; then
        REPO_ROOT="$candidate"
        break
    fi
done

if [[ -z "$REPO_ROOT" ]]; then
    json_error "check-cron-activation" "MISSING_REPO" "Cannot find openclaw-agents repo with update-cron-schedule.sh"
    exit 1
fi

source "$REPO_ROOT/scripts/lib/schedule-utils.sh"

# ── Args ─────────────────────────────────────
AGENTS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agents)
            AGENTS="$2"
            shift 2
            ;;
        *)
            json_error "check-cron-activation" "BAD_ARG" "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$AGENTS" ]]; then
    json_error "check-cron-activation" "MISSING_ARG" "--agents AGENT1,AGENT2,... is required"
    exit 1
fi

# ── Get current cron jobs from gateway ───────
GATEWAY_JOBS=$(openclaw cron list --json 2>/dev/null || echo '{"jobs":[]}')

# ── Process each agent ───────────────────────
IFS=',' read -ra AGENT_LIST <<< "$AGENTS"

ACTIVATED=()
SKIPPED=()
ERRORS=()

for agent in "${AGENT_LIST[@]}"; do
    agent=$(echo "$agent" | xargs)  # trim whitespace
    AGENT_PATH="$AGENT_DIR_BASE/$agent"

    # Gap 1 fix: backfill work-schedule.json from bootstrap-state.json
    if [[ ! -f "$AGENT_PATH/work-schedule.json" ]]; then
        BS_FILE="$AGENT_PATH/bootstrap-state.json"
        if [[ -f "$BS_FILE" ]]; then
            BS_COMPLETE=$(jq -r '.bootstrap_complete' "$BS_FILE" 2>/dev/null || echo "false")
            WS_VALUE=$(jq -r '.fields.work_schedule.value // empty' "$BS_FILE" 2>/dev/null || true)
            if [[ "$BS_COMPLETE" == "true" && -n "$WS_VALUE" && "$WS_VALUE" != "null" ]]; then
                jq -r '.fields.work_schedule.value' "$BS_FILE" > "$AGENT_PATH/work-schedule.json"
                log "Backfilled work-schedule.json for $agent from bootstrap-state.json"
            fi
        fi
    fi

    # Still no schedule — skip
    if [[ ! -f "$AGENT_PATH/work-schedule.json" ]]; then
        SKIPPED+=("$agent:no_schedule")
        continue
    fi

    # Check if agent already has morning/midday/evening cron jobs
    HAS_MORNING=$(echo "$GATEWAY_JOBS" | jq -r --arg sk "agent:${agent}:cron:morning" '.jobs[] | select(.sessionKey == $sk) | .id' 2>/dev/null | head -1 || true)
    HAS_MIDDAY=$(echo "$GATEWAY_JOBS" | jq -r --arg sk "agent:${agent}:cron:midday" '.jobs[] | select(.sessionKey == $sk) | .id' 2>/dev/null | head -1 || true)
    HAS_EVENING=$(echo "$GATEWAY_JOBS" | jq -r --arg sk "agent:${agent}:cron:evening" '.jobs[] | select(.sessionKey == $sk) | .id' 2>/dev/null | head -1 || true)

    if [[ -n "$HAS_MORNING" && -n "$HAS_MIDDAY" && -n "$HAS_EVENING" ]]; then
        # Gap 2 fix: detect schedule drift — compare existing cron vs work-schedule.json
        MORNING_CRON=$(echo "$GATEWAY_JOBS" | jq -r --arg sk "agent:${agent}:cron:morning" '.jobs[] | select(.sessionKey == $sk) | .schedule.cronExpr' 2>/dev/null | head -1 || true)
        MORNING_TZ=$(echo "$GATEWAY_JOBS" | jq -r --arg sk "agent:${agent}:cron:morning" '.jobs[] | select(.sessionKey == $sk) | .schedule.tz' 2>/dev/null | head -1 || true)

        if parse_work_schedule "$AGENT_PATH/work-schedule.json" 2>/dev/null; then
            compute_checkin_times "$WS_START_HOUR" "$WS_END_HOUR" 2>/dev/null || true
            EXPECTED_MORNING_CRON=$(build_cron_expr "$MORNING_HOUR" "$MORNING_MIN" "$WS_WORKS_WEEKENDS")

            if [[ "$MORNING_CRON" != "$EXPECTED_MORNING_CRON" || "$MORNING_TZ" != "$WS_TIMEZONE" ]]; then
                log "Schedule drift for $agent: gateway=$MORNING_CRON ($MORNING_TZ), expected=$EXPECTED_MORNING_CRON ($WS_TIMEZONE)"
                if bash "$REPO_ROOT/scripts/update-cron-schedule.sh" --agent "$agent" 2>&1; then
                    ACTIVATED+=("$agent")
                else
                    ERRORS+=("$agent:schedule_update_failed")
                fi
                continue
            fi
        fi

        SKIPPED+=("$agent:already_active")
        continue
    fi

    # Agent has work-schedule.json but missing cron jobs — activate!
    log "Activating check-in schedule for agent: $agent"
    if bash "$REPO_ROOT/scripts/update-cron-schedule.sh" --agent "$agent" 2>&1; then
        ACTIVATED+=("$agent")
    else
        ERRORS+=("$agent:activation_failed")
    fi
done

# ── Build JSON output ────────────────────────
# Handle empty arrays safely for jq
if [[ ${#ACTIVATED[@]} -gt 0 ]]; then
    ACTIVATED_JSON=$(printf '%s\n' "${ACTIVATED[@]}" | jq -R . | jq -s .)
else
    ACTIVATED_JSON="[]"
fi

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    SKIPPED_JSON=$(printf '%s\n' "${SKIPPED[@]}" | jq -R . | jq -s .)
else
    SKIPPED_JSON="[]"
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    ERRORS_JSON=$(printf '%s\n' "${ERRORS[@]}" | jq -R . | jq -s .)
else
    ERRORS_JSON="[]"
fi

DATA=$(jq -n \
    --argjson activated "$ACTIVATED_JSON" \
    --argjson skipped "$SKIPPED_JSON" \
    --argjson errors "$ERRORS_JSON" \
    '{
        activated: $activated,
        skipped: $skipped,
        errors: $errors,
        all_clear: (($activated | length) == 0 and ($errors | length) == 0)
    }')

log "Cron activation scan complete: ${#ACTIVATED[@]} activated, ${#SKIPPED[@]} skipped, ${#ERRORS[@]} errors"

json_success "check-cron-activation" "$DATA"
