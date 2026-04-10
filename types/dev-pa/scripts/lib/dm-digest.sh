#!/usr/bin/env bash
# dm-digest.sh — Extract a compact digest of recent DM conversation from the agent's session file.
# Produces a clean "Slack chat mirror" — only messages the developer would see in Slack.
#
# Standalone usage (auto-detects agent name from directory):
#   scripts/lib/dm-digest.sh
#
# Sourced usage:
#   source "$SCRIPT_DIR/lib/dm-digest.sh"
#   DIGEST=$(get_dm_digest "$AGENT_NAME")
#
# Returns JSON: {"messages": [...], "message_count": N, "digest_kb": M}
# Each message: {"role": "user"|"assistant", "ts": "ISO timestamp", "text": "..."}
# On any error, returns: {"messages": [], "message_count": 0, "digest_kb": 0, "error": "..."}
#
# Hardcoded limits (see #278 for making these configurable):
#   - Last 20 messages (user + assistant conversation turns)
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
    # sessions.json keys matching "slack:direct:" point to DM sessions.
    # Session files may be named {id}.jsonl or {id}-topic-{ts}.jsonl.
    local session_id
    session_id=$(python3 -c "
import json, sys
try:
    with open('$sessions_file') as f:
        sessions = json.load(f)
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

    # Resolve the actual file — handle both plain and -topic- suffixed filenames
    local session_file=""
    local candidate="$sessions_dir/${session_id}.jsonl"
    if [[ -f "$candidate" ]]; then
        session_file="$candidate"
    else
        # Glob for topic-suffixed files
        local matches=("$sessions_dir/${session_id}"-*.jsonl)
        if [[ -f "${matches[0]}" ]]; then
            session_file="${matches[0]}"
        fi
    fi

    if [[ -z "$session_file" ]]; then
        echo '{"messages":[],"message_count":0,"digest_kb":0,"error":"session file not found"}'
        return 0
    fi

    # ── Extract recent conversation messages ─────
    # Read last 500 lines (generous buffer — most lines are tool calls/results
    # that get skipped, so we need more raw lines to find 20 conversation turns)
    tail -n 500 "$session_file" 2>/dev/null | python3 -c "
import json, sys, re

max_messages = $max_messages
max_chars = $max_chars
messages = []

# Regex to extract actual message text from Slack DM envelope
# Matches: 'Slack DM from <Name>: <actual message>'
SLACK_DM_RE = re.compile(r'Slack DM from [^:]+:\s*(.*)', re.DOTALL)

# Regex to strip Conversation info metadata blocks
CONV_INFO_RE = re.compile(r'\n*Conversation info \(untrusted metadata\):.*', re.DOTALL)

# Regex to split queued messages
QUEUED_RE = re.compile(r'---\s*\nQueued #\d+\n')

def extract_slack_messages(content_str):
    \"\"\"Extract actual user message text from Slack DM envelope(s).
    Returns a list of extracted messages (handles queued multi-message blocks).\"\"\"
    results = []

    # Check if this is a queued messages block
    if content_str.startswith('[Queued messages'):
        parts = QUEUED_RE.split(content_str)
        for part in parts:
            extracted = _extract_single_dm(part)
            if extracted:
                results.append(extracted)
    else:
        extracted = _extract_single_dm(content_str)
        if extracted:
            results.append(extracted)

    return results

def _extract_single_dm(text):
    \"\"\"Extract the actual message from a single Slack DM system envelope.\"\"\"
    # Must contain 'Slack DM from' to be a real DM
    m = SLACK_DM_RE.search(text)
    if not m:
        return None
    msg = m.group(1).strip()
    # Strip Conversation info metadata
    msg = CONV_INFO_RE.sub('', msg).strip()
    return msg if msg else None

def extract_assistant_text(content_list):
    \"\"\"Extract visible text from assistant content array.
    Keeps only type=text blocks, strips prefixes and signatures.\"\"\"
    parts = []
    for c in content_list:
        if not isinstance(c, dict):
            continue
        if c.get('type') != 'text':
            continue
        t = c.get('text', '').strip()
        # Strip [[reply_to_current]] prefix
        if t.startswith('[[reply_to_current]]'):
            t = t[len('[[reply_to_current]]'):].strip()
        if t and t != 'HEARTBEAT_OK':
            parts.append(t)
    return ' '.join(parts) if parts else None

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except json.JSONDecodeError:
        continue

    # Only process message-type lines
    if obj.get('type') != 'message':
        continue

    msg = obj.get('message', {})
    if not isinstance(msg, dict):
        continue

    role = msg.get('role', '')
    ts = obj.get('timestamp', '')
    content = msg.get('content', '')

    if role == 'user':
        # Skip system exec messages
        if isinstance(content, str) and content.startswith('System: Exec completed'):
            continue

        # Handle string content (Slack DM envelope)
        if isinstance(content, str):
            extracted = extract_slack_messages(content)
            for text in extracted:
                if len(text) > max_chars:
                    text = text[:max_chars] + '...'
                messages.append({'role': 'user', 'ts': ts, 'text': text})
            continue

        # Handle array content (e.g. sessions_send injections)
        if isinstance(content, list):
            text_parts = []
            for c in content:
                if isinstance(c, dict) and c.get('type') == 'text':
                    t = c.get('text', '').strip()
                    if t:
                        text_parts.append(t)
            if text_parts:
                full = ' '.join(text_parts)
                if len(full) > max_chars:
                    full = full[:max_chars] + '...'
                messages.append({'role': 'user', 'ts': ts, 'text': full})
            continue

    elif role == 'assistant':
        if isinstance(content, list):
            text = extract_assistant_text(content)
            if text:
                if len(text) > max_chars:
                    text = text[:max_chars] + '...'
                messages.append({'role': 'assistant', 'ts': ts, 'text': text})
        elif isinstance(content, str):
            t = content.strip()
            if t and t != 'HEARTBEAT_OK':
                if len(t) > max_chars:
                    t = t[:max_chars] + '...'
                messages.append({'role': 'assistant', 'ts': ts, 'text': t})

    # Skip role=tool and anything else

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
