#!/bin/bash
# Hard block: prevent editing the deploy workflow without explicit user approval.
# deploy.yml is critical infrastructure. Always deny.

jq -n \
    --arg msg "BLOCKED: .github/workflows/deploy.yml is critical infrastructure. Explain the proposed change to the user and get explicit approval before editing. See docs/invariants.md (Area 2)." \
    '{permissionDecision: "deny", additionalContext: $msg}'
exit 0
