#!/usr/bin/env bash
set -euo pipefail

# daily-summary.sh — Deterministic wrapper for daily summary cron.
# Handles all mechanical state management; the model only synthesizes content.
#
# Usage:
#   daily-summary.sh prepare   → JSON with date, paths, template, epoch info
#   daily-summary.sh finalize  → validates output file, updates summary-state.json
#
# Output: JSON via json-response.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"
source "$SCRIPT_DIR/lib/dm-digest.sh"

# ── Dependency check ─────────────────────────
if ! command -v jq &>/dev/null; then
    echo '{"success":false,"operation":"daily-summary","error":{"code":"MISSING_DEP","message":"jq is required but not found"}}' >&2
    exit 1
fi

# ── Args ──────────────────────────────────────
PHASE="${1:-}"
case "$PHASE" in
    prepare|finalize) ;;
    *)
        json_error "daily-summary" "INVALID_PHASE" "Usage: daily-summary.sh <prepare|finalize>"
        exit 1
        ;;
esac

# ── Config ────────────────────────────────────
AGENT_DIR="$(dirname "$SCRIPT_DIR")"
AGENT_NAME="$(basename "$AGENT_DIR")"
MEMORY_DIR="$AGENT_DIR/memory"
SUMMARY_STATE_FILE="$MEMORY_DIR/summary-state.json"
TEMPLATE_FILE="$AGENT_DIR/DAILY-SUMMARY.template.md"
TODAY_DATE=$(date -u +%Y-%m-%d)
OUTPUT_FILE="$MEMORY_DIR/$TODAY_DATE.md"

# ── Ensure summary-state.json exists ──────────
if [[ ! -f "$SUMMARY_STATE_FILE" ]]; then
    log "Creating default summary state..."
    mkdir -p "$MEMORY_DIR"
    jq -n '{ last_summary_epoch: 0 }' > "$SUMMARY_STATE_FILE"
fi

# ══════════════════════════════════════════════
# PREPARE phase
# ══════════════════════════════════════════════
if [[ "$PHASE" == "prepare" ]]; then

    # Read last_summary_epoch
    LAST_SUMMARY_EPOCH=$(jq -r '.last_summary_epoch // 0' "$SUMMARY_STATE_FILE" 2>/dev/null || echo "0")

    # Read template
    if [[ ! -f "$TEMPLATE_FILE" ]]; then
        json_error "daily-summary" "MISSING_TEMPLATE" "Template not found: $TEMPLATE_FILE"
        exit 1
    fi
    TEMPLATE_CONTENT=$(cat "$TEMPLATE_FILE")

    # Check if output file already exists (re-run)
    FILE_EXISTS=false
    if [[ -f "$OUTPUT_FILE" ]]; then
        FILE_EXISTS=true
    fi

    # ── Fetch DM conversation digest ───────────
    <channel-id>N_DIGEST=$(get_dm_digest "$AGENT_NAME")

    log "Agent: $AGENT_NAME, date: $TODAY_DATE, last_summary_epoch: $LAST_SUMMARY_EPOCH, file_exists: $FILE_EXISTS"

    json_success "daily-summary:prepare" "$(jq -n \
        --arg date "$TODAY_DATE" \
        --arg output_file "$OUTPUT_FILE" \
        --arg template "$TEMPLATE_CONTENT" \
        --argjson last_summary_epoch "$LAST_SUMMARY_EPOCH" \
        --argjson file_exists "$FILE_EXISTS" \
        --arg agent "$AGENT_NAME" \
        --arg memory_dir "$MEMORY_DIR" \
        --argjson conversation_digest "$<channel-id>N_DIGEST" \
        '{
            date: $date,
            output_file: $output_file,
            template: $template,
            last_summary_epoch: $last_summary_epoch,
            file_exists: $file_exists,
            agent_name: $agent,
            memory_dir: $memory_dir,
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
        json_error "daily-summary" "FILE_MISSING" "Expected output file not found: $OUTPUT_FILE"
        exit 1
    fi

    # ── Validate output file has content ──────
    FILE_SIZE=$(wc -c < "$OUTPUT_FILE" | tr -d ' ')
    if (( FILE_SIZE < 20 )); then
        json_error "daily-summary" "FILE_EMPTY" "Output file is too small (${FILE_SIZE} bytes): $OUTPUT_FILE"
        exit 1
    fi

    # ── Validate expected sections exist ──────
    if ! grep -q '^## Focus' "$OUTPUT_FILE"; then
        json_error "daily-summary" "MISSING_SECTION" "Output file missing '## Focus' section: $OUTPUT_FILE"
        exit 1
    fi

    # ── Update summary-state.json ─────────────
    tmp_state=$(mktemp)
    trap "rm -f '$tmp_state'" EXIT

    jq -n \
        --argjson epoch "$NOW_EPOCH" \
        --arg date "$TODAY_DATE" \
        '{
            last_summary_epoch: $epoch,
            last_summary_date: $date
        }' > "$tmp_state" 2>/dev/null && mv "$tmp_state" "$SUMMARY_STATE_FILE"

    log "Agent: $AGENT_NAME, date: $TODAY_DATE, summary finalized, epoch: $NOW_EPOCH"

    json_success "daily-summary:finalize" "$(jq -n \
        --arg date "$TODAY_DATE" \
        --arg output_file "$OUTPUT_FILE" \
        --argjson epoch "$NOW_EPOCH" \
        --arg agent "$AGENT_NAME" \
        '{
            date: $date,
            output_file: $output_file,
            summary_epoch: $epoch,
            agent_name: $agent
        }')"
    exit 0
fi
