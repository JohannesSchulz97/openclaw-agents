#!/bin/bash

# OpenClaw CLI blocker - reminds to use cc-openclaw skills
# Blocks on 1st call (force skill reading) + every 5th call (fight context compression)

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')

# Only process openclaw commands
case "$COMMAND" in
    *openclaw\ *)
        STATE_FILE="/tmp/claude-openclaw-blocker-$SESSION_ID.state"

        # Read counter or start at 0
        count=$(cat "$STATE_FILE" 2>/dev/null || echo "0")
        count=$((count + 1))

        # Write back counter
        echo "$count" > "$STATE_FILE"

        # Decision: block on 1st call OR every 5th call
        should_block=$((count == 1 || count % 5 == 0))

        if [[ $should_block -eq 1 ]]; then
            # Deny with reminder
            jq -n \
                --arg msg "Reminder: Use openclaw-* skills from .claude/skills/cc-openclaw/ for OpenClaw management tasks. Run 'ls .claude/skills/cc-openclaw/' to see available skills, then read the relevant SKILL.md before continuing." \
                '{permissionDecision: "deny", additionalContext: $msg}'
            exit 0
        else
            # Allow but inject compact checklist
            jq -n \
                --arg msg "OpenClaw CLI: Use cc-openclaw skills (.claude/skills/cc-openclaw/) for management tasks." \
                '{permissionDecision: "allow", additionalContext: $msg}'
            exit 0
        fi
        ;;
esac

# Default: allow
jq -n '{permissionDecision: "allow"}'
exit 0