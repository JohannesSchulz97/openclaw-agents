# OpenClaw deleteAfterRun Cron Behavior Investigation

**Date:** 2026-03-30
**Investigator:** Research Agent
**Classification:** Actionable -- stale disabled jobs require cleanup

---

## Summary

`deleteAfterRun` on OpenClaw cron jobs does NOT delete the job after execution. Instead, it sets `enabled: false`. This is **expected behavior by design** -- the CLI explicitly offers both `--delete-after-run` and `--keep-after-run` flags, and the naming is misleading. The actual behavior is "disable after successful run."

However, the result is **16 stale disabled jobs out of 22 total** in `jobs.json`, all of which are one-shot Bootstrap Trigger/Retry jobs that will never run again and should be cleaned up.

---

## Findings

### 1. Stale Disabled Jobs (16 total)

| Job Name | Count | deleteAfterRun |
|----------|-------|----------------|
| Bootstrap Trigger (various agents) | 13 | true |
| Bootstrap Retry (dev10, dev7) | 2 | true |
| Developer Check-in (legacy) | 1 | false (null) |

All 15 `deleteAfterRun: true` jobs are disabled (enabled: false), confirming the pattern: after successful run, they were disabled but not removed.

The legacy "Developer Check-in" job is also disabled but was not a deleteAfterRun job -- it was manually disabled during migration.

### 2. deleteAfterRun Behavior -- Expected, Not a Bug

From `openclaw cron add --help`:
- `--delete-after-run`: "Delete one-shot job after it succeeds" (default: false)
- `--keep-after-run`: "Keep one-shot job after it succeeds" (default: false)

Despite the flag name saying "delete," the actual implementation only disables. This appears to be a known design decision or upstream bug in OpenClaw that has been stable for a while. The `--keep-after-run` flag suggests there was intent to support actual deletion, but the implementation only toggles the enabled state.

### 3. Cleanup Command Available

`openclaw cron rm <id>` (aliases: `remove`, `delete`) exists and can permanently remove jobs:

```bash
openclaw cron rm <job-id>
```

### 4. Active Jobs (6 of 22)

Only 6 jobs are actually enabled and running:
- Tech Manager: Hourly Monitoring, Morning Report, Evening Report
- dev1: Morning, Midday, Evening Check-ins

---

## Recommendation

**Clean up the 16 disabled jobs** using `openclaw cron rm`. They are dead weight in jobs.json.

### Cleanup Script

```bash
# Remove all disabled deleteAfterRun bootstrap jobs
for id in \
  e7cdcd66-6c6a-493d-b73f-171c8e557fa4 \
  b084a94c-cac6-4d21-b822-079b96117c63 \
  1b665db0-322d-4dc3-b06f-8b3c6646222b \
  519f4862-b580-432c-bd6c-e67f70239183 \
  e3992bde-a93b-4a26-8d99-ae9b963ce7c8 \
  68c1d2f4-30b6-49b7-b292-7077ddd4c848 \
  e93b0c0e-4364-42cb-a5a5-14ce99a1c867 \
  9dacf99f-b305-4fd7-aed0-5b47479f1931 \
  80910f84-6540-4215-9a1d-90f5ea467ff9 \
  4869183f-562f-4a5c-a2ae-5132d0139712 \
  d2438792-92e2-4ee5-b1f2-7ef1ea5e0c33 \
  def396b6-8bb4-466e-89c1-20bde9ccf0c7 \
  b06a3ed5-8d23-43f1-848a-b0acdec3dfae \
  9e3c5ea7-7709-4968-ae03-c8bb3e84a8cb \
  095e9697-804d-4b76-99e7-f1ae20187f02; do
  echo "Removing $id..."
  openclaw cron rm "$id"
done

# Also remove legacy disabled Developer Check-in
openclaw cron rm 8ef689e2-00c6-45a1-939d-a76e6a378549
```

### Preventive Measure

For future one-shot jobs, either:
1. Accept the disable-not-delete behavior and schedule periodic cleanup
2. File an issue upstream with OpenClaw about `deleteAfterRun` not actually deleting
3. Add a post-run cleanup step to `apply-cron.sh` that removes disabled `deleteAfterRun` jobs

---

## Verdict

| Question | Answer |
|----------|--------|
| Is this a bug? | Likely a naming/implementation mismatch upstream. The flag says "delete" but the behavior is "disable." |
| Is this expected? | Yes, in practice. The codebase has both `--delete-after-run` and `--keep-after-run`, suggesting the design intent may have been actual deletion, but the implementation only disables. |
| Is there a cleanup command? | Yes: `openclaw cron rm <id>` permanently removes jobs. |
| Impact? | 16 dead jobs cluttering jobs.json. No functional impact but messy. |
