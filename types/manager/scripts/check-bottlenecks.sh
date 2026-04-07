#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency check ─────────────────────────
if ! command -v jq &>/dev/null; then
    echo '{"success":false,"operation":"check-bottlenecks","error":{"code":"MISSING_DEP","message":"jq is required but not found"}}' >&2
    exit 1
fi

# ── Args ─────────────────────────────────────
AGENTS=""
BASE_DIR="$HOME/.openclaw/agents"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --agents)
            AGENTS="$2"
            shift 2
            ;;
        --base-dir)
            BASE_DIR="$2"
            shift 2
            ;;
        *)
            json_error "check-bottlenecks" "BAD_ARG" "Unknown argument: $1"
            exit 1
            ;;
    esac
done

if [[ -z "$AGENTS" ]]; then
    json_error "check-bottlenecks" "MISSING_ARG" "--agents AGENT1,AGENT2,... is required"
    exit 1
fi

# ── Constants ────────────────────────────────
LONG_SESSION_THRESHOLD_S=7200    # 2 hours in seconds
<slack-id>E_THRESHOLD_S=28800   # 8 hours in seconds
BLOCKED_KEYWORDS="blocked|stuck|waiting|error|failed|can't proceed|cannot proceed"

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
BOTTLENECKS="[]"

for agent in "${AGENT_LIST[@]}"; do
    agent=$(echo "$agent" | xargs)
    AGENT_DIR="$BASE_DIR/$agent"

    log "Checking bottlenecks for: $agent"

    # ── Check session data ──────────────────
    SESSIONS_FILE="$AGENT_DIR/sessions/sessions.json"

    if [[ -f "$SESSIONS_FILE" ]]; then
        # Check for long-running active sessions (>2 hours continuous)
        LONG_SESSIONS=$(jq -r \
            --argjson now_ms "$(( NOW_EPOCH * 1000 ))" \
            --argjson threshold_ms "$(( LONG_SESSION_THRESHOLD_S * 1000 ))" \
            '
            to_entries
            | map(select(.key | test("cron") | not))
            | map(select(
                (.value.updatedAt // 0) as $updated |
                (.value.createdAt // 0) as $created |
                ($updated - $created) >= $threshold_ms and
                ($now_ms - $updated) < 600000
            ))
            | length
            ' "$SESSIONS_FILE" 2>/dev/null || echo "0")

        if [[ "$LONG_SESSIONS" -gt 0 ]]; then
            BOTTLENECK=$(jq -n \
                --arg agent "$agent" \
                --arg type "long_running_session" \
                --arg detail "$agent has $LONG_SESSIONS session(s) running for over 2 hours" \
                --arg severity "medium" \
                --arg since "" \
                '{
                    agent: $agent,
                    type: $type,
                    detail: $detail,
                    severity: $severity,
                    since: null
                }')
            BOTTLENECKS=$(echo "$BOTTLENECKS" | jq --argjson b "$BOTTLENECK" '. + [$b]')
            log "  BOTTLENECK: $agent has long-running sessions"
        fi

        # Check for high token usage with no recent human interaction
        # (sessions with large token counts but no human response)
        LAST_HUMAN_EPOCH_MS=$(jq -r '
            to_entries
            | map(select(.key | test("cron") | not))
            | map(.value.updatedAt // 0)
            | max // 0
        ' "$SESSIONS_FILE" 2>/dev/null || echo "0")

        if [[ "$LAST_HUMAN_EPOCH_MS" != "0" && "$LAST_HUMAN_EPOCH_MS" != "null" ]]; then
            LAST_HUMAN_EPOCH_S=$(( LAST_HUMAN_EPOCH_MS / 1000 ))
            SILENCE_S=$(( NOW_EPOCH - LAST_HUMAN_EPOCH_S ))

            # Count cron sessions since last human interaction
            CRON_SINCE=$(jq -r \
                --argjson since "$LAST_HUMAN_EPOCH_MS" \
                '
                to_entries
                | map(select(.key | test("cron")))
                | map(select((.value.updatedAt // 0) > $since))
                | length
                ' "$SESSIONS_FILE" 2>/dev/null || echo "0")

            if [[ "$CRON_SINCE" -gt 5 && "$SILENCE_S" -gt "$LONG_SESSION_THRESHOLD_S" ]]; then
                SINCE_ISO=$(epoch_to_iso "$LAST_HUMAN_EPOCH_S")
                BOTTLENECK=$(jq -n \
                    --arg agent "$agent" \
                    --arg type "possible_loop" \
                    --arg detail "$agent has $CRON_SINCE cron sessions with no human interaction for $(( SILENCE_S / 3600 )) hours" \
                    --arg severity "high" \
                    --arg since "$SINCE_ISO" \
                    '{
                        agent: $agent,
                        type: $type,
                        detail: $detail,
                        severity: $severity,
                        since: $since
                    }')
                BOTTLENECKS=$(echo "$BOTTLENECKS" | jq --argjson b "$BOTTLENECK" '. + [$b]')
                log "  BOTTLENECK: $agent may be stuck in a loop"
            fi
        fi
    else
        log "  WARNING: sessions.json not found for $agent"
    fi

    # ── Check developer unresponsive for >8 hours ──
    SESSIONS_FILE="$AGENT_DIR/sessions/sessions.json"

    if [[ -f "$SESSIONS_FILE" ]]; then
        LAST_DM_EPOCH_MS=$(jq -r '
            to_entries
            | map(select(.key | test("slack:direct:")))
            | map(.value.updatedAt // 0)
            | max // 0
        ' "$SESSIONS_FILE" 2>/dev/null || echo "0")

        if [[ "$LAST_DM_EPOCH_MS" != "0" && "$LAST_DM_EPOCH_MS" != "null" ]]; then
            LAST_DM_EPOCH_S=$(( LAST_DM_EPOCH_MS / 1000 ))
            SINCE_DM_S=$(( NOW_EPOCH - LAST_DM_EPOCH_S ))

            if [[ "$SINCE_DM_S" -ge "$<slack-id>E_THRESHOLD_S" ]]; then
                HOURS_SINCE=$(( SINCE_DM_S / 3600 ))
                SINCE_ISO=$(epoch_to_iso "$LAST_DM_EPOCH_S")
                BOTTLENECK=$(jq -n \
                    --arg agent "$agent" \
                    --arg type "developer_unresponsive" \
                    --arg detail "No DM interaction for $HOURS_SINCE hours" \
                    --arg severity "high" \
                    --arg since "$SINCE_ISO" \
                    '{
                        agent: $agent,
                        type: $type,
                        detail: $detail,
                        severity: $severity,
                        since: $since
                    }')
                BOTTLENECKS=$(echo "$BOTTLENECKS" | jq --argjson b "$BOTTLENECK" '. + [$b]')
                log "  BOTTLENECK: $agent developer unresponsive for ${HOURS_SINCE}h"
            fi
        fi
    fi

    # ── Check daily notes for blockers ─────────
    MEMORY_DIR="$AGENT_DIR/memory"
    FOUND_STRUCTURED_BLOCKERS="false"

    if [[ -d "$MEMORY_DIR" ]]; then
        # Check recent daily notes (last 3 days)
        RECENT_NOTES=$(find "$MEMORY_DIR" -maxdepth 1 -name '????-??-??.md' -type f 2>/dev/null \
            | sort -r | head -3 || true)

        if [[ -n "$RECENT_NOTES" ]]; then
            # ── Phase 1: Structured ## Blockers section ──
            while IFS= read -r note_file; do
                [[ -z "$note_file" ]] && continue
                NOTE_DATE=$(basename "$note_file" .md)

                # Extract lines between ## Blockers and next ## (or EOF)
                BLOCKER_LINES=$(sed -n '/^## Blockers/,/^## /{/^## Blockers/d;/^## /d;p;}' "$note_file" 2>/dev/null || true)

                # Parse list items (lines starting with - or *)
                if [[ -n "$BLOCKER_LINES" ]]; then
                    while IFS= read -r line; do
                        # Skip empty lines
                        [[ -z "$(echo "$line" | tr -d '[:space:]')" ]] && continue
                        # Match list items
                        if [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+(.*) ]]; then
                            ITEM="${BASH_REMATCH[1]}"
                            [[ -z "$ITEM" ]] && continue

                            # Try to extract "since YYYY-MM-DD"
                            SINCE_DATE=""
                            if [[ "$ITEM" =~ since[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
                                SINCE_DATE="${BASH_REMATCH[1]}"
                            fi

                            BOTTLENECK=$(jq -n \
                                --arg agent "$agent" \
                                --arg type "structured_blocker" \
                                --arg detail "$ITEM" \
                                --arg severity "high" \
                                --arg since "$SINCE_DATE" \
                                --arg note_date "$NOTE_DATE" \
                                '{
                                    agent: $agent,
                                    type: $type,
                                    detail: $detail,
                                    severity: $severity,
                                    since: (if $since == "" then null else $since end),
                                    note_date: $note_date
                                }')
                            BOTTLENECKS=$(echo "$BOTTLENECKS" | jq --argjson b "$BOTTLENECK" '. + [$b]')
                            FOUND_STRUCTURED_BLOCKERS="true"
                            log "  BOTTLENECK: $agent structured blocker: $ITEM"
                        fi
                    done <<< "$BLOCKER_LINES"
                fi

                # Only check the most recent note with structured blockers
                [[ "$FOUND_STRUCTURED_BLOCKERS" == "true" ]] && break
            done <<< "$RECENT_NOTES"

            # ── Phase 2: Keyword grep fallback (only if no structured blockers) ──
            if [[ "$FOUND_STRUCTURED_BLOCKERS" == "false" ]]; then
                MATCHED_KEYWORDS=""
                while IFS= read -r note_file; do
                    [[ -z "$note_file" ]] && continue
                    # Case-insensitive grep for blocked keywords
                    MATCHES=$(grep -iEo "$BLOCKED_KEYWORDS" "$note_file" 2>/dev/null | sort -u | tr '\n' ',' | sed 's/,$//' || true)
                    if [[ -n "$MATCHES" ]]; then
                        MATCHED_KEYWORDS="$MATCHES"
                        NOTE_DATE=$(basename "$note_file" .md)
                        break  # Report only the most recent match
                    fi
                done <<< "$RECENT_NOTES"

                if [[ -n "$MATCHED_KEYWORDS" ]]; then
                    BOTTLENECK=$(jq -n \
                        --arg agent "$agent" \
                        --arg type "blocked_keywords" \
                        --arg detail "Daily note ($NOTE_DATE) contains: $MATCHED_KEYWORDS" \
                        --arg severity "medium" \
                        --arg since "" \
                        '{
                            agent: $agent,
                            type: $type,
                            detail: $detail,
                            severity: $severity,
                            since: null
                        }')
                    BOTTLENECKS=$(echo "$BOTTLENECKS" | jq --argjson b "$BOTTLENECK" '. + [$b]')
                    log "  BOTTLENECK: $agent daily notes mention: $MATCHED_KEYWORDS"
                fi
            fi
        fi
    fi
done

# ── Build output ────────────────────────────
BOTTLENECK_COUNT=$(echo "$BOTTLENECKS" | jq 'length')
ALL_CLEAR="true"
if [[ "$BOTTLENECK_COUNT" -gt 0 ]]; then
    ALL_CLEAR="false"
fi

DATA=$(jq -n \
    --argjson bottlenecks "$BOTTLENECKS" \
    --argjson all_clear "$ALL_CLEAR" \
    '{
        bottlenecks: $bottlenecks,
        all_clear: $all_clear
    }')

log "Bottleneck scan complete: $BOTTLENECK_COUNT issues found"

json_success "check-bottlenecks" "$DATA"
