#!/usr/bin/env bash
# cron-guard.sh — Idempotency guard for cron jobs using OpenClaw's native run history.
#
# Checks whether a cron job already successfully ran for its current slot by
# comparing the last ok run's nextRunAtMs against the current time. Works for
# any schedule cadence (hourly, daily, weekly, etc.).
#
# Usage:
#   scripts/lib/cron-guard.sh --session-key SESSION_KEY [--force]
#
# Returns JSON: {"success": true, "operation": "cron-guard", "data": {"result": "PROCEED"|"ALREADY_RAN", "reason": "..."}}
#
# PROCEED     — no ok run covers the current slot; safe to run
# ALREADY_RAN — last ok run's nextRunAtMs is still in the future; slot already covered
#
# --force bypasses the check and always returns PROCEED (for manual re-runs).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/json-response.sh"

SESSION_KEY=""
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --session-key) SESSION_KEY="$2"; shift 2 ;;
        --force) FORCE=true; shift ;;
        *) shift ;;
    esac
done

if [[ -z "$SESSION_KEY" ]]; then
    json_error "cron-guard" "MISSING_ARG" "--session-key is required"
    exit 1
fi

if ! command -v python3 &>/dev/null; then
    json_error "cron-guard" "MISSING_DEP" "python3 is required"
    exit 1
fi

python3 - "$SESSION_KEY" "$FORCE" <<'PY'
import json, sys, time
from pathlib import Path

session_key = sys.argv[1]
force = sys.argv[2] == "true"
base = Path.home() / '.openclaw' / 'cron'
now_ms = int(time.time() * 1000)

def out(result, reason):
    print(json.dumps({
        "success": True,
        "operation": "cron-guard",
        "data": {"result": result, "reason": reason, "session_key": session_key}
    }))

if force:
    out("PROCEED", "force flag set")
    sys.exit(0)

# Resolve sessionKey → jobId
jobs_file = base / 'jobs.json'
if not jobs_file.exists():
    out("PROCEED", "jobs.json not found")
    sys.exit(0)

try:
    jobs = json.loads(jobs_file.read_text()).get('jobs', [])
except Exception as e:
    out("PROCEED", f"failed to read jobs.json: {e}")
    sys.exit(0)

matches = [j for j in jobs if j.get('sessionKey') == session_key]
if not matches:
    out("PROCEED", f"no job found for sessionKey: {session_key}")
    sys.exit(0)

matches.sort(
    key=lambda j: (
        bool(j.get('enabled')),
        j.get('updatedAtMs') or 0,
        j.get('createdAtMs') or 0,
    ),
    reverse=True,
)
job = matches[0]

job_id = job.get('id', '')
run_file = base / 'runs' / f"{job_id}.jsonl"

if not run_file.exists():
    out("PROCEED", "no run history found")
    sys.exit(0)

# Find last ok run (scan reversed for efficiency)
last_ok = None
try:
    lines = [l.strip() for l in run_file.read_text().splitlines() if l.strip()]
    for line in reversed(lines):
        try:
            entry = json.loads(line)
            if entry.get('action') == 'finished' and entry.get('status') == 'ok':
                last_ok = entry
                break
        except json.JSONDecodeError:
            continue
except Exception as e:
    out("PROCEED", f"failed to read run history: {e}")
    sys.exit(0)

if last_ok is None:
    out("PROCEED", "no successful run in history")
    sys.exit(0)

next_run_ms = last_ok.get('nextRunAtMs')
if not next_run_ms:
    out("PROCEED", "nextRunAtMs missing from last ok run")
    sys.exit(0)

if next_run_ms > now_ms:
    out("ALREADY_RAN", f"slot covered (nextRunAtMs={next_run_ms}, now={now_ms})")
    sys.exit(0)

out("PROCEED", f"slot due (nextRunAtMs={next_run_ms}, now={now_ms})")
PY
