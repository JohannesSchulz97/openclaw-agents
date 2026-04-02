# Research: OpenClaw Repo Separation - Feasibility Analysis

**Date:** 2026-04-01
**Scope:** Evaluate separating git repo (dev machine) from OpenClaw host (~/.openclaw/ only)
**Method:** Direct filesystem inspection, script analysis, symlink tracing

---

## Executive Summary

**The current architecture is deeply entangled with the git repo on the same machine.** A clean separation is possible but requires resolving seven distinct problem categories, two of which are blockers requiring code changes before migration can proceed. The rest are solvable with process changes.

The central issue: stow creates symlinks from `~/.openclaw/` into `~/openclaw-agents/.openclaw/`. Almost nothing in `~/.openclaw/agents/` is a real file today. Nearly everything is a symlink pointing into the repo tree.

---

## 1. Agent Runtime Writes

### What Files Agents Create or Modify at Runtime

Verified by inspecting `~/.openclaw/agents/dev1/`, `dev10/`, `dev10/`, `dev10/`, and `tech-manager/`.

**Files that ARE real files (not symlinks) and written at runtime:**

| File | Location | Who Writes | Notes |
|------|----------|------------|-------|
| `IDENTITY.md` | `~/.openclaw/agents/<name>/IDENTITY.md` | Agent (during bootstrap) | Real file, excluded from stow via `.stow-local-ignore`. Also a real file in the repo. |
| `USER.md` | `~/.openclaw/agents/<name>/USER.md` | Agent (during bootstrap, ongoing updates) | Same. Real file in repo AND in ~/.openclaw/. |
| `.agent-type` | `~/.openclaw/agents/<name>/.agent-type` | `create-agent.sh` | Real file, excluded from stow. Not synced. |
| `memory/YYYY-MM-DD.md` | `~/.openclaw/agents/<name>/memory/` | Agent (daily summaries, notes) | Real files. `memory/` directory entirely excluded from stow. NOT in repo (gitignored). |
| `memory/poll-state.json` | `~/.openclaw/agents/<name>/memory/` | `checkin-guard.sh` | Real file in `memory/`, NOT in repo (gitignored). |
| `memory/heartbeat-state.json` | `~/.openclaw/agents/<name>/memory/` | Agent (heartbeat tracking) | Real file, if it exists. NOT in repo. |
| `memory/MEMORY.md` | `~/.openclaw/agents/<name>/memory/` OR as symlink | Agent (long-term memory) | Observed as **symlink** for dev10 pointing into repo. This is a stow artifact that has NOT been protected. |
| `.BOOTSTRAP.md.done` | `~/.openclaw/agents/<name>/` | Agent (bootstrap completion) | Excluded from stow. Gitignored. But observed as **symlink** for dev1 pointing into repo (the repo copy was adopted). |

**Files that are SYMLINKS into the repo (not real files in ~/.openclaw/):**

These are the stow-managed symlinks. Everything not excluded by `.stow-local-ignore` becomes a symlink:

- `AGENTS.md` -> `openclaw-agents/.openclaw/agents/<name>/AGENTS.md`
- `SOUL.md` -> `openclaw-agents/.openclaw/agents/<name>/SOUL.md`
- `TOOLS.md` -> `openclaw-agents/.openclaw/agents/<name>/TOOLS.md`
- `HEARTBEAT.md` -> `openclaw-agents/.openclaw/agents/<name>/HEARTBEAT.md`
- `BOOTSTRAP.md` -> `openclaw-agents/.openclaw/agents/<name>/BOOTSTRAP.md`
- `DAILY-SUMMARY.template.md` -> `openclaw-agents/.openclaw/agents/<name>/DAILY-SUMMARY.template.md`
- `poll-config.json` -> `openclaw-agents/.openclaw/agents/<name>/poll-config.json`
- `scripts/` -> individual script files symlinked into `openclaw-agents/.openclaw/agents/<name>/scripts/`
- `work-schedule.json` -> **symlink into repo** (observed for dev1, dev10, dev10, dev10)

**Critical: `work-schedule.json` is currently a SYMLINK into the repo for all bootstrapped agents.** This means `stow --adopt` pulled it from `~/.openclaw/` into the repo. It exists as a real file in `~/openclaw-agents/.openclaw/agents/<name>/work-schedule.json`. If the repo is removed from the host, agents lose access to their work schedules.

**Special cases observed:**

- `dev10/MEMORY.md`: Symlink into repo (`../../../openclaw-agents/.openclaw/agents/dev10/MEMORY.md`). This file was NOT supposed to be stowed (MEMORY.md is in `memory/` conventionally, but dev10's was at the root level and got adopted by stow).
- `dev1/.BOOTSTRAP.md.done`: Symlink into repo. The `.stow-local-ignore` pattern excludes this, but the symlink exists anyway, suggesting it was created before the ignore rule was added or the ignore didn't apply retroactively.

**Summary of what agents write at runtime:**

1. `memory/*.md` - daily notes, MEMORY.md (if stored there)
2. `memory/poll-state.json` - check-in state
3. `IDENTITY.md`, `USER.md` - during/after bootstrap
4. `.BOOTSTRAP.md.done` - bootstrap completion marker
5. `work-schedule.json` - during bootstrap (currently stow-adopted into repo)
6. `memory/heartbeat-state.json` - heartbeat tracking
7. `outbox/` - delivery queue (observed in dev1)
8. `reports/` - reports (observed in dev1)

---

## 2. The Feedback Loop Problem

### What `stow --adopt` Currently Captures

`stow --adopt` pulls any file from `~/.openclaw/` back into the repo before `stow` overwrites it. This currently captures:

- **work-schedule.json** (most important): agent-written during bootstrap, now lives in repo
- **IDENTITY.md**: agent-written, lives in repo (not gitignored, tracked)
- **USER.md**: agent-written, lives in repo (not gitignored, tracked)
- **MEMORY.md** (for dev10): unexpectedly ended up in the repo-side directory
- **.BOOTSTRAP.md.done** (for some agents): marker pulled into repo

From `git diff --name-only`: currently only `.openclaw/agents/dev7/IDENTITY.md` shows as modified, meaning dev7 recently updated their IDENTITY.md and it hasn't been committed yet.

### The Feedback Loop Without Repo on Host

If the repo is on a different machine:

**Problem 1 - work-schedule.json**: When a new agent completes bootstrap and writes `work-schedule.json`, that file exists only in `~/.openclaw/agents/<name>/`. There is no mechanism to get it back into the repo without SSH/manual copy. `check-cron-activation.sh` reads from `~/.openclaw/agents/<name>/work-schedule.json`, so the cron activation still works. But the file is not version-controlled, and if it's ever needed again (re-running stow, new host), it's lost.

**Problem 2 - IDENTITY.md / USER.md**: These are tracked in git (not gitignored). If an agent updates them and there's no repo on the host, the update is only in `~/.openclaw/` and is never committed. On next stow, the file would be overwritten with the old repo version.

**Problem 3 - Version control of agent identity data**: Currently the workflow `stow --adopt && stow` preserves runtime writes. Without repo on host, this workflow is impossible.

**Do we even need to?** The memory files (`YYYY-MM-DD.md`, `poll-state.json`) are intentionally gitignored. They do NOT need version control. Only `IDENTITY.md`, `USER.md`, and `work-schedule.json` would benefit from it, and primarily only for disaster recovery (re-deployment).

**Recommendation**: Accept that `IDENTITY.md`, `USER.md`, and `work-schedule.json` must be copied back to the dev machine periodically (rsync or similar) or excluded from stow's management entirely.

---

## 3. Scripts That Reference Repo Paths

### Hard-Coded Repo Path Reference: BLOCKER

**`check-cron-activation.sh` (types/manager/scripts/)** at lines 23-28:

```bash
for candidate in "$HOME/openclaw-agents" "$(dirname "$(dirname "$(dirname "$SCRIPT_DIR")")")"; do
    if [[ -f "$candidate/scripts/update-cron-schedule.sh" ]]; then
        REPO_ROOT="$candidate"
        break
    fi
done

if [[ -z "$REPO_ROOT" ]]; then
    json_error "check-cron-activation" "MISSING_REPO" "Cannot find openclaw-agents repo with update-cron-schedule.sh"
    exit 1
fi
```

This script **explicitly looks for `~/openclaw-agents`** as a primary candidate. It then falls back to walking up from `$SCRIPT_DIR`. Since `$SCRIPT_DIR` resolves through the symlink chain to the repo (scripts are symlinked), the fallback also resolves to the repo.

**Without the repo on the host, this script will fail with:** `MISSING_REPO: Cannot find openclaw-agents repo with update-cron-schedule.sh`

This is the automatic cron activation for newly bootstrapped agents. **This is a hard blocker** for the separation plan.

**`update-cron-schedule.sh` (scripts/)** at lines 8-9:

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
```

Then at line 41: `CRON_CONFIG="$REPO_ROOT/.openclaw/cron/jobs-config.json"`

This script is in the repo's `scripts/` directory. It's called by `check-cron-activation.sh`. Both are repo-resident scripts. Without the repo on the host, neither can be called.

**`apply-cron.sh` (scripts/):**

Uses `REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"` and then reads `$REPO_ROOT/.openclaw/cron/jobs-config.json`. This script lives in the repo and MUST be run from the repo. It is not stowed into `~/.openclaw/`.

**`jobs-config.json` is a symlink into the repo:**

```
~/.openclaw/cron/jobs-config.json -> ../../openclaw-agents/.openclaw/cron/jobs-config.json
```

Without the repo on the host, `~/.openclaw/cron/jobs-config.json` becomes a dangling symlink. OpenClaw may read this file directly. If it does, cron configuration is inaccessible.

### Scripts That Use `$HOME/.openclaw/` Directly (Safe)

The following scripts use `$HOME/.openclaw/agents` (not repo paths) and would work fine after separation:

- `collect-daily-notes.sh`: Uses `BASE_DIR="$HOME/.openclaw/agents"` - safe
- `check-status.sh`: Uses `BASE_DIR="$HOME/.openclaw/agents"` - safe
- `check-missed-checkins.sh`: Uses `BASE_DIR="$HOME/.openclaw/agents"` - safe
- `checkin-guard.sh`: Uses `$(dirname "$SCRIPT_DIR")` which resolves to agent dir in `~/.openclaw/` - safe
- `github-activity.sh`: Uses `$SCRIPT_DIR` only for sourcing `lib/json-response.sh` - safe

### Scripts Dir Symlinks

Every script in `~/.openclaw/agents/<name>/scripts/` is currently a symlink into the repo:
```
checkin-guard.sh -> ../../../../openclaw-agents/.openclaw/agents/dev1/scripts/checkin-guard.sh
```

Without the repo on the host, these symlinks become dangling. Agents cannot run any scripts. **This is a hard blocker.**

---

## 4. OpenClaw Architecture Questions

### Agent Workspace Root

From filesystem inspection, the agent's workspace root is `~/.openclaw/agents/<name>/`. OpenClaw reads files relative to this directory:
- `AGENTS.md`, `SOUL.md`, `IDENTITY.md`, `USER.md` - loaded at session start
- `sessions/sessions.json` - session state
- `memory/` - agent memory files
- `scripts/` - executable tools

### Does OpenClaw Assume a Git Repo?

No evidence found that OpenClaw itself checks for or requires a git repository. It operates entirely within `~/.openclaw/`. The repo dependency is entirely in the management tooling (`apply-cron.sh`, `sync-agents.sh`, `update-cron-schedule.sh`, `check-cron-activation.sh`) and in the stow-based deployment model.

### Can Agents Access Files Outside `~/.openclaw/agents/<name>/`?

Yes. Agents can read any file accessible to the OpenClaw process. The constraint is logical (AGENTS.md instructs agents not to run git/gh commands), not a technical sandbox. Scripts run by agents inherit full filesystem access.

The `collect-daily-notes.sh` script specifically reads across ALL agent directories at `$HOME/.openclaw/agents/*/memory/$DATE.md`, which is cross-agent access within `~/.openclaw/`.

---

## 5. Cron and Session Management

### apply-cron.sh Requires the Repo

`apply-cron.sh` is a repo-level script (not stowed). It:
1. Reads its location to find `REPO_ROOT`
2. Reads `$REPO_ROOT/.openclaw/cron/jobs-config.json`
3. Calls `openclaw cron add/edit/rm` commands

If the repo is not on the host, `apply-cron.sh` cannot be run at all. Cron job management must be done manually via `openclaw cron` commands, or `apply-cron.sh` must be copied to the host as a standalone script with a hardcoded path to `jobs-config.json`.

### Session Files

Session files live in `~/.openclaw/agents/<name>/sessions/` (gitignored). They contain no repo paths. The `sessions.json` file is read by multiple scripts using `$AGENT_DIR/sessions/sessions.json` where `$AGENT_DIR` is `~/.openclaw/agents/<name>/`. These are self-contained within `~/.openclaw/`.

### jobs-config.json Symlink

`~/.openclaw/cron/jobs-config.json` is currently a symlink into the repo. Without the repo:
- If OpenClaw reads this file directly (likely), cron configuration becomes inaccessible
- `jobs.json` (runtime, real file) would still exist but couldn't be updated from config

---

## 6. The stow --adopt Use Case

### What Gets Adopted in Practice

Current state: `git diff --name-only` shows only `.openclaw/agents/dev7/IDENTITY.md` as modified.

The adopt mechanism captures runtime changes that agents write to files that stow would otherwise overwrite:
- `work-schedule.json` (now in repo for all bootstrapped agents)
- `IDENTITY.md` (agents update this post-bootstrap; tracked in repo)
- `USER.md` (agents update this; tracked in repo)
- `MEMORY.md` (if mistakenly placed at agent root rather than in `memory/`)
- `.BOOTSTRAP.md.done` (if agent creates it before the ignore rule was enforced)

Without the repo on the host, the adopt mechanism is impossible. Any agent update to `IDENTITY.md` or `USER.md` would be lost the next time those files are deployed from repo to host.

---

## 7. Daily Summaries and Cross-Agent Access

### collect-daily-notes.sh

```bash
BASE_DIR="$HOME/.openclaw/agents"
for agent_dir in "$BASE_DIR"/*/; do
    note_file="$agent_dir/memory/$DATE.md"
    cat "$note_file"
done
```

This script uses `$HOME/.openclaw/agents` exclusively. It does NOT reference the repo. It reads:
- `$agent_dir/.agent-type` (real file, safe)
- `$agent_dir/IDENTITY.md` (real file in `~/.openclaw/`, safe)
- `$agent_dir/memory/$DATE.md` (real file in `memory/`, safe)

**This script works fine without the repo on the host.**

### MEMORY.md Anomaly

For `dev10`, `MEMORY.md` is a symlink at `~/.openclaw/agents/dev10/MEMORY.md -> ../../../openclaw-agents/.openclaw/agents/dev10/MEMORY.md`. AGENTS.md instructs agents to store MEMORY.md in `memory/MEMORY.md` (well, actually it says just `MEMORY.md` at the workspace root). The stow-local-ignore only excludes the `memory/` directory, not root-level MEMORY.md files. This means dev10's MEMORY.md went through stow adoption and is now tracked in the repo. Without the repo, this would be a dangling symlink.

---

## Findings Summary: All Limitations and Problems

### HARD BLOCKERS (require code changes before migration)

**B1. All scripts in agent workspace are symlinks into the repo.**
Every script at `~/.openclaw/agents/<name>/scripts/*.sh` symlinks into `~/openclaw-agents/`. Without the repo on the host, no agent can run any script. Agents use scripts for check-ins (`checkin-guard.sh`), GitHub activity (`github-activity.sh`), image generation (`generate-image.sh`).
- **Fix**: Before separation, convert all script symlinks to real file copies. This requires `rsync --delete` (which `sync-agents.sh` does) plus NOT using stow for scripts (or excluding scripts from stow). Alternatively, deliver scripts as real copies into `~/.openclaw/` without stow.

**B2. check-cron-activation.sh hardcodes `~/openclaw-agents` as a lookup path.**
This tech-manager cron job runs hourly to activate schedules for newly bootstrapped agents. It calls `update-cron-schedule.sh` from the repo. Without the repo, this fails entirely, meaning newly bootstrapped agents never get their cron jobs created.
- **Fix**: Refactor `check-cron-activation.sh` to call `openclaw cron add` directly rather than delegating to a repo script. Or copy `update-cron-schedule.sh` to the host at a known path.

**B3. `~/.openclaw/cron/jobs-config.json` is a symlink into the repo.**
If OpenClaw reads this file for cron configuration reference, it will be broken.
- **Fix**: Convert to a real file copy on the host before separation. Keep in sync manually or via rsync.

### SIGNIFICANT LIMITATIONS (operational changes required)

**L1. apply-cron.sh cannot run without the repo.**
Cron job management (adding/editing/removing jobs) relies on this script. Without it, cron changes require manual `openclaw cron` commands or a port of apply-cron.sh logic to run from `~/.openclaw/cron/jobs-config.json` directly.
- **Fix**: Either copy `apply-cron.sh` to the host with adjusted paths, or run cron management from the dev machine via SSH.

**L2. work-schedule.json files are symlinks into the repo for bootstrapped agents.**
All agents with completed work schedules (dev1, dev10, dev10, dev10, etc.) have their `work-schedule.json` as a stow symlink into the repo. Without the repo, these symlinks break, and scripts like `check-cron-activation.sh` and `check-status.sh` which read `work-schedule.json` will see missing files.
- **Fix**: Before separation, convert these symlinks to real files: `cp --remove-destination $(readlink $file) $file` for each.

**L3. No feedback loop for IDENTITY.md / USER.md changes.**
Agents update these files at runtime. Without the repo on the host, changes accumulate only in `~/.openclaw/` and cannot be committed. The next stow deployment would overwrite them.
- **Fix**: Either (a) stop tracking IDENTITY.md and USER.md in git (exclude from stow, accept they're runtime-only), or (b) establish a periodic rsync from host to dev machine.

**L4. sync-agents.sh and stow workflow cannot run without the repo.**
The full sync+stow pipeline (`bash scripts/sync-agents.sh && stow --adopt && stow`) requires the repo. This is the mechanism for deploying config updates to agents.
- **Fix**: On the dev machine, `rsync` updated files from repo to host directly. The sync-agents step could be replaced by rsync of specific files.

**L5. MEMORY.md is a symlink for dev10 (and possibly others via future stow runs).**
If MEMORY.md is placed at agent root level (not in `memory/`), stow will adopt it and it becomes repo-tracked. On host-without-repo, this breaks.
- **Fix**: Ensure MEMORY.md is always stored at `~/.openclaw/agents/<name>/memory/MEMORY.md` (or add MEMORY.md to `.stow-local-ignore`). Convert dev10's current MEMORY.md symlink to a real file.

### MINOR ISSUES (low impact)

**M1. .BOOTSTRAP.md.done is a symlink for some agents.**
For dev1 and others, this marker is a symlink into the repo rather than a real file. On separation, it becomes a dangling symlink, potentially causing agents to re-run bootstrap (AGENTS.md: "if BOOTSTRAP.md exists AND .BOOTSTRAP.md.done does NOT exist, follow bootstrap").
- **Fix**: Convert to real files, or rely on agents not finding `.BOOTSTRAP.md.done` as a valid symlink (OpenClaw may treat broken symlinks as missing).

**M2. outbox/ and reports/ directories are only in some agents.**
Observed in dev1, not others. These are runtime directories, not managed by stow, and would not be affected by separation.

**M3. .openclaw/ subdirectory inside each agent dir.**
Each agent has `~/.openclaw/agents/<name>/.openclaw/` (a hidden subdirectory). This appears to be OpenClaw internal state. It is NOT stowed (not in the repo's `.openclaw/agents/` directories). Safe from separation concerns.

---

## Migration Prerequisites Checklist

Before removing the repo from the OpenClaw host:

1. **Convert all script symlinks to real files.** For each agent, do `rsync -a ~/.openclaw/agents/<name>/scripts/ ~/.openclaw/agents/<name>/scripts/` won't work since source and dest are the same. Need to: read symlink targets, copy files to a temp location, replace symlinks with real copies.

2. **Convert `~/.openclaw/cron/jobs-config.json` from symlink to real file.**

3. **Convert `work-schedule.json` symlinks to real files for all agents.**

4. **Convert `.BOOTSTRAP.md.done` symlinks to real files.**

5. **Convert `dev10/MEMORY.md` symlink to real file.**

6. **Refactor `check-cron-activation.sh`** to remove `~/openclaw-agents` dependency. It should call `openclaw cron` commands directly instead of delegating to repo scripts.

7. **Copy or rewrite `apply-cron.sh`** to be host-runnable without a repo (or manage cron only from dev machine via SSH).

8. **Establish rsync or deploy workflow** from dev machine to host for config updates (replacing the stow+sync pipeline).

9. **Add `MEMORY.md` (at agent root) to `.stow-local-ignore`** to prevent future stow adoption of this file.

---

## Architecture Observations

The stow model creates a fundamental tension: stow's job is to manage symlinks, but OpenClaw's security model rejects symlinks that resolve outside the workspace root. This is why scripts are real copies in the repo-side directory (`openclaw-agents/.openclaw/agents/<name>/scripts/`) but then symlinked into `~/.openclaw/agents/<name>/scripts/`. From OpenClaw's perspective, the scripts ARE in the workspace (following the symlink), but OpenClaw doesn't see them as outside the workspace root because the symlink is within `~/.openclaw/agents/<name>/`.

The stated boundary in CLAUDE.md — "OpenClaw rejects symlinks that resolve outside the agent workspace root" — doesn't seem to be enforced for scripts (they resolve far outside the workspace to `~/openclaw-agents/`). Either the enforcement only applies to specific file types, or the scripts mechanism bypasses this check.

---

*Research saved to: /Users/<hostname>/openclaw-agents/docs/research/openclaw-repo-separation-analysis-2026-04-01.md*
*No ticketing context provided — file-based capture only.*
