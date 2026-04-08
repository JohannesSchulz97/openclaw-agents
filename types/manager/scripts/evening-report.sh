#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency checks ────────────────────────
for cmd in jq openclaw; do
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
SINCE_HOURS=24
MAX_PARALLEL=4
PHASE2_TIMEOUT=300
PHASE3_TIMEOUT=300
PHASE2_POLL_INTERVAL=10
PHASE2_POLL_MAX=360
PHASE3_POLL_MAX=180

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
        --since)
            SINCE_HOURS="$2"
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

TODAY=$(date '+%Y-%m-%d')

# ── Idempotency guard ───────────────────────
MARKER_FILE="/tmp/evening-report-${TODAY}.sent"
if [[ -f "$MARKER_FILE" && "$FORCE" != true ]]; then
    log "Evening report already sent today (marker: $MARKER_FILE). Use --force to override."
    exit 0
fi

# ── Gateway health check ────────────────────
if ! openclaw status 2>&1 | grep -qi "reachable"; then
    log "ERROR: Gateway unreachable — aborting to prevent session corruption"
    exit 1
fi
log "Gateway reachable."

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
        exit 1
    fi
    CHANNEL_ID=$(extract_slack_channel_id "$MANAGER_IDENTITY")
fi

if [[ -z "$CHANNEL_ID" ]]; then
    log "ERROR: Could not resolve Slack channel ID"
    exit 1
fi

log "Evening report targeting channel: $CHANNEL_ID"

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
    log "ERROR: No dev-pa agents found in $BASE_DIR"
    exit 1
fi

AGENT_LIST=$(IFS=','; echo "${AGENTS[*]}")
log "Found ${#AGENTS[@]} dev-pa agents: $AGENT_LIST"

# ── Working directory ────────────────────────
WORK_DIR="$BASE_DIR/tech-manager/evening-report"
mkdir -p "$WORK_DIR"
# Clean up previous run's files
rm -f "$WORK_DIR"/*.json "$WORK_DIR"/*-narrative.txt "$WORK_DIR"/summary.txt

# ════════════════════════════════════════════════
# PHASE 1 — Data Collection (bash, no LLM)
# ════════════════════════════════════════════════

log "=== Phase 1: Data collection ==="

GITHUB_JSON=""
STATUS_JSON=""
MISSED_JSON=""

log "Running collect-github-activity.sh --since $SINCE_HOURS"
GITHUB_JSON=$("$SCRIPT_DIR/collect-github-activity.sh" --since "$SINCE_HOURS" --base-dir "$BASE_DIR" 2>/dev/null) || {
    log "WARNING: collect-github-activity.sh failed, continuing with empty data"
    GITHUB_JSON='{"success":false,"data":{"agents":[],"summary":{}}}'
}

log "Running check-status.sh"
STATUS_JSON=$("$SCRIPT_DIR/check-status.sh" --agents "$AGENT_LIST" --base-dir "$BASE_DIR" 2>/dev/null) || {
    log "WARNING: check-status.sh failed"
    STATUS_JSON='{"success":false,"data":{"agents":[],"summary":{}}}'
}

log "Running check-missed-checkins.sh"
MISSED_JSON=$("$SCRIPT_DIR/check-missed-checkins.sh" --agents "$AGENT_LIST" --base-dir "$BASE_DIR" 2>/dev/null) || {
    log "WARNING: check-missed-checkins.sh failed"
    MISSED_JSON='{"success":false,"data":{"alerts":[],"all_clear":true}}'
}

# Split per-developer data into working directory files
ACTIVE_AGENTS=()
ACTIVE_SLACK_IDS=()

for i in "${!AGENTS[@]}"; do
    agent="${AGENTS[$i]}"
    slack_id="${AGENT_SLACK_IDS[$i]}"

    # Extract this agent's GitHub activity (fix: use array filter + first)
    agent_github=$(printf '%s' "$GITHUB_JSON" | jq \
        --arg name "$agent" \
        '[.data.agents[] | select(.agent == $name)] | first // {}' 2>/dev/null || echo '{}')

    # Extract this agent's status (fix: use array filter + first)
    agent_status=$(printf '%s' "$STATUS_JSON" | jq \
        --arg name "$agent" \
        '[.data.agents[] | select(.name == $name)] | first // {}' 2>/dev/null || echo '{}')

    # Write combined per-dev data
    jq -n \
        --arg agent "$agent" \
        --arg slack_id "$slack_id" \
        --argjson github "$agent_github" \
        --argjson status "$agent_status" \
        '{ agent: $agent, slack_id: $slack_id, github: $github, status: $status }' \
        > "$WORK_DIR/${agent}.json"

    # Determine if agent is "active" (has GitHub events or sessions today)
    github_events=$(printf '%s' "$agent_github" | jq -r '.activity.summary.total_events // 0' 2>/dev/null || echo "0")
    sessions_today=$(printf '%s' "$agent_status" | jq -r '.sessions_today // 0' 2>/dev/null || echo "0")

    if [[ "$github_events" -gt 0 || "$sessions_today" -gt 0 ]]; then
        ACTIVE_AGENTS+=("$agent")
        ACTIVE_SLACK_IDS+=("$slack_id")
    fi
done

log "Phase 1 complete. ${#ACTIVE_AGENTS[@]} active of ${#AGENTS[@]} total."

if [[ "$DRY_RUN" == true ]]; then
    log "Dry run — dumping per-agent data and exiting."
    for agent in "${ACTIVE_AGENTS[@]}"; do
        echo "--- $agent ---"
        cat "$WORK_DIR/${agent}.json"
        echo ""
    done
    log "Active agents: ${ACTIVE_AGENTS[*]}"
    exit 0
fi

# ════════════════════════════════════════════════
# PHASE 2 — Per-Developer Narratives (one-shot cron jobs)
# ════════════════════════════════════════════════

log "=== Phase 2: Per-developer narratives (${#ACTIVE_AGENTS[@]} agents) ==="

CRON_JOB_IDS=()
BATCH_COUNT=0

for i in "${!ACTIVE_AGENTS[@]}"; do
    agent="${ACTIVE_AGENTS[$i]}"
    slack_id="${ACTIVE_SLACK_IDS[$i]}"
    data_file="$WORK_DIR/${agent}.json"
    narrative_file="$WORK_DIR/${agent}-narrative.txt"

    prompt="You are composing an evening report entry for YOUR developer.
Read the data file at ${data_file} and write a 200-300 word narrative.

Cover:
1. What was implemented — PR titles, feature names, repos. Be specific.
2. Challenges — blockers, complexity, dependencies.
3. Next steps — open PRs, carry-over items.

Rules:
- Only reference data from the file.
- Do not fabricate numbers, PR titles, or features.
- No header or greeting. Just the narrative.
- Slack formatting: bold, bullets. No tables.
- If < 3 events, write 100-150 words instead.
- Write your output to: ${narrative_file}"

    # Create one-shot cron job with isolated session
    session_key="agent:${agent}:cron:evening-report:${TODAY}"
    job_output=$(openclaw cron add \
        --agent "$agent" \
        --name "${agent} Evening Narrative ${TODAY}" \
        --at "$(date -u -v+2M '+%Y-%m-%dT%H:%M:%SZ')" \
        --delete-after-run \
        --session-key "$session_key" \
        --session "session:slack:direct:$(echo "$slack_id" | tr '[:upper:]' '[:lower:]')" \
        --wake "now" \
        --no-deliver \
        --thinking "medium" \
        --timeout-seconds "$PHASE2_TIMEOUT" \
        --message "$prompt" 2>&1) || {
        log "  WARNING: Failed to create cron job for $agent: $job_output"
        continue
    }

    # Extract job ID from output
    job_id=$(echo "$job_output" | grep -o '[0-9a-f\-]\{36\}' | head -1 || true)
    if [[ -n "$job_id" ]]; then
        CRON_JOB_IDS+=("$job_id")
    fi

    log "  Scheduled: $agent (session: $session_key)"
    BATCH_COUNT=$((BATCH_COUNT + 1))

    # Throttle to avoid overwhelming the scheduler
    if [[ $((BATCH_COUNT % MAX_PARALLEL)) -eq 0 ]]; then
        sleep 2
    fi
done

log "Scheduled $BATCH_COUNT narrative jobs. Polling for output files..."

# Poll for narrative files
POLL_ELAPSED=0
while [[ $POLL_ELAPSED -lt $PHASE2_POLL_MAX ]]; do
    COMPLETED=0
    for agent in "${ACTIVE_AGENTS[@]}"; do
        narrative_file="$WORK_DIR/${agent}-narrative.txt"
        if [[ -f "$narrative_file" ]] && [[ -s "$narrative_file" ]]; then
            COMPLETED=$((COMPLETED + 1))
        fi
    done

    if [[ $COMPLETED -ge ${#ACTIVE_AGENTS[@]} ]]; then
        log "All $COMPLETED narratives received."
        break
    fi

    log "  $COMPLETED/${#ACTIVE_AGENTS[@]} narratives received (${POLL_ELAPSED}s elapsed)"
    sleep "$PHASE2_POLL_INTERVAL"
    POLL_ELAPSED=$((POLL_ELAPSED + PHASE2_POLL_INTERVAL))
done

# Count successes
NARRATIVE_COUNT=0
for agent in "${ACTIVE_AGENTS[@]}"; do
    narrative_file="$WORK_DIR/${agent}-narrative.txt"
    if [[ -f "$narrative_file" ]] && [[ -s "$narrative_file" ]]; then
        word_count=$(wc -w < "$narrative_file" | tr -d ' ')
        log "  OK: $agent ($word_count words)"
        NARRATIVE_COUNT=$((NARRATIVE_COUNT + 1))
    else
        log "  FAILED: $agent (no narrative file or empty)"
    fi
done

log "Phase 2 complete. $NARRATIVE_COUNT/${#ACTIVE_AGENTS[@]} narratives."

# Cleanup one-shot cron jobs (they're disabled but not deleted)
for job_id in "${CRON_JOB_IDS[@]}"; do
    openclaw cron rm "$job_id" 2>/dev/null || true
done

# ── Narrative count guard ────────────────────
MIN_NARRATIVES=$(( ${#ACTIVE_AGENTS[@]} / 2 ))
if [[ $NARRATIVE_COUNT -lt $MIN_NARRATIVES || $NARRATIVE_COUNT -eq 0 ]]; then
    log "ERROR: Only $NARRATIVE_COUNT/${#ACTIVE_AGENTS[@]} narratives succeeded (minimum: $MIN_NARRATIVES). Aborting."
    exit 1
fi

# ════════════════════════════════════════════════
# PHASE 3 — Team Summary (one-shot cron job)
# ════════════════════════════════════════════════

log "=== Phase 3: Team summary ==="

# Assemble all narratives
NARRATIVES_BLOCK=""
for i in "${!ACTIVE_AGENTS[@]}"; do
    agent="${ACTIVE_AGENTS[$i]}"
    slack_id="${ACTIVE_SLACK_IDS[$i]}"
    narrative_file="$WORK_DIR/${agent}-narrative.txt"
    narrative=$(cat "$narrative_file" 2>/dev/null || echo "[no data]")

    NARRATIVES_BLOCK="${NARRATIVES_BLOCK}
--- ${agent} (<@${slack_id}>) ---
${narrative}
"
done

STATUS_SUMMARY=$(printf '%s' "$STATUS_JSON" | jq '.data.summary // {}' 2>/dev/null || echo '{}')
MISSED_ALERTS=$(printf '%s' "$MISSED_JSON" | jq '.data.alerts // []' 2>/dev/null || echo '[]')

SUMMARY_FILE="$WORK_DIR/summary.txt"

summary_prompt="Compose the team evening report summary for Slack.
Date: ${TODAY}
Active: ${#ACTIVE_AGENTS[@]} of ${#AGENTS[@]} developers.

STATUS SUMMARY:
${STATUS_SUMMARY}

MISSED CHECK-IN ALERTS:
${MISSED_ALERTS}

PER-DEVELOPER NARRATIVES:
${NARRATIVES_BLOCK}

Sections:
- Team Overview (1 line: how many active, overall vibe)
- Key Themes (2-5 bullets, grouped by theme not by person)
- Blockers (who, what, how long — or \"No active blockers.\")
- Responsiveness (silent 12h+ from alerts, skip unscheduled — or \"All scheduled developers active today.\")
- Notable Items (omit section entirely if nothing notable)
End with: \"Per-developer details in thread.\"

Rules:
- Slack formatting only: *bold*, bullet lists, <@USER_ID> mentions. NO markdown tables.
- Under 500 words. Scannable.
- Be factual. Do not invent numbers or details not in the data.
- Output ONLY the Slack message text.
- Write your output to: ${SUMMARY_FILE}"

summary_session_key="agent:tech-manager:cron:evening-summary:${TODAY}"

summary_job_output=$(openclaw cron add \
    --agent tech-manager \
    --name "Evening Report Summary ${TODAY}" \
    --at "$(date -u -v+2M '+%Y-%m-%dT%H:%M:%SZ')" \
    --delete-after-run \
    --session-key "$summary_session_key" \
    --session "session:slack:channel:$(echo "$CHANNEL_ID" | tr '[:upper:]' '[:lower:]')" \
    --wake "now" \
    --no-deliver \
    --thinking "medium" \
    --timeout-seconds "$PHASE3_TIMEOUT" \
    --message "$summary_prompt" 2>&1) || true

summary_job_id=$(echo "$summary_job_output" | grep -o '[0-9a-f\-]\{36\}' | head -1 || true)

log "Scheduled summary job (session: $summary_session_key). Polling..."

# Poll for summary file
POLL_ELAPSED=0
while [[ $POLL_ELAPSED -lt $PHASE3_POLL_MAX ]]; do
    if [[ -f "$SUMMARY_FILE" ]] && [[ -s "$SUMMARY_FILE" ]]; then
        log "Summary received."
        break
    fi
    sleep "$PHASE2_POLL_INTERVAL"
    POLL_ELAPSED=$((POLL_ELAPSED + PHASE2_POLL_INTERVAL))
done

# Cleanup summary cron job
if [[ -n "$summary_job_id" ]]; then
    openclaw cron rm "$summary_job_id" 2>/dev/null || true
fi

TEAM_SUMMARY=""
if [[ -f "$SUMMARY_FILE" ]] && [[ -s "$SUMMARY_FILE" ]]; then
    TEAM_SUMMARY=$(cat "$SUMMARY_FILE")
fi

if [[ -z "$TEAM_SUMMARY" ]]; then
    log "WARNING: Team summary LLM call failed, using fallback"
    TEAM_SUMMARY="*Evening Report — ${TODAY}*

*Team Overview:* ${#ACTIVE_AGENTS[@]} of ${#AGENTS[@]} developers active today.

_Summary generation failed. Per-developer details in thread._"
fi

log "Phase 3 complete."

# ════════════════════════════════════════════════
# PHASE 4 — Send to Slack (bash, no LLM)
# ════════════════════════════════════════════════

log "=== Phase 4: Slack delivery ==="

# Send summary message
SEND_RESULT=$(openclaw message send \
    --channel slack \
    --target "channel:${CHANNEL_ID}" \
    --message "$TEAM_SUMMARY" 2>&1) || {
    log "ERROR: Failed to send summary: $SEND_RESULT"
    exit 1
}

log "Summary sent: $SEND_RESULT"

# Extract Message ID for threading
MSG_ID=$(echo "$SEND_RESULT" | grep -o 'Message ID: [0-9.]*' | sed 's/Message ID: //')

if [[ -z "$MSG_ID" ]]; then
    log "WARNING: Could not extract Message ID, thread replies will be top-level messages"
fi

# Send per-developer thread replies
for i in "${!ACTIVE_AGENTS[@]}"; do
    agent="${ACTIVE_AGENTS[$i]}"
    slack_id="${ACTIVE_SLACK_IDS[$i]}"
    narrative_file="$WORK_DIR/${agent}-narrative.txt"
    narrative=$(cat "$narrative_file" 2>/dev/null || continue)

    thread_msg="<@${slack_id}>
${narrative}"

    if [[ -n "$MSG_ID" ]]; then
        openclaw message send \
            --channel slack \
            --target "channel:${CHANNEL_ID}" \
            --reply-to "$MSG_ID" \
            --message "$thread_msg" 2>/dev/null || {
            log "WARNING: Thread reply failed for $agent"
        }
    else
        openclaw message send \
            --channel slack \
            --target "channel:${CHANNEL_ID}" \
            --message "$thread_msg" 2>/dev/null || {
            log "WARNING: Message send failed for $agent"
        }
    fi

    # Brief pause to avoid Slack rate limiting
    sleep 1
done

# Write idempotency marker
touch "$MARKER_FILE"

log "Phase 4 complete. Evening report delivered."
