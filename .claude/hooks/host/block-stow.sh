#!/bin/bash
# Hard block: prevent running stow commands directly on the host.
# deploy.sh handles stow automatically. Manual stow is emergency-only
# and should go through the openclaw-stow skill.

source "$(dirname "$0")/../detect-env.sh"
if [[ "$IS_HOST" != "true" ]]; then
    jq -n '{permissionDecision: "allow"}'
    exit 0
fi

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Only block actual stow commands, not references in other commands
if echo "$COMMAND" | grep -qE '^\s*stow\b|&&\s*stow\b|;\s*stow\b|\|\s*stow\b'; then
    jq -n \
        --arg msg "BLOCKED: Normal deployments handle stow via deploy.sh automatically. For emergency manual intervention, read .claude/skills/host/openclaw-stow/SKILL.md first — stow --adopt MUST run before regular stow or per-agent files get destroyed." \
        '{permissionDecision: "deny", additionalContext: $msg}'
    exit 0
fi

jq -n '{permissionDecision: "allow"}'
exit 0
