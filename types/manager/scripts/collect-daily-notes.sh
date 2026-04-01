#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Args ─────────────────────────────────────
DATE=$(date '+%Y-%m-%d')
BASE_DIR="$HOME/.openclaw/agents"
QUIET=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --date)
            DATE="$2"
            shift 2
            ;;
        --base-dir)
            BASE_DIR="$2"
            shift 2
            ;;
        --quiet)
            QUIET=true
            shift
            ;;
        *)
            log "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# ── Helper: title-case a kebab-case name ─────
title_case() {
    echo "$1" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2)}1'
}

# ── Helper: extract display name from IDENTITY.md ──
get_display_name() {
    local agent_dir="$1"
    local agent_name="$2"
    local identity_file="$agent_dir/IDENTITY.md"

    if [[ -f "$identity_file" ]]; then
        local name
        name=$(grep -m1 '\*\*Name\*\*:' "$identity_file" 2>/dev/null \
            | sed 's/.*\*\*Name\*\*:[[:space:]]*//' \
            | sed 's/[[:space:]]*$//' || true)
        if [[ -n "$name" ]]; then
            echo "$name"
            return
        fi
    fi

    title_case "$agent_name"
}

# ── Collect notes ────────────────────────────
FOUND=0

for agent_dir in "$BASE_DIR"/*/; do
    [[ -d "$agent_dir" ]] || continue

    # Only process dev-pa agents
    agent_type_file="$agent_dir/.agent-type"
    [[ -f "$agent_type_file" ]] || continue
    agent_type=$(cat "$agent_type_file" 2>/dev/null | tr -d '[:space:]')
    [[ "$agent_type" == "dev-pa" ]] || continue

    agent_name=$(basename "$agent_dir")
    note_file="$agent_dir/memory/$DATE.md"

    if [[ ! -f "$note_file" ]]; then
        [[ "$QUIET" == "false" ]] && log "No daily note for $agent_name on $DATE"
        continue
    fi

    display_name=$(get_display_name "$agent_dir" "$agent_name")

    # Output section header + note contents
    echo "# $display_name"
    echo ""
    cat "$note_file"
    echo ""

    FOUND=$((FOUND + 1))
    [[ "$QUIET" == "false" ]] && log "Collected note for $agent_name ($DATE)"
done

[[ "$QUIET" == "false" ]] && log "Collected $FOUND daily note(s) for $DATE"
