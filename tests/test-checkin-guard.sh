#!/usr/bin/env bash
set -euo pipefail

# test-checkin-guard.sh — Test harness for checkin-guard.sh bug fixes
#
# Tests 3 bugs:
#   Bug 1: State consistency validation (responded=true but epoch=0)
#   Bug 2: Renamed awaiting_response to checkin_dispatched
#   Bug 3: Inter-day state hygiene (date change resets stale state)
#
# Strategy:
#   We create a fake agent directory structure that mimics what
#   checkin-guard.sh expects, then run the real script and inspect
#   the resulting poll-state.json.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
GUARD_SCRIPT="$REPO_DIR/types/dev-pa/scripts/checkin-guard.sh"

# ── Test infrastructure ──────────────────────────
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

pass() {
    PASS_COUNT=$((PASS_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    echo "  PASS: $1"
}

fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    TOTAL_COUNT=$((TOTAL_COUNT + 1))
    echo "  FAIL: $1"
    if [[ -n "${2:-}" ]]; then
        echo "        Expected: $2"
    fi
    if [[ -n "${3:-}" ]]; then
        echo "        Actual:   $3"
    fi
}

assert_json_value() {
    local file="$1"
    local key="$2"
    local expected="$3"
    local label="$4"
    local actual
    actual=$(jq -r ".$key" "$file" 2>/dev/null)
    if [[ "$actual" == "$expected" ]]; then
        pass "$label"
    else
        fail "$label" "$expected" "$actual"
    fi
}

assert_json_key_exists() {
    local file="$1"
    local key="$2"
    local label="$3"
    local exists
    exists=$(jq "has(\"$key\")" "$file" 2>/dev/null)
    if [[ "$exists" == "true" ]]; then
        pass "$label"
    else
        fail "$label" "key '$key' to exist" "key not found"
    fi
}

assert_json_key_missing() {
    local file="$1"
    local key="$2"
    local label="$3"
    local exists
    exists=$(jq "has(\"$key\")" "$file" 2>/dev/null)
    if [[ "$exists" == "false" ]]; then
        pass "$label"
    else
        fail "$label" "key '$key' to NOT exist" "key exists"
    fi
}

# ── Setup fake agent directory ───────────────────
# The script derives AGENT_DIR from SCRIPT_DIR (parent of scripts/).
# So we need: <AGENT_DIR>/scripts/checkin-guard.sh
#              <AGENT_DIR>/scripts/lib/json-response.sh
#              <AGENT_DIR>/memory/poll-state.json

setup_test_agent() {
    local test_name="$1"
    TEST_TMPDIR=$(mktemp -d /tmp/checkin-guard-test-XXXXXX)
    AGENT_DIR="$TEST_TMPDIR/test-agent"
    SCRIPTS_DIR="$AGENT_DIR/scripts"
    LIB_DIR="$SCRIPTS_DIR/lib"
    MEMORY_DIR="$AGENT_DIR/memory"
    SESSIONS_DIR="$AGENT_DIR/sessions"
    POLL_STATE="$MEMORY_DIR/poll-state.json"

    mkdir -p "$LIB_DIR" "$MEMORY_DIR" "$SESSIONS_DIR"

    # Copy the real scripts into our fake agent structure
    cp "$GUARD_SCRIPT" "$SCRIPTS_DIR/checkin-guard.sh"
    cp "$REPO_DIR/types/dev-pa/scripts/lib/json-response.sh" "$LIB_DIR/json-response.sh"
    chmod +x "$SCRIPTS_DIR/checkin-guard.sh"
}

teardown_test_agent() {
    if [[ -n "${TEST_TMPDIR:-}" && -d "${TEST_TMPDIR:-}" ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

run_guard() {
    local checkin_type="$1"
    # Run the guard, suppress stdout (JSON output) and stderr
    "$SCRIPTS_DIR/checkin-guard.sh" "$checkin_type" --quiet >/dev/null 2>/dev/null || true
}

# ══════════════════════════════════════════════════
echo "============================================"
echo "checkin-guard.sh Bug Fix Tests"
echo "============================================"
echo ""

# ── Bug 1: State consistency validation ──────────
echo "--- Bug 1: State consistency validation ---"
echo "  (responded=true but epoch=0 should be reset to responded=false)"
echo ""

# Test 1a: morning_responded=true, last_morning_epoch=0
echo "  Test 1a: morning_responded inconsistency"
setup_test_agent "bug1-morning"
cat > "$POLL_STATE" <<'EOF'
{
  "morning_responded": true,
  "midday_responded": false,
  "evening_responded": false,
  "last_morning_epoch": 0,
  "last_midday_epoch": 0,
  "last_evening_epoch": 0,
  "missed_checkins": 0,
  "awaiting_response": false
}
EOF

# Create empty sessions file so script has no human activity
echo '{}' > "$SESSIONS_DIR/sessions.json"

# Run a midday check-in (not morning, so we don't overwrite morning state)
run_guard "midday"

# After the guard runs, morning_responded should be false because
# last_morning_epoch is 0 (inconsistent state should be corrected)
MORNING_RESPONDED=$(jq -r '.morning_responded' "$POLL_STATE")
if [[ "$MORNING_RESPONDED" == "false" ]]; then
    pass "morning_responded reset to false when last_morning_epoch=0"
else
    fail "morning_responded should be false when last_morning_epoch=0 (BUG EXISTS: not reset)" "false" "$MORNING_RESPONDED"
fi
teardown_test_agent

# Test 1b: midday_responded=true, last_midday_epoch=0
echo "  Test 1b: midday_responded inconsistency"
setup_test_agent "bug1-midday"
cat > "$POLL_STATE" <<'EOF'
{
  "morning_responded": false,
  "midday_responded": true,
  "evening_responded": false,
  "last_morning_epoch": 0,
  "last_midday_epoch": 0,
  "last_evening_epoch": 0,
  "missed_checkins": 0,
  "awaiting_response": false
}
EOF
echo '{}' > "$SESSIONS_DIR/sessions.json"
run_guard "morning"

MIDDAY_RESPONDED=$(jq -r '.midday_responded' "$POLL_STATE")
if [[ "$MIDDAY_RESPONDED" == "false" ]]; then
    pass "midday_responded reset to false when last_midday_epoch=0"
else
    fail "midday_responded should be false when last_midday_epoch=0 (BUG EXISTS: not reset)" "false" "$MIDDAY_RESPONDED"
fi
teardown_test_agent

# Test 1c: evening_responded=true, last_evening_epoch=0
echo "  Test 1c: evening_responded inconsistency"
setup_test_agent "bug1-evening"
cat > "$POLL_STATE" <<'EOF'
{
  "morning_responded": false,
  "midday_responded": false,
  "evening_responded": true,
  "last_morning_epoch": 0,
  "last_midday_epoch": 0,
  "last_evening_epoch": 0,
  "missed_checkins": 0,
  "awaiting_response": false
}
EOF
echo '{}' > "$SESSIONS_DIR/sessions.json"
run_guard "morning"

EVENING_RESPONDED=$(jq -r '.evening_responded' "$POLL_STATE")
if [[ "$EVENING_RESPONDED" == "false" ]]; then
    pass "evening_responded reset to false when last_evening_epoch=0"
else
    fail "evening_responded should be false when last_evening_epoch=0 (BUG EXISTS: not reset)" "false" "$EVENING_RESPONDED"
fi
teardown_test_agent

echo ""

# ── Bug 2: awaiting_response renamed to checkin_dispatched ──
echo "--- Bug 2: awaiting_response -> checkin_dispatched rename ---"
echo "  (output should use checkin_dispatched, NOT awaiting_response)"
echo ""

setup_test_agent "bug2"
cat > "$POLL_STATE" <<'EOF'
{
  "morning_responded": false,
  "midday_responded": false,
  "evening_responded": false,
  "last_morning_epoch": 0,
  "last_midday_epoch": 0,
  "last_evening_epoch": 0,
  "missed_checkins": 0,
  "awaiting_response": false
}
EOF
echo '{}' > "$SESSIONS_DIR/sessions.json"
run_guard "morning"

# Test 2a: checkin_dispatched key should exist
assert_json_key_exists "$POLL_STATE" "checkin_dispatched" "poll-state.json contains 'checkin_dispatched' key"

# Test 2b: awaiting_response key should NOT exist
assert_json_key_missing "$POLL_STATE" "awaiting_response" "poll-state.json does NOT contain 'awaiting_response' key"

teardown_test_agent

echo ""

# ── Bug 3: Inter-day state hygiene ───────────────
echo "--- Bug 3: Inter-day state hygiene ---"
echo "  (when date changes, stale responded flags and epochs should reset)"
echo ""

# Test 3a: last_state_date is yesterday, stale morning data
echo "  Test 3a: Date change resets stale state"
setup_test_agent "bug3"

YESTERDAY=$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date -d 'yesterday' '+%Y-%m-%d' 2>/dev/null || echo "2026-03-29")

cat > "$POLL_STATE" <<EOF
{
  "morning_responded": true,
  "midday_responded": true,
  "evening_responded": true,
  "last_morning_epoch": 1234567,
  "last_midday_epoch": 1234567,
  "last_evening_epoch": 1234567,
  "missed_checkins": 3,
  "awaiting_response": false,
  "last_state_date": "$YESTERDAY"
}
EOF
echo '{}' > "$SESSIONS_DIR/sessions.json"
run_guard "morning"

# After running on a new day, all responded flags should be reset
MORNING_R=$(jq -r '.morning_responded' "$POLL_STATE")
MIDDAY_R=$(jq -r '.midday_responded' "$POLL_STATE")
EVENING_R=$(jq -r '.evening_responded' "$POLL_STATE")
MORNING_E=$(jq -r '.last_morning_epoch' "$POLL_STATE")
MIDDAY_E=$(jq -r '.last_midday_epoch' "$POLL_STATE")
EVENING_E=$(jq -r '.last_evening_epoch' "$POLL_STATE")

# morning_responded should be false (it was just dispatched in this run)
if [[ "$MORNING_R" == "false" ]]; then
    pass "morning_responded is false after date change (expected: dispatched this run)"
else
    fail "morning_responded should be false after date change" "false" "$MORNING_R"
fi

# midday_responded should be reset to false (stale from yesterday)
if [[ "$MIDDAY_R" == "false" ]]; then
    pass "midday_responded reset to false after date change"
else
    fail "midday_responded should be false after date change (BUG EXISTS: stale state preserved)" "false" "$MIDDAY_R"
fi

# evening_responded should be reset to false (stale from yesterday)
if [[ "$EVENING_R" == "false" ]]; then
    pass "evening_responded reset to false after date change"
else
    fail "evening_responded should be false after date change (BUG EXISTS: stale state preserved)" "false" "$EVENING_R"
fi

# Stale epochs from yesterday should be reset to 0
# (morning epoch will be set to NOW because we just ran morning, but midday/evening should be 0)
if [[ "$MIDDAY_E" == "0" ]]; then
    pass "last_midday_epoch reset to 0 after date change"
else
    fail "last_midday_epoch should be 0 after date change (BUG EXISTS: stale epoch preserved)" "0" "$MIDDAY_E"
fi

if [[ "$EVENING_E" == "0" ]]; then
    pass "last_evening_epoch reset to 0 after date change"
else
    fail "last_evening_epoch should be 0 after date change (BUG EXISTS: stale epoch preserved)" "0" "$EVENING_E"
fi

# Test 3b: last_state_date should be updated to today
echo "  Test 3b: last_state_date updated to today"
TODAY=$(date '+%Y-%m-%d')
STATE_DATE=$(jq -r '.last_state_date // "missing"' "$POLL_STATE")
if [[ "$STATE_DATE" == "$TODAY" ]]; then
    pass "last_state_date updated to today's date"
else
    fail "last_state_date should be today ($TODAY) (BUG EXISTS: no date tracking)" "$TODAY" "$STATE_DATE"
fi

teardown_test_agent

echo ""

# ── Summary ──────────────────────────────────────
echo "============================================"
echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed, $TOTAL_COUNT total"
echo "============================================"

if [[ $FAIL_COUNT -gt 0 ]]; then
    echo ""
    echo "NOTE: FAILed tests indicate the bug fix is NOT yet applied."
    echo "Tests marked (BUG EXISTS) confirm the bug is present in the"
    echo "current version of checkin-guard.sh."
    exit 1
else
    echo ""
    echo "All bug fixes verified successfully."
    exit 0
fi
