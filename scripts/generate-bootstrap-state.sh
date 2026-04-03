#!/usr/bin/env bash
set -euo pipefail

# generate-bootstrap-state.sh — One-time migration: create bootstrap-state.json for existing agents.
# Reads IDENTITY.md, USER.md, work-schedule.json, and CLAUDE.md to auto-detect completed fields.
# Agents with .BOOTSTRAP.md.done are marked fully complete.
#
# Usage: scripts/generate-bootstrap-state.sh [--dry-run]

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="$HOME/.openclaw/agents"
TEMPLATE="$REPO_ROOT/types/dev-pa/bootstrap-state.json.template"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ ! -f "$TEMPLATE" ]]; then
    echo "Error: Template not found: $TEMPLATE" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "Error: jq is required" >&2
    exit 1
fi

for agent_dir in "$AGENTS_DIR"/*/; do
    agent_dir="${agent_dir%/}"
    agent_name="$(basename "$agent_dir")"

    # Skip non-dev-pa agents
    if [[ -f "$agent_dir/.agent-type" ]]; then
        agent_type="$(cat "$agent_dir/.agent-type")"
        if [[ "$agent_type" != "dev-pa" ]]; then
            echo "[skip] $agent_name (type: $agent_type)"
            continue
        fi
    fi

    # Skip if already has bootstrap-state.json
    state_file="$agent_dir/bootstrap-state.json"
    if [[ -f "$state_file" ]]; then
        echo "[skip] $agent_name (bootstrap-state.json already exists)"
        continue
    fi

    echo "[generate] $agent_name"

    if $DRY_RUN; then
        echo "  DRY RUN: would create $state_file"
        continue
    fi

    # Start from template
    cp "$TEMPLATE" "$state_file"

    # Auto-detect Slack ID from IDENTITY.md
    if [[ -f "$agent_dir/IDENTITY.md" ]]; then
        slack_id=$(sed -n 's/.*\*\*Slack User ID:\*\* \(U[A-Z0-9]*\).*/\1/p' "$agent_dir/IDENTITY.md" 2>/dev/null | head -1 || true)
        if [[ -n "$slack_id" ]]; then
            tmp=$(mktemp)
            jq --arg v "$slack_id" '.fields.slack_id.completed=true | .fields.slack_id.auto_detected=true | .fields.slack_id.value=$v' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
            echo "  slack_id: $slack_id"
        fi
    fi

    # Auto-detect GitHub from CLAUDE.md
    display_name=$(echo "$agent_name" | sed 's/-/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1))substr($i,2)}1')
    github=$(grep -A5 "^## Agent: $display_name" "$CLAUDE_MD" 2>/dev/null | sed -n 's/^- GitHub: \(.*\)/\1/p' | head -1 || true)
    if [[ -n "$github" ]]; then
        tmp=$(mktemp)
        jq --arg v "$github" '.fields.github_usernames.completed=true | .fields.github_usernames.auto_detected=true | .fields.github_usernames.value=$v' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
        echo "  github: $github"
    fi

    # Auto-detect from work-schedule.json
    ws_file="$agent_dir/work-schedule.json"
    if [[ -f "$ws_file" ]]; then
        ws_value=$(jq -c '.' "$ws_file" 2>/dev/null || true)
        if [[ -n "$ws_value" && "$ws_value" != "null" ]]; then
            tmp=$(mktemp)
            jq --argjson v "$ws_value" '.fields.work_schedule.completed=true | .fields.work_schedule.auto_detected=true | .fields.work_schedule.value=$v' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
            echo "  work_schedule: detected"
        fi

        tz=$(jq -r '.timezone // empty' "$ws_file" 2>/dev/null || true)
        if [[ -n "$tz" ]]; then
            tmp=$(mktemp)
            jq --arg v "$tz" '.fields.developer_timezone.completed=true | .fields.developer_timezone.auto_detected=true | .fields.developer_timezone.value=$v' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
            echo "  timezone: $tz"
        fi
    fi

    # If .BOOTSTRAP.md.done exists, mark everything complete
    if [[ -f "$agent_dir/.BOOTSTRAP.md.done" ]]; then
        tmp=$(mktemp)
        jq '.bootstrap_complete = true | .fields |= with_entries(.value.completed = true)' "$state_file" > "$tmp" && mv "$tmp" "$state_file"
        echo "  .BOOTSTRAP.md.done found — marked fully complete"
    fi

    echo "  -> $state_file"
done

echo ""
echo "Done. Run 'bash scripts/apply-cron.sh' to push updated cron config to gateway."
