#!/bin/bash
# Remind Claude Code to read script conventions before creating/editing agent scripts.
# Fires on 1st edit per session only.

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')
STATE_FILE="/tmp/claude-hook-script-$SESSION_ID.state"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "1" > "$STATE_FILE"
    jq -n \
        --arg msg "Before editing agent scripts, read .claude/skills/dev/openclaw-add-script/SKILL.md for our conventions (json-response library, output protocol, script template). Scripts go in types/<type>/scripts/, not .openclaw/agents/." \
        '{permissionDecision: "deny", additionalContext: $msg}'
    exit 0
fi

jq -n '{permissionDecision: "allow"}'
exit 0
