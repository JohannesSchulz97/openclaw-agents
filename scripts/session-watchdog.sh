#!/usr/bin/env bash
# session-watchdog.sh — Runs every 5 min, detects retry loops, auto-remediates
# Intended to run as a system cron or launchd job (no LLM needed)
#
# Actions on retry_loop detection (non-destructive migration, #313):
#   1. Rename active session .jsonl -> .loop-detected-<epoch>.jsonl (backup)
#   2. Copy backup to <new-uuid>.jsonl with the looping user/assistant turns
#      stripped out, preserving all other conversation history
#   3. Update sessions.json so every key that pointed at the old session_id
#      now points at the new UUID (OpenClaw re-reads sessions.json per
#      interaction, so no gateway restart is needed)
#   4. Send Slack alert via openclaw message send with migration summary
#   5. Log to ~/.openclaw/logs/session-watchdog.log
#
# Usage: bash scripts/session-watchdog.sh
# Exit 0 always (watchdog must never crash the scheduler)
#
# Install: cp scripts/com.openclaw-agents.session-watchdog.plist ~/Library/LaunchAgents/ && launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw-agents.session-watchdog.plist

# Launchd runs this with a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin).
# openclaw is installed via Homebrew at /opt/homebrew/bin, so ensure it's on
# PATH before any `openclaw ...` invocation (see issue #318).
export PATH="/opt/homebrew/bin:$PATH"

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

# Migrate a looping session into a new UUID, stripping the looping turns.
#
# Steps:
#   1. Rename active .jsonl -> .loop-detected-<epoch>.jsonl (backup)
#   2. Read backup, drop any user message whose first 200 chars match the
#      loop fingerprint, and drop the immediately-following assistant message
#      (and any tool_use/tool_result lines in between, if present)
#   3. Write remaining lines to <new-uuid>.jsonl in the same sessions dir
#   4. Update sessions.json: every key whose sessionId is the old UUID now
#      points at the new UUID (other metadata preserved). OpenClaw re-reads
#      sessions.json on the next interaction, so no gateway restart needed
#
# On success, echoes: new_uuid<TAB>kept_lines<TAB>stripped_turns
# On failure, echoes nothing and returns non-zero (caller logs & skips).
migrate_loop_session() {
  local agent="$1"
  local session_id="$2"
  local fingerprint="$3"
  local epoch="$4"

  local sessions_dir="$OPENCLAW_DIR/agents/$agent/sessions"
  local sessions_json="$sessions_dir/sessions.json"
  local active_file="$sessions_dir/${session_id}.jsonl"
  local backup_file="$sessions_dir/${session_id}.loop-detected-${epoch}.jsonl"

  [[ -f "$active_file" ]] || return 1

  # Atomic rename — gateway mid-write is safe on same filesystem
  mv "$active_file" "$backup_file" || return 1

  # Filter + write new-uuid.jsonl + update sessions.json in one python invocation
  python3 - "$sessions_dir" "$backup_file" "$sessions_json" "$session_id" "$fingerprint" <<'PY'
import json, os, sys, uuid, tempfile

sessions_dir, backup_file, sessions_json, old_sid, fingerprint = sys.argv[1:6]
new_sid = str(uuid.uuid4())
new_file = os.path.join(sessions_dir, f"{new_sid}.jsonl")

kept, stripped_turns = 0, 0
skip_until_assistant = False

with open(backup_file, 'r') as src, open(new_file, 'w') as dst:
    for line in src:
        raw = line.rstrip('\n')
        if not raw.strip():
            dst.write(line)
            continue
        try:
            obj = json.loads(raw)
        except json.JSONDecodeError:
            # Preserve non-JSON lines as-is; don't lose data we can't parse
            dst.write(line)
            kept += 1
            continue

        msg = obj.get('message') if isinstance(obj.get('message'), dict) else {}
        role = msg.get('role', '') if msg else ''

        if skip_until_assistant:
            # Swallow tool_use / tool_result / anything until we see the
            # assistant "message" line that closes the turn
            if obj.get('type') == 'message' and role == 'assistant':
                skip_until_assistant = False
                stripped_turns += 1
            continue

        # Check if this is a user "message" line that matches the loop
        # fingerprint. Normalization must match check-session-health.sh.
        is_loop_user = False
        if obj.get('type') == 'message' and role == 'user':
            contents = msg.get('content', [])
            if isinstance(contents, list):
                for c in contents:
                    if isinstance(c, dict) and c.get('type') == 'text':
                        text = (c.get('text', '') or '').strip()
                        text_fp = ' '.join(text.split())[:200]
                        if text_fp == fingerprint:
                            is_loop_user = True
                            break

        if is_loop_user:
            skip_until_assistant = True
            continue

        dst.write(line)
        kept += 1

# Update sessions.json: repoint any key with sessionId == old_sid to new_sid
updated_keys = 0
if os.path.isfile(sessions_json):
    try:
        with open(sessions_json, 'r') as f:
            data = json.load(f)
    except Exception:
        data = None
    if isinstance(data, dict):
        for key, meta in data.items():
            if isinstance(meta, dict) and meta.get('sessionId') == old_sid:
                meta['sessionId'] = new_sid
                updated_keys += 1
        if updated_keys > 0:
            # Atomic write via tempfile + rename on same filesystem
            fd, tmp = tempfile.mkstemp(dir=os.path.dirname(sessions_json), prefix='.sessions-', suffix='.json')
            try:
                with os.fdopen(fd, 'w') as f:
                    json.dump(data, f, indent=2)
                os.replace(tmp, sessions_json)
            except Exception:
                try: os.unlink(tmp)
                except Exception: pass
                raise

print(f"{new_sid}\t{kept}\t{stripped_turns}\t{updated_keys}")
PY
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
        # Preview is the full fingerprint (up to 200 chars, whitespace
        # normalized by check-session-health.sh). Carry it through for the
        # migration step; truncate only for Slack display downstream.
        print('\t'.join([
            a.get('agent', ''),
            a.get('session_id', ''),
            str(a.get('duplicate_count', 0)),
            a.get('message_preview', '')[:200],
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

  # 1. Detect root cause before any action (reads last 50 lines only)
  loop_cause=""
  if [[ -f "$session_file" ]]; then
    loop_cause=$(detect_loop_cause "$session_file" | sed 's/^CAUSE: //')
  fi

  if [[ ! -f "$session_file" ]]; then
    log "WARN: session file not found for agent=$agent session=$session_id (may already be resolved)"
    continue
  fi

  # 2. Migrate the session: rename active to backup, write a new-uuid file
  # with the looping turns stripped, and repoint sessions.json. The preview
  # is the fingerprint (first 200 chars of the duplicate user message).
  migration_result=$(migrate_loop_session "$agent" "$session_id" "$preview" "$timestamp" 2>>"$LOG_FILE") || migration_result=""
  if [[ -z "$migration_result" ]]; then
    log "ERROR: migration failed for agent=$agent session=$session_id — backup may or may not have been created"
    action_summary="Migration failed. Session may be in partial state — investigate ~/.openclaw/agents/$agent/sessions/."
    new_uuid=""
    kept_lines=0
    stripped_turns=0
    updated_keys=0
  else
    IFS=$'\t' read -r new_uuid kept_lines stripped_turns updated_keys <<< "$migration_result"
    action_summary="Migrated to new session ${new_uuid} (${kept_lines} lines preserved, ${stripped_turns} looping turns stripped, ${updated_keys} sessions.json keys repointed). Backup at ${session_id}.loop-detected-${timestamp}.jsonl."
    log "MIGRATED: agent=$agent old=$session_id new=$new_uuid kept=$kept_lines stripped=$stripped_turns keys=$updated_keys"
  fi

  # 3. Send Slack alert
  preview_truncated="${preview:0:100}"
  alert_msg="⚠️ Retry loop detected and migrated

Agent: ${agent}
Session: ${session_id}
Duplicates: ${dup_count} repeated messages (${size_kb}KB, ${lines} lines)
Preview: \"${preview_truncated}\"

Action taken: ${action_summary}

Root cause: ${loop_cause:-Unknown}

cc <@<slack-id>>"
  openclaw message send \
    --channel slack \
    --target "channel:${ALERT_CHANNEL}" \
    -m "$alert_msg" \
    2>>"$LOG_FILE" || log "WARN: Failed to send Slack alert for agent=$agent (stderr captured above)"

  # 4. Log details
  log "ALERT: agent=$agent session=$session_id dups=$dup_count size=${size_kb}KB lines=$lines cause='${loop_cause:-Unknown}' preview='${preview}'"

done <<< "$loop_alerts"

# ── GitHub Actions Runner Health Check ──────────────────────────────────────
RUNNER_MARKER="/tmp/openclaw-runner-alert-sent"
RUNNER_COOLDOWN_SECS=3600  # 1 hour

runner_is_loaded() {
  launchctl list 2>/dev/null | grep -q "actions.runner.<your-org>-openclaw-agents"
}

runner_marker_is_stale() {
  # True if marker doesn't exist or is older than cooldown
  [[ ! -f "$RUNNER_MARKER" ]] && return 0
  local marker_age=$(( $(date +%s) - $(stat -f %m "$RUNNER_MARKER" 2>/dev/null || echo 0) ))
  (( marker_age >= RUNNER_COOLDOWN_SECS ))
}

if runner_is_loaded; then
  # Runner is up — send recovery if we previously alerted
  if [[ -f "$RUNNER_MARKER" ]]; then
    recovery_msg="GitHub Actions runner (openclaw-host) is back online. Deploy pipeline restored.

cc <@<slack-id>>"
    openclaw message send \
      --channel slack \
      --target "channel:${ALERT_CHANNEL}" \
      -m "$recovery_msg" \
      2>>"$LOG_FILE" || log "WARN: Failed to send runner recovery Slack alert (stderr captured above)"
    rm -f "$RUNNER_MARKER"
    log "RUNNER: recovered — alert cleared"
  fi
else
  # Runner is down
  log "RUNNER: self-hosted runner not loaded"
  if runner_marker_is_stale; then
    down_msg="GitHub Actions runner (openclaw-host) is not running. Deploy pipeline will not trigger. Restart with: cd ~/actions-runner && ./svc.sh start

cc <@<slack-id>>"
    openclaw message send \
      --channel slack \
      --target "channel:${ALERT_CHANNEL}" \
      -m "$down_msg" \
      2>>"$LOG_FILE" || log "WARN: Failed to send runner-down Slack alert (stderr captured above)"
    touch "$RUNNER_MARKER"
    log "RUNNER: alert sent — next alert suppressed for ${RUNNER_COOLDOWN_SECS}s"
  else
    log "RUNNER: still down — alert suppressed (cooldown active)"
  fi
fi

exit 0
