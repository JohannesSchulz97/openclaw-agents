#!/usr/bin/env bash
# cron-utils.sh — Shared library for cron job management in jobs-config.json.
# Sourced by create-agent.sh and remove-agent.sh.
#
# Functions:
#   check_dependencies   — verify jq is installed
#   generate_uuid        — produce a new UUID v4
#   add_cron_job         — append a job entry to the cron config
#   remove_cron_job      — delete a job entry by agentId

set -euo pipefail

# --------------------------------------------------------------------------- #
# Source guard — prevent direct execution
# --------------------------------------------------------------------------- #
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: cron-utils.sh is a library and must be sourced, not executed directly." >&2
    echo "Usage: source \"\$(dirname \"\$0\")/lib/cron-utils.sh\"" >&2
    exit 1
fi

# Source schedule-utils for compute_checkin_times, build_cron_expr, validate_timezone
source "${BASH_SOURCE[0]%/*}/schedule-utils.sh"

# --------------------------------------------------------------------------- #
# check_dependencies — verify required tools are available
# --------------------------------------------------------------------------- #
check_dependencies() {
    if ! command -v jq &>/dev/null; then
        echo "Error: jq is required but not installed." >&2
        echo "Install it with:" >&2
        echo "  macOS:  brew install jq" >&2
        echo "  Ubuntu: sudo apt-get install jq" >&2
        echo "  Arch:   sudo pacman -S jq" >&2
        exit 1
    fi
}

# --------------------------------------------------------------------------- #
# generate_uuid — produce a UUID, using the best available method
# Note: The config id field is informational only. apply-cron.sh matches
# jobs by agentId, not by id. The gateway assigns and owns job IDs.
# --------------------------------------------------------------------------- #
generate_uuid() {
    # Prefer uuidgen (macOS, most Linux)
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
        return
    fi

    # Fallback: kernel random UUID (Linux)
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
        return
    fi

    # Last resort: construct from /dev/urandom
    local hex
    hex=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
    # Format as 8-4-4-4-12 and set version 4 / variant bits
    printf '%s-%s-4%s-%s-%s\n' \
        "${hex:0:8}" \
        "${hex:8:4}" \
        "${hex:13:3}" \
        "$(printf '%02x' $(( 0x${hex:16:2} & 0x3f | 0x80 )))${hex:18:2}" \
        "${hex:20:12}"
}

# --------------------------------------------------------------------------- #
# DEPRECATED: Use add_cron_jobs (plural) instead. This function creates a single
# every-2h check-in job. Retained for backward compatibility during migration.
#
# add_cron_job — add a new job to the cron config file
#
# Usage: add_cron_job <cron_file> <agent_name> <display_name> <slack_id> <model>
#
# Arguments:
#   cron_file    — path to jobs-config.json
#   agent_name   — agent identifier (e.g. "dev1")
#   display_name — human-readable name (e.g. "dev1")
#   slack_id     — Slack user ID (e.g. "<slack-id>")
#   model        — model identifier (e.g. "openai-codex/gpt-5.4")
# --------------------------------------------------------------------------- #
add_cron_job() {
    local cron_file="${1:?Usage: add_cron_job <cron_file> <agent_name> <display_name> <slack_id> <model>}"
    local agent_name="${2:?Missing agent_name}"
    local display_name="${3:?Missing display_name}"
    local slack_id="${4:?Missing slack_id}"
    local model="${5:?Missing model}"

    if [[ ! -f "$cron_file" ]]; then
        echo "Error: Cron file not found: $cron_file" >&2
        return 1
    fi

    local job_id
    job_id=$(generate_uuid)

    # Build the payload message with substituted values
    local message
    message="Run scripts/poll-check.sh. Parse the JSON output.\n\nIf data.due == 0, output ONLY 'NO_ACTION' and nothing else.\n\nIf data.due == 1:\n1. Read USER.md to find the developer's name, context, and GitHub username(s) from the ## GitHub section. Also read IDENTITY.md to find your target Slack user ID.\n2. If one or more GitHub usernames are configured in USER.md, run scripts/github-activity.sh --user <github-usernames> --since 24 (comma-separated if multiple). Parse the output for recent PRs, commits, reviews, and issues. If no GitHub username is configured, or the script fails or returns no data, skip this step and proceed without it -- GitHub activity is enrichment, not a blocker.\nIMPORTANT: Only use GitHub activity data from the script output above. Do NOT independently query GitHub APIs, the Events API, or any other GitHub endpoints. Do NOT reference any repositories outside <your-org> organization. Personal repos are strictly off-limits.\n3. Review your conversation history and memory for recent context about what the developer has been working on.\n4. Compose a check-in message that:\n   a. References specific GitHub activity or recent conversation context\n   b. Asks what they have been working on since the last check-in\n   c. Explicitly asks them to share any work NOT visible in GitHub -- meetings, design discussions, code reviews, research, architecture planning, pairing sessions, mentoring, documentation, or any other contributions\n   d. Asks about current blockers or anything they need help with\n   e. Is warm and specific, not generic. Avoid canned phrases like 'just checking in'.\n5. Send the message using this exact command: openclaw message send --channel slack --target user:<SLACK_ID> --message \"<your message>\" -- where <SLACK_ID> is the target user's Slack ID from your identity/config files.\n6. After sending, update memory/poll-state.json: set awaiting_response to true."

    # Build the job object and append it to the jobs array
    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN

    jq --arg id "$job_id" \
       --arg agentId "$agent_name" \
       --arg name "${display_name} Check-in" \
       --arg message "$message" \
       --arg model "$model" \
       --arg sessionKey "agent:${agent_name}:cron:checkin" \
       '.jobs += [{
            id: $id,
            agentId: $agentId,
            name: $name,
            enabled: true,
            schedule: {
                kind: "every",
                everyMs: 7200000
            },
            sessionTarget: "isolated",
            wakeMode: "now",
            payload: {
                kind: "agentTurn",
                message: $message,
                timeoutSeconds: 180,
                thinking: "on",
                model: $model
            },
            sessionKey: $sessionKey,
            delivery: {
                mode: "none"
            }
        }]' "$cron_file" > "$tmp_file"

    mv "$tmp_file" "$cron_file"
    echo "Added cron job '${display_name} Check-in' for agent '${agent_name}' (id: ${job_id})"
}

# --------------------------------------------------------------------------- #
# add_cron_jobs — add 3 time-of-day check-in jobs (morning, midday, evening)
#
# Usage: add_cron_jobs <cron_file> <agent_name> <display_name> <model> <start_hour> <end_hour> <timezone> <works_weekends>
# --------------------------------------------------------------------------- #
add_cron_jobs() {
    local cron_file="$1" agent_name="$2" display_name="$3" model="$4"
    local start_hour="${5:-9}" end_hour="${6:-18}" timezone="${7:-UTC}" works_weekends="${8:-false}"

    if [[ ! -f "$cron_file" ]]; then
        echo "Error: Cron file not found: $cron_file" >&2
        return 1
    fi

    # Validate timezone
    if ! validate_timezone "$timezone"; then
        echo "Error: Invalid timezone: $timezone" >&2
        return 1
    fi

    # Compute check-in times
    compute_checkin_times "$start_hour" "$end_hour"

    # Build cron expressions
    local morning_cron midday_cron evening_cron
    morning_cron=$(build_cron_expr "$MORNING_HOUR" "$MORNING_MIN" "$works_weekends")
    midday_cron=$(build_cron_expr "$MIDDAY_HOUR" "$MIDDAY_MIN" "$works_weekends")
    evening_cron=$(build_cron_expr "$EVENING_HOUR" "$EVENING_MIN" "$works_weekends")

    # Create 3 jobs with type-specific payloads
    for type in morning midday evening; do
        local job_id
        job_id=$(generate_uuid)
        local cron_expr name_suffix message

        case $type in
            morning)
                cron_expr="$morning_cron"
                name_suffix="Morning Check-in"
                message="Run scripts/checkin-guard.sh morning. Parse the JSON output.\n\nIf data.skip == true, output ONLY 'NO_ACTION' and nothing else.\n\nIf data.skip == false:\n1. Read USER.md to find the developer's name, context, and GitHub username(s). Read IDENTITY.md for your target Slack user ID.\n2. If GitHub usernames configured, run scripts/github-activity.sh --user <github-usernames> --since 16 (overnight activity). Parse for recent PRs, commits, reviews. Skip if no username or script fails.\nIMPORTANT: Only use GitHub data from script output. Do NOT query GitHub APIs independently. Only <your-org> org repos.\n3. Review conversation history and memory for recent context.\n4. Compose a SHORT morning check-in (2-3 sentences max) that:\n   a. Greets them for the start of their day\n   b. If relevant, mention carry-over from the previous workday or overnight activity -- do NOT list commits/PRs. If today is Monday and works_weekends is false in work-schedule.json, refer to carry-over from Friday/last week rather than yesterday.\n   c. Asks what they're planning to focus on today\n   d. Tone: energetic, forward-looking, planning-oriented\n5. If data.prev_unanswered == true, add a brief gentle note (e.g., \"Didn't hear back yesterday -- no worries, just making sure nothing's stuck.\")\n6. Send via: openclaw message send --channel slack --target user:<SLACK_ID> --message \"<your message>\" -- where <SLACK_ID> is from IDENTITY.md."
                ;;
            midday)
                cron_expr="$midday_cron"
                name_suffix="Midday Check-in"
                message="Run scripts/checkin-guard.sh midday. Parse the JSON output.\n\nIf data.skip == true, output ONLY 'NO_ACTION' and nothing else.\n\nIf data.skip == false:\n1. Read USER.md to find the developer's name, context, and GitHub username(s). Read IDENTITY.md for your target Slack user ID.\n2. If GitHub usernames configured, run scripts/github-activity.sh --user <github-usernames> --since 6 (today's work so far). Parse for recent activity. Skip if no username or script fails.\nIMPORTANT: Only use GitHub data from script output. Do NOT query GitHub APIs independently. Only <your-org> org repos.\n3. Review conversation history and memory for what they said this morning.\n4. Compose a SHORT midday check-in (2-3 sentences max) that:\n   a. Acknowledges the day is underway\n   b. Asks what's keeping them busy, including beyond what's visible in GitHub\n   c. Asks if they need help with anything\n   d. Tone: collaborative, curious, supportive\n5. If data.prev_unanswered == true, mention briefly and move on.\n6. Send via: openclaw message send --channel slack --target user:<SLACK_ID> --message \"<your message>\" -- where <SLACK_ID> is from IDENTITY.md."
                ;;
            evening)
                cron_expr="$evening_cron"
                name_suffix="Evening Check-in"
                message="Run scripts/checkin-guard.sh evening. Parse the JSON output.\n\nIf data.skip == true, output ONLY 'NO_ACTION' and nothing else.\n\nIf data.skip == false:\n1. Read USER.md to find the developer's name, context, and GitHub username(s). Read IDENTITY.md for your target Slack user ID.\n2. If GitHub usernames configured, run scripts/github-activity.sh --user <github-usernames> --since 10 (today's full activity). Parse for recent activity. Skip if no username or script fails.\nIMPORTANT: Only use GitHub data from script output. Do NOT query GitHub APIs independently. Only <your-org> org repos.\n3. Review conversation history and memory for what happened today.\n4. Compose a SHORT evening check-in (2-3 sentences max) that:\n   a. Acknowledges the day is winding down\n   b. Asks how the day went -- what went well, what didn't. If today is Friday and works_weekends is false in work-schedule.json, ask what to carry over to next week and add a brief weekend sign-off. Otherwise ask what to carry over tomorrow.\n   c. Tone: reflective, appreciative, wrap-up oriented\n5. If data.prev_unanswered == true and data.missed_checkins >= 2, note gently (\"Haven't heard from you today -- hope everything's OK. No pressure, just here if you need anything.\")\n6. Send via: openclaw message send --channel slack --target user:<SLACK_ID> --message \"<your message>\" -- where <SLACK_ID> is from IDENTITY.md."
                ;;
        esac

        # Append to jobs-config.json using jq
        local tmp_file
        tmp_file=$(mktemp)
        trap "rm -f '$tmp_file'" RETURN

        jq --arg id "$job_id" \
           --arg agentId "$agent_name" \
           --arg name "${display_name} ${name_suffix}" \
           --arg message "$message" \
           --arg model "$model" \
           --arg sessionKey "agent:${agent_name}:cron:${type}" \
           --arg cronExpr "$cron_expr" \
           --arg tz "$timezone" \
           '.jobs += [{
                id: $id,
                agentId: $agentId,
                name: $name,
                enabled: true,
                schedule: {
                    kind: "cron",
                    cronExpr: $cronExpr,
                    tz: $tz
                },
                sessionTarget: "isolated",
                wakeMode: "now",
                payload: {
                    kind: "agentTurn",
                    message: $message,
                    timeoutSeconds: 180,
                    thinking: "on",
                    model: $model
                },
                sessionKey: $sessionKey,
                delivery: {
                    mode: "none"
                }
            }]' "$cron_file" > "$tmp_file"

        mv "$tmp_file" "$cron_file"
        echo "Added cron job '${display_name} ${name_suffix}' for agent '${agent_name}' (id: ${job_id})"
    done
}

# --------------------------------------------------------------------------- #
# remove_cron_job — remove a job by agentId from the cron config file
#
# Usage: remove_cron_job <cron_file> <agent_name>
# --------------------------------------------------------------------------- #
remove_cron_job() {
    local cron_file="${1:?Usage: remove_cron_job <cron_file> <agent_name>}"
    local agent_name="${2:?Missing agent_name}"

    if [[ ! -f "$cron_file" ]]; then
        echo "Error: Cron file not found: $cron_file" >&2
        return 1
    fi

    # Check if a matching job exists
    local count
    count=$(jq --arg agentId "$agent_name" '[.jobs[] | select(.agentId == $agentId)] | length' "$cron_file")

    if [[ "$count" -eq 0 ]]; then
        echo "Warning: No cron job found for agent '${agent_name}'" >&2
        return 1
    fi

    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN

    jq --arg agentId "$agent_name" \
       '.jobs = [.jobs[] | select(.agentId != $agentId)]' \
       "$cron_file" > "$tmp_file"

    mv "$tmp_file" "$cron_file"
    echo "Removed ${count} cron job(s) for agent '${agent_name}'"
}
