#!/bin/bash
# Remind Claude Code to read workspace layer model before editing shared agent config files.
# Fires on 1st edit per session only.

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')
STATE_FILE="/tmp/claude-hook-workspace-$SESSION_ID.state"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "1" > "$STATE_FILE"
    jq -n \
        --arg msg "Before editing shared agent config, read .claude/skills/dev/openclaw-workspace/SKILL.md for the layer model (which file owns which behavior). Remember: these files are shared across all agents of this type — per-agent changes must go in USER.md or MEMORY.md instead." \
        '{permissionDecision: "deny", additionalContext: $msg}'
    exit 0
fi

jq -n '{permissionDecision: "allow"}'
exit 0
