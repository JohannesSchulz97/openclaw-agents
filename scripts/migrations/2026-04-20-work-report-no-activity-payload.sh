#!/usr/bin/env bash
set -euo pipefail

# 2026-04-20-work-report-no-activity-payload.sh
#
# One-off migration for #310 (PR 2): rewrite the payload.message of every
# dev-pa work-report cron entry in .openclaw/cron/jobs-config.json to the
# new template produced by add_cron_jobs() after PR 1 merged.
#
# What changes per entry:
#   • Early-exit branch when data.no_activity == true
#   • "No activity recorded today" rule removed (we now skip writing the file)
#   • DM flow reordered (sessions_send after the dm gate)
#
# Each existing entry already has the agent's lowercased Slack ID baked into
# its sessions_send sessionKey — this script extracts that ID and substitutes
# it back into the new template. Agent name is taken from .agentId.
#
# Safe to re-run: the result is idempotent (same output for same input).
#
# Usage:  bash scripts/migrations/2026-04-20-work-report-no-activity-payload.sh
#         Operates on the repo's jobs-config.json in place.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONFIG="$REPO_ROOT/.openclaw/cron/jobs-config.json"

if [[ ! -f "$CONFIG" ]]; then
    echo "Error: $CONFIG not found" >&2
    exit 1
fi

# Canonical template — must stay in sync with the string built by
# scripts/lib/cron-utils.sh :: add_cron_jobs(). Placeholders:
#   __AGENT__  → agentId
#   __slack__  → lowercased Slack user ID
TEMPLATE='Run scripts/work-report.sh prepare and parse the JSON output.\nIf success is false, stop and output the error.\n\nIf data.no_activity is true, stop here. Do NOT compose a report, do NOT write a file, do NOT call finalize, do NOT send a DM. The prepare step already recorded that the cron fired (report-state.last_run_epoch). Output only '\''NO_ACTIVITY'\''.\n\nOtherwise, compose an end-of-day work report using data.github_activity and data.conversation_digest. Format richly using bold, italic, `backticks` for technical terms (script names, config keys, file paths), and linked PR/issue references.\n\nUse these sections:\n\n## Work Report — <data.date>\n\n### ✅ What was accomplished\nEach distinct item (feature, fix, investigation, review, discussion) gets its OWN bullet with a detailed explanation of what and why. NEVER combine multiple PRs or features into a single bullet point. Include both GitHub activity and work from data.conversation_digest. Link PRs and issues using full markdown links to <your-org> org.\n\nExample bullet:\n- **Preserved LCM plugin config** across `plugins install --force` — added two-layer save/restore in `update-openclaw.sh` to back up `openclaw.json` and launchd plist env vars before reinstall ([#257](https://github.com/<your-org>/openclaw-agents/pull/257), fixes [#256](https://github.com/<your-org>/openclaw-agents/issues/256))\n\n### ⚠️ Challenges\nBlockers, complexity, dependencies, things that need attention. Write "None" if clear.\n\n### 📋 Next steps\nOpen PRs, carry-over items, plans for the next working day. Only write "Not discussed" if there is genuinely no indication of what comes next.\n\nRules:\n- One bullet per distinct item. Each PR or piece of work is separate.\n- Each bullet should explain what was done and why — the reader should understand the change without looking up the PR.\n- Be factual. Do NOT fabricate PR titles, issue numbers, or feature names.\n- If data.file_exists is true, mention "Updated report" in the DM.\n\nSave the report to data.output_file.\nRun scripts/work-report.sh finalize.\n\nIf data.dm is true, send the report to your developer via Slack DM.\n\nBefore sending, inject the report into the DM session so replies have context:\nsessions_send sessionKey="agent:__AGENT__:slack:direct:__slack__" message="<report>" timeoutSeconds=0\n\nConvert the markdown formatting to Slack equivalents — keep all rich formatting (bold, italic, inline code, emojis, links) but use Slack syntax:\nopenclaw message send --channel slack --target user:<data.slack_user_id> --message "<report>"\nIf data.dm is false, skip the DM — only write the report to data.output_file.'

# Enumerate agents with a :report cron entry (excludes tech-manager, whose
# :report-style key is :evening-report, not :report).
AGENTS=$(jq -r '
    .jobs[]
    | select(.sessionKey | endswith(":report"))
    | select(.agentId != "tech-manager")
    | .agentId
' "$CONFIG")

if [[ -z "$AGENTS" ]]; then
    echo "No dev-pa :report entries found. Nothing to do."
    exit 0
fi

updated=0
for agent in $AGENTS; do
    existing_msg=$(jq -r --arg a "$agent" '
        .jobs[]
        | select(.agentId == $a and (.sessionKey | endswith(":report")))
        | .payload.message
    ' "$CONFIG")

    slack_id_lower=$(printf '%s' "$existing_msg" \
        | grep -oE "agent:${agent}:slack:direct:[a-z0-9]+" \
        | head -1 \
        | sed 's|.*:||' || true)

    if [[ -z "$slack_id_lower" ]]; then
        echo "WARN: could not extract slack-id for agent '$agent' — skipping"
        continue
    fi

    new_msg="${TEMPLATE//__AGENT__/$agent}"
    new_msg="${new_msg//__slack__/$slack_id_lower}"

    tmp=$(mktemp)
    jq --arg a "$agent" --arg m "$new_msg" '
        .jobs |= map(
            if .agentId == $a and (.sessionKey | endswith(":report"))
            then .payload.message = $m
            else .
            end
        )
    ' "$CONFIG" > "$tmp"
    mv "$tmp" "$CONFIG"

    updated=$((updated + 1))
    echo "updated: $agent (slack:direct:$slack_id_lower)"
done

echo
echo "Total entries updated: $updated"
