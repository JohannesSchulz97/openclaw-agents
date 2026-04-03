# Research: Does Editing/Updating a Cron Job in OpenClaw Fire It?

Date: 2026-04-03
Status: Complete

## Question

Does editing or updating a cron job in OpenClaw (via `openclaw cron edit` or `apply-cron.sh`) automatically trigger/fire that job immediately?

## Findings

### 1. apply-cron.sh — What It Actually Does

The script performs a three-phase declarative reconciliation:

- **Phase 1 (ADD):** Calls `openclaw cron add` for config entries not yet in the gateway.
- **Phase 2 (EDIT):** Calls `openclaw cron edit <gateway-id>` for config entries that already exist in the gateway.
- **Phase 2b (CLEAR MODEL):** Directly patches `~/.openclaw/cron/jobs.json` with `jq` to null out `.payload.model` for jobs where config has no model field (workaround for missing `--clear-model` CLI flag).
- **Phase 3 (REMOVE):** Calls `openclaw cron rm <gateway-id>` for gateway jobs not present in config (orphan removal).

There is NO call to `openclaw cron run` anywhere in `apply-cron.sh`. The script never triggers any job. It only reconciles metadata.

### 2. deploy.sh — What It Actually Does

The deployment pipeline sequence is:

1. `openclaw config validate`
2. `git fetch + reset` (if `--pull`)
3. `bash scripts/sync-agents.sh`
4. `stow --adopt` then `stow` (file sync)
5. `bash scripts/apply-cron.sh`
6. Restart guard: `openclaw gateway restart` (only if restart marker `/tmp/openclaw-deploy-needs-restart` exists OR `--force-restart` is passed)

There is NO `openclaw cron run` call in `deploy.sh`. The restart guard is only about restarting the gateway process — it does not trigger any cron jobs.

### 3. OpenClaw CLI — `cron add` and `cron edit` Flags

Inspected actual CLI help output from `openclaw cron add --help` and `openclaw cron edit --help`:

- Neither command has a `--run-now`, `--trigger`, `--fire`, or any equivalent flag.
- Neither command has any described side effect of triggering immediate execution.
- The only command that fires a job immediately is `openclaw cron run <id>`, which is explicitly labeled "Run a cron job now (debug)".

Relevant available flags for `cron add` and `cron edit`:
- `--wake <mode>` — controls `now` vs `next-heartbeat` for SCHEDULED runs, not for the edit/add operation itself.
- `--every`, `--cron`, `--at` — schedule configuration only.

### 4. `openclaw cron run` — The Only Fire Mechanism

```
Usage: openclaw cron run [options] <id>
Run a cron job now (debug)

Options:
  --due     Run only when due (default behavior in older versions)
```

This is the ONLY way to manually trigger a cron job. It requires an explicit `<id>` argument and is described as a debug command. It is never called by `apply-cron.sh` or `deploy.sh`.

### 5. jobs-config.json — Examined

The `wakeMode: "now"` field present in all jobs controls behavior when the gateway itself wakes (e.g., after restart) — it makes the scheduler check and run overdue jobs immediately on gateway wake. This is NOT triggered by `cron add` or `cron edit`; it is a property of the job's scheduled execution behavior.

## Conclusion

**There is no evidence that editing or updating a cron job in OpenClaw fires it.**

Specifically:

| Operation | Fires Job? | Notes |
|-----------|-----------|-------|
| `openclaw cron add` | No | Registers job; does not run it |
| `openclaw cron edit <id>` | No | Patches job metadata; does not run it |
| `apply-cron.sh` | No | Calls only `cron add`, `cron edit`, `cron rm`, and direct jq patching |
| `deploy.sh` | No | Calls only sync, stow, apply-cron.sh, and optional gateway restart |
| `openclaw gateway restart` | Possibly | If `wakeMode: "now"` jobs are overdue at restart time, they may fire. This is the only indirect mechanism. |
| `openclaw cron run <id>` | Yes | Explicit manual trigger — never called by automation scripts |

## Potential Indirect Trigger: Gateway Restart

The one scenario where an edit could indirectly cause a job to fire:

1. `apply-cron.sh` Phase 2b patches `jobs.json` directly (to clear model fields).
2. This creates the restart marker `/tmp/openclaw-deploy-needs-restart`.
3. `deploy.sh` reads the marker and runs `openclaw gateway restart`.
4. On gateway restart, jobs with `wakeMode: "now"` that are past their scheduled time will fire immediately.

This is NOT triggered by `cron edit` itself — it's a consequence of the gateway restart picking up overdue jobs. And it only applies to jobs whose schedule time has already passed (i.e., they were overdue at restart time, which is normal catch-up behavior).

## If Unexpected Fires Were Observed

Possible causes to investigate:

1. **Gateway restart coincidence:** A restart happened around the same time as a cron edit, and an overdue job fired on wake.
2. **Manual `openclaw cron run`:** Someone ran this command explicitly.
3. **`--delete-after-run` / `--at` one-shot jobs:** These have special firing semantics, but none of the jobs in `jobs-config.json` use them.
4. **OpenClaw gateway bug:** Possible undocumented behavior on the gateway side when a job config changes mid-schedule-cycle.

## Files Examined

- `/Users/<hostname>/openclaw-agents/scripts/apply-cron.sh`
- `/Users/<hostname>/openclaw-agents/scripts/deploy.sh`
- `/Users/<hostname>/openclaw-agents/scripts/lib/cron-utils.sh`
- `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json`
- `openclaw cron --help`, `openclaw cron add --help`, `openclaw cron edit --help`, `openclaw cron run --help` (live CLI)
