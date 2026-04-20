#!/usr/bin/env bash
set -euo pipefail

# evening-report.sh — Collect per-developer work reports and team status.
#
# Decentralized architecture: each dev-pa agent writes its own report to
# memory/reports/YYYY-MM-DD.md at 19:00. This script (run at 20:00 by the
# tech-manager cron) reads those reports and combines them with status data.
#
# Phase 1 only (bash, no LLM). The cron prompt handles synthesis and Slack delivery.
#
# Usage:
#   bash scripts/evening-report.sh [--date YYYY-MM-DD] [--base-dir DIR]
#                                  [--channel CHANNEL_ID] [--dry-run] [--force]
#
# --date defaults to the host's local date. Use to pin a specific report day
# when a cron run has been delayed or is being re-run manually.
#
# Output: JSON via json-response.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency checks ────────────────────────
for cmd in jq; do
    if ! command -v "$cmd" &>/dev/null; then
        json_error "evening-report" "MISSING_DEP" "$cmd is required but not found"
        exit 1
    fi
done

# ── Args ─────────────────────────────────────
BASE_DIR="$HOME/.openclaw/agents"
CHANNEL_OVERRIDE=""
DRY_RUN=false
FORCE=false
TODAY=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --channel)
            CHANNEL_OVERRIDE="$2"
            shift 2
            ;;
        --base-dir)
            BASE_DIR="$2"
            shift 2
            ;;
        --date)
            TODAY="${2:-}"
            if ! [[ "$TODAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                json_error "evening-report" "BAD_DATE" "--date requires a YYYY-MM-DD value, got: ${TODAY:-<missing>}"
                exit 1
            fi
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        *)
            json_error "evening-report" "BAD_ARG" "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Default to the host's local date. Aligns with cron tz when --date is not passed.
TODAY="${TODAY:-$(date '+%Y-%m-%d')}"

# ── Idempotency guard ───────────────────────
MARKER_FILE="/tmp/evening-report-${TODAY}.sent"
if [[ -f "$MARKER_FILE" && "$FORCE" != true ]]; then
    log "Evening report already sent today (marker: $MARKER_FILE). Use --force to override."
    json_success "evening-report" '{"skipped": true, "reason": "already_sent"}'
    exit 0
fi

# ── Helpers ──────────────────────────────────
extract_slack_user_id() {
    local identity_file="$1"
    sed -n 's/.*\*\*Slack User ID:\*\* \(U[A-Z0-9]*\).*/\1/p' "$identity_file" 2>/dev/null | head -1 || true
}

extract_slack_channel_id() {
    local identity_file="$1"
    sed -n 's/.*\*\*Slack Channel ID:\*\* \(C[A-Z0-9]*\).*/\1/p' "$identity_file" 2>/dev/null | head -1 || true
}

# ── Resolve channel ID ──────────────────────
if [[ -n "$CHANNEL_OVERRIDE" ]]; then
    CHANNEL_ID="$CHANNEL_OVERRIDE"
else
    MANAGER_IDENTITY="$BASE_DIR/tech-manager/IDENTITY.md"
    if [[ ! -f "$MANAGER_IDENTITY" ]]; then
        log "ERROR: No IDENTITY.md at $MANAGER_IDENTITY and no --channel override"
        json_error "evening-report" "NO_CHANNEL" "Cannot resolve Slack channel ID"
        exit 1
    fi
    CHANNEL_ID=$(extract_slack_channel_id "$MANAGER_IDENTITY")
fi

if [[ -z "$CHANNEL_ID" ]]; then
    json_error "evening-report" "NO_CHANNEL" "Could not resolve Slack channel ID"
    exit 1
fi

log "Evening report targeting channel: $CHANNEL_ID"

# ── Read report template ───────────────────
TEMPLATE_FILE="$BASE_DIR/tech-manager/EVENING-REPORT.template.md"
TEMPLATE_CONTENT=""
if [[ -f "$TEMPLATE_FILE" ]]; then
    TEMPLATE_CONTENT=$(cat "$TEMPLATE_FILE")
else
    log "WARNING: Template not found at $TEMPLATE_FILE"
fi

# ── Define output file ─────────────────────
REPORTS_DIR="$BASE_DIR/tech-manager/memory/reports"
OUTPUT_FILE="$REPORTS_DIR/$TODAY.md"
mkdir -p "$REPORTS_DIR"

# ── Discover dev-pa agents ───────────────────
AGENTS=()
AGENT_SLACK_IDS=()

for agent_dir in "$BASE_DIR"/*/; do
    [[ -d "$agent_dir" ]] || continue

    agent_type_file="$agent_dir/.agent-type"
    [[ -f "$agent_type_file" ]] || continue
    agent_type=$(cat "$agent_type_file" 2>/dev/null | tr -d '[:space:]')
    [[ "$agent_type" == "dev-pa" ]] || continue

    agent_name=$(basename "$agent_dir")
    slack_id=$(extract_slack_user_id "$agent_dir/IDENTITY.md")

    AGENTS+=("$agent_name")
    AGENT_SLACK_IDS+=("$slack_id")
done

if [[ ${#AGENTS[@]} -eq 0 ]]; then
    json_error "evening-report" "NO_AGENTS" "No dev-pa agents found in $BASE_DIR"
    exit 1
fi

AGENT_LIST=$(IFS=','; echo "${AGENTS[*]}")
log "Found ${#AGENTS[@]} dev-pa agents: $AGENT_LIST"

# ════════════════════════════════════════════════
# Data Collection
# ════════════════════════════════════════════════

log "=== Collecting per-developer reports ==="

DEVELOPERS="[]"
DEVS_WITH_REPORTS=0
DEVS_WITHOUT_REPORTS=0
ACTIVE_COUNT=0
IDLE_COUNT=0
MISSED_COUNT=0

for i in "${!AGENTS[@]}"; do
    agent="${AGENTS[$i]}"
    slack_id="${AGENT_SLACK_IDS[$i]}"
    report_file="$BASE_DIR/$agent/memory/reports/$TODAY.md"
    state_file="$BASE_DIR/$agent/memory/report-state.json"

    has_report=false
    report_content=""
    report_status="cron_missed"

    if [[ -f "$report_file" ]] && [[ -s "$report_file" ]]; then
        has_report=true
        report_content=$(cat "$report_file")
        report_status="active"
        DEVS_WITH_REPORTS=$((DEVS_WITH_REPORTS + 1))
        ACTIVE_COUNT=$((ACTIVE_COUNT + 1))
    else
        DEVS_WITHOUT_REPORTS=$((DEVS_WITHOUT_REPORTS + 1))
        # Distinguish "cron fired, dev was idle" from "cron never fired"
        # by checking report-state.last_run_epoch against today's date.
        if [[ -f "$state_file" ]]; then
            last_run_epoch=$(jq -r '.last_run_epoch // 0' "$state_file" 2>/dev/null || echo 0)
            if [[ "$last_run_epoch" -gt 0 ]]; then
                last_run_date=$(date -r "$last_run_epoch" '+%Y-%m-%d' 2>/dev/null || echo "")
                if [[ "$last_run_date" == "$TODAY" ]]; then
                    report_status="idle"
                fi
            fi
        fi
        if [[ "$report_status" == "idle" ]]; then
            IDLE_COUNT=$((IDLE_COUNT + 1))
        else
            MISSED_COUNT=$((MISSED_COUNT + 1))
        fi
    fi

    # has_meaningful_report retained for backward compat with existing tech-manager
    # cron payload. After the "skip writing empty reports" change lands, it is
    # always equal to has_report (empty "No activity" files no longer exist).
    DEVELOPERS=$(printf '%s' "$DEVELOPERS" | jq \
        --arg agent "$agent" \
        --arg slack_id "$slack_id" \
        --argjson has_report "$has_report" \
        --argjson has_meaningful_report "$has_report" \
        --arg report_status "$report_status" \
        --arg report "$report_content" \
        '. + [{
            agent: $agent,
            slack_id: $slack_id,
            has_report: $has_report,
            has_meaningful_report: $has_meaningful_report,
            report_status: $report_status,
            report: $report
        }]')
done

log "Reports: $DEVS_WITH_REPORTS found, $DEVS_WITHOUT_REPORTS missing (active=$ACTIVE_COUNT, idle=$IDLE_COUNT, cron_missed=$MISSED_COUNT)"

# ── Run check-status.sh ─────────────────────
log "Running check-status.sh"
STATUS_JSON=$("$SCRIPT_DIR/check-status.sh" --agents "$AGENT_LIST" --base-dir "$BASE_DIR" 2>/dev/null) || {
    log "WARNING: check-status.sh failed, continuing with empty data"
    STATUS_JSON='{"success":false,"data":{"agents":[],"summary":{}}}'
}

# ── Run check-missed-checkins.sh ─────────────
log "Running check-missed-checkins.sh"
MISSED_JSON=$("$SCRIPT_DIR/check-missed-checkins.sh" --agents "$AGENT_LIST" --base-dir "$BASE_DIR" 2>/dev/null) || {
    log "WARNING: check-missed-checkins.sh failed"
    MISSED_JSON='{"success":false,"data":{"alerts":[],"all_clear":true}}'
}

STATUS_SUMMARY=$(printf '%s' "$STATUS_JSON" | jq '.data.summary // {}' 2>/dev/null || echo '{}')
STATUS_AGENTS=$(printf '%s' "$STATUS_JSON" | jq '.data.agents // []' 2>/dev/null || echo '[]')
MISSED_ALERTS=$(printf '%s' "$MISSED_JSON" | jq '.data.alerts // []' 2>/dev/null || echo '[]')

# ── Merge status into developers ─────────────
DEVELOPERS=$(printf '%s' "$DEVELOPERS" | jq \
    --argjson status_agents "$STATUS_AGENTS" \
    '[.[] | . as $dev |
        ($status_agents | map(select(.name == $dev.agent)) | first // {}) as $status |
        $dev + {status: $status}
    ]')

log "Data collection complete."

# ── Write idempotency marker ────────────────
touch "$MARKER_FILE"

# ── Build final output ───────────────────────
CHANNEL_SESSION_KEY="agent:tech-manager:slack:channel:$(echo "$CHANNEL_ID" | tr '[:upper:]' '[:lower:]')"

RESULT=$(jq -n \
    --arg date "$TODAY" \
    --arg channel_id "$CHANNEL_ID" \
    --arg channel_session_key "$CHANNEL_SESSION_KEY" \
    --arg template "$TEMPLATE_CONTENT" \
    --arg output_file "$OUTPUT_FILE" \
    --argjson total_developers "${#AGENTS[@]}" \
    --argjson developers_with_reports "$DEVS_WITH_REPORTS" \
    --argjson developers_without_reports "$DEVS_WITHOUT_REPORTS" \
    --argjson active_count "$ACTIVE_COUNT" \
    --argjson idle_count "$IDLE_COUNT" \
    --argjson cron_missed_count "$MISSED_COUNT" \
    --argjson developers "$DEVELOPERS" \
    --argjson status_summary "$STATUS_SUMMARY" \
    --argjson missed_alerts "$MISSED_ALERTS" \
    --argjson dry_run "$DRY_RUN" \
    '{
        date: $date,
        channel_id: $channel_id,
        channel_session_key: $channel_session_key,
        template: $template,
        output_file: $output_file,
        total_developers: $total_developers,
        developers_with_reports: $developers_with_reports,
        developers_without_reports: $developers_without_reports,
        active_count: $active_count,
        idle_count: $idle_count,
        cron_missed_count: $cron_missed_count,
        developers: $developers,
        status_summary: $status_summary,
        missed_alerts: $missed_alerts,
        dry_run: $dry_run
    }')

json_success "evening-report" "$RESULT"
