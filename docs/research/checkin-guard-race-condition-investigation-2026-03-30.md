# Investigation: checkin-guard.sh Changes Lost After Parallel QA + Stow

**Date:** 2026-03-30
**Status:** Root cause identified with high confidence

## Executive Summary

The engineer's changes to `types/dev-pa/scripts/checkin-guard.sh` **are currently present** in the working tree (uncommitted). All 17 agent copies in `.openclaw/agents/*/scripts/` also contain the changes. The live `~/.openclaw/` symlinks resolve correctly to these files. However, the changes were **never committed** -- they exist only as unstaged modifications.

The most likely cause of the QA failure was a **race condition between `sync-agents.sh` (QA step 2) and `stow --adopt` (Ops step 3) running in parallel**, where `stow --adopt` temporarily overwrote the synced copies with stale versions from `~/.openclaw/`.

## Evidence

### 1. Current State of Files

**`types/dev-pa/scripts/checkin-guard.sh`** (source of truth):
- Has engineer's changes (uncommitted, shown by `git diff`)
- Last commit touching this file: `5ea7a35` ("feat: add 3-slot poll-state schema and checkin-guard script") -- the ORIGINAL commit, not the engineer's edits
- Changes include: state consistency validation (Bug 1), inter-day state hygiene (Bug 3), `checkin_dispatched` field rename, `last_state_date` field

**All 17 `.openclaw/agents/*/scripts/checkin-guard.sh` copies:**
- All contain the engineer's fixes (10 marker lines each)
- All have identical modification timestamp: `Mar 31 07:22:43 2026`
- This timestamp matches `types/dev-pa/scripts/checkin-guard.sh` exactly

**Live `~/.openclaw/` copies:**
- Are symlinks pointing back to repo `.openclaw/agents/*/scripts/checkin-guard.sh`
- Resolve correctly and contain the fixes

### 2. The Race Condition Explained

The reported sequence was:
1. Engineer edits `types/dev-pa/scripts/checkin-guard.sh` -- SUCCESS
2. QA runs `sync-agents.sh` (copies types/ -> .openclaw/agents/) -- SUCCESS
3. Ops runs `stow --adopt` then `stow` **IN PARALLEL with step 2**

**What `stow --adopt` does:**
- Pulls files FROM `~/.openclaw/` INTO the repo's `.openclaw/` directory
- If `~/.openclaw/agents/dev1/scripts/checkin-guard.sh` was a symlink to the repo copy, `--adopt` replaces the repo file with whatever the symlink points to (which is the same file -- no-op in this case)
- But if the symlink was already resolved/broken, or if `sync-agents.sh` was mid-write, `--adopt` could pull a STALE copy

**The race condition window:**

```
Timeline:
  sync-agents.sh starts copying types/ -> .openclaw/agents/dev1/scripts/
  |                                                                          |
  |  stow --adopt reads ~/.openclaw/agents/dev1/scripts/checkin-guard.sh |
  |  (symlink resolves to .openclaw/ copy which is MID-WRITE or PRE-SYNC)   |
  |                                                                          |
  sync-agents.sh finishes writing new copy
  |
  stow (second command) re-creates symlinks from .openclaw/ -> ~/.openclaw/
  (but .openclaw/ copy may have been overwritten by --adopt with old version)
```

**Critical detail:** `stow --adopt` does NOT touch `types/dev-pa/scripts/checkin-guard.sh`. The `types/` directory is excluded from the stow tree (listed in `.stow-local-ignore`). This is why the source file survived -- the race only affected the `.openclaw/agents/*/` copies.

### 3. Why QA Tests Failed

After the parallel execution:
1. `stow --adopt` may have pulled pre-sync (old) versions from `~/.openclaw/` into `.openclaw/agents/*/`
2. The subsequent `stow` command then pushed these old versions back out to `~/.openclaw/`
3. QA tests ran against the live `~/.openclaw/` path, which now had old versions

### 4. Why Changes Are Present Now

Someone (likely the QA agent or a subsequent sync) re-ran `sync-agents.sh` after the stow commands completed. Evidence: all 17 agent copies have identical timestamps (`Mar 31 07:22:43 2026`), matching the types/ source. This is characteristic of a `sync-agents.sh` run, not stow.

## Key Question Answers

**Q: Could `stow --adopt` have caused this?**
A: YES, with high confidence. `stow --adopt` running in parallel with `sync-agents.sh` creates a classic TOCTOU (time-of-check-time-of-use) race. The adopt command reads files that sync is actively writing.

**Q: Did `stow --adopt` affect `types/dev-pa/scripts/checkin-guard.sh`?**
A: NO. The `types/` directory is excluded from the stow tree via `.stow-local-ignore`. The engineer's source edits were never at risk. Only the `.openclaw/agents/*/` copies were affected.

**Q: Was the file modified and then reverted?**
A: No revert in git history. The file has never been committed with the engineer's changes -- there is only one commit (`5ea7a35`) touching this file, which is the original creation. The engineer's changes remain uncommitted.

**Q: Are the changes present now?**
A: YES. Both `types/dev-pa/scripts/checkin-guard.sh` and all 17 agent copies contain the fixes. The live `~/.openclaw/` symlinks resolve to the correct files.

## Root Cause

**Parallel execution of `sync-agents.sh` and `stow --adopt`** created a race condition where `stow --adopt` could read mid-sync or pre-sync file states from `~/.openclaw/` and write them back into the repo's `.openclaw/` directory, overwriting the freshly-synced copies.

## Recommendations

1. **Never run sync and stow in parallel.** Enforce sequential execution:
   ```bash
   bash scripts/sync-agents.sh && cd ~/openclaw-agents/.openclaw && stow --adopt --no-folding -t ~/.openclaw . && stow --no-folding -t ~/.openclaw .
   ```

2. **Commit the engineer's changes.** They are currently uncommitted and at risk of being lost by any `git checkout`, `git stash`, or accidental `stow --adopt`:
   ```bash
   git add types/dev-pa/scripts/checkin-guard.sh
   git commit -m "fix: add state consistency validation and day-boundary reset to checkin-guard"
   ```

3. **Add a lock file mechanism** to `sync-agents.sh` and `apply-cron.sh` (or a wrapper script) to prevent concurrent stow operations.

4. **Document the ordering requirement** in CLAUDE.md under the "Sync and Stow Workflow" section: sync MUST complete before stow begins.

## Risk Assessment

The uncommitted changes in `types/dev-pa/scripts/checkin-guard.sh` are currently the ONLY copy of the engineer's work. If anyone runs `git checkout -- types/dev-pa/scripts/checkin-guard.sh` or `git stash`, these changes will be lost permanently. Committing them should be the immediate priority.
