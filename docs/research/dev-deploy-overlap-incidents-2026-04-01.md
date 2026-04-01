# Dev/Deploy Overlap Incidents: openclaw-agents Repository

**Date:** 2026-04-01
**Status:** Research Complete
**Scope:** Evidence of problems caused by development and deployment sharing the same machine, where editing the repo and running OpenClaw from ~/.openclaw/ (stow-symlinked to the repo) are the same environment.

---

## Summary

Five distinct categories of confirmed incidents were found. All stem from the fundamental tension that the development workspace (openclaw-agents git repo) and the production runtime (~/.openclaw/) are the same filesystem location. This means git operations, stow operations, and agent runtime activity all collide in the same file tree.

---

## Incident 1: Stow Overwrote Per-Agent Identity Data (CONFIRMED DATA LOSS)

**Date:** 2026-03-30
**Evidence:** MEMORY.md "Stow Safety" section; stow-per-agent-files-investigation-2026-04-01.md; commit 24d6888

**What happened:**
A developer ran `stow` without first running `stow --adopt`. This caused stow to push repo template files (blank IDENTITY.md, blank USER.md) over the live runtime copies that agents had already populated with real developer data. The dev10 and dev10 identity data was lost.

MEMORY.md records this explicitly:
> "Lost dev10/dev10 identity data on 2026-03-30 due to careless stow (needs GH issue)"

The stow-per-agent-files-investigation-2026-04-01.md confirmed that a residual artifact of this incident remains: dev10-jean's live USER.md in ~/.openclaw/ still has empty template placeholders, while the repo copy has enriched data (Name, Timezone, Notes all filled in). The stow protection added afterward prevents both future overwrites AND prevents stow from restoring the enriched data to the live location.

**Root cause:**
Per-agent files (IDENTITY.md, USER.md) were stow-symlinked into ~/.openclaw/ from the repo. When the developer ran `stow` without `--adopt`, stow replaced the live (agent-enriched) copies with repo template copies. The repo templates are blank placeholders.

**Fix applied (commit 24d6888, 2026-03-30):**
- Added .openclaw/.stow-local-ignore to exclude IDENTITY.md, USER.md, .agent-type, memory/ from stow entirely
- Added migrate-per-agent-files.sh to convert any remaining per-agent symlinks to real files
- Documented "always run stow --adopt BEFORE stow" in CLAUDE.md

**Residual risk (confirmed by stow-per-agent-files-investigation-2026-04-01.md):**
Manual `cp` or `rsync` operations that bypass stow still have no protection. Also, if a per-agent file is deleted in ~/.openclaw/ and sync-agents.sh is run, the blank template would be recreated since the guard is `! -f "$dst"`.

---

## Incident 2: Agent Committed a File Directly to the Git Repo (CONFIRMED)

**Date:** 2026-03-27
**Evidence:** GitHub issue #47; GitHub issue #49 (MERGED PR); commit 4377962; commit 5823cf9

**What happened:**
The dev1 agent was asked during a conversation to create a daily update report as a markdown file. Instead of delivering it via Slack message, the agent created the file in its workspace directory and then ran `git add` + `git commit` (or equivalent), committing the file `reports/2026-03-27-daily-update.md` directly to the main branch of the openclaw-agents repository.

Issue #47 states:
> "This has already happened: the dev1 agent committed a report file directly to the repo during a conversation."

PR #49 reverts commit `24ce2ce` (the rogue agent commit) and adds `.openclaw/agents/*/reports/` to .gitignore.

**Root cause:**
The agent's workspace IS the openclaw-agents repo (via stow symlinks). When the agent ran git commands, they operated on the live repository. There was no enforcement preventing this — the only guard was instructional (AGENTS.md said "Commit and push your own changes," which actively encouraged it).

**Fix applied (commit d79511a, 2026-03-31):**
- Removed "Commit and push your own changes" from AGENTS.md proactive work list
- Added explicit git prohibition to AGENTS.md Red Lines section
- The broader investigation (blocking-agent-git-commands-2026-03-31.md) identified that instructional guards alone are insufficient; a layered approach (PATH wrapper, git hooks) was recommended but not yet fully implemented

**Remaining exposure:**
Instructional prohibition is ~70% effective per the research doc. No hard technical block exists at the OpenClaw Gateway level (OpenClaw tool restrictions can deny `exec` entirely but cannot selectively block `git` while permitting other shell commands agents need).

---

## Incident 3: Symlinks Broke After Early Arch Used symlinks Into types/ (CONFIRMED BREAKAGE)

**Date:** 2026-03-25
**Evidence:** commit e075729; commit 62081b5; openclaw-boundary-symlink-bypass-2026-03-25.md

**What happened:**
The initial architecture (commit e075729) implemented shared agent config by making SOUL.md, AGENTS.md, etc. in each agent directory be symlinks pointing into `types/dev-pa/`. When this was stowed to ~/.openclaw/, stow created a second layer of symlinks. The final symlink chain was:

```
~/.openclaw/agents/dev1/SOUL.md
  -> ../../../openclaw-agents/.openclaw/agents/dev1/SOUL.md (stow symlink)
    -> ../../../types/dev-pa/SOUL.md  (repo symlink)
      -> /Users/<hostname>/openclaw-agents/types/dev-pa/SOUL.md  (real file)
```

OpenClaw's boundary security check follows the full symlink chain and checks whether the realpath falls inside the agent workspace root. The realpath `/Users/<hostname>/openclaw-agents/types/dev-pa/SOUL.md` is outside the agent workspace root `~/.openclaw/agents/dev1`, so OpenClaw rejected all file reads with `symlinkEscapeError`.

The research doc (openclaw-boundary-symlink-bypass-2026-03-25.md) confirmed this by reading OpenClaw's compiled boundary check source (`boundary-file-read-Bb0WDUIN.js`) and tracing the exact code path.

**Fix applied (commit 62081b5, same day):**
- Replaced symlinks with real file copies via sync-agents.sh (rsync --delete from types/ into .openclaw/agents/)
- This eliminated the double-symlink problem at the cost of requiring sync-agents.sh to be run whenever type files change

**Ongoing implication:**
The fact that this requires `sync-agents.sh` to be run manually (or via the combined sync+stow command) creates the race condition described in Incident 4.

---

## Incident 4: Race Condition Between sync-agents.sh and stow --adopt Overwrote Freshly-Synced Files

**Date:** 2026-03-30 (investigated) / ongoing risk
**Evidence:** checkin-guard-race-condition-investigation-2026-03-30.md; commit 8e906d5 (added warning to CLAUDE.md); MEMORY.md warning

**What happened:**
The developer edited `types/dev-pa/scripts/checkin-guard.sh` with three bug fixes. During QA, `sync-agents.sh` was run to propagate the changes to all 17 agent copies in .openclaw/agents/*/scripts/. Separately (in parallel), an ops step ran `stow --adopt` followed by `stow`. The race window:

```
sync-agents.sh: writing new checkin-guard.sh to .openclaw/agents/dev1/scripts/
                                                                                  |
stow --adopt:   reads ~/.openclaw/agents/dev1/scripts/checkin-guard.sh        |
                (symlink resolves to the .openclaw/ copy, which is mid-write      |
                or was just written by a previous stow that picked up stale data) |
                overwrites .openclaw/ copy with the stale version                 |
```

The investigation found that the source file in `types/` survived (stow ignore excludes types/), but the `.openclaw/agents/*/` copies could be overwritten with stale versions from ~/.openclaw/ if the timing is wrong.

The changes were not lost in this case (they were present in the working tree uncommitted), but the investigation confirmed the race condition is real and the QA test failure was likely caused by it.

**Fix applied (commit 8e906d5, 2026-03-31):**
CLAUDE.md updated with explicit warning:
> "WARNING: These steps MUST run sequentially (&&), never in parallel. Running stow --adopt before sync completes will overwrite freshly-synced files in .openclaw/ with stale copies from ~/.openclaw/, destroying your changes."

The command was consolidated into a single `&&`-chained command to enforce ordering.

**Ongoing implication:**
The fix is procedural (CLAUDE.md documentation). Nothing prevents a developer from running the steps in parallel or out of order. The ci-deployment-feasibility-2026-04-01.md doc notes this explicitly as a constraint: "stow must run with --adopt before stow to prevent overwriting per-agent runtime files... This is a race-condition-sensitive sequential operation."

---

## Incident 5: Runtime State Files Were Tracked in Git, Causing Constant Noise and Risk

**Date:** 2026-03-25 (initial) / ongoing evolution
**Evidence:** hybrid-file-problem-2026-03-25.md; commit aac6c8d; multiple subsequent gitignore fixes

**What happened:**
Because ~/.openclaw/ is stow-symlinked to the repo, every file that OpenClaw writes at runtime (poll-state.json, jobs.json, workspace-state.json, memory files) was written through a symlink back into the openclaw-agents git repository. This caused:

1. `git diff` always showed runtime noise (lastRunAtMs, nextRunAtMs, updatedAtMs, etc.) mixed with intentional config changes, making reviews difficult and `git add -p` tedious
2. `git stash` or `git checkout` could overwrite live cron state (jobs.json) and break the cron scheduler
3. Agent memory files (daily notes, poll-state) were committed to git, leaking runtime state into version history

The hybrid-file-problem-2026-03-25.md found that jobs.json mixed 12 config fields (intentional, should be tracked) with 9 runtime state fields (OpenClaw manages, should not be tracked) in a single monolithic file with no separation option.

**Fixes applied over multiple commits:**
- commit aac6c8d (2026-03-25): Added SOUL.md, AGENTS.md, TOOLS.md, HEARTBEAT.md, BOOTSTRAP.md, scripts/, poll-state.json, jobs.json, workspace-state.json, memory/ to .gitignore; removed previously tracked agent files from git
- Multiple follow-up gitignore additions (reports/, daily memory notes, bootstrap markers)
- jobs-config.json introduced as the config-only source of truth; jobs.json treated as runtime-only (gitignored)
- apply-cron.sh script written to apply jobs-config.json to live cron without touching jobs.json directly

**Residual risk:**
The jobs-config.json / jobs.json split requires discipline: edits to jobs-config.json only take effect after running apply-cron.sh. It is possible to edit jobs-config.json and forget to apply it, leaving config drift between the repo source of truth and the live cron state.

---

## Pattern: Branch Switching Risk (Documented, No Confirmed Incident)

**Evidence:** MEMORY.md: "Stow requires being on the correct git branch (symlinks break if files don't exist)"

**Description:**
The stow symlink tree from ~/.openclaw/ points to files in the openclaw-agents repo at specific paths. If the developer switches git branches and the branch being checked out does not contain a file that is currently symlinked from ~/.openclaw/, the symlink becomes dangling (broken). OpenClaw then fails to read the file and the agent loses access to its configuration.

No specific incident was found in git history, but the constraint is documented in MEMORY.md as a known risk. The ci-deployment-feasibility-2026-04-01.md also lists branch switching as a hazard for any deployment automation.

---

## Structural Root Cause

All five incidents share the same underlying cause: the repository is simultaneously the development workspace and the production runtime environment. There is no staging layer between "edit in repo" and "running in production."

Specific structural problems:

1. No isolation between dev and prod file trees — edits to types/ are immediately live via stow symlinks
2. No deployment review step — the combined sync+stow command is the entire deployment pipeline
3. Agents have write access to files inside the repo boundary — memory/, poll-state.json, reports/
4. Agents have shell exec access that can run git against the live repo
5. Config files and runtime state files are in the same directories (and historically in the same files)

The ci-deployment-feasibility-2026-04-01.md was produced as a direct result of investigating whether this overlap could be addressed via CI automation (GitHub Actions self-hosted runner). That research found it is feasible but would not eliminate the structural overlap — it would only automate the sync+stow sequence triggered by merges to main.

---

## Files Referenced

- /Users/<hostname>/openclaw-agents/docs/research/stow-per-agent-files-investigation-2026-04-01.md
- /Users/<hostname>/openclaw-agents/docs/research/hybrid-file-problem-2026-03-25.md
- /Users/<hostname>/openclaw-agents/docs/research/blocking-agent-git-commands-2026-03-31.md
- /Users/<hostname>/openclaw-agents/docs/research/openclaw-boundary-symlink-bypass-2026-03-25.md
- /Users/<hostname>/openclaw-agents/docs/research/checkin-guard-race-condition-investigation-2026-03-30.md
- /Users/<hostname>/openclaw-agents/docs/research/ci-deployment-feasibility-2026-04-01.md
- /Users/<hostname>/.claude/projects/-Users-<hostname>-openclaw-agents/memory/MEMORY.md
- Git commits: aac6c8d, e075729, 62081b5, 24d6888, d79511a, 8e906d5, 4377962, 5823cf9, fc7d2dd
- GitHub issues: #47 (agent git prohibition), #49 (rogue agent commit revert)
