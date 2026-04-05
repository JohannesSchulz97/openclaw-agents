#!/bin/bash
# Hard block: prevent editing scripts in .openclaw/agents/ directly.
# The scripts/ directory is wiped by rsync --delete on every deploy.
# Source of truth is types/<type>/scripts/. Always deny.

jq -n \
    --arg msg "BLOCKED: Scripts in .openclaw/agents/*/scripts/ are wiped by rsync --delete on every deploy. Edit types/<type>/scripts/ instead. See docs/invariants.md (Area 2.1)." \
    '{permissionDecision: "deny", additionalContext: $msg}'
exit 0
