# Duplicate Slack Reply Race Condition Analysis

**Date:** 2026-03-24
**Status:** Actionable - Multiple root causes identified
**Severity:** Medium (intermittent, user-facing)

---

## Executive Summary

The dev1 agent has **two independent, overlapping mechanisms** that can trigger Slack messages to the same user (<slack-id>), with **no deduplication or coordination** between them. This is the primary root cause of duplicate replies. Additionally, the OpenClaw cron job's `isolated` session mode creates sessions with no awareness of each other, compounding the problem.

---

## Root Cause 1: Dual Trigger Mechanisms (PRIMARY)

### Finding

Two completely independent systems can fire check-in messages to the same Slack user:

**Mechanism A - OpenClaw Internal Cron Job** (`jobs.json`, line 31-63):
- Job ID: `1e14ae94-94b2-4ab3-81d0-d36814d90eaf`
- Schedule: `*/10 * * * *` (every 10 minutes)
- Session: `"sessionTarget": "isolated"` (each execution is a new isolated session)
- Delivery: Direct to Slack user `<slack-id>` via `"mode": "announce"`
- Currently enabled: `true`

**Mechanism B - External Shell Script** (`cron-check.sh`):
- Script: `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/scripts/cron-check.sh`
- Calls `poll-check.sh` to determine if a check-in is due
- Runs `openclaw agent --agent dev1 --message ... --deliver --reply-channel slack --reply-to "<slack-id>"`
- Has its own timestamp update logic (lines 23-29)

**The critical problem:** These two mechanisms operate independently. If both fire within a short window, dev1 sends two messages to the same Slack user. There is zero coordination between them.

### Evidence

- `jobs.json` line 34: `"enabled": true` -- the OpenClaw cron is active
- `cron-check.sh` exists as a standalone script designed to be invoked externally
- Both target the same Slack user ID: `<slack-id>`
- No lock file, mutex, or shared "last sent" timestamp between the two mechanisms

---

## Root Cause 2: Isolated Sessions with No Deduplication (SECONDARY)

### Finding

The OpenClaw cron job at `jobs.json` line 41 uses:

```json
"sessionTarget": "isolated"
```

This means **every 10-minute cron execution spawns a completely new, isolated session**. Each session:
- Has no knowledge of previous sessions
- Cannot check if a message was already sent recently
- Cannot see that another session is currently running
- Has no shared state to coordinate with

If OpenClaw's cron scheduler fires overlapping executions (e.g., the previous job hasn't finished when the next 10-minute tick arrives), two isolated sessions can run concurrently and both send messages.

### Evidence

- `jobs.json` line 55: `"lastDurationMs": 6743` -- last execution took ~7 seconds
- `jobs.json` line 39: `"expr": "*/10 * * * *"` -- fires every 10 minutes
- While 7 seconds is well within the 10-minute window, the `"lastRunStatus": "error"` (line 56) and `"timeoutSeconds": 120` (line 47) suggest that error conditions or slow model responses could cause executions to overlap

---

## Root Cause 3: Divergent State Files (<channel-id>G)

### Finding

There are **three separate poll-state.json files** in the repository, each with different timestamps:

1. `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/memory/poll-state.json`
   - `last_interaction`: `"2026-03-24T05:48:00Z"`

2. `/Users/<hostname>/openclaw-agents/.openclaw/agents/memory/poll-state.json`
   - `last_interaction`: `"2026-03-23T15:19:57Z"` (over 14 hours behind)

3. The OpenClaw cron job (`jobs.json`) has its own `state` object with `lastRunAtMs` (line 55)

**The problem:** Depending on which state file is read, the system may incorrectly determine a check-in is "due" even though one was recently sent via a different mechanism.

### Evidence

- `poll-check.sh` line 24: reads from `$AGENT_DIR/memory/poll-state.json` (relative to script location)
- `cron-check.sh` line 5: `cd /Users/<hostname>/openclaw-agents/.openclaw/agents/dev1` then reads `memory/poll-state.json`
- The stow workflow (`stow --no-folding -t ~ .`) creates symlinks, potentially causing the agent directory at `~/.openclaw/agents/dev1/` to point to different physical files than the repo checkout
- The extra `agents/memory/poll-state.json` (outside dev1/) appears to be a stale copy or misplaced state file

---

## Root Cause 4: Missing Guard in cron-check.sh (<channel-id>G)

### Finding

`cron-check.sh` has no guard against concurrent execution. If triggered by an external scheduler (system crontab, launchd, etc.) while also being triggered manually or by another mechanism:

- Line 8: Runs `poll-check.sh` which only checks elapsed time
- Line 11: If `due == 1`, sends message immediately
- Lines 23-29: Updates timestamp AFTER sending the message

**Race window:** Between lines 11-22 (sending message) and lines 23-29 (updating timestamp), another invocation could read the old timestamp, determine a check-in is due, and also send a message.

### Evidence

- No PID file or lock file creation in `cron-check.sh`
- No `flock` or similar mutex mechanism
- Timestamp update happens at the END of the script (line 23-29), not at the START
- The node.js timestamp update (lines 24-29) is non-atomic -- reads, modifies in memory, writes back

---

## Root Cause 5: OpenClaw Cron Job Payload Design (<channel-id>G)

### Finding

The cron job payload at `jobs.json` lines 44-47:

```json
"payload": {
    "kind": "agentTurn",
    "message": "Output ONLY the exact message to send to dev1 on Slack. Nothing else...",
    "timeoutSeconds": 120
}
```

This directly instructs the agent to output a Slack message every single time it fires (every 10 minutes). The `poll-check.sh` guard is NOT invoked by this cron path -- only `cron-check.sh` uses it. The OpenClaw cron fires unconditionally based on the `*/10 * * * *` schedule with no "is due" check.

### Evidence

- The payload contains no reference to `poll-check.sh` or any due-checking logic
- The `"kind": "agentTurn"` triggers a full agent session that outputs the message
- The delivery config (`"mode": "announce"`, `"channel": "slack"`) ensures it reaches Slack

---

## Contributing Factor: Stow Symlink Complexity

The repo uses GNU stow to symlink `.openclaw/` to `~/.openclaw/`. With `--no-folding`, individual files are symlinked rather than directories. This creates a scenario where:

- Runtime OpenClaw reads from `~/.openclaw/`
- The repo has the source files at `/Users/<hostname>/openclaw-agents/.openclaw/`
- If stow is not re-run after changes, state files can diverge
- The `<your-org>/` directory suggests a previous agent configuration that may have had its own polling state

---

## Scenario: How Duplicate Messages Occur

1. At minute :00, OpenClaw's internal cron fires the "dev1 Check-in" job (every 10 minutes)
2. An isolated session spawns, the agent generates a check-in message, delivery announces to Slack
3. Separately, if `cron-check.sh` is triggered (manually, by external cron, or by launchd):
   - It reads `poll-state.json` which may show the last interaction as hours ago
   - It determines `due == 1`
   - It runs `openclaw agent --agent dev1 --message "Hey dev1..."` which ALSO delivers to Slack
4. dev1 receives two check-in messages within seconds/minutes of each other

---

## Recommendations

### Immediate Fix (choose one):

**Option A:** Disable the OpenClaw internal cron job by setting `"enabled": false` in `jobs.json` line 34, and rely solely on `cron-check.sh` with its poll-state guard logic.

**Option B:** Remove `cron-check.sh` and rely solely on the OpenClaw cron job, but change its schedule from `*/10 * * * *` to something sane like `0 */4 * * *` (every 4 hours, matching the 240-minute interval in poll-state.json).

### Structural Fixes:

1. **Add a lock mechanism** to `cron-check.sh` -- use `flock` or a PID file to prevent concurrent execution
2. **Move timestamp update to BEFORE message send** in `cron-check.sh` (lines 23-29 should come before line 14)
3. **Consolidate state files** -- remove the stale `.openclaw/agents/memory/poll-state.json`
4. **Add deduplication to the OpenClaw cron payload** -- include a check of `poll-state.json` in the agent message or use a pre-flight script
5. **Change session target** from `"isolated"` to `"main"` if the agent should be aware of recent conversation history

---

## Files Examined

| File | Path | Relevance |
|------|------|-----------|
| Cron Jobs Config | `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs.json` | Primary: dual trigger mechanism |
| External Cron Script | `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/scripts/cron-check.sh` | Primary: second trigger mechanism |
| Poll Check Script | `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/scripts/poll-check.sh` | Secondary: guard logic (only used by one path) |
| Poll State (dev1) | `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/memory/poll-state.json` | Contributing: state divergence |
| Poll State (agents root) | `/Users/<hostname>/openclaw-agents/.openclaw/agents/memory/poll-state.json` | Contributing: stale duplicate state |
| Agent Config | `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/AGENTS.md` | Context: heartbeat vs cron guidance |
| Workspace State | `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/.openclaw/workspace-state.json` | Context: bootstrap timing |
