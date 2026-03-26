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
# add_cron_job — add a new job to the cron config file
#
# Usage: add_cron_job <cron_file> <agent_name> <display_name> <slack_id> <model>
#
# Arguments:
#   cron_file    — path to jobs-config.json
#   agent_name   — agent identifier (e.g. "dev1")
#   display_name — human-readable name (e.g. "dev1")
#   slack_id     — Slack user ID (e.g. "<slack-id>")
#   model        — model identifier (e.g. "fw-mm25")
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
    message="Run scripts/poll-check.sh. Parse the JSON output.

If data.due == 0, output ONLY 'NO_ACTION' and nothing else.

If data.due == 1:
1. Review your conversation history and memory to understand what the developer has been working on recently.
2. Compose a warm, friendly check-in message. Be specific — reference something they were working on or mentioned recently. Your goal is to be supportive and helpful, not generic. Avoid canned phrases like 'just checking in' — instead ask a thoughtful question or offer help with something concrete.
3. Send the message using this exact command: openclaw message send --channel slack --target user:${slack_id} --message \"<your message>\"
4. After sending, update memory/poll-state.json: set awaiting_response to true."

    # Build the job object and append it to the jobs array
    local tmp_file
    tmp_file=$(mktemp)
    trap "rm -f '$tmp_file'" RETURN

    jq --arg id "$job_id" \
       --arg agentId "$agent_name" \
       --arg name "${display_name} Check-in" \
       --arg message "$message" \
       --arg model "$model" \
       --arg sessionKey "agent:${agent_name}:main" \
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
