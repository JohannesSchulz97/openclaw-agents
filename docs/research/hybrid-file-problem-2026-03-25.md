# Hybrid File Problem: OpenClaw jobs.json and poll-state.json

**Date:** 2026-03-25
**Status:** Investigation Complete
**Classification:** Actionable

---

## Problem Statement

After `stow --no-folding -t ~ .` from the openclaw-agents repo, OpenClaw's `jobs.json` becomes a symlink pointing back into the repo. OpenClaw writes runtime state (timestamps, error counts, durations) into this same file. This causes:

1. `git diff` always shows noise from runtime state changes
2. `git stash`/`git checkout` could overwrite live cron state and break the scheduler
3. Intentional config changes are mixed with runtime churn, making review difficult

## Current Symlink State

```
~/.openclaw/cron/jobs.json -> ../../openclaw-agents/.openclaw/cron/jobs.json  (SYMLINK)
~/.openclaw/agents/dev1/memory/poll-state.json -> ../../../../openclaw-agents/...  (SYMLINK)
```

Both files are actively written to by OpenClaw through the symlinks, causing repo modifications.

## Field Classification: jobs.json

### CONFIG fields (we manage, should be version-controlled)

| Field | Example |
|-------|---------|
| `id` | `"1e14ae94-..."` |
| `agentId` | `"dev1"` |
| `name` | `"dev1 Check-in"` |
| `enabled` | `true` |
| `schedule.kind` | `"every"` |
| `schedule.everyMs` | `7200000` |
| `schedule.anchorMs` | `1774341480360` |
| `sessionTarget` | `"isolated"` |
| `wakeMode` | `"now"` |
| `payload.*` | The full payload block (kind, message, model, thinking, timeoutSeconds) |
| `sessionKey` | `"agent:dev1:main"` |
| `delivery` | `{"mode": "none"}` |

### RUNTIME STATE fields (OpenClaw manages, should NOT be version-controlled)

| Field | Example | Changes on |
|-------|---------|------------|
| `createdAtMs` | `1774250651333` | Job creation only |
| `updatedAtMs` | `1774404843779` | Every edit AND every run |
| `state.nextRunAtMs` | `1774427400024` | Every run |
| `state.lastRunAtMs` | `1774404838990` | Every run |
| `state.lastRunStatus` | `"ok"` | Every run |
| `state.lastStatus` | `"ok"` | Every run |
| `state.lastDurationMs` | `4789` | Every run |
| `state.lastDeliveryStatus` | `"not-delivered"` | Every run |
| `state.consecutiveErrors` | `0` | Every run |
| `state.lastDelivered` | `false` | Every run |

### GRAY AREA fields

| Field | Notes |
|-------|-------|
| `createdAtMs` | Set once, never changes. Safe to track but not meaningful. |
| `updatedAtMs` | OpenClaw updates this on every run AND every edit. Cannot be kept clean. |

## Field Classification: poll-state.json

| Field | Type | Notes |
|-------|------|-------|
| `interval_minutes` | CONFIG | We set this, agents read it |
| `awaiting_response` | RUNTIME | Agents write this on every check-in cycle |
| `last_interaction` | RUNTIME | Previously tracked, currently replaced by `awaiting_response` |

Same problem: config and runtime state mixed in one file.

## OpenClaw CLI Capabilities

### What EXISTS

- `openclaw cron add` -- Full CLI for creating jobs with all config fields
- `openclaw cron edit <id>` -- Full CLI for patching any config field on existing jobs
- `openclaw cron list --json` -- Export current jobs as JSON
- `openclaw cron rm <id>` -- Delete a job
- `openclaw cron enable/disable <id>` -- Toggle jobs
- `openclaw cron status` -- Shows `storePath: ~/.openclaw/cron/jobs.json`

### What DOES NOT EXIST

- No `cron.stateFile` config key (checked via `openclaw config get`)
- No `cron.jobsFile` config key
- No way to tell OpenClaw to store state separately from config
- No `cron import` or `cron apply` command
- No native config/state separation

OpenClaw stores everything in one monolithic `jobs.json` and there is no configuration option to change this behavior.

## Current .gitignore

```gitignore
# Runtime artifacts - do not commit
.openclaw/agents/*/sessions/
.openclaw/agents/*/memory/daily/
.openclaw/agents/*/memory/archives/
```

Note: Neither `jobs.json` nor `poll-state.json` is ignored.

## Git Diff Analysis

The current diff shows BOTH types of changes mixed together:

- **Intentional config changes:** `everyMs` changed from 28800000 to 7200000, `message` payload rewritten, `thinking` changed from "off" to "on"
- **Runtime noise:** `updatedAtMs`, `lastRunAtMs`, `lastDurationMs`, `nextRunAtMs` all changed

These are interleaved within the same hunk, making `git add -p` tedious.

---

## Options Analysis

### Option A: .gitignore + CLI-Only Management

**How:** Add `jobs.json` to `.gitignore`, manage jobs purely via `openclaw cron add/edit`.

**Pros:**
- Clean git history, zero noise
- CLI is comprehensive (all config fields supported)
- No symlink needed for jobs.json at all

**Cons:**
- Job definitions are not version-controlled (no history, no review, no rollback)
- New machine setup requires manually re-running CLI commands
- Easy to lose job config if machine is wiped

**Verdict:** Loses too much. We want job configs tracked.

### Option B: Git Clean/Smudge Filter

**How:** Use a git filter that strips `state.*`, `updatedAtMs`, `createdAtMs` on checkout/commit.

**Pros:**
- Transparent to the user
- Config changes tracked cleanly

**Cons:**
- Complex to implement and maintain (JSON-aware filter needed)
- Fragile with JSON formatting changes
- Surprising behavior for collaborators
- Merge conflicts become harder to debug

**Verdict:** Over-engineered for this use case.

### Option C: Accept the Noise, Use `git add -p`

**How:** Manually stage only config changes, ignore state changes.

**Pros:**
- Zero infrastructure
- Works immediately

**Cons:**
- Tedious every single time
- State and config changes are in the same hunk (hard to split)
- Easy to accidentally commit state
- `git stash`/`git checkout` still dangerous for the live system

**Verdict:** Workable short-term but unsustainable.

### Option D: Template File + Apply Script (RECOMMENDED)

**How:**
1. Keep a `jobs-config.json` (or `jobs.template.json`) in the repo with ONLY config fields
2. Remove `jobs.json` from git tracking entirely (add to `.gitignore`)
3. Break the stow symlink for `jobs.json` (let OpenClaw own it directly)
4. Write an `apply-cron.sh` script that reads the template and calls `openclaw cron edit` for each job

**Pros:**
- Clean separation: config in repo, state in OpenClaw's domain
- Version-controlled config with full git history
- Safe `git stash`/`git checkout` (never touches live state)
- Declarative: template is the source of truth for config intent
- CLI handles state management naturally

**Cons:**
- Requires a one-time script to sync template to live
- Template must be maintained alongside CLI edits (discipline needed)
- New jobs require both template update and `openclaw cron add`

**Template format example:**
```json
{
  "jobs": [
    {
      "id": "1e14ae94-94b2-4ab3-81d0-d36814d90eaf",
      "agentId": "dev1",
      "name": "dev1 Check-in",
      "enabled": true,
      "schedule": { "kind": "every", "everyMs": 7200000 },
      "sessionTarget": "isolated",
      "wakeMode": "now",
      "payload": {
        "kind": "agentTurn",
        "message": "...",
        "timeoutSeconds": 120,
        "thinking": "on",
        "model": "fw-mm25"
      },
      "sessionKey": "agent:dev1:main",
      "delivery": { "mode": "none" }
    }
  ]
}
```

**Apply script sketch:**
```bash
#!/bin/bash
# apply-cron.sh - Apply job config template to live OpenClaw cron
for job in $(jq -c '.jobs[]' .openclaw/cron/jobs-config.json); do
  id=$(echo "$job" | jq -r '.id')
  name=$(echo "$job" | jq -r '.name')
  # ... map fields to openclaw cron edit flags
  openclaw cron edit "$id" --name "$name" --every "$(echo "$job" | jq -r '.schedule.everyMs/3600000')h" ...
done
```

### Option E: OpenClaw-Native (NOT AVAILABLE)

There is no OpenClaw-native way to separate config from state. The `storePath` is a single file path with no override. No `cron.stateFile` config key exists. This option does not exist today.

---

## poll-state.json: Same Problem, Different Solution

**Problem:** `poll-state.json` has the same hybrid issue. `interval_minutes` is config, `awaiting_response` is runtime state.

**Key difference:** This file is much simpler (3 fields) and the runtime field changes less frequently (only on check-in cycles, not every 2 hours like cron state).

**Recommended approach:** Split into two files:

1. **`poll-config.json`** (tracked in repo, stowed)
   ```json
   { "interval_minutes": 240 }
   ```

2. **`poll-state.json`** (gitignored, written by agents)
   ```json
   { "awaiting_response": true }
   ```

3. Update `poll-check.sh` to read from both files (merge config + state)
4. Update agent instructions to write only to `poll-state.json`
5. Add `poll-state.json` to `.gitignore`

---

## Recommended Implementation Plan

### Phase 1: Immediate (jobs.json)

1. **Create `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json`** with config-only fields
2. **Add to `.gitignore`:**
   ```
   .openclaw/cron/jobs.json
   ```
3. **Remove `jobs.json` from git tracking:**
   ```bash
   git rm --cached .openclaw/cron/jobs.json
   ```
4. **Unstow and let OpenClaw own `jobs.json` directly:**
   ```bash
   rm ~/.openclaw/cron/jobs.json  # Remove symlink
   cp .openclaw/cron/jobs.json ~/.openclaw/cron/jobs.json  # Copy current state
   ```
5. **Write `apply-cron.sh`** that reads `jobs-config.json` and calls `openclaw cron edit`
6. **Commit** the template file + apply script + .gitignore update

### Phase 2: Follow-up (poll-state.json)

1. **Split into `poll-config.json` + `poll-state.json`**
2. **Add `poll-state.json` to `.gitignore`**
3. **Update `poll-check.sh`** to read both
4. **Update agent AGENTS.md** instructions for the new file split

### Phase 3: Documentation

1. **Update CLAUDE.md** with the new workflow:
   - "After editing jobs-config.json, run `./apply-cron.sh` to sync to live cron"
   - "poll-config.json is tracked; poll-state.json is runtime-only"

---

## Risk Assessment

| Risk | Impact | Mitigation |
|------|--------|------------|
| Forgetting to run apply-cron.sh after config edit | Config drift between template and live | Add pre-commit hook or CI check |
| OpenClaw cron add creates job not in template | Orphan job not tracked | Always add to template first |
| git checkout clobbers live jobs.json | Broken cron scheduler | Fixed by removing from git tracking |
| Template format diverges from CLI flags | Apply script breaks | Keep apply script simple, test after changes |
