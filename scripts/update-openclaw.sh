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
OPENCLAW_JSON="$HOME/.openclaw/openclaw.json"
PLIST="$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist"

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
# LCM config preservation helpers
# --------------------------------------------------------------------------- #
# LCM config lives in TWO places and BOTH can be wiped:
#   1. openclaw.json (plugins.entries.lossless-claw.config) — wiped by plugins install --force
#   2. launchd plist env vars (LCM_*) — wiped by openclaw doctor --fix
# The env vars take PRECEDENCE over openclaw.json (LCM resolves env first).
# See issue #256 and docs/research/lcm-config-reset-investigation-2026-04-09.md
#
# Required LCM env vars in plist:
#   LCM_SUMMARY_MODEL, LCM_SUMMARY_PROVIDER, LCM_CONTEXT_THRESHOLD,
#   LCM_FRESH_TAIL_COUNT, LCM_INCREMENTAL_MAX_DEPTH, LCM_IGNORE_SESSION_PATTERNS

LCM_CONFIG_BACKUP="/tmp/lcm-plugin-config-backup.json"
LCM_PLIST_BACKUP="/tmp/lcm-plist-envvars-backup.txt"

save_lcm_config() {
  # Save openclaw.json plugin config
  if [ -f "$OPENCLAW_JSON" ] && command -v python3 &>/dev/null; then
    python3 -c "
import json, sys
with open('$OPENCLAW_JSON') as f:
    cfg = json.load(f)
lcm = cfg.get('plugins', {}).get('entries', {}).get('lossless-claw', {}).get('config', {})
if lcm:
    with open('$LCM_CONFIG_BACKUP', 'w') as f:
        json.dump(lcm, f, indent=2)
    print('[update-openclaw]   Saved LCM plugin config (' + str(len(lcm)) + ' keys)')
else:
    print('[update-openclaw]   WARN: No LCM plugin config found to save')
" 2>&1
  else
    log "  WARN: Cannot save LCM config (missing openclaw.json or python3)"
  fi
}

restore_lcm_config() {
  if [ ! -f "$LCM_CONFIG_BACKUP" ]; then
    log "  WARN: No LCM config backup to restore"
    return
  fi
  if [ ! -f "$OPENCLAW_JSON" ]; then
    log "  WARN: openclaw.json missing, cannot restore LCM config"
    return
  fi
  python3 -c "
import json, sys
with open('$LCM_CONFIG_BACKUP') as f:
    saved_config = json.load(f)
with open('$OPENCLAW_JSON') as f:
    cfg = json.load(f)
# Merge: saved config keys take precedence, but keep any new keys from install
current = cfg.get('plugins', {}).get('entries', {}).get('lossless-claw', {}).get('config', {})
merged = {**current, **saved_config}
cfg.setdefault('plugins', {}).setdefault('entries', {}).setdefault('lossless-claw', {})['config'] = merged
with open('$OPENCLAW_JSON', 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
print('[update-openclaw]   Restored LCM config (' + str(len(saved_config)) + ' keys merged)')
" 2>&1
  rm -f "$LCM_CONFIG_BACKUP"
}

save_lcm_plist_envvars() {
  # Save LCM_* env vars from the launchd plist before doctor --fix overwrites it
  if [ -f "$PLIST" ]; then
    # Extract key-value pairs for LCM_* and NODE_OPTIONS
    python3 -c "
import xml.etree.ElementTree as ET, json, sys
tree = ET.parse('$PLIST')
root = tree.getroot()
d = root.find('.//dict/dict')  # EnvironmentVariables dict
if d is None:
    # Try finding it via key name
    for elem in root.iter():
        if elem.text == 'EnvironmentVariables':
            d = elem.getnext() if hasattr(elem, 'getnext') else None
            break
if d is None:
    print('[update-openclaw]   WARN: No EnvironmentVariables dict found in plist')
    sys.exit(0)
keys = d.findall('key')
strings = d.findall('string')
envvars = {}
for i, key in enumerate(keys):
    if key.text and (key.text.startswith('LCM_') or key.text == 'NODE_OPTIONS'):
        if i < len(strings) and strings[i].text:
            envvars[key.text] = strings[i].text
if envvars:
    with open('$LCM_PLIST_BACKUP', 'w') as f:
        json.dump(envvars, f, indent=2)
    print('[update-openclaw]   Saved ' + str(len(envvars)) + ' plist env vars: ' + ', '.join(sorted(envvars.keys())))
else:
    print('[update-openclaw]   WARN: No LCM_*/NODE_OPTIONS env vars found in plist')
" 2>&1 || {
      # Fallback: grep-based extraction
      log "  Falling back to grep-based plist extraction..."
      local vars_found=0
      > "$LCM_PLIST_BACKUP.raw"
      for varname in LCM_SUMMARY_MODEL LCM_SUMMARY_PROVIDER LCM_CONTEXT_THRESHOLD LCM_FRESH_TAIL_COUNT LCM_INCREMENTAL_MAX_DEPTH LCM_IGNORE_SESSION_PATTERNS NODE_OPTIONS; do
        local val
        val=$(grep -A1 "<key>${varname}</key>" "$PLIST" 2>/dev/null | grep '<string>' | sed 's/.*<string>//;s/<\/string>.*//' || true)
        if [ -n "$val" ]; then
          echo "${varname}=${val}" >> "$LCM_PLIST_BACKUP.raw"
          vars_found=$((vars_found + 1))
        fi
      done
      if [ "$vars_found" -gt 0 ]; then
        log "  Saved $vars_found plist env vars (grep fallback)"
      else
        log "  WARN: No LCM env vars found in plist"
      fi
    }
  else
    log "  WARN: Plist not found at $PLIST"
  fi
}

restore_lcm_plist_envvars() {
  # Re-inject LCM_* and NODE_OPTIONS env vars into plist after doctor --fix
  if [ ! -f "$PLIST" ]; then
    log "  WARN: Plist not found, cannot restore env vars"
    return
  fi

  local restored=0

  # Try JSON backup first
  if [ -f "$LCM_PLIST_BACKUP" ]; then
    python3 -c "
import json
with open('$LCM_PLIST_BACKUP') as f:
    envvars = json.load(f)
print(json.dumps(envvars))
" 2>/dev/null | python3 -c "
import json, sys
envvars = json.load(sys.stdin)
for key, value in sorted(envvars.items()):
    print(f'{key}={value}')
" 2>/dev/null | while IFS='=' read -r key value; do
      if ! grep -q "<key>${key}</key>" "$PLIST" 2>/dev/null; then
        # Insert before the closing </dict> of EnvironmentVariables
        sed -i '' "/<key>LCM_IGNORE_SESSION_PATTERNS<\/key>/,/<\/string>/{
          /<\/string>/a\\
\\    <key>${key}</key>\\
\\    <string>${value}</string>
        }" "$PLIST" 2>/dev/null || true
        restored=$((restored + 1))
      fi
    done
    rm -f "$LCM_PLIST_BACKUP"
  fi

  # Fallback: raw format
  if [ -f "$LCM_PLIST_BACKUP.raw" ]; then
    while IFS='=' read -r key value; do
      if [ -n "$key" ] && ! grep -q "<key>${key}</key>" "$PLIST" 2>/dev/null; then
        # Use the last LCM_ key as anchor for insertion
        local anchor_key
        anchor_key=$(grep '<key>LCM_' "$PLIST" 2>/dev/null | tail -1 | sed 's/.*<key>//;s/<\/key>.*//')
        if [ -n "$anchor_key" ]; then
          sed -i '' "/<key>${anchor_key}<\/key>/,/<\/string>/{
            /<\/string>/a\\
\\    <key>${key}</key>\\
\\    <string>${value}</string>
          }" "$PLIST" 2>/dev/null || true
        fi
        restored=$((restored + 1))
      fi
    done < "$LCM_PLIST_BACKUP.raw"
    rm -f "$LCM_PLIST_BACKUP.raw"
  fi

  # Always verify the critical env vars are present
  local missing=""
  for varname in LCM_SUMMARY_MODEL LCM_SUMMARY_PROVIDER LCM_IGNORE_SESSION_PATTERNS NODE_OPTIONS; do
    if ! grep -q "<key>${varname}</key>" "$PLIST" 2>/dev/null; then
      missing="${missing:+$missing, }$varname"
    fi
  done

  if [ -n "$missing" ]; then
    log "  ERROR: Missing plist env vars after restore: $missing"
    log "  Manual fix needed: edit $PLIST and add the missing env vars"
  else
    log "  Plist env vars verified OK"
  fi
}

verify_lcm_config() {
  # Post-update verification: ensure summaryModel is set in BOTH places
  local issues=""

  # Check openclaw.json
  if [ -f "$OPENCLAW_JSON" ] && command -v python3 &>/dev/null; then
    local json_result
    json_result=$(python3 -c "
import json
with open('$OPENCLAW_JSON') as f:
    cfg = json.load(f)
sm = cfg.get('plugins', {}).get('entries', {}).get('lossless-claw', {}).get('config', {}).get('summaryModel', '')
print('OK' if sm else 'MISSING')
" 2>&1)
    if [ "$json_result" != "OK" ]; then
      issues="${issues:+$issues; }openclaw.json summaryModel missing"
    fi
  fi

  # Check plist env vars
  if [ -f "$PLIST" ]; then
    if ! grep -q '<key>LCM_SUMMARY_MODEL</key>' "$PLIST" 2>/dev/null; then
      issues="${issues:+$issues; }plist LCM_SUMMARY_MODEL missing"
    fi
  fi

  if [ -n "$issues" ]; then
    log "  ERROR: LCM config issues: $issues"
    log "  Check $BACKUP_DIR/openclaw.json.$epoch for pre-update config"
    log "  LCM compaction may not work until this is fixed!"
  else
    log "  LCM config verified OK (both openclaw.json and plist)"
  fi
}

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
if [ -f "$OPENCLAW_JSON" ]; then
  cp "$OPENCLAW_JSON" "$BACKUP_DIR/openclaw.json.$epoch"
  log "  Backed up to $BACKUP_DIR/openclaw.json.$epoch"
else
  log "  WARN: ~/.openclaw/openclaw.json not found, skipping backup"
fi

# Step 1b: Save LCM plist env vars before ANY operation that might trigger doctor --fix
log "Saving LCM plist env vars..."
save_lcm_plist_envvars

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
    # WARNING: This regenerates the launchd plist, wiping all custom env vars!
    # (upstream bug openclaw/openclaw#62342)
    log "Running openclaw doctor --fix..."
    if openclaw doctor --fix; then
      log "  OK"
    else
      log "  WARN: openclaw doctor --fix returned non-zero (continuing)"
    fi

    # Step 4b: Re-inject ALL custom env vars into gateway plist
    # doctor --fix overwrites the plist, losing LCM_* and NODE_OPTIONS.
    # This replaces the old NODE_OPTIONS-only workaround.
    log "Restoring plist env vars after doctor --fix..."
    restore_lcm_plist_envvars

    # Step 4c: Re-apply jiti patches and fix streaming config
    # Workaround for openclaw/openclaw#63080 — npm install overwrites the
    # patched dist files, and doctor --fix converts streaming config to
    # object format. Remove once #63080 is fixed upstream.
    PATCH_SCRIPT="$HOME/.openclaw/patch-openclaw.sh"
    if [ -f "$PATCH_SCRIPT" ]; then
      log "Running patch-openclaw.sh (jiti + streaming config fixes)..."
      if bash "$PATCH_SCRIPT"; then
        log "  OK"
      else
        failed_step="patch-openclaw.sh"
      fi
    else
      log "  WARN: $PATCH_SCRIPT not found, skipping patches"
    fi
  else
    failed_step="npm i -g openclaw"
  fi
fi

if [ -z "$failed_step" ] && should_update "lossless-claw"; then
  log "Updating lossless-claw..."

  # Save LCM plugin config before install (plugins install --force resets it)
  log "  Saving LCM plugin config..."
  save_lcm_config

  if openclaw plugins install --force @martian-engineering/lossless-claw; then
    log "  OK"
    changes_applied="${changes_applied:+$changes_applied, }lossless-claw"

    # Restore LCM plugin config after install
    log "  Restoring LCM plugin config..."
    restore_lcm_config
  else
    # Restore even on failure — the install may have partially run
    restore_lcm_config
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

# Step 7b: Verify LCM config survived the entire update cycle
log "Verifying LCM config..."
verify_lcm_config

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
