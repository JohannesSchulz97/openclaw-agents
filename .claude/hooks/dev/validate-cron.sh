#!/bin/bash
# PostToolUse: validate cron config after edit.
# Runs validate-invariants.sh and reports failures as additionalContext.

REPO_ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"

RESULT=$(bash "$REPO_ROOT/scripts/validate-invariants.sh" --target cron --format json 2>/dev/null) || true
FAILED=$(echo "$RESULT" | jq -r '.failed // 0')

if [[ "$FAILED" -gt 0 ]]; then
    MSGS=$(echo "$RESULT" | jq -r '[.failures[] | "- [" + .check + "] " + .message] | join("\n")')
    jq -n --arg m "Cron invariant validation FAILED after edit:\n$MSGS\n\nFix these before committing. See docs/invariants.md (Area 1)." \
        '{additionalContext: $m}'
else
    echo '{}'
fi
exit 0
