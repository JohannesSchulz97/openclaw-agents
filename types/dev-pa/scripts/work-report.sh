#!/usr/bin/env bash
set -euo pipefail

# work-report.sh — Deterministic wrapper for evening work report cron.
# Handles data gathering and state management; the model only synthesizes content.
#
# Usage:
#   work-report.sh prepare [--date YYYY-MM-DD] [--no-dm]
#                          → JSON with date, output path, slack ID, GitHub activity,
#                            and no_activity flag. Bumps report-state.last_run_epoch.
#   work-report.sh finalize [--date YYYY-MM-DD]
#                          → validates output file, bumps report-state.last_report_epoch.
#
# --date defaults to "today" in the agent's timezone (read from work-schedule.json).
# Falls back to host-local if the schedule file is missing. Use --date to pin a
# specific report day when a cron run has been delayed or is being re-run manually.
#
# Output: JSON via json-response.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"
source "$SCRIPT_DIR/lib/dm-digest.sh"

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
        json_error "work-report" "INVALID_PHASE" "Usage: work-report.sh <prepare|finalize> [--date YYYY-MM-DD] [--no-dm]"
        exit 1
        ;;
esac
shift

DM=true
TODAY_DATE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-dm) DM=false; shift ;;
        --date)
            TODAY_DATE="${2:-}"
            if ! [[ "$TODAY_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
                json_error "work-report" "BAD_DATE" "--date requires a YYYY-MM-DD value, got: ${TODAY_DATE:-<missing>}"
                exit 1
            fi
            shift 2
            ;;
        *) shift ;;
    esac
done

# ── Config ────────────────────────────────────
AGENT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT_NAME="$(basename "$AGENT_DIR")"
MEMORY_DIR="$AGENT_DIR/memory"
REPORTS_DIR="$MEMORY_DIR/reports"
REPORT_STATE_FILE="$MEMORY_DIR/report-state.json"
USER_FILE="$AGENT_DIR/USER.md"
IDENTITY_FILE="$AGENT_DIR/IDENTITY.md"

# Resolve the default report date in the agent's local timezone (from
# work-schedule.json). OpenClaw does not propagate the cron schedule's tz
# into the process env, so a bare `date` would return host-local (CET) and
# misalign the filename for devs whose 19:00 local doesn't land in the
# host's calendar day. Explicit TZ= is the same pattern check-status.sh uses.
if [[ -z "$TODAY_DATE" ]]; then
    AGENT_TZ=""
    for ws_file in "$AGENT_DIR/memory/work-schedule.json" "$AGENT_DIR/work-schedule.json"; do
        if [[ -f "$ws_file" ]]; then
            AGENT_TZ=$(jq -r '.timezone // ""' "$ws_file" 2>/dev/null || true)
            [[ -n "$AGENT_TZ" ]] && break
        fi
    done
    if [[ -n "$AGENT_TZ" ]]; then
        TODAY_DATE=$(TZ="$AGENT_TZ" date '+%Y-%m-%d')
    else
        TODAY_DATE=$(date '+%Y-%m-%d')
    fi
fi

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
        log "Running github-activity.sh --user $GITHUB_USERNAMES --since 24"
        GITHUB_ACTIVITY=$("$SCRIPT_DIR/github-activity.sh" --user "$GITHUB_USERNAMES" --since 24 2>/dev/null) || {
            log "WARNING: github-activity.sh failed, continuing without GitHub data"
            GITHUB_ACTIVITY='{"success":false,"data":{}}'
        }
    else
        log "No GitHub usernames configured, skipping activity fetch"
    fi

    # ── Fetch DM conversation digest ───────────
    <channel-id>N_DIGEST=$(get_dm_digest "$AGENT_NAME")

    # ── Detect "no activity" ─────────────────────
    # Only set when we have definitive zero counts from both sources.
    # Ambiguous/missing counts (e.g. GitHub API failure) fail open: treat as
    # "has activity" so the report is still written rather than suppressed.
    NO_ACTIVITY=$(jq -n \
        --argjson ga "$GITHUB_ACTIVITY" \
        --argjson cd "$<channel-id>N_DIGEST" \
        '
        ($ga.data.summary.total_events) as $events |
        ($cd.message_count) as $msgs |
        (($events | type) == "number" and $events == 0
         and ($msgs | type) == "number" and $msgs == 0)
        ')

    # ── Bump last_run_epoch on every prepare run ────────────
    # Proof the cron fired, independent of whether a report ends up written.
    NOW_EPOCH=$(date -u +%s)
    tmp_state=$(mktemp)
    trap "rm -f '$tmp_state'" EXIT
    jq --argjson epoch "$NOW_EPOCH" \
       '. + {last_run_epoch: $epoch}' \
       "$REPORT_STATE_FILE" > "$tmp_state" 2>/dev/null && mv "$tmp_state" "$REPORT_STATE_FILE"

    log "Agent: $AGENT_NAME, date: $TODAY_DATE, last_report_epoch: $LAST_REPORT_EPOCH, file_exists: $FILE_EXISTS, no_activity: $NO_ACTIVITY"

    json_success "work-report:prepare" "$(jq -n \
        --arg date "$TODAY_DATE" \
        --arg output_file "$OUTPUT_FILE" \
        --argjson last_report_epoch "$LAST_REPORT_EPOCH" \
        --argjson file_exists "$FILE_EXISTS" \
        --argjson no_activity "$NO_ACTIVITY" \
        --arg agent "$AGENT_NAME" \
        --arg slack_user_id "$SLACK_USER_ID" \
        --argjson dm "$DM" \
        --argjson github_activity "$GITHUB_ACTIVITY" \
        --argjson conversation_digest "$<channel-id>N_DIGEST" \
        '{
            date: $date,
            output_file: $output_file,
            last_report_epoch: $last_report_epoch,
            file_exists: $file_exists,
            no_activity: $no_activity,
            agent_name: $agent,
            slack_user_id: $slack_user_id,
            dm: $dm,
            github_activity: $github_activity,
            conversation_digest: $conversation_digest
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
    if ! grep -q '^### .*What was accomplished' "$OUTPUT_FILE" || \
       ! grep -q '^### .*Challenges' "$OUTPUT_FILE" || \
       ! grep -q '^### .*Next steps' "$OUTPUT_FILE"; then
        json_error "work-report" "MISSING_SECTION" "Output file missing expected report sections (What was accomplished / Challenges / Next steps): $OUTPUT_FILE"
        exit 1
    fi

    # ── Update report-state.json ─────────────
    # Merge over existing state so last_run_epoch (set by prepare) is preserved.
    tmp_state=$(mktemp)
    trap "rm -f '$tmp_state'" EXIT

    jq \
        --argjson epoch "$NOW_EPOCH" \
        --arg date "$TODAY_DATE" \
        '. + {
            last_report_epoch: $epoch,
            last_report_date: $date
        }' "$REPORT_STATE_FILE" > "$tmp_state" 2>/dev/null && mv "$tmp_state" "$REPORT_STATE_FILE"

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
