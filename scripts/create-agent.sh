#!/usr/bin/env bash
# create-agent.sh — Create a new OpenClaw agent with type-based config
#
# Usage: ./scripts/create-agent.sh --name NAME --slack-id ID [OPTIONS]
#
# Creates agent directory structure, copies type files via sync-agents.sh,
# adds cron job, runs stow, registers in openclaw.json, and updates CLAUDE.md.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# ------------------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------------------
NAME=""
SLACK_ID=""
TYPE="dev-pa"
MODEL="glm-5"
DISPLAY_NAME=""
DRY_RUN=false

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
  cat <<'EOF'
Usage: scripts/create-agent.sh --name NAME --slack-id ID [OPTIONS]

Required:
  --name NAME          Agent name, kebab-case (e.g., "dev1", "<your-org>")
  --slack-id ID        Slack user ID (e.g., "<slack-id>")

Optional:
  --type TYPE          Agent type under types/ (default: dev-pa)
  --model MODEL        Model for cron job (default: glm-5)
  --display-name NAME  Human-readable name (default: title-cased agent name)
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
    --name)        NAME="$2"; shift 2 ;;
    --slack-id)    SLACK_ID="$2"; shift 2 ;;
    --type)        TYPE="$2"; shift 2 ;;
    --model)       MODEL="$2"; shift 2 ;;
    --display-name) DISPLAY_NAME="$2"; shift 2 ;;
    --dry-run)     DRY_RUN=true; shift ;;
    --help)        usage 0 ;;
    *)             echo "ERROR: Unknown argument: $1" >&2; usage 1 ;;
  esac
done

# ------------------------------------------------------------------------------
# Title-case helper: "<your-org>" -> "<your-org>"
# ------------------------------------------------------------------------------
to_title_case() {
  echo "$1" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
}

# Derive display name if not provided
if [ -z "$DISPLAY_NAME" ]; then
  DISPLAY_NAME="$(to_title_case "$NAME")"
fi

# ------------------------------------------------------------------------------
# Action helpers (respect --dry-run)
# ------------------------------------------------------------------------------
run_cmd() {
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] $*"
  else
    "$@"
  fi
}

log_action() {
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] $1"
  else
    echo "$1"
  fi
}

# ------------------------------------------------------------------------------
# Step 1: Validate
# ------------------------------------------------------------------------------
ERRORS=()

if [ -z "$NAME" ]; then
  ERRORS+=("--name is required")
elif ! echo "$NAME" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?$'; then
  ERRORS+=("--name must be kebab-case (lowercase letters, numbers, hyphens, no leading/trailing hyphen)")
fi

if [ -z "$SLACK_ID" ]; then
  ERRORS+=("--slack-id is required")
elif ! echo "$SLACK_ID" | grep -qE '^U[A-Z0-9]+$'; then
  ERRORS+=("--slack-id must match pattern U[A-Z0-9]+ (e.g., <slack-id>)")
fi

if [ ! -d "$REPO_ROOT/types/$TYPE" ]; then
  ERRORS+=("Type directory not found: types/$TYPE/")
fi

AGENT_DIR="$REPO_ROOT/.openclaw/agents/$NAME"
if [ -d "$AGENT_DIR" ]; then
  ERRORS+=("Agent already exists: .openclaw/agents/$NAME/")
fi

for tool in jq stow; do
  if ! command -v "$tool" &>/dev/null; then
    ERRORS+=("$tool is required but not installed")
  fi
done

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo "ERROR: Validation failed:" >&2
  for err in "${ERRORS[@]}"; do
    echo "  - $err" >&2
  done
  echo "" >&2
  echo "Run with --help for usage." >&2
  exit 1
fi

TYPE_DIR="$REPO_ROOT/types/$TYPE"
CRON_CONFIG="$REPO_ROOT/.openclaw/cron/jobs-config.json"

echo "Creating agent: $NAME ($DISPLAY_NAME)"
echo "  Type:     $TYPE"
echo "  Slack ID: $SLACK_ID"
echo "  Model:    $MODEL"
echo ""

# ------------------------------------------------------------------------------
# Step 2: Create agent directory + copy per-agent templates
# ------------------------------------------------------------------------------
log_action "Creating directory: .openclaw/agents/$NAME/memory/"
run_cmd mkdir -p "$AGENT_DIR/memory"

# Write agent type marker
log_action "Writing .agent-type file ($TYPE)"
if [ "$DRY_RUN" = false ]; then
  printf '%s\n' "$TYPE" > "$AGENT_DIR/.agent-type"
else
  echo "[DRY RUN] Write '$TYPE' to .openclaw/agents/$NAME/.agent-type"
fi

# Copy per-agent files from templates
log_action "Copying IDENTITY.md from template"
run_cmd cp "$TYPE_DIR/IDENTITY.md.template" "$AGENT_DIR/IDENTITY.md"

# Substitute placeholders in IDENTITY.md
log_action "Substituting placeholders in IDENTITY.md"
if [ "$DRY_RUN" = false ]; then
  sed -i '' "s/<slack-user-id>/$SLACK_ID/g" "$AGENT_DIR/IDENTITY.md"
  sed -i '' "s/^\(- \*\*Name:\*\*\) *$/\1 $DISPLAY_NAME/" "$AGENT_DIR/IDENTITY.md"
fi

log_action "Copying USER.md from template"
run_cmd cp "$TYPE_DIR/USER.md.template" "$AGENT_DIR/USER.md"

# Note: poll-state.json and checkin-guard.sh are no longer used. Check-in cron jobs rely on AGENTS.md guidance.

# ------------------------------------------------------------------------------
# Step 3: Sync shared files from type
# ------------------------------------------------------------------------------
log_action "Syncing shared files from types/$TYPE/ into agent directory"
if [ "$DRY_RUN" = true ]; then
  "$REPO_ROOT/scripts/sync-agents.sh" --dry-run
else
  "$REPO_ROOT/scripts/sync-agents.sh"
fi

# ------------------------------------------------------------------------------
# Step 4: Create bootstrap-state.json with auto-detected fields
# ------------------------------------------------------------------------------
BOOTSTRAP_STATE="$AGENT_DIR/bootstrap-state.json"
BOOTSTRAP_TEMPLATE="$REPO_ROOT/types/$TYPE/bootstrap-state.json.template"

if [ -f "$BOOTSTRAP_TEMPLATE" ]; then
  log_action "Creating bootstrap-state.json with auto-detected fields"
  if [ "$DRY_RUN" = false ]; then
    # Copy template and pre-fill slack_id
    jq --arg sid "$SLACK_ID" \
      '.fields.slack_id.completed = true | .fields.slack_id.auto_detected = true | .fields.slack_id.value = $sid' \
      "$BOOTSTRAP_TEMPLATE" > "$BOOTSTRAP_STATE"

    # Try to auto-detect GitHub username(s) from CLAUDE.md
    GITHUB_USERS=$(grep -A5 "^## Agent: $DISPLAY_NAME" "$REPO_ROOT/CLAUDE.md" 2>/dev/null \
      | sed -n 's/^- GitHub: \(.*\)/\1/p' | head -1 || true)
    if [ -n "$GITHUB_USERS" ]; then
      tmp=$(mktemp)
      jq --arg g "$GITHUB_USERS" \
        '.fields.github_usernames.completed = true | .fields.github_usernames.auto_detected = true | .fields.github_usernames.value = $g' \
        "$BOOTSTRAP_STATE" > "$tmp" && mv "$tmp" "$BOOTSTRAP_STATE"
      echo "  Auto-detected GitHub username(s): $GITHUB_USERS"
    fi
  else
    echo "[DRY RUN] Would create bootstrap-state.json with slack_id=$SLACK_ID"
  fi
fi

# ------------------------------------------------------------------------------
# Step 5: Add default CET cron jobs (replaced with personalized schedule after bootstrap)
# ------------------------------------------------------------------------------
log_action "Adding default CET check-in cron jobs for '$NAME'"
if [ "$DRY_RUN" = false ]; then
  source "$REPO_ROOT/scripts/lib/cron-utils.sh"
  add_cron_jobs "$CRON_CONFIG" "$NAME" "$DISPLAY_NAME" "$MODEL" \
    9 17 "Europe/Berlin" "false" "$SLACK_ID"
  echo "  Default schedule: 09:00/13:00/16:30 CET (will be personalized after bootstrap)"
else
  echo "[DRY RUN] Would add default CET cron jobs for '$NAME'"
fi

# ------------------------------------------------------------------------------
# Step 6: Run stow
# ------------------------------------------------------------------------------
log_action "Running stow to create symlinks in ~/.openclaw/"
if [ "$DRY_RUN" = false ]; then
  (cd "$REPO_ROOT/.openclaw" && stow --no-folding -t ~/.openclaw .)
fi

# ------------------------------------------------------------------------------
# Step 7: Register agent in openclaw.json
# ------------------------------------------------------------------------------
OPENCLAW_UTILS="$REPO_ROOT/scripts/lib/openclaw-utils.sh"
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"

if [ ! -f "$OPENCLAW_CONFIG" ]; then
  echo "WARNING: $OPENCLAW_CONFIG not found (openclaw may not be installed). Skipping openclaw.json registration."
elif [ ! -f "$OPENCLAW_UTILS" ]; then
  echo "WARNING: $OPENCLAW_UTILS not found. Skipping openclaw.json registration."
else
  # shellcheck source=lib/openclaw-utils.sh
  source "$OPENCLAW_UTILS"
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would add agent entry for '$NAME' in $OPENCLAW_CONFIG"
    echo "[DRY RUN] Would add Slack binding for '$NAME' (slack-id: $SLACK_ID) in $OPENCLAW_CONFIG"
    echo "[DRY RUN] Would add Slack ID '$SLACK_ID' to allowFrom in $OPENCLAW_CONFIG"
  else
    log_action "Registering agent '$NAME' in openclaw.json"
    add_agent_entry "$OPENCLAW_CONFIG" "$NAME" "$REPO_ROOT"
    log_action "Adding Slack binding for '$NAME' in openclaw.json"
    add_binding "$OPENCLAW_CONFIG" "$NAME" "$SLACK_ID"
    log_action "Adding Slack ID '$SLACK_ID' to DM allowlist in openclaw.json"
    add_to_allowlist "$OPENCLAW_CONFIG" "$SLACK_ID"
  fi
fi

# ------------------------------------------------------------------------------
# Step 8: Update CLAUDE.md
# ------------------------------------------------------------------------------
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"

log_action "Appending agent info to CLAUDE.md"
if [ "$DRY_RUN" = false ]; then
  INSERT_BLOCK="
## Agent: $DISPLAY_NAME

- Slack ID: $SLACK_ID
- Heartbeat: every 10 minutes | Check-ins: morning/midday/evening (per work schedule, configured during bootstrap)
- Model: $MODEL
"
  LINE_NUM=$(grep -n "^## Useful Commands" "$CLAUDE_MD" | head -1 | cut -d: -f1)
  if [ -n "$LINE_NUM" ]; then
    # Insert before "## Useful Commands" using head/tail
    _claude_tmp="${CLAUDE_MD}.tmp"
    trap 'rm -f "$_claude_tmp"' EXIT
    {
      head -n "$(( LINE_NUM - 1 ))" "$CLAUDE_MD"
      printf '%s\n' "$INSERT_BLOCK"
      tail -n +"$LINE_NUM" "$CLAUDE_MD"
    } > "$_claude_tmp" && mv "$_claude_tmp" "$CLAUDE_MD"
    trap - EXIT
  else
    # Append at end
    printf '%s\n' "$INSERT_BLOCK" >> "$CLAUDE_MD"
  fi
fi

# ------------------------------------------------------------------------------
# Step 9: Print summary
# ------------------------------------------------------------------------------
echo ""
echo "=========================================="
echo "Agent '$NAME' created successfully!"
echo "=========================================="
echo ""
echo "Files created:"
echo "  .openclaw/agents/$NAME/IDENTITY.md           (from template)"
echo "  .openclaw/agents/$NAME/USER.md               (from template)"
echo "  .openclaw/agents/$NAME/bootstrap-state.json  (auto-detected fields pre-filled)"
echo "  .openclaw/agents/$NAME/memory/              (runtime memory)"
echo ""
echo "Cron jobs:"
echo "  Default CET schedule (09:00/13:00/16:30 Europe/Berlin)"
echo "  Will be personalized after developer provides timezone + work hours."
echo ""
echo "Next steps:"
echo "  1. Restart the gateway: openclaw gateway restart"
echo "  2. Run: bash scripts/apply-cron.sh"
echo "  3. The agent will proactively reach out to the developer via Slack."
