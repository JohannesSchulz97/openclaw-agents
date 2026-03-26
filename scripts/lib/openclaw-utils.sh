#!/usr/bin/env bash
# openclaw-utils.sh — Shared library for managing openclaw.json entries.
# Sourced by create-agent.sh and remove-agent.sh.
#
# Functions:
#   add_agent_entry    — register an agent in .agents.list[]
#   remove_agent_entry — remove an agent from .agents.list[]
#   add_binding        — add a Slack DM route to .bindings[]
#   remove_binding     — remove a Slack DM route from .bindings[]
#   add_to_allowlist   — add a Slack user ID to .channels.slack.allowFrom[]
#
# SECURITY: openclaw.json contains credentials — never echo its contents.

set -euo pipefail

# --------------------------------------------------------------------------- #
# Source guard — prevent direct execution
# --------------------------------------------------------------------------- #
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "Error: openclaw-utils.sh is a library and must be sourced, not executed directly." >&2
    echo "Usage: source \"\$(dirname \"\$0\")/lib/openclaw-utils.sh\"" >&2
    exit 1
fi

# --------------------------------------------------------------------------- #
# log — print a message to stderr (never stdout, to protect credentials)
# --------------------------------------------------------------------------- #
log() {
    echo "[openclaw-utils] $*" >&2
}

# --------------------------------------------------------------------------- #
# check_jq — verify jq is installed
# --------------------------------------------------------------------------- #
check_jq() {
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
# _atomic_write — apply a jq filter to a JSON file via temp file + mv
#
# Usage: _atomic_write <file> <jq_filter> [jq_args...]
#
# All arguments after the filter are passed directly to jq (e.g. --arg).
# --------------------------------------------------------------------------- #
_atomic_write() {
    local file="$1"; shift
    local filter="$1"; shift

    local tmp_file
    tmp_file=$(mktemp "${file}.tmp.XXXXXX")
    trap "rm -f '$tmp_file'" RETURN

    jq "$filter" "$@" "$file" > "$tmp_file"
    mv "$tmp_file" "$file"
}

# --------------------------------------------------------------------------- #
# add_agent_entry — register an agent in .agents.list[]
#
# Usage: add_agent_entry <openclaw_file> <agent_name> <repo_root>
# --------------------------------------------------------------------------- #
add_agent_entry() {
    local openclaw_file="${1:?Usage: add_agent_entry <openclaw_file> <agent_name> <repo_root>}"
    local agent_name="${2:?Missing agent_name}"
    local repo_root="${3:?Missing repo_root}"

    check_jq

    if [[ ! -f "$openclaw_file" ]]; then
        log "Error: File not found: $openclaw_file"
        return 1
    fi

    # Idempotent: skip if already registered
    local exists
    exists=$(jq --arg id "$agent_name" \
        '[.agents.list[] | select(.id == $id)] | length' \
        "$openclaw_file")

    if [[ "$exists" -gt 0 ]]; then
        log "Agent '$agent_name' already exists in agents.list — skipping."
        return 0
    fi

    # Read the default model from the same file
    local model
    model=$(jq -r '.agents.defaults.model.primary // empty' "$openclaw_file")
    if [[ -z "$model" ]]; then
        log "Warning: No default model found at .agents.defaults.model.primary — using empty string."
        model=""
    fi

    local openclaw_dir
    openclaw_dir=$(dirname "$openclaw_file")

    _atomic_write "$openclaw_file" \
        '.agents.list += [{
            id: $name,
            name: $name,
            workspace: $workspace,
            agentDir: $agentDir,
            model: $model
        }]' \
        --arg name "$agent_name" \
        --arg workspace "${repo_root}/.openclaw/agents/${agent_name}" \
        --arg agentDir "${openclaw_dir}/agents/${agent_name}/agent" \
        --arg model "$model"

    log "Added agent '$agent_name' to agents.list."
}

# --------------------------------------------------------------------------- #
# remove_agent_entry — remove an agent from .agents.list[]
#
# Usage: remove_agent_entry <openclaw_file> <agent_name>
# --------------------------------------------------------------------------- #
remove_agent_entry() {
    local openclaw_file="${1:?Usage: remove_agent_entry <openclaw_file> <agent_name>}"
    local agent_name="${2:?Missing agent_name}"

    check_jq

    if [[ ! -f "$openclaw_file" ]]; then
        log "Error: File not found: $openclaw_file"
        return 1
    fi

    local count
    count=$(jq --arg id "$agent_name" \
        '[.agents.list[] | select(.id == $id)] | length' \
        "$openclaw_file")

    if [[ "$count" -eq 0 ]]; then
        log "Warning: No agent entry found for '$agent_name' — nothing to remove."
        return 1
    fi

    _atomic_write "$openclaw_file" \
        '.agents.list = [.agents.list[] | select(.id != $id)]' \
        --arg id "$agent_name"

    log "Removed agent '$agent_name' from agents.list."
}

# --------------------------------------------------------------------------- #
# add_binding — add a Slack DM route to .bindings[]
#
# Usage: add_binding <openclaw_file> <agent_name> <slack_id>
# --------------------------------------------------------------------------- #
add_binding() {
    local openclaw_file="${1:?Usage: add_binding <openclaw_file> <agent_name> <slack_id>}"
    local agent_name="${2:?Missing agent_name}"
    local slack_id="${3:?Missing slack_id}"

    check_jq

    if [[ ! -f "$openclaw_file" ]]; then
        log "Error: File not found: $openclaw_file"
        return 1
    fi

    # Idempotent: skip if a binding for this agent already exists
    local exists
    exists=$(jq --arg agentId "$agent_name" \
        '[.bindings // [] | .[] | select(.agentId == $agentId)] | length' \
        "$openclaw_file")

    if [[ "$exists" -gt 0 ]]; then
        log "Binding for agent '$agent_name' already exists — skipping."
        return 0
    fi

    _atomic_write "$openclaw_file" \
        '.bindings = (.bindings // []) + [{
            type: "route",
            agentId: $agentId,
            match: {
                channel: "slack",
                peer: {
                    kind: "direct",
                    id: $slackId
                }
            }
        }]' \
        --arg agentId "$agent_name" \
        --arg slackId "$slack_id"

    log "Added Slack DM binding for agent '$agent_name' (peer: $slack_id)."
}

# --------------------------------------------------------------------------- #
# remove_binding — remove a Slack DM route from .bindings[]
#
# Usage: remove_binding <openclaw_file> <agent_name>
# --------------------------------------------------------------------------- #
remove_binding() {
    local openclaw_file="${1:?Usage: remove_binding <openclaw_file> <agent_name>}"
    local agent_name="${2:?Missing agent_name}"

    check_jq

    if [[ ! -f "$openclaw_file" ]]; then
        log "Error: File not found: $openclaw_file"
        return 1
    fi

    local count
    count=$(jq --arg agentId "$agent_name" \
        '[.bindings // [] | .[] | select(.agentId == $agentId)] | length' \
        "$openclaw_file")

    if [[ "$count" -eq 0 ]]; then
        log "Warning: No binding found for agent '$agent_name' — nothing to remove."
        return 1
    fi

    _atomic_write "$openclaw_file" \
        '.bindings = [.bindings[] | select(.agentId != $agentId)]' \
        --arg agentId "$agent_name"

    log "Removed binding for agent '$agent_name'."
}

# --------------------------------------------------------------------------- #
# add_to_allowlist — add a Slack user ID to .channels.slack.allowFrom[]
#
# Usage: add_to_allowlist <openclaw_file> <slack_id>
#
# Idempotent: skips if the ID is already present.
# --------------------------------------------------------------------------- #
add_to_allowlist() {
    local openclaw_file="${1:?Usage: add_to_allowlist <openclaw_file> <slack_id>}"
    local slack_id="${2:?Missing slack_id}"

    check_jq

    if [[ ! -f "$openclaw_file" ]]; then
        log "Error: File not found: $openclaw_file"
        return 1
    fi

    # Idempotent: skip if already in the allowlist
    local already_present
    already_present=$(jq --arg id "$slack_id" \
        'if (.channels.slack.allowFrom | index($id)) then "yes" else "no" end' \
        "$openclaw_file" | tr -d '"')

    if [[ "$already_present" == "yes" ]]; then
        log "Slack ID '$slack_id' already in allowFrom — skipping."
        return 0
    fi

    _atomic_write "$openclaw_file" \
        '.channels.slack.allowFrom += [$id]' \
        --arg id "$slack_id"

    log "Added Slack ID '$slack_id' to channels.slack.allowFrom."
}
