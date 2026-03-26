#!/usr/bin/env bash
# apply-cron.sh — Declarative sync: reconcile gateway cron jobs with jobs-config.json
#
# Usage: ./scripts/apply-cron.sh [--dry-run] [--no-delete]
#
# Three-phase reconciliation:
#   1. ADD    — config entries whose agentId has no gateway match
#   2. EDIT   — config entries whose agentId exists in gateway (update in place)
#   3. REMOVE — gateway jobs whose agentId is NOT in config (orphans)
#
# Fields NOT settable via `openclaw cron edit`:
#   - delivery.mode (no CLI flag; use openclaw cron edit <id> --no-deliver to disable)
#   - payload.kind (implicitly set by --message for agentTurn)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE="$REPO_ROOT/.openclaw/cron/jobs-config.json"
LOCKFILE="/tmp/apply-cron.lock"

# --------------------------------------------------------------------------- #
# Flags
# --------------------------------------------------------------------------- #
DRY_RUN=false
NO_DELETE=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=true; shift ;;
    --no-delete)  NO_DELETE=true; shift ;;
    --help)
      echo "Usage: $(basename "$0") [--dry-run] [--no-delete]"
      echo ""
      echo "  --dry-run     Preview all add/edit/remove operations without executing"
      echo "  --no-delete   Skip the removal phase (backward-compatible mode)"
      exit 0
      ;;
    *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
# Dependency checks
# --------------------------------------------------------------------------- #
if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: Config file not found: $CONFIG_FILE" >&2
  exit 1
fi

for cmd in jq openclaw; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: $cmd is required but not installed" >&2
    exit 1
  fi
done

# --------------------------------------------------------------------------- #
# Locking — prevent concurrent runs
# Uses flock (Linux) with fd-based lock, or mkdir-based fallback (macOS).
# --------------------------------------------------------------------------- #
LOCK_ACQUIRED=false
LOCKDIR="$LOCKFILE.d"

cleanup_lock() {
  if [ "$LOCK_ACQUIRED" = true ]; then
    rm -f "$LOCKDIR/pid"
    rmdir "$LOCKDIR" 2>/dev/null || true
  fi
}

acquire_mkdir_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo $$ > "$LOCKDIR/pid"
    LOCK_ACQUIRED=true
    trap cleanup_lock EXIT
    return 0
  fi
  return 1
}

if command -v flock &>/dev/null; then
  exec 9>"$LOCKFILE"
  if ! flock -n 9; then
    echo "ERROR: Another instance of apply-cron.sh is already running" >&2
    exit 1
  fi
  # fd 9 released automatically on exit
else
  if ! acquire_mkdir_lock; then
    # Lock exists — check if the owning process is still alive
    LOCK_PID=$(cat "$LOCKDIR/pid" 2>/dev/null || echo "")
    if [ -n "$LOCK_PID" ] && ! kill -0 "$LOCK_PID" 2>/dev/null; then
      echo "Removing stale lock from PID $LOCK_PID"
      rm -f "$LOCKDIR/pid"
      rmdir "$LOCKDIR" 2>/dev/null || true
      # Retry once — if another process grabbed it between rmdir and mkdir, we lose
      if ! acquire_mkdir_lock; then
        echo "ERROR: Another instance of apply-cron.sh is already running" >&2
        exit 1
      fi
    else
      echo "ERROR: Another instance of apply-cron.sh is already running" >&2
      exit 1
    fi
  fi
fi

# --------------------------------------------------------------------------- #
# Build CLI args from a config job entry
# --------------------------------------------------------------------------- #
build_cmd_args() {
  local JOB="$1"
  local MODE="$2"        # "add" or "edit"
  local GATEWAY_ID="$3"  # only used for edit

  local -a CMD

  if [ "$MODE" = "edit" ]; then
    CMD=(openclaw cron edit "$GATEWAY_ID")
  else
    CMD=(openclaw cron add)
  fi

  local NAME AGENT_ID ENABLED EVERY_MS SESSION_TARGET WAKE_MODE
  local MESSAGE MODEL THINKING TIMEOUT_SEC SESSION_KEY DELIVERY_MODE

  NAME=$(echo "$JOB" | jq -r '.name')
  AGENT_ID=$(echo "$JOB" | jq -r '.agentId // empty')
  ENABLED=$(echo "$JOB" | jq -r '.enabled')
  EVERY_MS=$(echo "$JOB" | jq -r '.schedule.everyMs // empty')
  SESSION_TARGET=$(echo "$JOB" | jq -r '.sessionTarget // empty')
  WAKE_MODE=$(echo "$JOB" | jq -r '.wakeMode // empty')
  MESSAGE=$(echo "$JOB" | jq -r '.payload.message // empty')
  MODEL=$(echo "$JOB" | jq -r '.payload.model // empty')
  THINKING=$(echo "$JOB" | jq -r '.payload.thinking // empty')
  TIMEOUT_SEC=$(echo "$JOB" | jq -r '.payload.timeoutSeconds // empty')
  SESSION_KEY=$(echo "$JOB" | jq -r '.sessionKey // empty')
  DELIVERY_MODE=$(echo "$JOB" | jq -r '.delivery.mode // empty')

  CMD+=(--name "$NAME")

  [ -n "$AGENT_ID" ] && CMD+=(--agent "$AGENT_ID")

  if [ "$MODE" = "edit" ]; then
    if [ "$ENABLED" = "true" ]; then CMD+=(--enable); else CMD+=(--disable); fi
  else
    [ "$ENABLED" != "true" ] && CMD+=(--disabled)
  fi

  if [ -n "$EVERY_MS" ]; then
    local EVERY_MIN=$((EVERY_MS / 60000))
    CMD+=(--every "${EVERY_MIN}m")
  fi

  [ -n "$SESSION_TARGET" ] && CMD+=(--session "$SESSION_TARGET")
  [ -n "$WAKE_MODE" ]      && CMD+=(--wake "$WAKE_MODE")
  [ -n "$MESSAGE" ]        && CMD+=(--message "$MESSAGE")
  [ -n "$MODEL" ]          && CMD+=(--model "$MODEL")
  [ -n "$THINKING" ]       && CMD+=(--thinking "$THINKING")
  [ -n "$TIMEOUT_SEC" ]    && CMD+=(--timeout-seconds "$TIMEOUT_SEC")
  [ -n "$SESSION_KEY" ]    && CMD+=(--session-key "$SESSION_KEY")
  [ "$DELIVERY_MODE" = "none" ] && CMD+=(--no-deliver)

  # Output the command array; caller evals it
  printf '%q ' "${CMD[@]}"
}

# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
ERRORS=0

JOB_COUNT=$(jq '.jobs | length' "$CONFIG_FILE")
echo "Reconciling gateway with $JOB_COUNT config job(s) from $CONFIG_FILE"
[ "$DRY_RUN" = true ] && echo "(dry-run mode -- no changes will be made)"
[ "$NO_DELETE" = true ] && echo "(no-delete mode -- orphan gateway jobs will be kept)"
echo ""

# Fetch gateway state once
GATEWAY_JOBS=$(openclaw cron list --json 2>/dev/null || echo '{"jobs":[]}')
GATEWAY_COUNT=$(echo "$GATEWAY_JOBS" | jq '.jobs | length')
echo "Gateway has $GATEWAY_COUNT existing job(s)"
echo ""

# Collect config agentIds for the removal phase
CONFIG_AGENT_IDS=$(jq -r '.jobs[].agentId' "$CONFIG_FILE" | sort -u)

# --------------------------------------------------------------------------- #
# Phase 1: ADD — config entries with no gateway match
# --------------------------------------------------------------------------- #
echo "=== Phase 1: ADD ==="
ADD_COUNT=0

for i in $(seq 0 $((JOB_COUNT - 1))); do
  JOB=$(jq ".jobs[$i]" "$CONFIG_FILE")
  AGENT_ID=$(echo "$JOB" | jq -r '.agentId // empty')
  NAME=$(echo "$JOB" | jq -r '.name')

  [ -z "$AGENT_ID" ] && continue

  GATEWAY_ID=$(echo "$GATEWAY_JOBS" | jq -r --arg aid "$AGENT_ID" \
    '.jobs[] | select(.agentId == $aid) | .id' 2>/dev/null | head -1)

  if [ -z "$GATEWAY_ID" ]; then
    ADD_COUNT=$((ADD_COUNT + 1))
    echo "  ADD: $NAME (agentId=$AGENT_ID)"
    CMD_STR=$(build_cmd_args "$JOB" "add" "")
    if [ "$DRY_RUN" = true ]; then
      echo "    [DRY RUN] $CMD_STR"
    else
      echo "    Running: $CMD_STR"
      if eval "$CMD_STR"; then
        echo "    OK"
      else
        echo "    FAILED" >&2
        ERRORS=$((ERRORS + 1))
      fi
    fi
  fi
done

[ "$ADD_COUNT" -eq 0 ] && echo "  (none)"
echo ""

# --------------------------------------------------------------------------- #
# Phase 2: EDIT — config entries with existing gateway match
# --------------------------------------------------------------------------- #
echo "=== Phase 2: EDIT ==="
EDIT_COUNT=0

for i in $(seq 0 $((JOB_COUNT - 1))); do
  JOB=$(jq ".jobs[$i]" "$CONFIG_FILE")
  AGENT_ID=$(echo "$JOB" | jq -r '.agentId // empty')
  NAME=$(echo "$JOB" | jq -r '.name')

  [ -z "$AGENT_ID" ] && continue

  GATEWAY_ID=$(echo "$GATEWAY_JOBS" | jq -r --arg aid "$AGENT_ID" \
    '.jobs[] | select(.agentId == $aid) | .id' 2>/dev/null | head -1)

  if [ -n "$GATEWAY_ID" ]; then
    EDIT_COUNT=$((EDIT_COUNT + 1))
    echo "  EDIT: $NAME (agentId=$AGENT_ID, gateway=$GATEWAY_ID)"
    CMD_STR=$(build_cmd_args "$JOB" "edit" "$GATEWAY_ID")
    if [ "$DRY_RUN" = true ]; then
      echo "    [DRY RUN] $CMD_STR"
    else
      echo "    Running: $CMD_STR"
      if eval "$CMD_STR"; then
        echo "    OK"
      else
        echo "    FAILED" >&2
        ERRORS=$((ERRORS + 1))
      fi
    fi
  fi
done

[ "$EDIT_COUNT" -eq 0 ] && echo "  (none)"
echo ""

# --------------------------------------------------------------------------- #
# Phase 3: REMOVE — gateway jobs whose agentId is NOT in config
# --------------------------------------------------------------------------- #
echo "=== Phase 3: REMOVE ==="
REMOVE_COUNT=0

if [ "$NO_DELETE" = true ]; then
  echo "  (skipped -- --no-delete flag is set)"
else
  for j in $(seq 0 $((GATEWAY_COUNT - 1))); do
    GW_JOB=$(echo "$GATEWAY_JOBS" | jq ".jobs[$j]")
    GW_AGENT_ID=$(echo "$GW_JOB" | jq -r '.agentId // empty')
    GW_ID=$(echo "$GW_JOB" | jq -r '.id')
    GW_NAME=$(echo "$GW_JOB" | jq -r '.name // "unnamed"')

    [ -z "$GW_AGENT_ID" ] && continue

    if ! echo "$CONFIG_AGENT_IDS" | grep -qx "$GW_AGENT_ID"; then
      REMOVE_COUNT=$((REMOVE_COUNT + 1))
      echo "  REMOVE: $GW_NAME (agentId=$GW_AGENT_ID, gateway=$GW_ID)"
      if [ "$DRY_RUN" = true ]; then
        echo "    [DRY RUN] openclaw cron rm $GW_ID"
      else
        echo "    Running: openclaw cron rm $GW_ID"
        if openclaw cron rm "$GW_ID"; then
          echo "    OK"
        else
          echo "    FAILED" >&2
          ERRORS=$((ERRORS + 1))
        fi
      fi
    fi
  done

  [ "$REMOVE_COUNT" -eq 0 ] && echo "  (none)"
fi

echo ""

# --------------------------------------------------------------------------- #
# Summary
# --------------------------------------------------------------------------- #
TOTAL=$((ADD_COUNT + EDIT_COUNT + REMOVE_COUNT))
echo "--- Summary ---"
echo "  Added:   $ADD_COUNT"
echo "  Edited:  $EDIT_COUNT"
echo "  Removed: $REMOVE_COUNT"
echo "  Errors:  $ERRORS"

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "(dry run -- no changes were made)"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo ""
  echo "WARNING: $ERRORS operation(s) failed" >&2
  exit 1
fi

echo ""
echo "All $TOTAL operation(s) completed successfully."
