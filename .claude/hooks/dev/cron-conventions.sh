#!/bin/bash
# Remind Claude Code to read cron conventions before editing jobs-config.json.
# Fires on 1st edit per session only — not every time.

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')
STATE_FILE="/tmp/claude-hook-cron-$SESSION_ID.state"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "1" > "$STATE_FILE"
    jq -n \
        --arg msg "Before editing cron config, read .claude/skills/dev/openclaw-add-cron/SKILL.md for our conventions (sessionKey patterns, field names, delivery modes). These differ from generic OpenClaw defaults." \
        '{permissionDecision: "deny", additionalContext: $msg}'
    exit 0
fi

jq -n '{permissionDecision: "allow"}'
exit 0
