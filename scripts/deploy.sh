#!/usr/bin/env bash
# deploy.sh — Full config deployment pipeline for openclaw-agents.
# Run manually on the OpenClaw host or via GitHub Actions self-hosted runner.
#
# Usage: scripts/deploy.sh [--pull] [--dry-run] [--force-restart]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RESTART_MARKER="/tmp/openclaw-deploy-needs-restart"

# --------------------------------------------------------------------------- #
# Flags
# --------------------------------------------------------------------------- #
PULL=false
DRY_RUN=false
FORCE_RESTART=false

while [ $# -gt 0 ]; do
  case "$1" in
    --pull)           PULL=true; shift ;;
    --dry-run)        DRY_RUN=true; shift ;;
    --force-restart)  FORCE_RESTART=true; shift ;;
    --help)
      echo "Usage: $(basename "$0") [--pull] [--dry-run] [--force-restart]"
      echo ""
      echo "  --pull           git fetch + reset to origin/main before deploying"
      echo "  --dry-run        print what would happen without making changes"
      echo "  --force-restart  always restart the gateway after deploy"
      exit 0
      ;;
    *) echo "[deploy] ERROR: Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
log()  { echo "[deploy] $*"; }
fail() { echo "[deploy] FATAL: $*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# Pre-flight checks
# --------------------------------------------------------------------------- #
log "=== Pre-flight checks ==="

[ -f "$REPO_ROOT/scripts/sync-agents.sh" ] || fail "Not in openclaw-agents repo root (missing scripts/sync-agents.sh)"

for cmd in openclaw stow; do
  command -v "$cmd" &>/dev/null || fail "$cmd not found on PATH"
done

log "Validating openclaw config..."
if [ "$DRY_RUN" = true ]; then
  log "  (dry-run) would run: openclaw config validate"
else
  if ! openclaw config validate; then
    fail "openclaw config validate failed — aborting"
  fi
  log "  OK"
fi

# --------------------------------------------------------------------------- #
# Pull latest (optional)
# --------------------------------------------------------------------------- #
if [ "$PULL" = true ]; then
  log "=== Pulling latest from origin/main ==="
  if [ "$DRY_RUN" = true ]; then
    log "  (dry-run) would run: git fetch origin && git reset --hard origin/main"
  else
    cd "$REPO_ROOT"
    git fetch origin && git reset --hard origin/main
    log "  OK — now at $(git rev-parse --short HEAD)"

    # Verify we fetched the expected commit (GITHUB_SHA set by Actions)
    if [ -n "${GITHUB_SHA:-}" ]; then
      actual=$(git rev-parse HEAD)
      if [ "$actual" != "$GITHUB_SHA" ]; then
        log "WARN: HEAD ($actual) != GITHUB_SHA ($GITHUB_SHA), retrying in 5s..."
        sleep 5
        git fetch origin && git reset --hard origin/main
        actual=$(git rev-parse HEAD)
        if [ "$actual" != "$GITHUB_SHA" ]; then
          fail "HEAD ($actual) still != GITHUB_SHA ($GITHUB_SHA) after retry — aborting to prevent stale deploy"
        fi
        log "  OK after retry — now at $(git rev-parse --short HEAD)"
      fi
    fi
  fi
fi

# --------------------------------------------------------------------------- #
# Deploy sequence (strictly sequential)
# --------------------------------------------------------------------------- #
log "=== Deploy sequence ==="

log "Syncing agents..."
if [ "$DRY_RUN" = true ]; then
  log "  (dry-run) would run: bash scripts/sync-agents.sh"
else
  bash "$REPO_ROOT/scripts/sync-agents.sh"
fi

log "Running stow (adopt then push)..."
if [ "$DRY_RUN" = true ]; then
  log "  (dry-run) would run: stow --adopt --no-folding -t ~/.openclaw . && stow --no-folding -t ~/.openclaw ."
else
  cd "$REPO_ROOT/.openclaw" \
    && stow --adopt --no-folding -t ~/.openclaw . \
    && stow --no-folding -t ~/.openclaw .
  cd "$REPO_ROOT"
  log "  OK"
fi

log "Applying cron config..."
if [ "$DRY_RUN" = true ]; then
  log "  (dry-run) would run: bash scripts/apply-cron.sh"
else
  bash "$REPO_ROOT/scripts/apply-cron.sh"
fi

# --------------------------------------------------------------------------- #
# Restart guard
# --------------------------------------------------------------------------- #
log "=== Restart guard ==="

needs_restart=false
if [ "$FORCE_RESTART" = true ]; then
  needs_restart=true
  log "Force restart requested"
elif [ -f "$RESTART_MARKER" ]; then
  needs_restart=true
  log "Restart marker found ($RESTART_MARKER)"
else
  log "No restart needed"
fi

if [ "$needs_restart" = true ]; then
  if [ "$DRY_RUN" = true ]; then
    log "  (dry-run) would run: openclaw gateway restart"
  else
    log "Restarting gateway..."
    openclaw gateway restart
    log "  OK"
    rm -f "$RESTART_MARKER"
  fi
fi

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #
log "=== Deploy complete ==="
