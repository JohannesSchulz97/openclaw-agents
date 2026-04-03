#!/usr/bin/env bash
# cron-utils.sh — Shared library for cron job management in jobs-config.json.
# Sourced by create-agent.sh and remove-agent.sh.
#
# Functions:
#   check_dependencies   — verify jq is installed
#   generate_uuid        — produce a new UUID v4
#   add_cron_job         — append a job entry to the cron config (DEPRECATED)
#   add_cron_jobs        — add 3 check-in + 1 summary job to the cron config
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
#   model        — model identifier (e.g. "glm-5")
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
            sessionTarget: "session:main",
            wakeMode: "now",
            payload: {
                kind: "agentTurn",
                message: $message,
                timeoutSeconds: 300,
                thinking: "medium"
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
# add_cron_jobs — add 3 time-of-day check-in jobs (morning, midday, evening) + 1 daily summary job
#
# Usage: add_cron_jobs <cron_file> <agent_name> <display_name> <model> <start_hour> <end_hour> <timezone> <works_weekends> <slack_id>
# --------------------------------------------------------------------------- #
add_cron_jobs() {
    local cron_file="$1" agent_name="$2" display_name="$3" model="$4"
    local start_hour="${5:-9}" end_hour="${6:-18}" timezone="${7:-UTC}" works_weekends="${8:-false}"
    local slack_id="${9:-}"

    # Derive session target: use DM session if Slack ID provided, otherwise fall back to session:main
    local session_target="session:main"
    if [[ -n "$slack_id" ]]; then
        session_target="session:slack:direct:$(echo "$slack_id" | tr '[:upper:]' '[:lower:]')"
    fi

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

    # Bootstrap preamble — shared across all check-in types
    local bootstrap_preamble
    bootstrap_preamble="Run scripts/bootstrap-check.sh prepare and parse the JSON.\n\nIf data.bootstrap_complete == false:\n  1. Check conversation history for replies to previous bootstrap questions. For each piece of info the developer provided, call: scripts/bootstrap-check.sh update --field <key> --value \"<value>\"\n  2. If data.missing_required is not empty after processing replies:\n     a. Read IDENTITY.md for your Slack user ID.\n     b. Send a friendly message. If this is the first interaction (no conversation history), introduce yourself: you are their personal AI assistant and will be checking in during the work day. Then ask for the missing information as bullet points, using each field's description from data.missing_required.\n     c. Send via: openclaw message send --channel slack --target user:<SLACK_ID> --message \"<your message>\"\n     d. Stop here. Do NOT proceed to the normal check-in below.\n  3. If data.missing_required is empty and data.identity_ask_available == true:\n     a. Ask if they'd like to customize your personality (name, vibe, creature, emoji). Keep it casual and brief.\n     b. Run scripts/bootstrap-check.sh identity-asked to record the ask.\n     c. If they decline or ignore, run scripts/bootstrap-check.sh identity-declined.\n     d. Send via openclaw message send, then stop.\n  4. If data.missing_required is empty and data.identity_ask_available == false: proceed to normal check-in below.\n\n--- Normal check-in (only when bootstrap is complete) ---\n\n"

    # Create 3 jobs with type-specific payloads
    for type in morning midday evening; do
        local job_id
        job_id=$(generate_uuid)
        local cron_expr name_suffix checkin_message message

        case $type in
            morning)
                cron_expr="$morning_cron"
                name_suffix="Morning Check-in"
                checkin_message="Run scripts/checkin-guard.sh morning. Parse the JSON output.\n\nIf data.skip == true, output ONLY 'NO_ACTION' and nothing else.\n\nIf data.skip == false:\n1. Read USER.md to find the developer's name, context, and GitHub username(s). Read IDENTITY.md for your target Slack user ID.\n2. If GitHub usernames configured, run scripts/github-activity.sh --user <github-usernames> --since 16 (overnight activity). Use this for your own context — do NOT mention specific GitHub activity unless you have a concrete reason to ask about it. Skip if no username or script fails.\nIMPORTANT: Only use GitHub data from script output. Do NOT query GitHub APIs independently. Only <your-org> org repos.\n3. Review conversation history and memory for recent context.\n4. Compose a SHORT morning check-in (2-3 sentences max) that:\n   a. Greets them naturally\n   b. Asks what their main priority is for today -- what's the most important thing to get done?\n   c. If you know from context that something is carrying over, briefly reference it. Otherwise don't force it.\n   d. Tone: natural, warm, straightforward. Not performatively energetic.\n5. If data.prev_unanswered == true, add a brief gentle note (e.g., \"Didn't hear back yesterday -- no worries, just making sure nothing's stuck.\")\n6. Send via: openclaw message send --channel slack --target user:<SLACK_ID> --message \"<your message>\" -- where <SLACK_ID> is from IDENTITY.md."
                ;;
            midday)
                cron_expr="$midday_cron"
                name_suffix="Midday Check-in"
                checkin_message="Run scripts/checkin-guard.sh midday. Parse the JSON output.\n\nIf data.skip == true, output ONLY 'NO_ACTION' and nothing else.\n\nIf data.skip == false:\n1. Read USER.md to find the developer's name, context, and GitHub username(s). Read IDENTITY.md for your target Slack user ID.\n2. If GitHub usernames configured, run scripts/github-activity.sh --user <github-usernames> --since 6 (today's work so far). Use this for your own context — do NOT mention specific GitHub activity unless you have a concrete reason to ask about it. Skip if no username or script fails.\nIMPORTANT: Only use GitHub data from script output. Do NOT query GitHub APIs independently. Only <your-org> org repos.\n3. Review conversation history and memory for what they said this morning.\n4. Compose a SHORT midday check-in (2-3 sentences max) that:\n   a. References what they said their priority was this morning (you have the morning conversation in this session) and asks how it's going. If no morning context is available, just ask what they're focused on.\n   b. Asks if anything is blocked or waiting on someone else\n   c. Tone: natural, curious. Don't try to summarize what you think they've been doing.\n5. If data.prev_unanswered == true, mention briefly and move on.\n6. Send via: openclaw message send --channel slack --target user:<SLACK_ID> --message \"<your message>\" -- where <SLACK_ID> is from IDENTITY.md."
                ;;
            evening)
                cron_expr="$evening_cron"
                name_suffix="Evening Check-in"
                checkin_message="Run scripts/checkin-guard.sh evening. Parse the JSON output.\n\nIf data.skip == true, output ONLY 'NO_ACTION' and nothing else.\n\nIf data.skip == false:\n1. Read USER.md to find the developer's name, context, and GitHub username(s). Read IDENTITY.md for your target Slack user ID.\n2. If GitHub usernames configured, run scripts/github-activity.sh --user <github-usernames> --since 10 (today's full activity). Use this for your own context — do NOT mention specific GitHub activity unless you have a concrete reason to ask about it. Skip if no username or script fails.\nIMPORTANT: Only use GitHub data from script output. Do NOT query GitHub APIs independently. Only <your-org> org repos.\n3. Review conversation history and memory for what happened today.\n4. Compose a SHORT evening check-in (2-3 sentences max) that:\n   a. Asks how the day went — what got done, what didn't\n   b. Asks if anything is carrying over and how the workload feels (stretched thin, comfortable, or have room for more?)\n   c. If today is Friday and works_weekends is false in work-schedule.json, frame carry-over as \"next week\" and include a brief weekend sign-off.\n   d. Tone: natural, reflective. Not overly appreciative or sentimental.\n5. If data.prev_unanswered == true and data.missed_checkins >= 2, note gently (\"Haven't heard from you today -- hope everything's OK. No pressure, just here if you need anything.\")\n6. Send via: openclaw message send --channel slack --target user:<SLACK_ID> --message \"<your message>\" -- where <SLACK_ID> is from IDENTITY.md."
                ;;
        esac

        # Combine bootstrap preamble with type-specific check-in
        message="${bootstrap_preamble}${checkin_message}"

        # Append to jobs-config.json using jq
        local tmp_file
        tmp_file=$(mktemp)
        trap "rm -f '$tmp_file'" RETURN

        jq --arg id "$job_id" \
           --arg agentId "$agent_name" \
           --arg name "${display_name} ${name_suffix}" \
           --arg message "$message" \
           --arg cronExpr "$cron_expr" \
           --arg tz "$timezone" \
           --arg sessionKey "agent:${agent_name}:cron:${type}" \
           --arg sessionTarget "$session_target" \
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
                sessionTarget: $sessionTarget,
                wakeMode: "now",
                payload: {
                    kind: "agentTurn",
                    message: $message,
                    timeoutSeconds: 300,
                    thinking: "medium"
                },
                sessionKey: $sessionKey,
                delivery: {
                    mode: "none"
                }
            }]' "$cron_file" > "$tmp_file"

        mv "$tmp_file" "$cron_file"
        echo "Added cron job '${display_name} ${name_suffix}' for agent '${agent_name}' (id: ${job_id})"
    done

    # Add daily summary job — runs at 20:00 CET (after evening check-in, before tech-manager report)
    local summary_id summary_message
    summary_id=$(generate_uuid)
    summary_message="Run scripts/daily-summary.sh prepare and parse the JSON. If success is false, stop.\n\n1. Summarize today's session conversations since data.last_summary_epoch (0 means full day). Follow data.template for section format.\n2. Write to data.output_file. Stay factual — use the developer's own words, do not fabricate.\n3. Run scripts/daily-summary.sh finalize.\n\nDo not modify any state files yourself."

    local summary_cron_expr
    if [[ "$works_weekends" == "true" ]]; then
        summary_cron_expr="0 20 * * *"
    else
        summary_cron_expr="0 20 * * 1-5"
    fi

    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN

    jq --arg id "$summary_id" \
       --arg agentId "$agent_name" \
       --arg name "${display_name} Daily Summary" \
       --arg message "$summary_message" \
       --arg cronExpr "$summary_cron_expr" \
       --arg sessionKey "agent:${agent_name}:cron:summary" \
       --arg sessionTarget "$session_target" \
       '.jobs += [{
            id: $id,
            agentId: $agentId,
            name: $name,
            enabled: true,
            schedule: {
                kind: "cron",
                cronExpr: $cronExpr,
                tz: "Europe/Berlin"
            },
            sessionTarget: $sessionTarget,
            wakeMode: "now",
            payload: {
                kind: "agentTurn",
                message: $message,
                timeoutSeconds: 300,
                thinking: "medium"
            },
            sessionKey: $sessionKey,
            delivery: {
                mode: "none"
            }
        }]' "$cron_file" > "$tmp_file"

    mv "$tmp_file" "$cron_file"
    echo "Added cron job '${display_name} Daily Summary' for agent '${agent_name}' (id: ${summary_id})"
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
