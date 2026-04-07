#!/bin/bash
# Hard block: prevent git commit, checkout, and branch operations on the host.
# The host repo is a deployment cache — all changes go through PRs from the dev machine.
# Git hooks on the host also block these, but this gives a better error message.

source "$(dirname "$0")/../detect-env.sh"
if [[ "$IS_HOST" != "true" ]]; then
    jq -n '{permissionDecision: "allow"}'
    exit 0
fi

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Block git write operations (commit, checkout, switch, branch -d/-D, reset, rebase, merge, cherry-pick, push)
if echo "$COMMAND" | grep -qE 'git\s+(commit|checkout|switch|rebase|merge|cherry-pick|push|reset)\b'; then
    jq -n \
        --arg msg "BLOCKED: The host repo is a deployment cache. All code changes go through PRs from the dev machine. Never commit, checkout branches, or push on the host. See CLAUDE.md Deployment Architecture." \
        '{permissionDecision: "deny", additionalContext: $msg}'
    exit 0
fi

# Block destructive branch operations
if echo "$COMMAND" | grep -qE 'git\s+branch\s+-[dD]\b'; then
    jq -n \
        --arg msg "BLOCKED: The host repo is a deployment cache. Branch management happens on the dev machine." \
        '{permissionDecision: "deny", additionalContext: $msg}'
    exit 0
fi

jq -n '{permissionDecision: "allow"}'
exit 0
