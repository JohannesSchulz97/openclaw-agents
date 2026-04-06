#!/usr/bin/env bash
# update-openclaw.sh — Update OpenClaw and its plugins with version tracking.
# Run on the OpenClaw host. Default: check-only (show version status).
#
# Usage: scripts/update-openclaw.sh [--apply] [--check-only] [--component NAME] [--skip-restart] [--help]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SLACK_CHANNEL="<channel-id>"
JOHANNES_SLACK_ID="<slack-id>"
UPDATE_MARKER="/tmp/openclaw-update-requested"
BACKUP_DIR="$HOME/.openclaw/backups"

# --------------------------------------------------------------------------- #
# Flags
# --------------------------------------------------------------------------- #
MODE="check-only"
COMPONENT=""
SKIP_RESTART=false

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)        MODE="apply"; shift ;;
    --check-only)   MODE="check-only"; shift ;;
    --component)
      [ $# -ge 2 ] || fail "--component requires a value (openclaw|lossless-claw|qmd)"
      COMPONENT="$2"; shift 2
      ;;
    --skip-restart) SKIP_RESTART=true; shift ;;
    --help)
      echo "Usage: $(basename "$0") [--apply] [--check-only] [--component NAME] [--skip-restart]"
      echo ""
      echo "  --apply              perform updates (default: check-only)"
      echo "  --check-only         show current vs latest versions (default)"
      echo "  --component NAME     update only: openclaw, lossless-claw, or qmd"
      echo "  --skip-restart       skip gateway restart after update"
      echo "  --help               show this help"
      exit 0
      ;;
    *) echo "[update-openclaw] ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
log()  { echo "[update-openclaw] $*"; }
fail() { echo "[update-openclaw] FATAL: $*" >&2; exit 1; }

# Validate --component value
if [ -n "$COMPONENT" ]; then
  case "$COMPONENT" in
    openclaw|lossless-claw|qmd) ;;
    *) fail "Unknown component: $COMPONENT (must be openclaw, lossless-claw, or qmd)" ;;
  esac
fi

# --------------------------------------------------------------------------- #
# Version helpers
# --------------------------------------------------------------------------- #
get_current_openclaw() {
  openclaw --version 2>/dev/null | grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+' || echo "not installed"
}

get_latest_openclaw() {
  npm view openclaw version 2>/dev/null || echo "unknown"
}

get_current_lossless_claw() {
  openclaw plugins inspect lossless-claw 2>/dev/null | grep -E '^Version:' | awk '{print $2}' || echo "not installed"
}

get_latest_lossless_claw() {
  npm view @martian-engineering/lossless-claw version 2>/dev/null || echo "unknown"
}

get_current_qmd() {
  qmd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "not installed"
}

get_latest_qmd() {
  npm view @tobilu/qmd version 2>/dev/null || echo "unknown"
}

version_indicator() {
  local current="$1" latest="$2"
  if [ "$current" = "$latest" ]; then
    echo "✓"
  else
    echo "↑"
  fi
}

# --------------------------------------------------------------------------- #
# Pre-flight checks
# --------------------------------------------------------------------------- #
log "=== Pre-flight checks ==="

for cmd in openclaw npm; do
  command -v "$cmd" &>/dev/null || fail "$cmd not found on PATH"
done

log "  OK"

# --------------------------------------------------------------------------- #
# Gather versions
# --------------------------------------------------------------------------- #
log "=== Gathering versions ==="

cur_openclaw=$(get_current_openclaw)
lat_openclaw=$(get_latest_openclaw)
cur_lcm=$(get_current_lossless_claw)
lat_lcm=$(get_latest_lossless_claw)
cur_qmd=$(get_current_qmd)
lat_qmd=$(get_latest_qmd)

# --------------------------------------------------------------------------- #
# Check-only mode
# --------------------------------------------------------------------------- #
if [ "$MODE" = "check-only" ]; then
  log ""
  log "Component          Current          Latest           Status"
  log "─────────────────  ───────────────  ───────────────  ──────"
  printf "[update-openclaw] %-18s %-16s %-16s %s\n" "openclaw" "$cur_openclaw" "$lat_openclaw" "$(version_indicator "$cur_openclaw" "$lat_openclaw")"
  printf "[update-openclaw] %-18s %-16s %-16s %s\n" "lossless-claw" "$cur_lcm" "$lat_lcm" "$(version_indicator "$cur_lcm" "$lat_lcm")"
  printf "[update-openclaw] %-18s %-16s %-16s %s\n" "qmd" "$cur_qmd" "$lat_qmd" "$(version_indicator "$cur_qmd" "$lat_qmd")"
  log ""
  exit 0
fi

# --------------------------------------------------------------------------- #
# Apply mode
# --------------------------------------------------------------------------- #
log "=== Applying updates ==="

# Step 1: Back up openclaw.json
log "Backing up openclaw.json..."
mkdir -p "$BACKUP_DIR"
epoch=$(date +%s)
if [ -f "$HOME/.openclaw/openclaw.json" ]; then
  cp "$HOME/.openclaw/openclaw.json" "$BACKUP_DIR/openclaw.json.$epoch"
  log "  Backed up to $BACKUP_DIR/openclaw.json.$epoch"
else
  log "  WARN: ~/.openclaw/openclaw.json not found, skipping backup"
fi

# Step 2: Record pre-update versions
pre_openclaw="$cur_openclaw"
pre_lcm="$cur_lcm"
pre_qmd="$cur_qmd"

# Track what was updated for the Slack message
failed_step=""
changes_applied=""

# Step 3-6: Update components
should_update() {
  [ -z "$COMPONENT" ] || [ "$COMPONENT" = "$1" ]
}

if should_update "openclaw"; then
  log "Updating openclaw..."
  if npm i -g openclaw; then
    log "  OK"
    changes_applied="${changes_applied:+$changes_applied, }openclaw"

    # Step 4: openclaw doctor --fix (REQUIRED after openclaw update)
    log "Running openclaw doctor --fix..."
    if openclaw doctor --fix; then
      log "  OK"
    else
      log "  WARN: openclaw doctor --fix returned non-zero (continuing)"
    fi
  else
    failed_step="npm i -g openclaw"
  fi
fi

if [ -z "$failed_step" ] && should_update "lossless-claw"; then
  log "Updating lossless-claw..."
  if openclaw plugins install --force @martian-engineering/lossless-claw; then
    log "  OK"
    changes_applied="${changes_applied:+$changes_applied, }lossless-claw"
  else
    failed_step="openclaw plugins install lossless-claw"
  fi
fi

if [ -z "$failed_step" ] && should_update "qmd"; then
  log "Updating qmd..."
  if npm i -g @tobilu/qmd; then
    log "  OK"
    changes_applied="${changes_applied:+$changes_applied, }qmd"
  else
    failed_step="npm i -g qmd"
  fi
fi

# Step 7: Config validation
if [ -z "$failed_step" ]; then
  log "Validating openclaw config..."
  if ! openclaw config validate; then
    failed_step="config validate"
  else
    log "  OK"
  fi
fi

# Step 9: Post-update versions
post_openclaw=$(get_current_openclaw)
post_lcm=$(get_current_lossless_claw)
post_qmd=$(get_current_qmd)

# Build version change strings
version_change() {
  local name="$1" pre="$2" post="$3"
  if [ "$pre" = "$post" ]; then
    echo "$name $post (unchanged)"
  else
    echo "$name $pre→$post"
  fi
}

oc_change=$(version_change "openclaw" "$pre_openclaw" "$post_openclaw")
lcm_change=$(version_change "lossless-claw" "$pre_lcm" "$post_lcm")
qmd_change=$(version_change "qmd" "$pre_qmd" "$post_qmd")

# Step 7 (failure path): notify and abort
if [ -n "$failed_step" ]; then
  log "FAILED at step: $failed_step"
  msg="OpenClaw update FAILED at step: $failed_step. Changes applied: ${changes_applied:-none}. Gateway NOT restarted. Manual review needed: bash scripts/update-openclaw.sh --check-only\n\ncc <@$JOHANNES_SLACK_ID>"
  openclaw message send --channel slack --target "channel:$SLACK_CHANNEL" -m "$msg" 2>/dev/null || log "WARN: Failed to send Slack notification"
  fail "Update failed at step: $failed_step"
fi

# Step 8: Gateway restart
if [ "$SKIP_RESTART" = true ]; then
  log "Skipping gateway restart (--skip-restart)"
  restart_status="gateway restart skipped"
else
  log "Restarting gateway..."
  if openclaw gateway restart; then
    log "  OK"
    restart_status="gateway restarted"
  else
    log "  WARN: gateway restart failed"
    restart_status="gateway restart FAILED"
  fi
fi

# Step 10: Slack notification (success)
msg="OpenClaw update complete: $oc_change, $lcm_change, $qmd_change. Config validated, $restart_status.\n\ncc <@$JOHANNES_SLACK_ID>"
openclaw message send --channel slack --target "channel:$SLACK_CHANNEL" -m "$msg" 2>/dev/null || log "WARN: Failed to send Slack notification"

# Step 11: Clean up marker
rm -f "$UPDATE_MARKER"

log "=== Update complete ==="
log "  $oc_change"
log "  $lcm_change"
log "  $qmd_change"
