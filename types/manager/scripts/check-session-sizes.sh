#!/usr/bin/env bash
# check-session-sizes.sh — Detect oversized session files that may indicate retry loops
# Called by tech-manager hourly monitoring
# Outputs JSON with alerts for sessions exceeding size threshold

set -euo pipefail

THRESHOLD_KB="${1:-500}"
OPENCLAW_DIR="$HOME/.openclaw/agents"
ALERTS="[]"
TOTAL_CHECKED=0
TOTAL_ALERTS=0

for agent_dir in "$OPENCLAW_DIR"/*/; do
  agent_name=$(basename "$agent_dir")
  sessions_dir="$agent_dir/sessions"

  [ -d "$sessions_dir" ] || continue

  for session_file in "$sessions_dir"/*.jsonl; do
    [ -f "$session_file" ] || continue
    TOTAL_CHECKED=$((TOTAL_CHECKED + 1))

    size_bytes=$(stat -f%z "$session_file" 2>/dev/null || stat -c%s "$session_file" 2>/dev/null || echo 0)
    size_kb=$((size_bytes / 1024))

    if [ "$size_kb" -ge "$THRESHOLD_KB" ]; then
      TOTAL_ALERTS=$((TOTAL_ALERTS + 1))
      line_count=$(wc -l < "$session_file" | tr -d ' ')
      session_id=$(basename "$session_file" .jsonl)

      ALERTS=$(echo "$ALERTS" | python3 -c "
import sys, json
alerts = json.load(sys.stdin)
alerts.append({
    'agent': '$agent_name',
    'session_id': '$session_id',
    'size_kb': $size_kb,
    'lines': $line_count,
    'file': '$session_file'
})
print(json.dumps(alerts))
")
    fi
  done
done

python3 -c "
import json
result = {
    'sessions_checked': $TOTAL_CHECKED,
    'alerts': $TOTAL_ALERTS,
    'threshold_kb': $THRESHOLD_KB,
    'oversized_sessions': $ALERTS
}
print(json.dumps(result, indent=2))
"
