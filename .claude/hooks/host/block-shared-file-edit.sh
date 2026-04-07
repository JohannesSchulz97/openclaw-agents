#!/bin/bash
# Hard block: prevent editing shared files in ~/.openclaw/agents/*/
# on the host. These are symlinks managed by stow — edits would either
# fail (symlink to repo) or get overwritten on next deploy.
# Source of truth is types/<type>/ on the dev machine.

source "$(dirname "$0")/../detect-env.sh"
if [[ "$IS_HOST" != "true" ]]; then
    jq -n '{permissionDecision: "allow"}'
    exit 0
fi

jq -n \
    --arg msg "BLOCKED: Shared files in ~/.openclaw/agents/ are symlinks managed by stow. They're overwritten on every deploy. To change shared config, edit types/<type>/ on the dev machine and push via PR. Per-agent files (IDENTITY.md, USER.md, memory/) can be edited directly." \
    '{permissionDecision: "deny", additionalContext: $msg}'
exit 0
