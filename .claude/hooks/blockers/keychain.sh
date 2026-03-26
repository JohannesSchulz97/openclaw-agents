#!/bin/bash

# Keychain blocker - reminds to use openclaw-add-secret skill
# Blocks on 1st call (force skill reading) + every 5th call (fight context compression)

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')

# Only process keychain commands
case "$COMMAND" in
    *security\ add-generic-password*|*security\ delete-generic-password*)
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
                --arg msg "Reminder: Use 'openclaw-add-secret' skill for keychain operations. See .claude/skills/cc-openclaw/openclaw-add-secret/SKILL.md" \
                '{permissionDecision: "deny", additionalContext: $msg}'
            exit 0
        else
            # Allow but inject compact checklist
            jq -n \
                --arg msg "Keychain: Use openclaw-add-secret skill for secrets management." \
                '{permissionDecision: "allow", additionalContext: $msg}'
            exit 0
        fi
        ;;
esac

# Default: allow
jq -n '{permissionDecision: "allow"}'
exit 0