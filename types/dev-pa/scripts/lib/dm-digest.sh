#!/usr/bin/env bash
# dm-digest.sh — Extract a compact digest of recent DM messages from the agent's session file.
# Provides conversation context to isolated cron sessions.
#
# Standalone usage (auto-detects agent name from directory):
#   scripts/lib/dm-digest.sh
#
# Sourced usage:
#   source "$SCRIPT_DIR/lib/dm-digest.sh"
#   DIGEST=$(get_dm_digest "$AGENT_NAME")
#
# Returns JSON: {"messages": [...], "message_count": N, "digest_kb": M}
# On any error, returns: {"messages": [], "message_count": 0, "digest_kb": 0, "error": "..."}
#
# Hardcoded limits (see #278 for making these configurable):
#   - Last 20 messages (user + assistant)
#   - 1000 chars per message

get_dm_digest() {
    local agent_name="$1"
    local max_messages=20
    local max_chars=1000
    local sessions_dir="$HOME/.openclaw/agents/$agent_name/sessions"
    local sessions_file="$sessions_dir/sessions.json"

    # ── Guard: python3 required ──────────────────
    if ! command -v python3 &>/dev/null; then
        echo '{"messages":[],"message_count":0,"digest_kb":0,"error":"python3 not found"}'
        return 0
    fi

    # ── Guard: sessions.json must exist ──────────
    if [[ ! -f "$sessions_file" ]]; then
        echo '{"messages":[],"message_count":0,"digest_kb":0,"error":"sessions.json not found"}'
        return 0
    fi

    # ── Find the DM session file ─────────────────
    # sessions.json keys matching "slack:direct:" point to DM sessions
    local session_id
    session_id=$(python3 -c "
import json, sys
try:
    with open('$sessions_file') as f:
        sessions = json.load(f)
    # Find the most recently updated slack:direct session
    best_id, best_ts = None, 0
    for key, meta in sessions.items():
        if 'slack:direct:' in key:
            ts = meta.get('updatedAt', 0)
            if ts > best_ts:
                best_ts = ts
                best_id = meta.get('sessionId', '')
    print(best_id or '')
except Exception:
    print('')
" 2>/dev/null)

    if [[ -z "$session_id" ]]; then
        echo '{"messages":[],"message_count":0,"digest_kb":0,"error":"no DM session found"}'
        return 0
    fi

    local session_file="$sessions_dir/${session_id}.jsonl"
    if [[ ! -f "$session_file" ]]; then
        echo '{"messages":[],"message_count":0,"digest_kb":0,"error":"session file not found"}'
        return 0
    fi

    # ── Extract recent messages ──────────────────
    # Read last 200 lines (generous buffer to find 20 user/assistant messages)
    # and extract the most recent ones via python3
    tail -n 200 "$session_file" 2>/dev/null | python3 -c "
import json, sys

max_messages = $max_messages
max_chars = $max_chars
messages = []

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue

    msg = obj.get('message', {})
    if not isinstance(msg, dict):
        continue

    role = msg.get('role', '')
    if role not in ('user', 'assistant'):
        continue

    # Extract text content
    content = msg.get('content', [])
    text_parts = []
    if isinstance(content, list):
        for c in content:
            if isinstance(c, dict) and c.get('type') == 'text':
                t = c.get('text', '').strip()
                if t:
                    text_parts.append(t)
    elif isinstance(content, str):
        text_parts.append(content.strip())

    if not text_parts:
        continue

    full_text = ' '.join(text_parts)
    if len(full_text) > max_chars:
        full_text = full_text[:max_chars] + '...'

    messages.append({'role': role, 'text': full_text})

# Keep only the last N messages
messages = messages[-max_messages:]

digest = json.dumps(messages, ensure_ascii=False)
digest_kb = round(len(digest.encode('utf-8')) / 1024, 1)

print(json.dumps({
    'messages': messages,
    'message_count': len(messages),
    'digest_kb': digest_kb
}, ensure_ascii=False))
" 2>/dev/null || echo '{"messages":[],"message_count":0,"digest_kb":0,"error":"extraction failed"}'
}

# ── Standalone mode ──────────────────────────
# When executed directly (not sourced), auto-detect agent name and output digest.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    AGENT_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
    AGENT_NAME="$(basename "$AGENT_DIR")"
    get_dm_digest "$AGENT_NAME"
fi
