#!/usr/bin/env bash
# session-watchdog.sh — Runs every 5 min, detects retry loops, auto-remediates
# Intended to run as a system cron or launchd job (no LLM needed)
#
# Actions on retry_loop detection:
#   1. Rename session .jsonl -> .jsonl.loop-detected-<epoch> (breaks the loop)
#   2. Send Slack alert via openclaw message send
#   3. Log to ~/.openclaw/logs/session-watchdog.log
#
# Usage: bash scripts/session-watchdog.sh
# Exit 0 always (watchdog must never crash the scheduler)
#
# Install: cp scripts/com.openclaw-agents.session-watchdog.plist ~/Library/LaunchAgents/ && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw-agents.session-watchdog.plist

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HEALTH_SCRIPT="$REPO_ROOT/types/manager/scripts/check-session-health.sh"
OPENCLAW_DIR="$HOME/.openclaw"
LOG_DIR="$OPENCLAW_DIR/logs"
LOG_FILE="$LOG_DIR/session-watchdog.log"
ALERT_CHANNEL="<channel-id>"  # #<manager-agent>-feedback

# Ensure log directory exists
mkdir -p "$LOG_DIR"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

# Reads last 50 lines of a session file and identifies the likely root cause
detect_loop_cause() {
  local session_file="$1"
  local tail_content
  tail_content=$(tail -n 50 "$session_file" 2>/dev/null || echo "")

  if echo "$tail_content" | grep -qi "usage limit\|rate.limit\|429\|too many requests"; then
    echo "CAUSE: API rate limit exceeded — model returned 'usage limit' error on every retry"
  elif echo "$tail_content" | grep -qi "unauthorized\|401\|auth\|api.key\|invalid.*key"; then
    echo "CAUSE: Authentication failure — API key rejected or expired"
  elif echo "$tail_content" | grep -qi "context.overflow\|context.*size.*exceeds\|token.*limit"; then
    echo "CAUSE: Context overflow — session exceeded model's context window"
  elif echo "$tail_content" | python3 -c "
import sys, json
empty = 0
total = 0
for line in sys.stdin:
    try:
        obj = json.loads(line.strip())
        msg = obj.get('message', {})
        if msg.get('role') == 'assistant':
            total += 1
            content = msg.get('content', '')
            if isinstance(content, list):
                texts = [c.get('text','') for c in content if isinstance(c, dict)]
                content = ' '.join(texts)
            if not content.strip():
                empty += 1
    except: pass
print('EMPTY' if total > 0 and empty / total > 0.8 else 'OK')
" 2>/dev/null | grep -q "EMPTY"; then
    echo "CAUSE: Model returning empty responses — possible model outage or misconfiguration"
  else
    echo "CAUSE: Unknown — no recognizable error pattern in session tail"
  fi
}

# Verify health script exists
if [[ ! -f "$HEALTH_SCRIPT" ]]; then
  log "ERROR: check-session-health.sh not found at $HEALTH_SCRIPT"
  exit 0
fi

# Verify python3 available
if ! command -v python3 &>/dev/null; then
  log "ERROR: python3 not found"
  exit 0
fi

# Run health check and capture JSON output
health_json=$(bash "$HEALTH_SCRIPT" 2>/dev/null) || {
  log "ERROR: check-session-health.sh failed"
  exit 0
}

# Parse retry_loop alerts from JSON output
# Returns tab-separated: agent\tsession_id\tduplicate_count\tmessage_preview\tsize_kb\tlines
loop_alerts=$(python3 -c "
import json, sys
try:
    data = json.loads(sys.stdin.read())
except Exception:
    sys.exit(0)
alerts = data.get('alerts', [])
for a in alerts:
    if a.get('type') == 'retry_loop':
        print('\t'.join([
            a.get('agent', ''),
            a.get('session_id', ''),
            str(a.get('duplicate_count', 0)),
            a.get('message_preview', '')[:80],
            str(a.get('size_kb', 0)),
            str(a.get('lines', 0))
        ]))
" <<< "$health_json") || exit 0

# No loops detected — exit silently
if [[ -z "$loop_alerts" ]]; then
  exit 0
fi

# Process each retry loop alert
while IFS=$'\t' read -r agent session_id dup_count preview size_kb lines; do
  [[ -z "$agent" || -z "$session_id" ]] && continue

  session_file="$OPENCLAW_DIR/agents/$agent/sessions/${session_id}.jsonl"
  timestamp=$(date +%s)

  # 1. Detect root cause before renaming (reads last 50 lines only)
  loop_cause=""
  if [[ -f "$session_file" ]]; then
    loop_cause=$(detect_loop_cause "$session_file" | sed 's/^CAUSE: //')
  fi

  # 2. Rename session file to break the loop
  if [[ -f "$session_file" ]]; then
    renamed="${session_file}.loop-detected-${timestamp}"
    mv "$session_file" "$renamed"
    log "REMEDIATED: agent=$agent session=$session_id renamed to $(basename "$renamed")"
  else
    log "WARN: session file not found for agent=$agent session=$session_id (may already be resolved)"
    continue
  fi

  # 3. Send Slack alert
  preview_truncated="${preview:0:100}"
  alert_msg="⚠️ Retry loop detected and auto-remediated

Agent: ${agent}
Session: ${session_id}
Duplicates: ${dup_count} repeated messages (${size_kb}KB, ${lines} lines)
Preview: \"${preview_truncated}\"

Action taken: Session file renamed to break the loop. The agent will start a fresh session on next interaction.

Root cause: ${loop_cause:-Unknown}

No immediate action needed — the loop is stopped. If the agent was mid-conversation, the developer may need to re-send their last message.

cc <@<slack-id>>"
  openclaw message send \
    --channel slack \
    --target "channel:${ALERT_CHANNEL}" \
    -m "$alert_msg" \
    2>/dev/null || log "WARN: Failed to send Slack alert for agent=$agent"

  # 4. Log details
  log "ALERT: agent=$agent session=$session_id dups=$dup_count size=${size_kb}KB lines=$lines cause='${loop_cause:-Unknown}' preview='${preview}'"

done <<< "$loop_alerts"

exit 0
