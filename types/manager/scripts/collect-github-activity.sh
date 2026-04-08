#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency checks ────────────────────────
if ! command -v jq &>/dev/null; then
    json_error "collect-github-activity" "MISSING_DEP" "jq is required but not found"
    exit 1
fi

# ── Args ─────────────────────────────────────
SINCE_HOURS=12
BASE_DIR="$HOME/.openclaw/agents"
MAX_CONCURRENT=5

while [[ $# -gt 0 ]]; do
    case "$1" in
        --since)
            SINCE_HOURS="$2"
            shift 2
            ;;
        --base-dir)
            BASE_DIR="$2"
            shift 2
            ;;
        --max-concurrent)
            MAX_CONCURRENT="$2"
            shift 2
            ;;
        *)
            json_error "collect-github-activity" "BAD_ARG" "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ── Helper: extract GitHub username(s) from USER.md ──
extract_github_usernames() {
    local user_file="$1"
    local usernames=""

    if [[ -f "$user_file" ]]; then
        usernames=$(sed -n 's/.*[*][*]GitHub Usernames:[*][*][[:space:]]*//p' "$user_file" \
            | head -1 \
            | sed 's/[[:space:]]*$//' || true)
    fi

    # Return empty if placeholder or missing
    if [[ -z "$usernames" || "$usernames" == *"<"*">"* ]]; then
        echo ""
    else
        echo "$usernames"
    fi
}

# ── Phase 1: Pre-checks (sequential, fast) ──
TOTAL=0
SKIPPED_NO_USERNAME=0
SKIPPED_NO_SCRIPT=0
SKIP_RESULTS="[]"

AGENT_NAMES=()
AGENT_DIRS=()
AGENT_GITHUB_USERS=()

for agent_dir in "$BASE_DIR"/*/; do
    [[ -d "$agent_dir" ]] || continue

    agent_type_file="$agent_dir/.agent-type"
    [[ -f "$agent_type_file" ]] || continue
    agent_type=$(cat "$agent_type_file" 2>/dev/null | tr -d '[:space:]')
    [[ "$agent_type" == "dev-pa" ]] || continue

    agent_name=$(basename "$agent_dir")
    TOTAL=$((TOTAL + 1))

    ACTIVITY_SCRIPT="$agent_dir/scripts/github-activity.sh"
    if [[ ! -f "$ACTIVITY_SCRIPT" ]]; then
        log "SKIP $agent_name: no github-activity.sh"
        SKIPPED_NO_SCRIPT=$((SKIPPED_NO_SCRIPT + 1))
        SKIP_RESULTS=$(printf '%s' "$SKIP_RESULTS" | jq \
            --arg name "$agent_name" \
            '. + [{"agent": $name, "status": "no_script", "activity": null}]')
        continue
    fi

    GITHUB_USERS=$(extract_github_usernames "$agent_dir/USER.md")
    if [[ -z "$GITHUB_USERS" ]]; then
        log "SKIP $agent_name: no GitHub username in USER.md"
        SKIPPED_NO_USERNAME=$((SKIPPED_NO_USERNAME + 1))
        SKIP_RESULTS=$(printf '%s' "$SKIP_RESULTS" | jq \
            --arg name "$agent_name" \
            '. + [{"agent": $name, "status": "no_github_username", "activity": null}]')
        continue
    fi

    AGENT_NAMES+=("$agent_name")
    AGENT_DIRS+=("$agent_dir")
    AGENT_GITHUB_USERS+=("$GITHUB_USERS")
done

log "Pre-check: ${#AGENT_NAMES[@]} agents to fetch, $SKIPPED_NO_USERNAME no username, $SKIPPED_NO_SCRIPT no script"

# ── Phase 2: Parallel API calls ─────────────
WORK_TMPDIR=$(mktemp -d)
trap 'rm -rf "$WORK_TMPDIR"' EXIT

BATCH_PIDS=()

for i in "${!AGENT_NAMES[@]}"; do
    agent_name="${AGENT_NAMES[$i]}"
    agent_dir="${AGENT_DIRS[$i]}"
    github_users="${AGENT_GITHUB_USERS[$i]}"

    (
        ACTIVITY_SCRIPT="$agent_dir/scripts/github-activity.sh"
        log "Fetching $agent_name ($github_users, --since $SINCE_HOURS)"

        ACTIVITY_OUTPUT=""
        if ACTIVITY_OUTPUT=$(bash "$ACTIVITY_SCRIPT" --user "$github_users" --since "$SINCE_HOURS" 2>/dev/null); then
            ACTIVITY_DATA=$(printf '%s' "$ACTIVITY_OUTPUT" | jq '.data // empty' 2>/dev/null || echo "null")
            if [[ "$ACTIVITY_DATA" != "null" && -n "$ACTIVITY_DATA" ]]; then
                jq -n --arg name "$agent_name" --argjson activity "$ACTIVITY_DATA" \
                    '{"agent": $name, "status": "ok", "activity": $activity}' > "$WORK_TMPDIR/$agent_name.json"
            else
                jq -n --arg name "$agent_name" \
                    '{"agent": $name, "status": "ok", "activity": null}' > "$WORK_TMPDIR/$agent_name.json"
            fi
        else
            jq -n --arg name "$agent_name" \
                '{"agent": $name, "status": "script_error", "activity": null}' > "$WORK_TMPDIR/$agent_name.json"
            log "FAILED: $agent_name"
        fi
    ) &
    BATCH_PIDS+=($!)

    if [[ ${#BATCH_PIDS[@]} -ge $MAX_CONCURRENT ]]; then
        for pid in "${BATCH_PIDS[@]}"; do
            wait "$pid" 2>/dev/null || true
        done
        BATCH_PIDS=()
    fi
done

for pid in "${BATCH_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
done

# ── Phase 3: Merge results ──────────────────
COLLECTED=0
FAILED=0
AGENT_RESULTS="$SKIP_RESULTS"

for agent_name in "${AGENT_NAMES[@]}"; do
    result_file="$WORK_TMPDIR/$agent_name.json"
    if [[ -f "$result_file" ]]; then
        status=$(jq -r '.status' "$result_file")
        if [[ "$status" == "ok" ]]; then
            COLLECTED=$((COLLECTED + 1))
        else
            FAILED=$((FAILED + 1))
        fi
        AGENT_RESULTS=$(printf '%s' "$AGENT_RESULTS" | jq --slurpfile r "$result_file" '. + $r')
    else
        FAILED=$((FAILED + 1))
        AGENT_RESULTS=$(printf '%s' "$AGENT_RESULTS" | jq --arg name "$agent_name" \
            '. + [{"agent": $name, "status": "script_error", "activity": null}]')
    fi
done

# ── Build output ─────────────────────────────
DATA=$(jq -n \
    --argjson agents "$AGENT_RESULTS" \
    --argjson since_hours "$SINCE_HOURS" \
    --argjson total "$TOTAL" \
    --argjson collected "$COLLECTED" \
    --argjson skipped_no_username "$SKIPPED_NO_USERNAME" \
    --argjson skipped_no_script "$SKIPPED_NO_SCRIPT" \
    --argjson failed "$FAILED" \
    '{
        agents: $agents,
        since_hours: $since_hours,
        summary: {
            total_agents: $total,
            collected: $collected,
            skipped_no_github_username: $skipped_no_username,
            skipped_no_script: $skipped_no_script,
            failed: $failed
        }
    }')

log "Collection complete: $TOTAL agents, $COLLECTED collected, $SKIPPED_NO_USERNAME no username, $SKIPPED_NO_SCRIPT no script, $FAILED failed"

json_success "collect-github-activity" "$DATA"
