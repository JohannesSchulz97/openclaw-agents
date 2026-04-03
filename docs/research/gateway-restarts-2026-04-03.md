# Gateway Restart Investigation — 2026-04-03

## Summary

The OpenClaw gateway restarted approximately 9-10 times today because there were 9 pushes to `main` today, and **every single deploy unconditionally triggers a gateway restart**. There is no cooldown, dedup, or guard mechanism.

## Findings

### 1. GitHub Actions Runs Today

9 successful Deploy workflow runs fired today (2026-04-03), in addition to 1 run from the night before (2026-04-02 at 00:07 UTC which is 05:37 IST — within the same work day for IST):

| Time (UTC) | Commit |
|---|---|
| 2026-04-03 00:07 | fix: route cron check-ins to DM session (#129, #134) |
| 2026-04-03 01:16 | fix: bump cron timeout from 180s to 300s (#138) |
| 2026-04-03 01:35 | feat: enhance daily summary template and cron prompt (#136) |
| 2026-04-03 01:44 | fix: route tech-manager cron to channel session (#135, #140) |
| 2026-04-03 01:46 | chore: disable tech-manager morning status report (#141) |
| 2026-04-03 04:09 | fix: create-agent.sh sets workspace to live stow path (#142) |
| 2026-04-03 04:15 | docs: require dev/host machine separation in issues and tasks (#145) |
| 2026-04-03 04:55 | fix: route tech-manager operational alerts to #<manager-agent>-feedback (#149) |
| 2026-04-03 08:38 | feat: proactive bootstrap with per-field state tracking (#150) |

That is 9 deploys today, producing 9 gateway restarts. The burst between 01:16–01:46 UTC (4 deploys in 30 minutes) matches the pattern of rapid hot-fixing a chain of cron routing issues.

### 2. How deploy.sh Decides to Restart

`scripts/deploy.sh` runs this logic on every deploy:

```
needs_restart=false
if [ "$FORCE_RESTART" = true ]; then     # --force-restart flag
  needs_restart=true
elif [ -f "/tmp/openclaw-deploy-needs-restart" ]; then  # restart marker
  needs_restart=true
fi
```

The restart marker is created by `scripts/apply-cron.sh` **Phase 2b**, which fires whenever any cron job config entry has no `payload.model` field and that job already exists in the gateway.

### 3. The Unconditional Restart Trigger

**Every job in `jobs-config.json` has no `payload.model` set** (0 out of 71 jobs have a model value). The MEMORY.md notes this is intentional: models were removed from per-job payloads to inherit from `agents.defaults.model`.

This means:
- Phase 2: EDIT runs on every existing job (23 jobs currently active)
- For each edited job with no model, `apply-cron.sh` adds that gateway ID to `CLEAR_MODEL_IDS`
- Phase 2b then patches `~/.openclaw/cron/jobs.json` directly for all 23 jobs
- Since `PHASE2B_PATCHED > 0`, the restart marker is always written
- `deploy.sh` finds the marker and restarts the gateway

**This means every deploy to main unconditionally restarts the gateway**, because Phase 2b always fires (all 23 active jobs have no model in config and thus always need model-clearing in the live jobs.json).

### 4. Is There a Cooldown or Dedup Mechanism?

No. There is:
- No minimum interval between restarts
- No check for "was there a restart in the last N minutes?"
- No batching of rapid successive deploys
- The restart marker is deleted immediately after restart (`rm -f "$RESTART_MARKER"`), but a new deploy arriving seconds later will write a new marker

The deploy workflow also has no concurrency control — two pushes that land seconds apart will both queue separate runner jobs that each restart the gateway.

### 5. What Changed Today That Caused So Many Runs

Today was an active bug-fix day for cron routing issues (PRs #134, #138, #139, #140, #141) and workspace path fixes (#142), docs (#145), alert routing (#149), and a new bootstrap feature (#150). The burst of 4 PRs merged within 30 minutes (01:16–01:46 UTC) is the densest concentration.

## Root Cause

**The restart marker is not the problem per se — the problem is that Phase 2b fires on every deploy because all job configs intentionally omit the `payload.model` field.** Phase 2b was designed to handle the model-clearing migration, but now that the migration is permanent (no jobs have models), Phase 2b always runs, always patches jobs.json, and always creates the restart marker. This makes the restart unconditional rather than exception-based.

## Implications

- 9 restarts in a day is not dangerous but it does interrupt active agent sessions each time
- The restarts during the 01:16–01:46 burst (4 in 30 minutes) would have interrupted any morning check-ins in progress for dev1 or other agents in that timezone window
- There is no data loss from restarts themselves, but sessions mid-conversation would be dropped

## Potential Fixes (Not Implemented)

1. **Short-circuit Phase 2b when jobs.json already has null models**: Before patching, check if the model field is already null. If so, skip the patch and do not write the restart marker. This would eliminate most restarts.

2. **Add restart cooldown in deploy.sh**: If a restart occurred less than N minutes ago (check a timestamp file), skip restarting and let the next deploy pick it up.

3. **Concurrency control in the workflow**: Add `concurrency: group: deploy` with `cancel-in-progress: false` so rapid pushes queue up and only the latest actually runs, or at minimum so two deploys can't overlap and both restart.

4. **Batch merges**: For rapid sequential fixes, merge them in a single PR to reduce deploy count. Already partially done via stacked PRs on some days.

The cleanest fix is option 1 — make Phase 2b idempotent so it only writes the restart marker when it actually changes something in jobs.json.
