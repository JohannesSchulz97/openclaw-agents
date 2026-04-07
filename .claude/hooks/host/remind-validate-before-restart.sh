#!/bin/bash
# Fire-once reminder: when running openclaw gateway restart, check that
# openclaw config validate was run first.

source "$(dirname "$0")/../detect-env.sh"
if [[ "$IS_HOST" != "true" ]]; then
    jq -n '{permissionDecision: "allow"}'
    exit 0
fi

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Only trigger on gateway restart commands
if ! echo "$COMMAND" | grep -qE 'openclaw\s+gateway\s+restart'; then
    jq -n '{permissionDecision: "allow"}'
    exit 0
fi

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')
STATE_FILE="/tmp/claude-hook-validate-restart-$SESSION_ID.state"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "1" > "$STATE_FILE"
    jq -n \
        --arg msg "Before restarting the gateway, make sure you ran 'openclaw config validate' first. Never restart without validating — a broken config will take the gateway down. If you already validated, proceed." \
        '{permissionDecision: "deny", additionalContext: $msg}'
    exit 0
fi

jq -n '{permissionDecision: "allow"}'
exit 0
