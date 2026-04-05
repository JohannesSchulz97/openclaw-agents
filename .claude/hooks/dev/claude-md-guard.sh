#!/bin/bash
# Fire-once deny: force reading invariants before editing CLAUDE.md.
# CLAUDE.md contains the agent table with Slack IDs that cron jobs depend on.

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')
STATE_FILE="/tmp/claude-hook-claudemd-$SESSION_ID.state"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "1" > "$STATE_FILE"
    jq -n \
        --arg msg "CLAUDE.md contains the agent table — Slack IDs here must match cron sessionTarget values in jobs-config.json. Read docs/invariants.md (Area 1.3) before editing." \
        '{permissionDecision: "deny", additionalContext: $msg}'
    exit 0
fi

jq -n '{permissionDecision: "allow"}'
exit 0
