#!/usr/bin/env bash
set -euo pipefail

# test-checkin-guard.sh — Test harness for checkin-guard.sh
#
# Tests the stateless checkin-guard that reads sessions.json
# and outputs last_interaction + hours_since_interaction.
#
# Strategy:
#   Create a fake agent directory with sessions/sessions.json,
#   run the guard, and verify the JSON output.

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

# ── Setup fake agent directory ───────────────────
setup_test_agent() {
    local test_name="$1"
    TEST_TMPDIR=$(mktemp -d /tmp/checkin-guard-test-XXXXXX)
    AGENT_DIR="$TEST_TMPDIR/test-agent"
    SCRIPTS_DIR="$AGENT_DIR/scripts"
    LIB_DIR="$SCRIPTS_DIR/lib"
    SESSIONS_DIR="$AGENT_DIR/sessions"

    mkdir -p "$LIB_DIR" "$SESSIONS_DIR"

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
    "$SCRIPTS_DIR/checkin-guard.sh" "$checkin_type" --quiet 2>/dev/null
}

# ══════════════════════════════════════════════════
echo "============================================"
echo "checkin-guard.sh Tests"
echo "============================================"
echo ""

# ── Test 1: DM sessions are detected correctly ───
echo "--- Test 1: DM session filter ---"
echo ""

setup_test_agent "dm-filter"
NOW_MS=$(( $(date -u +%s) * 1000 ))
RECENT_MS=$(( NOW_MS - 3600000 ))  # 1 hour ago

cat > "$SESSIONS_DIR/sessions.json" <<EOF
{
  "agent:test-agent:slack:direct:u1234": {
    "updatedAt": $RECENT_MS,
    "chatType": "direct"
  },
  "agent:test-agent:cron:abc123": {
    "updatedAt": $NOW_MS,
    "chatType": "cron"
  },
  "agent:test-agent:main": {
    "updatedAt": $NOW_MS,
    "chatType": "main"
  }
}
EOF

OUTPUT=$(run_guard "morning")
HOURS=$(echo "$OUTPUT" | jq -r '.data.hours_since_interaction')
LAST=$(echo "$OUTPUT" | jq -r '.data.last_interaction')

if [[ "$HOURS" -le 1 ]]; then
    pass "hours_since_interaction reflects DM session (${HOURS}h, expected ~1h)"
else
    fail "hours_since_interaction should be ~1 from DM session" "0-1" "$HOURS"
fi

if [[ "$LAST" != "null" && "$LAST" != "" ]]; then
    pass "last_interaction is set from DM session"
else
    fail "last_interaction should be set" "ISO timestamp" "$LAST"
fi
teardown_test_agent

# ── Test 2: Cron/main sessions are excluded ──────
echo ""
echo "--- Test 2: Non-DM sessions excluded ---"
echo ""

setup_test_agent "cron-excluded"
NOW_MS=$(( $(date -u +%s) * 1000 ))

cat > "$SESSIONS_DIR/sessions.json" <<EOF
{
  "agent:test-agent:cron:abc123": {
    "updatedAt": $NOW_MS,
    "chatType": "cron"
  },
  "agent:test-agent:main": {
    "updatedAt": $NOW_MS,
    "chatType": "main"
  },
  "agent:test-agent:slack:channel:c123": {
    "updatedAt": $NOW_MS,
    "chatType": "channel"
  }
}
EOF

OUTPUT=$(run_guard "morning")
LAST=$(echo "$OUTPUT" | jq -r '.data.last_interaction')
HOURS=$(echo "$OUTPUT" | jq -r '.data.hours_since_interaction')

if [[ "$LAST" == "null" ]]; then
    pass "last_interaction is null when no DM sessions exist"
else
    fail "last_interaction should be null (only cron/main/channel sessions)" "null" "$LAST"
fi

if [[ "$HOURS" -eq 0 ]]; then
    pass "hours_since_interaction is 0 when no DM sessions"
else
    fail "hours_since_interaction should be 0" "0" "$HOURS"
fi
teardown_test_agent

# ── Test 3: Skip when recently active ────────────
echo ""
echo "--- Test 3: Skip when recently active ---"
echo ""

setup_test_agent "skip-active"
VERY_RECENT_MS=$(( $(date -u +%s) * 1000 - 300000 ))  # 5 min ago

cat > "$SESSIONS_DIR/sessions.json" <<EOF
{
  "agent:test-agent:slack:direct:u1234": {
    "updatedAt": $VERY_RECENT_MS,
    "chatType": "direct"
  }
}
EOF

OUTPUT=$(run_guard "morning")
SKIP=$(echo "$OUTPUT" | jq -r '.data.skip')

if [[ "$SKIP" == "true" ]]; then
    pass "skip=true when developer active 5 min ago"
else
    fail "should skip when developer was active recently" "true" "$SKIP"
fi
teardown_test_agent

# ── Test 4: Don't skip when not recently active ──
echo ""
echo "--- Test 4: Don't skip when not recently active ---"
echo ""

setup_test_agent "no-skip"
OLD_MS=$(( $(date -u +%s) * 1000 - 7200000 ))  # 2 hours ago

cat > "$SESSIONS_DIR/sessions.json" <<EOF
{
  "agent:test-agent:slack:direct:u1234": {
    "updatedAt": $OLD_MS,
    "chatType": "direct"
  }
}
EOF

OUTPUT=$(run_guard "midday")
SKIP=$(echo "$OUTPUT" | jq -r '.data.skip')
TYPE=$(echo "$OUTPUT" | jq -r '.data.checkin_type')

if [[ "$SKIP" == "false" ]]; then
    pass "skip=false when developer inactive for 2h"
else
    fail "should not skip when developer inactive for 2h" "false" "$SKIP"
fi

if [[ "$TYPE" == "midday" ]]; then
    pass "checkin_type=midday passed through correctly"
else
    fail "checkin_type should be midday" "midday" "$TYPE"
fi
teardown_test_agent

# ── Test 5: Missing sessions.json ────────────────
echo ""
echo "--- Test 5: Missing sessions.json ---"
echo ""

setup_test_agent "no-sessions"
rm -f "$SESSIONS_DIR/sessions.json"

OUTPUT=$(run_guard "evening")
SKIP=$(echo "$OUTPUT" | jq -r '.data.skip')
LAST=$(echo "$OUTPUT" | jq -r '.data.last_interaction')
SUCCESS=$(echo "$OUTPUT" | jq -r '.success')

if [[ "$SUCCESS" == "true" ]]; then
    pass "guard succeeds even without sessions.json"
else
    fail "guard should succeed without sessions.json" "true" "$SUCCESS"
fi

if [[ "$LAST" == "null" ]]; then
    pass "last_interaction is null when sessions.json missing"
else
    fail "last_interaction should be null" "null" "$LAST"
fi

if [[ "$SKIP" == "false" ]]; then
    pass "skip=false when no session data (proceed with check-in)"
else
    fail "should not skip when no session data" "false" "$SKIP"
fi
teardown_test_agent

# ── Test 6: Hours calculation for stale sessions ─
echo ""
echo "--- Test 6: Stale session hours calculation ---"
echo ""

setup_test_agent "stale"
TWO_DAYS_AGO_MS=$(( $(date -u +%s) * 1000 - 172800000 ))  # 48h ago

cat > "$SESSIONS_DIR/sessions.json" <<EOF
{
  "agent:test-agent:slack:direct:u1234": {
    "updatedAt": $TWO_DAYS_AGO_MS,
    "chatType": "direct"
  }
}
EOF

OUTPUT=$(run_guard "morning")
HOURS=$(echo "$OUTPUT" | jq -r '.data.hours_since_interaction')

if [[ "$HOURS" -ge 47 && "$HOURS" -le 49 ]]; then
    pass "hours_since_interaction is ~48 for 2-day-old session (got ${HOURS}h)"
else
    fail "hours_since_interaction should be ~48" "47-49" "$HOURS"
fi
teardown_test_agent

# ── Test 7: No poll-state.json created ───────────
echo ""
echo "--- Test 7: No poll-state.json side effects ---"
echo ""

setup_test_agent "no-side-effects"
echo '{}' > "$SESSIONS_DIR/sessions.json"

run_guard "morning" >/dev/null

MEMORY_DIR="$AGENT_DIR/memory"
if [[ ! -d "$MEMORY_DIR" ]] || [[ -z "$(ls -A "$MEMORY_DIR" 2>/dev/null)" ]]; then
    pass "no poll-state.json or memory files created"
else
    fail "guard should not create any files" "empty memory dir" "$(ls "$MEMORY_DIR" 2>/dev/null)"
fi
teardown_test_agent

echo ""

# ── Summary ──────────────────────────────────────
echo "============================================"
echo "RESULTS: $PASS_COUNT passed, $FAIL_COUNT failed, $TOTAL_COUNT total"
echo "============================================"

if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
else
    echo ""
    echo "All tests passed."
    exit 0
fi
