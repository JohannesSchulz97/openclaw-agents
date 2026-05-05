#!/usr/bin/env bash
# check-session-sizes.sh — Detect runaway session growth that may indicate retry loops.
# Called by tech-manager hourly monitoring. Outputs JSON with alerts.
#
# Detection: delta-based. Alerts when a session grew more than THRESHOLD_KB since
# the last run. Stable large files (delta = 0) never alert. First-seen sessions
# are recorded but not alerted (need two samples).
#
# State file: ~/.openclaw/state/session-size-history.json

set -euo pipefail

THRESHOLD_KB="${1:-1024}"
OPENCLAW_DIR="$HOME/.openclaw/agents"
STATE_FILE="$HOME/.openclaw/state/session-size-history.json"

mkdir -p "$(dirname "$STATE_FILE")"

python3 - "$THRESHOLD_KB" "$OPENCLAW_DIR" "$STATE_FILE" <<'PYEOF'
import sys, json, os, subprocess

threshold_kb = int(sys.argv[1])
agents_dir = sys.argv[2]
state_file = sys.argv[3]

try:
    with open(state_file) as f:
        prior = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    prior = {}

new_state = {}
alerts = []
sessions_checked = 0

if os.path.isdir(agents_dir):
    for agent_name in sorted(os.listdir(agents_dir)):
        sessions_dir = os.path.join(agents_dir, agent_name, 'sessions')
        if not os.path.isdir(sessions_dir):
            continue
        for fname in sorted(os.listdir(sessions_dir)):
            if not fname.endswith('.jsonl'):
                continue
            # Skip lossless-claw trajectory files: append-only audit log, not a retry-loop signal.
            if fname.endswith('.trajectory.jsonl'):
                continue
            fpath = os.path.join(sessions_dir, fname)
            sessions_checked += 1
            session_id = fname[:-6]  # strip .jsonl

            try:
                cur_bytes = os.path.getsize(fpath)
            except OSError:
                continue

            new_state[session_id] = cur_bytes

            prev = prior.get(session_id)
            if prev is None:
                continue  # first seen, need two samples

            delta_kb = (cur_bytes - prev) // 1024
            if delta_kb < 0:
                continue  # file shrank (rotation/truncation), not a loop

            if delta_kb >= threshold_kb:
                try:
                    wc = subprocess.run(['wc', '-l', fpath], capture_output=True, text=True, timeout=5)
                    line_count = int(wc.stdout.strip().split()[0])
                except Exception:
                    line_count = 0
                alerts.append({
                    'agent': agent_name,
                    'session_id': session_id,
                    'delta_kb': delta_kb,
                    'size_kb': cur_bytes // 1024,
                    'lines': line_count,
                    'file': fpath
                })

# Persist updated state atomically (only currently existing sessions)
tmp = state_file + '.tmp'
with open(tmp, 'w') as f:
    json.dump(new_state, f)
os.replace(tmp, state_file)

print(json.dumps({
    'sessions_checked': sessions_checked,
    'alerts': len(alerts),
    'threshold_kb': threshold_kb,
    'growing_sessions': alerts
}, indent=2))
PYEOF
