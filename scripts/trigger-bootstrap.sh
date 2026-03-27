#!/usr/bin/env bash
# trigger-bootstrap.sh — Trigger bootstrap for an agent by creating a one-time cron job
# that tells the agent to read BOOTSTRAP.md and reach out to its developer.
#
# Use case: Proactively initiate bootstrap from the admin side when a new agent
# has been created but hasn't had its first interactive session yet.
#
# Usage: scripts/trigger-bootstrap.sh --agent <name> [--dry-run]
# Example: scripts/trigger-bootstrap.sh --agent dev10

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------
AGENT_NAME=""
DRY_RUN=false

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: scripts/trigger-bootstrap.sh --agent NAME [OPTIONS]

Required:
  --agent NAME         Agent name, kebab-case (e.g., "dev10", "<your-org>")

Optional:
  --dry-run            Print what would be done without making changes
  --help               Show this help message
EOF
  exit "${1:-0}"
}

# ------------------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --agent)   AGENT_NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help)    usage 0 ;;
    *)         echo "Error: Unknown option: $1" >&2; usage 1 ;;
  esac
done

if [[ -z "$AGENT_NAME" ]]; then
  echo "Error: --agent is required" >&2
  usage 1
fi

# ------------------------------------------------------------------------------
# Validate agent exists
# ------------------------------------------------------------------------------
AGENT_DIR="$HOME/.openclaw/agents/$AGENT_NAME"
if [[ ! -d "$AGENT_DIR" ]]; then
  echo "Error: Agent directory not found: $AGENT_DIR" >&2
  exit 1
fi

# ------------------------------------------------------------------------------
# Check if already bootstrapped
# ------------------------------------------------------------------------------
if [[ -f "$AGENT_DIR/.BOOTSTRAP.md.done" ]]; then
  echo "Warning: Agent '$AGENT_NAME' has already completed bootstrap (.BOOTSTRAP.md.done exists)" >&2
  echo "Proceeding anyway..." >&2
fi

# ------------------------------------------------------------------------------
# Bootstrap message
# ------------------------------------------------------------------------------
MESSAGE="You have not yet been bootstrapped. Read BOOTSTRAP.md now and follow its instructions.

Your first task is to introduce yourself to your developer on Slack:
1. Read IDENTITY.md to find your target Slack user ID.
2. Compose a warm, casual introductory message following the spirit of BOOTSTRAP.md.
3. Send it using this exact command: openclaw message send --channel slack --target user:<SLACK_ID> --message \"<your intro message>\"
   Replace <SLACK_ID> with the actual Slack user ID from IDENTITY.md.

IMPORTANT RULES:
- You MUST use the openclaw message send command above to deliver your message. Do not skip this step.
- Do NOT run any git commands (no git add, git commit, git push, git checkout, etc.)
- Do NOT create branches or try to commit your changes.
- Simply write to the files in your workspace directly.
- Have a real conversation with your developer — don't rush through all bootstrap steps in one message. Start with just the introduction."

echo "Triggering bootstrap for agent: $AGENT_NAME"

if [[ "$DRY_RUN" == true ]]; then
  echo "[DRY RUN] Would create one-time cron job with message:"
  echo "$MESSAGE"
  exit 0
fi

# ------------------------------------------------------------------------------
# Create one-time cron job
# ------------------------------------------------------------------------------
openclaw cron add \
  --name "${AGENT_NAME} Bootstrap Trigger" \
  --agent "$AGENT_NAME" \
  --at "1m" \
  --delete-after-run \
  --session isolated \
  --wake now \
  --message "$MESSAGE" \
  --model "openai-codex/gpt-5.4" \
  --thinking on \
  --timeout-seconds 300 \
  --session-key "agent:${AGENT_NAME}:bootstrap"

echo "Bootstrap trigger created for '$AGENT_NAME'. The agent will reach out to its developer within ~1 minute."
