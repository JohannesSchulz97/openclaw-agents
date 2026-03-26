# Duplicate Cron Job Entries for dev10 and dev10

**Date:** 2026-03-26
**Type:** Root Cause Analysis
**Status:** Actionable

---

## Summary

dev10 has 3 duplicate check-in entries and dev10 has 3 duplicate check-in entries in the runtime `jobs.json`. The root cause is in `apply-cron.sh`, which matches gateway jobs by `agentId` using `head -1` but creates NEW jobs when the gateway has no prior entry -- and then on subsequent runs, the `head -1` selector only updates the first of the duplicates, leaving the rest untouched.

The **primary bug** is that `apply-cron.sh` creates duplicates on the gateway when a config entry has no pre-existing gateway match, and the gateway `openclaw cron add` command is called once per config entry. However, looking deeper, the actual duplication happened because **all three agents (dev10, dev10, dev10-jean) were added to `jobs-config.json` in a single batch commit** (commit `10f942f`) and then `apply-cron.sh` was run -- but the gateway likely had no existing entries for them, so `openclaw cron add` was called. The question is: why 3 entries each?

## Detailed Findings

### 1. Source of Truth: `jobs-config.json` -- NO duplicates

The config file has exactly 1 entry per agent (6 agents total):
- dev1: 1 entry
- <your-org>: 1 entry
- dev10: 1 entry
- dev10: 1 entry
- dev10: 1 entry
- dev10-jean: 1 entry

### 2. Runtime: `~/.openclaw/cron/jobs.json` -- DUPLICATES present

| Agent | Entries in jobs.json | Expected |
|-------|---------------------|----------|
| dev1 | 1 | 1 |
| <your-org> | 1 | 1 |
| dev10 | 1 | 1 |
| **dev10** | **3** | 1 |
| **dev10** | **3** | 1 |
| dev10-jean | 1 | 1 |
| (legacy) Developer Check-in | 1 | N/A |

dev10's 3 entries have gateway IDs: `0539cda7...`, `a5e01de9...`, `1e3cda9f...`
dev10's 3 entries have gateway IDs: `1ee78b16...`, `a37a9d44...`, `82dee0ec...`

### 3. Git History of `jobs-config.json`

Only 2 commits touch this file:
1. **`07b5c17`** -- Initial creation with dev1, <your-org>, dev10 (3 jobs)
2. **`10f942f`** -- Added dev10, dev10, dev10-jean (3 new jobs appended)

Each agent was added exactly once to the config. No duplicate entries were ever committed.

### 4. Root Cause Analysis: `apply-cron.sh`

The duplication mechanism is in `apply-cron.sh` lines 67-80:

```bash
# Match by agentId: look up the gateway job's real ID
GATEWAY_ID=""
if [ -n "$AGENT_ID" ]; then
  GATEWAY_ID=$(echo "$GATEWAY_JOBS" | jq -r --arg aid "$AGENT_ID" \
    '.jobs[] | select(.agentId == $aid) | .id' 2>/dev/null | head -1)
fi

if [ -n "$GATEWAY_ID" ]; then
  # EDIT existing job
else
  # CREATE new job via `openclaw cron add`
fi
```

**The bug chain:**

1. When `apply-cron.sh` runs for a NEW agent (no existing gateway entry), it calls `openclaw cron add`, which creates a job on the gateway.
2. The script was likely run **3 times** for dev10 and dev10 -- once by `create-agent.sh` Step 4 (which calls `apply-cron.sh`), and then 2 more manual invocations or from concurrent/repeated agent creation runs.
3. Each time `apply-cron.sh` is invoked, it fetches the gateway list ONCE at the top (`GATEWAY_JOBS`), then iterates all config entries. For agents already on the gateway, it finds a match via `head -1` and does an EDIT. For agents NOT yet on the gateway at the time the snapshot was taken, it does a CREATE -- even if a previous iteration in the SAME run already created one.

**Wait -- that last point is the key insight.** The `GATEWAY_JOBS` snapshot is taken once at the start of the script (line 40). If `apply-cron.sh` creates a job for dev10 on iteration 4, that new job is NOT reflected in the `GATEWAY_JOBS` variable. So if the script were run again immediately, it would find dev10's job and EDIT it. But within a single run, there is only 1 config entry per agent, so a single run should only create 1 gateway entry per agent.

**Therefore, `apply-cron.sh` must have been run 3 separate times** for dev10 and dev10 before any gateway entries existed for them. The creation timestamps support this:

- dev10: `1774446656250`, `1774446656258`, `1774446656262` (within 12ms of each other)
- dev10: `1774446658261`, `1774446658312`, `1774446658320` (within 59ms of each other)

These timestamps are extremely close together (milliseconds apart), which strongly suggests **parallel/concurrent execution** of `apply-cron.sh` -- not 3 separate manual invocations.

### 5. How the Concurrent Execution Happened

Looking at commit `10f942f`, which added dev10, dev10, and dev10-jean in one batch, the `create-agent.sh` script was likely run 3 times in quick succession (once for each new agent). Each invocation of `create-agent.sh`:
1. Adds the agent's cron entry to `jobs-config.json` (Step 4, line 233: `.jobs += [$newJob]`)
2. Calls `apply-cron.sh` (Step 4, line 248)

**The race condition:**
- `create-agent.sh --name dev10` adds dev10 to config, then calls `apply-cron.sh`
- `create-agent.sh --name dev10` adds dev10 to config, then calls `apply-cron.sh`
- `create-agent.sh --name dev10-jean` adds dev10-jean to config, then calls `apply-cron.sh`

If these 3 scripts ran concurrently (or the `apply-cron.sh` calls overlapped):
- Each `apply-cron.sh` invocation snapshots the gateway list at the start
- At that moment, none of the new agents have gateway entries yet
- Each invocation iterates ALL jobs in `jobs-config.json` (which by then contains all 6 agents)
- Each invocation CREATEs new gateway jobs for any agent not found in its snapshot
- Result: each new agent gets 1 CREATE per concurrent invocation

Since dev10 and dev10 were in the config before all 3 runs, they got 3 CREATEs each. dev10-jean also should have gotten 3, but the timestamps show only 1 entry -- possibly the first `create-agent.sh` invocation was for dev10-jean and the config only had their entry at that point, or the race condition resolved differently.

Actually, re-examining: dev10-jean has exactly 1 runtime entry (ID `d8cd5bd4...`, created at `1774446660017`). The timing is later than dev10/dev10, consistent with being the last agent added. But the key question is: by the time the 2nd and 3rd `apply-cron.sh` ran, did the gateway already have a dev10-jean entry from the 1st run?

The timestamps show:
- dev10 entries created: 656250, 656258, 656262 ms (epoch suffix)
- dev10 entries created: 658261, 658312, 658320 ms
- dev10-jean entry created: 660017 ms

dev10-jean's single entry was created ~2-4 seconds after the dev10/dev10 batches. This could mean the 2nd and 3rd `apply-cron.sh` invocations saw dev10-jean's gateway entry from the 1st invocation and did EDITs instead of CREATEs.

### 6. Secondary Issue: No Deduplication Guard

Neither `create-agent.sh` nor `apply-cron.sh` has deduplication logic:

- **`create-agent.sh`**: The `add_cron_job` function in `cron-utils.sh` (line 116) does a blind `.jobs += [$newJob]` -- no check for existing `agentId`.
- **`apply-cron.sh`**: Uses `head -1` to pick the first gateway match. If duplicates already exist on the gateway, only the first one gets updated; the rest are orphaned but still run.

### 7. Why dev10 Was Not Affected

dev10 was included in the initial `jobs-config.json` (commit `07b5c17`), created alongside the `create-agent.sh` script itself. There was no batch of concurrent `create-agent.sh` invocations for the initial set of agents -- they were manually added to the config file.

## Root Cause Summary

**Primary cause:** Three `create-agent.sh` invocations ran concurrently (or in very rapid succession) for dev10, dev10, and dev10-jean. Each invocation called `apply-cron.sh`, which snapshots the gateway state once at startup. Since the gateway had no entries for the new agents yet, all 3 `apply-cron.sh` processes created new gateway jobs for all new agents they found in the config.

**Contributing factors:**
1. `apply-cron.sh` takes a single snapshot of gateway state and does not re-check before creating
2. `apply-cron.sh` has no locking mechanism to prevent concurrent execution
3. `add_cron_job` in `cron-utils.sh` does not check for existing `agentId` before appending
4. `apply-cron.sh` processes ALL config entries, not just the newly added one

## Recommended Fixes

### Fix 1: Add file locking to `apply-cron.sh` (HIGH PRIORITY)
Use `flock` or a lockfile to prevent concurrent execution:
```bash
LOCK_FILE="/tmp/apply-cron.lock"
exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Another apply-cron.sh is running. Exiting."; exit 1; }
```

### Fix 2: Re-fetch gateway state before CREATE (HIGH PRIORITY)
Before creating a new job, re-query the gateway to check if it was just created by a concurrent process:
```bash
# Before CREATE, double-check the gateway
FRESH_CHECK=$(openclaw cron list --json 2>/dev/null | jq -r --arg aid "$AGENT_ID" \
  '.jobs[] | select(.agentId == $aid) | .id' | head -1)
if [ -n "$FRESH_CHECK" ]; then
  # Switch to EDIT instead
fi
```

### Fix 3: Add dedup guard to `cron-utils.sh:add_cron_job` (MEDIUM PRIORITY)
Check if an entry for the agentId already exists before appending:
```bash
existing=$(jq --arg aid "$agent_name" '[.jobs[] | select(.agentId == $aid)] | length' "$cron_file")
if [[ "$existing" -gt 0 ]]; then
  echo "Warning: Cron job for agent '$agent_name' already exists. Skipping."
  return 0
fi
```

### Fix 4: Scope `apply-cron.sh` to specific agent (MEDIUM PRIORITY)
Add an optional `--agent` flag so `create-agent.sh` can call `apply-cron.sh --agent dev10` instead of applying ALL jobs:
```bash
# apply-cron.sh --agent dev10
# Only process the job for the specified agent
```

### Fix 5: Clean up existing duplicates (IMMEDIATE)
Remove the extra gateway entries for dev10 and dev10:
```bash
# Keep one, delete the rest
openclaw cron delete a5e01de9-16a4-469d-bf53-11c05804a47e
openclaw cron delete 1e3cda9f-7c81-40d8-961a-d1ae0eca0467
openclaw cron delete a37a9d44-2c23-44c3-bf82-0f57035b6d52
openclaw cron delete 82dee0ec-85d1-42e1-86d2-e15113d417a1
```

## Files Involved

- `/Users/<hostname>/openclaw-agents/scripts/create-agent.sh` -- Agent creation workflow (calls apply-cron.sh)
- `/Users/<hostname>/openclaw-agents/scripts/apply-cron.sh` -- Cron config applicator (primary bug location)
- `/Users/<hostname>/openclaw-agents/scripts/lib/cron-utils.sh` -- Cron utility library (no dedup guard)
- `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json` -- Source of truth (clean, no duplicates)
- `~/.openclaw/cron/jobs.json` -- Runtime file (contains duplicates)
