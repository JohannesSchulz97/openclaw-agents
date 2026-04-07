#!/bin/bash
# Fire-once deny: remind to use openclaw-add-channel or openclaw-add-secret
# skills before directly editing openclaw.json on the host.
# After the first deny, allows edits (the user may need to make manual changes).

source "$(dirname "$0")/../detect-env.sh"
if [[ "$IS_HOST" != "true" ]]; then
    jq -n '{permissionDecision: "allow"}'
    exit 0
fi

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // "default"')
STATE_FILE="/tmp/claude-hook-openclaw-json-$SESSION_ID.state"

if [[ ! -f "$STATE_FILE" ]]; then
    echo "1" > "$STATE_FILE"
    jq -n \
        --arg msg "You're editing openclaw.json directly on the host. Before proceeding, check if one of these skills covers your change: openclaw-add-channel (Slack bindings), openclaw-add-secret (credentials), openclaw-new-agent (agent registration). Direct edits are fine for other config changes — just run 'openclaw config validate' before restarting." \
        '{permissionDecision: "deny", additionalContext: $msg}'
    exit 0
fi

jq -n '{permissionDecision: "allow"}'
exit 0
