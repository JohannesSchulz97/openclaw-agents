#!/bin/bash
# Hard block: prevent editing shared files in .openclaw/agents/ directly.
# These files are overwritten by sync-agents.sh on every deploy.
# Source of truth is types/<type>/. Always deny.

jq -n \
    --arg msg "BLOCKED: Shared files in .openclaw/agents/ are overwritten by sync-agents.sh on every deploy. Edit the source of truth in types/<type>/ instead. See docs/invariants.md (Area 2.1)." \
    '{permissionDecision: "deny", additionalContext: $msg}'
exit 0
