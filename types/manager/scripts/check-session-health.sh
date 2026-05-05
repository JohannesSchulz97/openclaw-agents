#!/usr/bin/env bash
# check-session-health.sh — Detect retry loops and oversized sessions
# Called by tech-manager hourly monitoring
# Primary detection: duplicate inbound user messages arriving within a short
# time window (real retry loops fire many messages in seconds/minutes;
# scheduled traffic like heartbeats is spaced far enough apart to not trip it)
# Secondary detection: file size > 2MB (catches edge cases)
# Outputs JSON with categorized alerts

set -euo pipefail

SIZE_THRESHOLD_KB="${1:-25600}"
DUPLICATE_THRESHOLD="${2:-10}"
WINDOW_SECONDS="${3:-300}"
TAIL_LINES=500
OPENCLAW_DIR="$HOME/.openclaw/agents"

# Require python3 for JSON parsing
if ! command -v python3 &>/dev/null; then
  echo '{"error":"python3 not found","sessions_checked":0,"loops_detected":0,"large_sessions":0,"alerts":[]}'
  exit 0
fi

# Collect session file paths and metadata, then hand off to Python for analysis
python3 -c "
import json, os, subprocess, sys
from collections import Counter
from datetime import datetime, timedelta, timezone

agents_dir = '$OPENCLAW_DIR'
size_threshold_kb = $SIZE_THRESHOLD_KB
dup_threshold = $DUPLICATE_THRESHOLD
tail_lines = $TAIL_LINES
window_seconds = $WINDOW_SECONDS

window_start = datetime.now(timezone.utc) - timedelta(seconds=window_seconds)

def parse_ts(ts):
    if not ts or not isinstance(ts, str):
        return None
    try:
        # Python 3.11+ accepts 'Z'; older versions do not
        return datetime.fromisoformat(ts.replace('Z', '+00:00'))
    except (ValueError, TypeError):
        return None

alerts = []
sessions_checked = 0
loops_detected = 0
large_sessions = 0

if not os.path.isdir(agents_dir):
    print(json.dumps({'sessions_checked': 0, 'loops_detected': 0, 'large_sessions': 0, 'alerts': []}))
    sys.exit(0)

for agent_name in sorted(os.listdir(agents_dir)):
    sessions_dir = os.path.join(agents_dir, agent_name, 'sessions')
    if not os.path.isdir(sessions_dir):
        continue
    for fname in os.listdir(sessions_dir):
        if not fname.endswith('.jsonl'):
            continue
        # Skip lossless-claw trajectory files: append-only audit log, not a retry-loop signal.
        if fname.endswith('.trajectory.jsonl'):
            continue
        fpath = os.path.join(sessions_dir, fname)
        sessions_checked += 1
        session_id = fname[:-6]  # strip .jsonl

        # Get file size without reading the whole file
        try:
            size_bytes = os.path.getsize(fpath)
        except OSError:
            continue
        size_kb = size_bytes // 1024

        # Read only the tail of the file (efficient for large files)
        try:
            result = subprocess.run(
                ['tail', '-n', str(tail_lines), fpath],
                capture_output=True, text=True, timeout=5
            )
            tail_text = result.stdout
        except Exception:
            tail_text = ''

        # Extract user messages from the tail, keeping only those whose
        # timestamp falls inside the detection window. Messages with no
        # parseable timestamp are skipped (can't prove they're recent).
        # Fingerprint: whitespace-normalized, first 200 chars. Must match the
        # same normalization in session-watchdog.sh migrate_loop_session.
        user_messages = []
        for line in tail_text.splitlines():
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except json.JSONDecodeError:
                continue
            msg = obj.get('message', {})
            if not isinstance(msg, dict):
                continue
            if msg.get('role') != 'user':
                continue
            ts = parse_ts(obj.get('timestamp'))
            if ts is None or ts < window_start:
                continue
            contents = msg.get('content', [])
            if isinstance(contents, list):
                for c in contents:
                    if isinstance(c, dict) and c.get('type') == 'text':
                        text = c.get('text', '').strip()
                        if text:
                            fp = ' '.join(text.split())[:200]
                            user_messages.append(fp)

        # Count line total from tail (approximate; exact only if needed)
        line_count = tail_text.count('\n')

        # Retry loop: any fingerprint appearing dup_threshold+ times within
        # the time window. A real loop fires many messages in seconds/minutes;
        # scheduled traffic (heartbeat, cron) is spaced far enough to not hit
        # the threshold within the window.
        is_loop = False
        max_dup_count = 0
        dup_preview = ''
        if user_messages:
            counts = Counter(user_messages)
            most_common_msg, max_dup_count = counts.most_common(1)[0]
            if max_dup_count >= dup_threshold:
                is_loop = True
                # Full 200-char fingerprint — consumers (watchdog migration,
                # tech-manager alerts) can truncate for display.
                dup_preview = most_common_msg

        # Check for oversized file
        is_large = size_kb >= size_threshold_kb

        if is_loop:
            loops_detected += 1
            # Get actual line count for flagged sessions
            try:
                wc = subprocess.run(['wc', '-l', fpath], capture_output=True, text=True, timeout=5)
                actual_lines = int(wc.stdout.strip().split()[0])
            except Exception:
                actual_lines = line_count
            alerts.append({
                'agent': agent_name,
                'session_id': session_id,
                'type': 'retry_loop',
                'duplicate_count': max_dup_count,
                'message_preview': dup_preview,
                'size_kb': size_kb,
                'lines': actual_lines
            })
        elif is_large:
            large_sessions += 1
            try:
                wc = subprocess.run(['wc', '-l', fpath], capture_output=True, text=True, timeout=5)
                actual_lines = int(wc.stdout.strip().split()[0])
            except Exception:
                actual_lines = line_count
            alerts.append({
                'agent': agent_name,
                'session_id': session_id,
                'type': 'large_session',
                'duplicate_count': max_dup_count,
                'message_preview': dup_preview if dup_preview else '(no duplicates detected)',
                'size_kb': size_kb,
                'lines': actual_lines
            })

print(json.dumps({
    'sessions_checked': sessions_checked,
    'loops_detected': loops_detected,
    'large_sessions': large_sessions,
    'alerts': alerts
}, indent=2))
"
