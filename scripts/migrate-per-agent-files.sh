#!/usr/bin/env bash
# migrate-per-agent-files.sh — Convert per-agent symlinks to real files
# so stow can never overwrite them again.
#
# Safe to run multiple times (idempotent).
set -euo pipefail

OPENCLAW_DIR="${HOME}/.openclaw"
CONVERTED=0
SKIPPED=0
WARNED=0

PER_AGENT_FILES=(IDENTITY.md USER.md .agent-type)

for agent_dir in "$OPENCLAW_DIR"/agents/*/; do
  agent=$(basename "$agent_dir")
  [[ "$agent" == "main" ]] && continue

  # Convert per-agent files from symlinks to real files
  for file in "${PER_AGENT_FILES[@]}"; do
    target="$agent_dir$file"
    if [[ -L "$target" ]]; then
      # Read content through the symlink, then replace with real file
      real_content="$(cat "$target")"
      rm "$target"
      printf '%s' "$real_content" > "$target"
      echo "[migrate] Converted symlink to real file: $agent/$file"
      ((CONVERTED++))
    elif [[ -f "$target" ]]; then
      echo "[skip]    Already real: $agent/$file"
      ((SKIPPED++))
    else
      echo "[WARN]    Missing: $agent/$file"
      ((WARNED++))
    fi
  done

  # Convert memory directory contents from symlinks to real files
  if [[ -d "$agent_dir/memory" ]]; then
    for memfile in "$agent_dir"/memory/*; do
      [[ -e "$memfile" ]] || continue
      if [[ -L "$memfile" ]]; then
        real_content="$(cat "$memfile")"
        rm "$memfile"
        printf '%s' "$real_content" > "$memfile"
        echo "[migrate] Converted symlink to real file: $agent/memory/$(basename "$memfile")"
        ((CONVERTED++))
      fi
    done
  fi
done

echo ""
echo "[migrate] Done. Converted: $CONVERTED, Already real: $SKIPPED, Warnings: $WARNED"
