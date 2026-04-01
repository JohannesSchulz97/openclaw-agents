#!/usr/bin/env bash
# sync-agents.sh — Copy shared type files into each agent directory.
# Source of truth: types/<type>/
# Safe to run multiple times (idempotent).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AGENTS_DIR="$REPO_ROOT/.openclaw/agents"
TYPES_DIR="$REPO_ROOT/types"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Shared files to sync (directories handled separately)
SHARED_FILES=(SOUL.md AGENTS.md TOOLS.md HEARTBEAT.md BOOTSTRAP.md poll-config.json DAILY-SUMMARY.template.md)

# Template files — only copied if target does not exist
TEMPLATE_FILES=(IDENTITY.md USER.md)

log() { echo "[sync] $*"; }

sync_file() {
  local src="$1" dst="$2"
  if $DRY_RUN; then
    log "DRY-RUN: would copy $src -> $dst"
  else
    cp -f "$src" "$dst"
    log "copied $src -> $dst"
  fi
}

sync_dir() {
  local src="$1" dst="$2"
  if $DRY_RUN; then
    log "DRY-RUN: would rsync $src/ -> $dst/"
  else
    rsync -a --delete "$src/" "$dst/"
    log "synced $src/ -> $dst/"
  fi
}

for agent_dir in "$AGENTS_DIR"/*/; do
  agent_dir="${agent_dir%/}"
  agent_name="$(basename "$agent_dir")"
  # Read type from .agent-type file, fall back to dev-pa for backward compatibility
  if [[ -f "$agent_dir/.agent-type" ]]; then
    type="$(cat "$agent_dir/.agent-type")"
  else
    log "WARNING: $agent_dir.agent-type not found, falling back to 'dev-pa'"
    type="dev-pa"
  fi
  type_dir="$TYPES_DIR/$type"

  if [[ ! -d "$type_dir" ]]; then
    log "WARNING: type dir $type_dir not found, skipping $agent_name"
    continue
  fi

  log "--- syncing agent: $agent_name (type: $type) ---"

  # 1. Shared files
  for f in "${SHARED_FILES[@]}"; do
    src="$type_dir/$f"
    dst="$agent_dir/$f"
    if [[ -f "$src" ]]; then
      # Remove symlink if present before copying
      if [[ -L "$dst" ]]; then
        if $DRY_RUN; then
          log "DRY-RUN: would remove symlink $dst"
        else
          rm "$dst"
          log "removed symlink $dst"
        fi
      fi
      sync_file "$src" "$dst"
    else
      log "SKIP: $src not found"
    fi
  done

  # 2. Scripts directory
  if [[ -d "$type_dir/scripts" ]]; then
    dst_scripts="$agent_dir/scripts"
    if [[ -L "$dst_scripts" ]]; then
      if $DRY_RUN; then
        log "DRY-RUN: would remove symlink $dst_scripts"
      else
        rm "$dst_scripts"
        log "removed symlink $dst_scripts"
      fi
    fi
    if ! $DRY_RUN; then
      mkdir -p "$dst_scripts"
    fi
    sync_dir "$type_dir/scripts" "$dst_scripts"
  fi

  # 3. Template files — only if target does not already exist
  for t in "${TEMPLATE_FILES[@]}"; do
    template="$type_dir/${t}.template"
    dst="$agent_dir/$t"
    if [[ -f "$template" && ! -f "$dst" ]]; then
      sync_file "$template" "$dst"
      log "(template) created $dst from $template"
    fi
  done
done

log "=== sync complete ==="
