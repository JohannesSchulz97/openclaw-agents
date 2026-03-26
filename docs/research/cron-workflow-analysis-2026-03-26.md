# Cron Workflow & Agent Creation Scripts Analysis

**Date:** 2026-03-26
**Status:** Research complete -- actionable findings
**Scope:** `scripts/create-agent.sh`, `scripts/apply-cron.sh`, `scripts/remove-agent.sh`, `scripts/lib/cron-utils.sh`, `scripts/lib/openclaw-utils.sh`, `.openclaw/cron/jobs-config.json`

---

## 1. Overall Design Intent

The cron workflow follows a **config-as-code** pattern:

```
jobs-config.json (source of truth, committed to git)
        |
        v
  apply-cron.sh (reconciliation script)
        |
        v
  openclaw cron gateway (runtime state, never committed)
```

The design intent is declarative: you define desired state in `jobs-config.json`, then `apply-cron.sh` reconciles that with the live gateway. This is the right architectural direction.

---

## 2. Current State of `apply-cron.sh`

**What it does well:**

- Matches config jobs to gateway jobs by `agentId` (not by config `id`, which is informational only)
- Uses `openclaw cron edit` for existing gateway jobs, `openclaw cron add` for new ones
- Translates all config fields to CLI flags correctly
- Handles `delivery.mode=none` via `--no-deliver`
- Fetches gateway state once at the top (`openclaw cron list --json`)

**What it does NOT do:**

- **Does not remove orphaned gateway jobs.** If you remove a job from `jobs-config.json` and run `apply-cron.sh`, the gateway job persists forever.
- **Does not detect or handle multi-match ambiguity.** If multiple gateway jobs share the same `agentId`, `head -1` silently picks one.
- **No dry-run mode.** Cannot preview what changes will be made.
- **No exit code management.** If one job fails to apply, the script continues but reports "All jobs applied successfully" regardless.

### Idempotency Assessment

`apply-cron.sh` is **partially idempotent** for existing jobs (edit is a patch operation). But it is **not fully idempotent** because:
1. Running it after removing a job from config leaves the orphan on the gateway
2. Creating a new job via `openclaw cron add` generates a new gateway ID each time -- if the `agentId` match fails for any reason, a duplicate gets created

---

## 3. Current State of `create-agent.sh`

**Workflow (8 steps):**
1. Validate inputs (name, slack-id, type existence, no duplicate agent dir)
2. Create agent directory + copy per-agent template files (IDENTITY.md, USER.md, poll-state.json)
3. Run `sync-agents.sh` to copy shared type files
4. Add cron job to `jobs-config.json` + call `apply-cron.sh`
5. Run `stow` to symlink into `~/.openclaw/`
6. Register agent in `openclaw.json` (agent entry + Slack binding)
7. Update `CLAUDE.md` with agent info
8. Print summary

**Key observations:**

- **Dual cron-add logic:** Lines 182-243 have two code paths -- one using `cron-utils.sh` (if it exists), one inline fallback. Both do the same thing (append to `jobs-config.json`). The fallback is dead code now that `cron-utils.sh` exists, but it drifts (e.g., different `timeoutSeconds`: 120 in both paths, but the live config shows 180).
- **`apply-cron.sh` is called after adding to config.** This means every agent creation triggers a full reconciliation of ALL jobs, not just the new one. This is fine for correctness but wasteful.
- **The config `id` is generated locally** but never used by `apply-cron.sh` (which matches by `agentId`). The `id` field in `jobs-config.json` is purely cosmetic.

---

## 4. Current State of `remove-agent.sh`

**Workflow (6 steps):**
1. Remove cron entries from `jobs-config.json` (by `agentId`)
2. Call `apply-cron.sh` to reconcile (but this does NOT remove the gateway job!)
3. Delete agent directories (repo + live)
4. Re-stow remaining agents
5. Remove agent from `openclaw.json`
6. Remove agent section from `CLAUDE.md`

**Critical gap:** Step 2 calls `apply-cron.sh`, but since `apply-cron.sh` only adds/edits and never removes, the gateway cron job for the removed agent **persists on the gateway**. The job was removed from `jobs-config.json` but the gateway still has it. This is a real bug.

---

## 5. Analysis of `jobs-config.json`

- 6 agents, all with identical structure except for `agentId`, `name`, `sessionKey`, and the Slack target in the message
- dev1 has an enhanced message (includes `github-activity.sh` step)
- All use `everyMs: 7200000` (2 hours), `timeoutSeconds: 180`, `model: fw-mm25`
- The `id` field in each job is locally generated and not used for matching

---

## 6. Available `openclaw cron` CLI Commands

| Command | Purpose |
|---------|---------|
| `openclaw cron add` | Create a new job (returns gateway-assigned ID) |
| `openclaw cron edit <id>` | Patch fields on existing job |
| `openclaw cron rm <id>` | Remove a job by gateway ID |
| `openclaw cron list [--json]` | List jobs (supports `--all` for disabled) |
| `openclaw cron enable <id>` | Enable a job |
| `openclaw cron disable <id>` | Disable a job |
| `openclaw cron run <id>` | Trigger job immediately (debug) |

Key constraint: `openclaw cron rm` requires the **gateway ID**, not the config ID or agentId. So removal requires first looking up the gateway ID by agentId.

---

## 7. Architectural Options

### Option A: Make `apply-cron.sh` a proper declarative sync

**How:** After applying all config jobs, iterate gateway jobs and remove any whose `agentId` is NOT in the config.

```bash
# Pseudo-code for the removal phase:
CONFIGURED_AGENTS=$(jq -r '.jobs[].agentId' "$CONFIG_FILE" | sort -u)
GATEWAY_AGENTS=$(echo "$GATEWAY_JOBS" | jq -r '.jobs[].agentId' | sort -u)

for agent in $GATEWAY_AGENTS; do
  if ! echo "$CONFIGURED_AGENTS" | grep -qx "$agent"; then
    GATEWAY_ID=$(echo "$GATEWAY_JOBS" | jq -r --arg a "$agent" '.jobs[] | select(.agentId == $a) | .id')
    openclaw cron rm "$GATEWAY_ID"
  fi
done
```

**Pros:**
- True config-as-code: config file is the single source of truth
- Removing a job from config + running `apply-cron.sh` actually removes it from gateway
- Idempotent: run N times, same result
- `remove-agent.sh` just needs to remove from config + call `apply-cron.sh`

**Cons:**
- Must be careful not to remove manually-created gateway jobs
- Slightly more dangerous (deletes things)

### Option B: Keep additive but add `openclaw cron rm` to remove-agent.sh

**How:** `remove-agent.sh` directly calls `openclaw cron rm` for the agent's gateway job(s) instead of relying on `apply-cron.sh`.

**Pros:**
- Simpler change, targeted fix
- No risk of accidentally removing unrelated gateway jobs

**Cons:**
- `apply-cron.sh` remains non-declarative (config drift possible)
- Manual gateway cleanup still needed for other scenarios

### Option C: Have `create-agent.sh` call `openclaw cron add` directly

**How:** Skip `jobs-config.json` entirely. `create-agent.sh` calls `openclaw cron add` and `remove-agent.sh` calls `openclaw cron rm`.

**Pros:**
- Simplest possible approach
- No config file to keep in sync

**Cons:**
- Loses config-as-code benefit (no git history of cron changes)
- No way to review/audit cron config
- Cannot reproduce gateway state from repo alone
- Breaks the architecture's core design intent

---

## 8. Recommendation: Option A (Declarative Sync)

**Make `apply-cron.sh` a full declarative sync.** This is the cleanest approach because:

1. **It aligns with the existing design intent.** The architecture already treats `jobs-config.json` as source of truth -- it just does not fully enforce it yet.

2. **It fixes the `remove-agent.sh` bug.** Once `apply-cron.sh` can remove orphaned gateway jobs, the removal workflow becomes: delete from config, call `apply-cron.sh`, done.

3. **It is idempotent.** Run it 1 time or 100 times, the gateway matches the config.

4. **It simplifies `create-agent.sh` and `remove-agent.sh`.** Both scripts only need to modify `jobs-config.json` and then call `apply-cron.sh`. The reconciliation logic lives in one place.

### Implementation Plan

**Phase 1: Enhance `apply-cron.sh`**

Add a removal phase after the existing add/edit loop:

```
For each gateway job:
  If agentId NOT in config:
    openclaw cron rm <gateway-id>
    Log: "REMOVE: <name> (agentId=<id>, not in config)"
```

Add safety measures:
- `--dry-run` flag to preview changes without executing
- `--no-delete` flag to skip removal phase (backward-compatible)
- Error tracking: count successes/failures, report accurately
- Handle multi-match: warn if multiple gateway jobs share an agentId

**Phase 2: Simplify `remove-agent.sh`**

Replace the current cron removal logic (lines 86-111) with:
1. Remove job from `jobs-config.json` (keep existing jq logic)
2. Call `apply-cron.sh` (which now handles gateway removal)

**Phase 3: Clean up `create-agent.sh`**

- Remove the inline fallback cron-add logic (lines 191-243). Always use `cron-utils.sh`.
- Optionally: add `--skip-apply` flag for batch operations

### Safety Guardrails

- Only remove gateway jobs whose `agentId` matches a known pattern (e.g., agent names that exist as directories)
- Log every removal with full context
- `--dry-run` is essential for confidence
- Consider: only remove jobs whose `agentId` was previously in the config (track removals explicitly)

---

## 9. Additional Issues Found

### `timeoutSeconds` inconsistency

- `cron-utils.sh` sets `timeoutSeconds: 120`
- All live jobs in `jobs-config.json` have `timeoutSeconds: 180`
- The inline fallback in `create-agent.sh` also uses `120`

This means new agents created via `cron-utils.sh` get 120s while existing agents have 180s. Should be unified.

### `sync-agents.sh` hardcodes agent type

Line 44: `type="dev-pa"` is hardcoded. If a second type is ever added, this breaks. Consider reading the type from a `.type` marker file in each agent directory, or from a mapping in `jobs-config.json`.

### Duplicate cron-add code paths

`create-agent.sh` has ~50 lines of inline cron job creation (lines 191-243) that duplicates what `cron-utils.sh` does. The fallback path should be removed since `cron-utils.sh` exists.

### `remove-agent.sh` does not use `cron-utils.sh`

`remove-agent.sh` has its own inline jq logic for removing cron entries (line 96) instead of calling `remove_cron_job()` from `cron-utils.sh`. It also sources `openclaw-utils.sh` but not `cron-utils.sh`.

---

## 10. Summary

| Issue | Severity | Fix |
|-------|----------|-----|
| `apply-cron.sh` does not remove orphaned gateway jobs | High | Add removal phase (Option A) |
| `remove-agent.sh` leaves ghost jobs on gateway | High | Fixed by Option A |
| No `--dry-run` in `apply-cron.sh` | Medium | Add flag |
| `timeoutSeconds` inconsistency (120 vs 180) | Medium | Unify to 180 |
| Duplicate cron-add code in `create-agent.sh` | Low | Remove inline fallback |
| `remove-agent.sh` does not use `cron-utils.sh` | Low | Refactor to use shared lib |
| `sync-agents.sh` hardcodes type | Low | Add type discovery |
| No error tracking in `apply-cron.sh` | Low | Track success/failure counts |
