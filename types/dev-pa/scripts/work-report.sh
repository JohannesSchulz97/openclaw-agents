#!/usr/bin/env bash
set -euo pipefail

# work-report.sh — Deterministic wrapper for evening work report cron.
# Handles data gathering and state management; the model only synthesizes content.
#
# Usage:
#   work-report.sh prepare   → JSON with date, output path, slack ID, GitHub activity
#   work-report.sh finalize  → validates output file, updates report-state.json
#
# Output: JSON via json-response.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency check ─────────────────────────
if ! command -v jq &>/dev/null; then
    echo '{"success":false,"operation":"work-report","error":{"code":"MISSING_DEP","message":"jq is required but not found"}}' >&2
    exit 1
fi

# ── Args ──────────────────────────────────────
PHASE="${1:-}"
case "$PHASE" in
    prepare|finalize) ;;
    *)
        json_error "work-report" "INVALID_PHASE" "Usage: work-report.sh <prepare|finalize>"
        exit 1
        ;;
esac

# ── Config ────────────────────────────────────
AGENT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT_NAME="$(basename "$AGENT_DIR")"
MEMORY_DIR="$AGENT_DIR/memory"
REPORTS_DIR="$MEMORY_DIR/reports"
REPORT_STATE_FILE="$MEMORY_DIR/report-state.json"
USER_FILE="$AGENT_DIR/USER.md"
IDENTITY_FILE="$AGENT_DIR/IDENTITY.md"
TODAY_DATE=$(date -u +%Y-%m-%d)
OUTPUT_FILE="$REPORTS_DIR/$TODAY_DATE.md"

# ── Ensure directories and state file exist ──
mkdir -p "$REPORTS_DIR"
if [[ ! -f "$REPORT_STATE_FILE" ]]; then
    log "Creating default report state..."
    jq -n '{ last_report_epoch: 0 }' > "$REPORT_STATE_FILE"
fi

# ══════════════════════════════════════════════
# PREPARE phase
# ══════════════════════════════════════════════
if [[ "$PHASE" == "prepare" ]]; then

    # Read last_report_epoch
    LAST_REPORT_EPOCH=$(jq -r '.last_report_epoch // 0' "$REPORT_STATE_FILE" 2>/dev/null || echo "0")

    # Extract GitHub usernames from USER.md
    GITHUB_USERNAMES=""
    if [[ -f "$USER_FILE" ]]; then
        GITHUB_USERNAMES=$(sed -n 's/.*\*\*GitHub Usernames:\*\* \(.*\)/\1/p' "$USER_FILE" 2>/dev/null | head -1 || true)
        # Trim whitespace
        GITHUB_USERNAMES=$(echo "$GITHUB_USERNAMES" | xargs)
    fi

    # Extract Slack User ID from IDENTITY.md
    SLACK_USER_ID=""
    if [[ -f "$IDENTITY_FILE" ]]; then
        SLACK_USER_ID=$(sed -n 's/.*\*\*Slack User ID:\*\* \(U[A-Z0-9]*\).*/\1/p' "$IDENTITY_FILE" 2>/dev/null | head -1 || true)
    fi

    # Check if output file already exists (re-run)
    FILE_EXISTS=false
    if [[ -f "$OUTPUT_FILE" ]]; then
        FILE_EXISTS=true
    fi

    # ── Fetch GitHub activity ────────────────
    GITHUB_ACTIVITY='{}'
    if [[ -n "$GITHUB_USERNAMES" && "$GITHUB_USERNAMES" != *"<"* ]]; then
        log "Running github-activity.sh --user $GITHUB_USERNAMES --since 16"
        GITHUB_ACTIVITY=$("$SCRIPT_DIR/github-activity.sh" --user "$GITHUB_USERNAMES" --since 16 2>/dev/null) || {
            log "WARNING: github-activity.sh failed, continuing without GitHub data"
            GITHUB_ACTIVITY='{"success":false,"data":{}}'
        }
    else
        log "No GitHub usernames configured, skipping activity fetch"
    fi

    log "Agent: $AGENT_NAME, date: $TODAY_DATE, last_report_epoch: $LAST_REPORT_EPOCH, file_exists: $FILE_EXISTS"

    json_success "work-report:prepare" "$(jq -n \
        --arg date "$TODAY_DATE" \
        --arg output_file "$OUTPUT_FILE" \
        --argjson last_report_epoch "$LAST_REPORT_EPOCH" \
        --argjson file_exists "$FILE_EXISTS" \
        --arg agent "$AGENT_NAME" \
        --arg slack_user_id "$SLACK_USER_ID" \
        --argjson github_activity "$GITHUB_ACTIVITY" \
        '{
            date: $date,
            output_file: $output_file,
            last_report_epoch: $last_report_epoch,
            file_exists: $file_exists,
            agent_name: $agent,
            slack_user_id: $slack_user_id,
            github_activity: $github_activity
        }')"
    exit 0
fi

# ══════════════════════════════════════════════
# FINALIZE phase
# ══════════════════════════════════════════════
if [[ "$PHASE" == "finalize" ]]; then

    NOW_EPOCH=$(date -u +%s)

    # ── Validate output file exists ───────────
    if [[ ! -f "$OUTPUT_FILE" ]]; then
        json_error "work-report" "FILE_MISSING" "Expected output file not found: $OUTPUT_FILE"
        exit 1
    fi

    # ── Validate output file has content ──────
    FILE_SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
    if (( FILE_SIZE < 20 )); then
        json_error "work-report" "FILE_EMPTY" "Output file is too small (${FILE_SIZE} bytes): $OUTPUT_FILE"
        exit 1
    fi

    # ── Validate expected sections exist ──────
    # Match with or without emoji prefixes (e.g. "### ✅ What was accomplished")
    if ! grep -q '^### .*What was accomplished' "$OUTPUT_FILE" && \
       ! grep -q '^### .*Challenges' "$OUTPUT_FILE" && \
       ! grep -q '^### .*Next steps' "$OUTPUT_FILE"; then
        json_error "work-report" "MISSING_SECTION" "Output file missing expected report sections (What was accomplished / Challenges / Next steps): $OUTPUT_FILE"
        exit 1
    fi

    # ── Update report-state.json ─────────────
    tmp_state=$(mktemp)
    trap "rm -f '$tmp_state'" EXIT

    jq -n \
        --argjson epoch "$NOW_EPOCH" \
        --arg date "$TODAY_DATE" \
        '{
            last_report_epoch: $epoch,
            last_report_date: $date
        }' > "$tmp_state" 2>/dev/null && mv "$tmp_state" "$REPORT_STATE_FILE"

    log "Agent: $AGENT_NAME, date: $TODAY_DATE, report finalized, epoch: $NOW_EPOCH"

    json_success "work-report:finalize" "$(jq -n \
        --arg date "$TODAY_DATE" \
        --arg output_file "$OUTPUT_FILE" \
        --argjson epoch "$NOW_EPOCH" \
        --arg agent "$AGENT_NAME" \
        '{
            date: $date,
            output_file: $output_file,
            report_epoch: $epoch,
            agent_name: $agent
        }')"
    exit 0
fi
