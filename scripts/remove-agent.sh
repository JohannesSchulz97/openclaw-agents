#!/usr/bin/env bash
# remove-agent.sh — Remove an OpenClaw agent: delete cron entries, delete files, re-stow
#
# Usage: ./scripts/remove-agent.sh --name <agent-name> [--force] [--dry-run]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="$REPO_ROOT/.openclaw/agents"
CRON_CONFIG="$REPO_ROOT/.openclaw/cron/jobs-config.json"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"

OPENCLAW_UTILS="$REPO_ROOT/scripts/lib/openclaw-utils.sh"
if [ ! -f "$OPENCLAW_UTILS" ]; then
  echo "WARNING: $OPENCLAW_UTILS not found. openclaw.json cleanup will be skipped." >&2
  HAS_OPENCLAW_UTILS=false
else
  source "$OPENCLAW_UTILS"
  HAS_OPENCLAW_UTILS=true
fi
source "$REPO_ROOT/scripts/lib/cron-utils.sh"

NAME=""
FORCE=false
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") --name NAME [--force] [--dry-run] [--help]

Remove an OpenClaw agent and its associated configuration.

Options:
  --name NAME   Agent name to remove (required)
  --force       Skip confirmation prompt
  --dry-run     Show what would be done without acting
  --help        Show this help message
EOF
  exit 0
}

die() {
  echo "ERROR: $1" >&2
  exit 1
}

run_cmd() {
  local description="$1"; shift
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] $description"
  else
    echo "$description"
    "$@"
  fi
}

# --- Parse arguments ---

while [ $# -gt 0 ]; do
  case "$1" in
    --name)   NAME="$2"; shift 2 ;;
    --force)  FORCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help)   usage ;;
    *)        die "Unknown argument: $1" ;;
  esac
done

[ -z "$NAME" ] && die "Missing required argument: --name"

# --- Validate ---

AGENT_DIR="$AGENTS_DIR/$NAME"
[ -d "$AGENT_DIR" ] || die "Agent directory not found: $AGENT_DIR"
command -v jq &>/dev/null || die "jq is required but not installed"
command -v stow &>/dev/null || die "stow is required but not installed"

# --- Confirm ---

if [ "$FORCE" = false ] && [ "$DRY_RUN" = false ]; then
  printf "Remove agent '%s'? This will delete all agent files and cron entries. [y/N] " "$NAME"
  read -r REPLY
  [ "$REPLY" = "y" ] || [ "$REPLY" = "Y" ] || { echo "Aborted."; exit 0; }
fi

echo ""
echo "Removing agent: $NAME"
echo "---"

# --- Step 1: Remove cron entries matching this agent ---

CRON_REMOVED=0
if [ -f "$CRON_CONFIG" ]; then
  CRON_REMOVED=$(jq --arg agent "$NAME" '[.jobs[] | select(.agentId == $agent)] | length' "$CRON_CONFIG")
  if [ "$CRON_REMOVED" -gt 0 ]; then
    if [ "$DRY_RUN" = true ]; then
      echo "[DRY RUN] Remove $CRON_REMOVED cron job(s) for agent '$NAME' from $CRON_CONFIG"
      echo "[DRY RUN] Apply cron changes to live (remove phase will clean up gateway)"
    else
      echo "Remove $CRON_REMOVED cron job(s) for agent '$NAME' from $CRON_CONFIG"
      remove_cron_job "$CRON_CONFIG" "$NAME"
      echo "Apply cron changes to live (remove phase will clean up gateway)"
      if ! "$REPO_ROOT/scripts/apply-cron.sh" 2>&1; then
        echo "Warning: Failed to apply cron config to live system."
        echo "  Run 'scripts/apply-cron.sh' manually after fixing the issue."
      fi
    fi
  else
    echo "No cron jobs found for agent '$NAME'"
  fi
else
  echo "No cron config found at $CRON_CONFIG (skipping)"
  CRON_REMOVED=0
fi

# --- Step 2: Remove agent directories (repo and live) ---

run_cmd "Delete repo agent directory: $AGENT_DIR" \
  rm -rf "$AGENT_DIR"

LIVE_AGENT_DIR="$HOME/.openclaw/agents/$NAME"
run_cmd "Delete live agent directory: $LIVE_AGENT_DIR" \
  rm -rf "$LIVE_AGENT_DIR"

# --- Step 3: Re-stow remaining agents ---

run_cmd "Re-stow: restoring symlinks for remaining agents" \
  bash -c "cd '$REPO_ROOT/.openclaw' && stow --no-folding -t ~/.openclaw ."

# --- Step 4: Remove agent from openclaw.json ---

if [ -f "$OPENCLAW_CONFIG" ]; then
  if [ "$HAS_OPENCLAW_UTILS" = false ]; then
    echo "WARNING: Skipping openclaw.json cleanup (openclaw-utils.sh not available)"
  elif [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Remove agent entry and binding for '$NAME' from $OPENCLAW_CONFIG"
  else
    echo "Remove agent entry and binding for '$NAME' from $OPENCLAW_CONFIG"
    remove_agent_entry "$OPENCLAW_CONFIG" "$NAME"
    remove_binding "$OPENCLAW_CONFIG" "$NAME"
  fi
else
  echo "WARNING: $OPENCLAW_CONFIG not found (skipping openclaw.json cleanup)"
fi

# --- Step 5: Remove agent section from CLAUDE.md ---

if [ -f "$CLAUDE_MD" ]; then
  # Match "## Agent: <Display Name>" where agentId matches the directory name.
  # The section extends from that heading to the next ## heading or EOF.
  if grep -q "^## Agent:.*" "$CLAUDE_MD" 2>/dev/null; then
    # Build a pattern that matches agent name in the heading (e.g., "## Agent: dev1" for agent "dev1")
    DISPLAY_NAME="$(echo "$NAME" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1')"
    if grep -qi "^## Agent: $DISPLAY_NAME" "$CLAUDE_MD" || grep -qi "^## Agent: $NAME" "$CLAUDE_MD"; then
      if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Remove agent section from $CLAUDE_MD"
      else
        echo "Remove agent section from $CLAUDE_MD"
        # Delete from "## Agent: Name" to the line before the next "## " heading (or EOF)
        awk -v display="## Agent: $DISPLAY_NAME" -v raw="## Agent: $NAME" '
          BEGIN { skip=0 }
          { low=tolower($0) }
          low == tolower(display) || low == tolower(raw) { skip=1; next }
          /^## / { skip=0 }
          !skip
        ' "$CLAUDE_MD" > "$CLAUDE_MD.tmp" && mv "$CLAUDE_MD.tmp" "$CLAUDE_MD"
      fi
    else
      echo "No matching '## Agent:' section found in CLAUDE.md (skipping)"
    fi
  fi
fi

# --- Step 6: Summary ---

echo ""
echo "--- Summary ---"
echo "Agent:          $NAME"
if [ "$DRY_RUN" = true ]; then
  echo "Repo directory: $AGENT_DIR (would be removed)"
  echo "Live directory: $HOME/.openclaw/agents/$NAME (would be removed)"
else
  echo "Repo directory: $AGENT_DIR (removed)"
  echo "Live directory: $HOME/.openclaw/agents/$NAME (removed)"
fi
echo "Cron jobs:      $CRON_REMOVED removed"
if [ "$HAS_OPENCLAW_UTILS" = false ]; then
  echo "openclaw.json:  skipped (openclaw-utils.sh not available)"
elif [ "$DRY_RUN" = true ]; then
  echo "openclaw.json:  agent entry and binding would be removed"
else
  echo "openclaw.json:  agent entry and binding removed"
fi
echo "Stow:           re-stowed remaining agents"
if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "(dry run -- no changes were made)"
fi
