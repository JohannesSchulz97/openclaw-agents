#!/usr/bin/env bash
# validate-invariants.sh — Machine-validate architectural invariants.
#
# Usage:
#   bash scripts/validate-invariants.sh                    # all checks
#   bash scripts/validate-invariants.sh --target cron      # cron checks only
#   bash scripts/validate-invariants.sh --target gitignore  # gitignore checks only
#   bash scripts/validate-invariants.sh --format json      # JSON output for hooks
#
# Exit codes: 0 = all pass, 1 = failures found, 2 = script error
#
# See docs/invariants.md for the full invariant catalog.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CRON_CONFIG="$REPO_ROOT/.openclaw/cron/jobs-config.json"
GITIGNORE="$REPO_ROOT/.gitignore"

TARGET="all"
FORMAT="human"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target) TARGET="$2"; shift 2 ;;
    --format) FORMAT="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

# ── Result tracking ──────────────────────────────────────────
PASSED=0
FAILED=0
FAILURES="[]"

pass() {
  PASSED=$((PASSED + 1))
}

fail() {
  local check="$1" message="$2"
  FAILED=$((FAILED + 1))
  FAILURES=$(echo "$FAILURES" | jq --arg c "$check" --arg m "$message" '. + [{check: $c, message: $m, severity: "error"}]')
}

# ── Cron checks ──────────────────────────────────────────────

check_cron_session_key_format() {
  # Invariant 1.1: sessionKey must match agent:<agentId>:cron:<type>
  local bad
  bad=$(jq -r '.jobs[] | . as $job | select($job.sessionKey != null) |
    select(($job.sessionKey | startswith("agent:" + $job.agentId + ":cron:")) | not) |
    $job.name + " (sessionKey: " + $job.sessionKey + ", agentId: " + $job.agentId + ")"' "$CRON_CONFIG")
  if [[ -z "$bad" ]]; then
    pass
  else
    while IFS= read -r line; do
      fail "session_key_format" "sessionKey does not match agent:<agentId>:cron:<type>: $line"
    done <<< "$bad"
  fi
}

check_cron_session_key_unique() {
  # Invariant 1.2: no duplicate sessionKeys
  local dupes
  dupes=$(jq -r '[.jobs[] | .sessionKey] | group_by(.) | map(select(length > 1)) | .[][0]' "$CRON_CONFIG")
  if [[ -z "$dupes" ]]; then
    pass
  else
    while IFS= read -r line; do
      fail "session_key_unique" "Duplicate sessionKey: $line"
    done <<< "$dupes"
  fi
}

check_cron_session_target_format() {
  # Invariant 1.3: sessionTarget format
  local bad
  bad=$(jq -r '.jobs[] |
    select(.sessionTarget | test("^session:slack:(direct|channel):[a-z0-9]+$") | not) |
    .name + " (sessionTarget: " + .sessionTarget + ")"' "$CRON_CONFIG")
  if [[ -z "$bad" ]]; then
    pass
  else
    while IFS= read -r line; do
      fail "session_target_format" "Invalid sessionTarget format: $line"
    done <<< "$bad"
  fi
}

check_cron_session_target_consistency() {
  # Invariant 1.4: all jobs for same agent share same sessionTarget
  local inconsistent
  inconsistent=$(jq -r '
    [.jobs[] | {agentId, sessionTarget}] |
    group_by(.agentId) |
    map(select(map(.sessionTarget) | unique | length > 1)) |
    .[] | .[0].agentId + " has " + (map(.sessionTarget) | unique | join(", "))' "$CRON_CONFIG")
  if [[ -z "$inconsistent" ]]; then
    pass
  else
    while IFS= read -r line; do
      fail "session_target_consistency" "Inconsistent sessionTargets: $line"
    done <<< "$inconsistent"
  fi
}

check_cron_delivery_mode() {
  # Invariant 1.5: delivery.mode must be "none"
  local bad
  bad=$(jq -r '.jobs[] | select(.delivery.mode != "none") |
    .name + " (delivery.mode: " + .delivery.mode + ")"' "$CRON_CONFIG")
  if [[ -z "$bad" ]]; then
    pass
  else
    while IFS= read -r line; do
      fail "delivery_mode" "delivery.mode is not 'none': $line"
    done <<< "$bad"
  fi
}

check_cron_wake_mode() {
  # Invariant 1.6: wakeMode must be "now"
  local bad
  bad=$(jq -r '.jobs[] | select(.wakeMode != "now") |
    .name + " (wakeMode: " + .wakeMode + ")"' "$CRON_CONFIG")
  if [[ -z "$bad" ]]; then
    pass
  else
    while IFS= read -r line; do
      fail "wake_mode" "wakeMode is not 'now': $line"
    done <<< "$bad"
  fi
}

check_cron_payload_kind() {
  # Invariant 1.7: payload.kind must be "agentTurn"
  local bad
  bad=$(jq -r '.jobs[] | select(.payload.kind != "agentTurn") |
    .name + " (payload.kind: " + .payload.kind + ")"' "$CRON_CONFIG")
  if [[ -z "$bad" ]]; then
    pass
  else
    while IFS= read -r line; do
      fail "payload_kind" "payload.kind is not 'agentTurn': $line"
    done <<< "$bad"
  fi
}

check_cron_no_model() {
  # Invariant 1.8: payload.model must be absent or null (inherit from defaults)
  # Exception: jobs with sessionKey in the allowed list may override the model
  # (e.g., weekly update-check uses gemini-pro for higher-quality analysis)
  local allowed_model_overrides='["agent:tech-manager:cron:update-check"]'
  local bad
  bad=$(jq -r --argjson allowed "$allowed_model_overrides" \
    '.jobs[] | select(.payload.model != null) |
    select(.sessionKey as $sk | $allowed | index($sk) | not) |
    .name + " (payload.model: " + (.payload.model // "null") + ")"' "$CRON_CONFIG")
  if [[ -z "$bad" ]]; then
    pass
  else
    while IFS= read -r line; do
      fail "no_model_field" "payload.model is set (should be absent): $line"
    done <<< "$bad"
  fi
}

check_cron_thinking_valid() {
  # Invariant 1.9: thinking must be a valid value
  local bad
  bad=$(jq -r '.jobs[] |
    select(.payload.thinking as $t | ["off","minimal","low","medium","high","xhigh"] | index($t) | not) |
    .name + " (thinking: " + .payload.thinking + ")"' "$CRON_CONFIG")
  if [[ -z "$bad" ]]; then
    pass
  else
    while IFS= read -r line; do
      fail "thinking_valid" "Invalid thinking level: $line"
    done <<< "$bad"
  fi
}

check_cron_timeout_minimum() {
  # Invariant 1.10: timeoutSeconds >= 300
  local bad
  bad=$(jq -r '.jobs[] | select(.payload.timeoutSeconds < 300) |
    .name + " (timeoutSeconds: " + (.payload.timeoutSeconds | tostring) + ")"' "$CRON_CONFIG")
  if [[ -z "$bad" ]]; then
    pass
  else
    while IFS= read -r line; do
      fail "timeout_minimum" "timeoutSeconds below 300: $line"
    done <<< "$bad"
  fi
}

check_cron_summary_timezone() {
  # Invariant 1.11: summary jobs must use Europe/Berlin
  local bad
  bad=$(jq -r '.jobs[] |
    select(.sessionKey | test(":summary$")) |
    select(.schedule.tz != "Europe/Berlin") |
    .name + " (tz: " + (.schedule.tz // "null") + ")"' "$CRON_CONFIG")
  if [[ -z "$bad" ]]; then
    pass
  else
    while IFS= read -r line; do
      fail "summary_timezone" "Summary job not using Europe/Berlin: $line"
    done <<< "$bad"
  fi
}

check_cron_summary_schedule() {
  # Invariant 1.12: summary jobs must be at 0 20 * * * or 0 20 * * 1-5
  local bad
  bad=$(jq -r '.jobs[] |
    select(.sessionKey | test(":summary$")) |
    select(.schedule.cronExpr != "0 20 * * *" and .schedule.cronExpr != "0 20 * * 1-5") |
    .name + " (cronExpr: " + (.schedule.cronExpr // "null") + ")"' "$CRON_CONFIG")
  if [[ -z "$bad" ]]; then
    pass
  else
    while IFS= read -r line; do
      fail "summary_schedule" "Summary job not at 20:00: $line"
    done <<< "$bad"
  fi
}

check_cron_no_duplicate_agent_type() {
  # Invariant 1.13: no duplicate agentId + type suffix
  local dupes
  dupes=$(jq -r '
    [.jobs[] | . as $job | $job.agentId + ":" + ($job.sessionKey | split(":") | last)] |
    group_by(.) | map(select(length > 1)) | .[][0]' "$CRON_CONFIG")
  if [[ -z "$dupes" ]]; then
    pass
  else
    while IFS= read -r line; do
      fail "no_duplicate_agent_type" "Duplicate agent+type: $line"
    done <<< "$dupes"
  fi
}

# ── Gitignore checks ────────────────────────────────────────

check_gitignore_required_patterns() {
  # Check that essential gitignore patterns are present
  local missing=""
  local -a required=(
    ".openclaw/cron/jobs.json"
    ".openclaw/agents/*/SOUL.md"
    ".openclaw/agents/*/AGENTS.md"
    ".openclaw/agents/*/TOOLS.md"
    ".openclaw/agents/*/HEARTBEAT.md"
    ".openclaw/agents/*/BOOTSTRAP.md"
    ".openclaw/agents/*/scripts/"
    ".openclaw/agents/*/memory/"
    ".openclaw/agents/*/reports/"
    ".openclaw/agents/*/.BOOTSTRAP.md.done"
  )

  for pattern in "${required[@]}"; do
    # Check for exact match or a broader pattern that covers it
    if ! grep -qF "$pattern" "$GITIGNORE" 2>/dev/null; then
      # Also check if a glob pattern covers it (e.g., memory/*.md covers memory/*)
      local found=false
      # Simple substring check — the pattern or a parent pattern should appear
      local parent
      parent=$(dirname "$pattern")
      if grep -qF "$parent" "$GITIGNORE" 2>/dev/null; then
        found=true
      fi
      if [[ "$found" == "false" ]]; then
        missing="$missing$pattern\n"
      fi
    fi
  done

  if [[ -z "$missing" ]]; then
    pass
  else
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      fail "gitignore_required" "Missing gitignore pattern: $line"
    done <<< "$(echo -e "$missing")"
  fi
}

# ── Runner ───────────────────────────────────────────────────

run_checks() {
  case "$TARGET" in
    all)
      run_cron_checks
      run_gitignore_checks
      ;;
    cron)
      run_cron_checks
      ;;
    gitignore)
      run_gitignore_checks
      ;;
    *)
      echo "Unknown target: $TARGET" >&2
      exit 2
      ;;
  esac
}

run_cron_checks() {
  if [[ ! -f "$CRON_CONFIG" ]]; then
    fail "cron_config_exists" "Cron config not found: $CRON_CONFIG"
    return
  fi
  check_cron_session_key_format
  check_cron_session_key_unique
  check_cron_session_target_format
  check_cron_session_target_consistency
  check_cron_delivery_mode
  check_cron_wake_mode
  check_cron_payload_kind
  check_cron_no_model
  check_cron_thinking_valid
  check_cron_timeout_minimum
  check_cron_summary_timezone
  check_cron_summary_schedule
  check_cron_no_duplicate_agent_type
}

run_gitignore_checks() {
  if [[ ! -f "$GITIGNORE" ]]; then
    fail "gitignore_exists" ".gitignore not found"
    return
  fi
  check_gitignore_required_patterns
}

# ── Output ───────────────────────────────────────────────────

output_results() {
  if [[ "$FORMAT" == "json" ]]; then
    jq -n \
      --argjson passed "$PASSED" \
      --argjson failed "$FAILED" \
      --argjson failures "$FAILURES" \
      '{passed: $passed, failed: $failed, failures: $failures}'
  else
    if [[ "$FAILED" -eq 0 ]]; then
      echo "All $PASSED checks passed."
    else
      echo "FAILED: $FAILED of $((PASSED + FAILED)) checks failed."
      echo ""
      echo "$FAILURES" | jq -r '.[] | "  ✗ [" + .check + "] " + .message'
    fi
  fi
}

# ── Main ─────────────────────────────────────────────────────

# Dependency check
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not found" >&2
  exit 2
fi

run_checks
output_results

if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
exit 0
