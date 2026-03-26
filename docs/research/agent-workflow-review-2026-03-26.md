# Agent Creation/Removal/Sync Workflow Review

**Date:** 2026-03-26
**Scope:** Full review of create-agent.sh, remove-agent.sh, apply-cron.sh, sync-agents.sh, cron-utils.sh, openclaw-utils.sh, templates, and CLAUDE.md accuracy.

---

## Summary

The workflow is well-structured overall. The scripts follow good practices (set -euo pipefail, dry-run support, dependency checking, atomic file writes). The three-phase apply-cron.sh reconciliation is solid. However, there are several issues ranging from critical to minor that should be addressed.

---

## CRITICAL Issues

### 1. remove-agent.sh unconditionally sources openclaw-utils.sh (will crash if file is missing)

**File:** `scripts/remove-agent.sh`, line 14
**Problem:** Line 14 does `source "$REPO_ROOT/scripts/lib/openclaw-utils.sh"` at the top of the script, before any validation. If `openclaw-utils.sh` does not exist, the script fails immediately with an error -- even though the script later (line 126) handles the case where `openclaw.json` does not exist. By contrast, `create-agent.sh` checks for the file before sourcing (line 216).
**Impact:** The removal script becomes completely non-functional if openclaw-utils.sh is accidentally deleted or the repo is partially checked out.
**Fix:** Guard the source with a file existence check, or defer the source until it is actually needed (like create-agent.sh does).

### 2. sync-agents.sh hardcodes type to "dev-pa" for all agents

**File:** `scripts/sync-agents.sh`, line 44-46
**Problem:** The comment says "Hardcoded type for now -- all agents are dev-pa" but there is no mechanism to determine or store which type an agent belongs to. If a second type is ever created, sync-agents.sh will silently apply the wrong type files to agents of the new type.
**Impact:** Adding a second agent type will break sync without code changes. There is no per-agent type metadata.
**Fix:** Store the agent type in a file inside the agent directory (e.g., `.agent-type` containing "dev-pa"), and read it during sync instead of hardcoding.

### 3. apply-cron.sh locking: stale lock cleanup uses rmdir then mkdir (TOCTOU race)

**File:** `scripts/apply-cron.sh`, lines 83-87
**Problem:** When a stale lock is detected, the script does `rmdir "$LOCKFILE.d"` followed by `mkdir "$LOCKFILE.d"`. Between these two operations, another process could create the directory. The `rm -rf "$LOCKFILE.d"` fallback on line 83 partially mitigates this, but introduces its own race -- if another process just successfully created the lock dir and wrote its PID, `rm -rf` would destroy a valid lock.
**Impact:** Low probability in practice, but under high concurrency (e.g., two cron jobs firing apply-cron.sh simultaneously), both could acquire the "lock."
**Fix:** Use a single atomic operation. After rmdir, if mkdir fails, treat it as "another process got there first" and exit.

---

## IMPORTANT Issues

### 4. create-agent.sh template files are not substituted -- placeholders remain

**File:** `scripts/create-agent.sh`, lines 149-153
**Problem:** The templates (`IDENTITY.md.template`, `USER.md.template`) are copied verbatim with `cp`. No placeholder substitution is performed (e.g., replacing `{{AGENT_NAME}}` or `{{DISPLAY_NAME}}`). Examining the templates, they contain generic placeholder text like "Name: " (blank) rather than template variables, so this is by design -- but it means the agent starts with completely empty identity/user files.
**Impact:** Minor -- the bootstrap process is designed to fill these in conversationally. But the GitHub username placeholder in USER.md (`<github-username(s)>`) could be pre-populated from script arguments.
**Suggestion:** Consider adding optional `--github-user` flag to create-agent.sh and performing sed substitution on the copied templates.

### 5. CLAUDE.md does not document the "<your-org>" agent

**File:** `CLAUDE.md` and `.openclaw/cron/jobs-config.json`
**Problem:** The `<your-org>` agent exists in the cron config (with Slack ID <slack-id>) and has an agent directory, but is not documented in CLAUDE.md. Every other agent (dev1, dev10, dev10, dev10-jean, dev10) has a "## Agent:" section.
**Impact:** CLAUDE.md is incomplete as documentation. Anyone reading it would not know about <your-org> agent.
**Fix:** Add <your-org> agent section to CLAUDE.md, or if it was intentionally omitted, add a comment explaining why.

### 6. CLAUDE.md says "Polling: every 10 minutes" but cron config says every 2 hours (7200000ms)

**File:** `CLAUDE.md` vs `.openclaw/cron/jobs-config.json`
**Problem:** Every agent entry in CLAUDE.md says "Polling: every 10 minutes, check-in due after 240 min of no interaction." The cron jobs in jobs-config.json have `everyMs: 7200000` which is 120 minutes (2 hours), not 10 minutes. The "240 min" check-in threshold matches `poll-config.json`'s `interval_minutes: 240`.
**Impact:** Documentation is misleading. The 10-minute interval likely refers to the OpenClaw heartbeat polling interval, not the cron check-in interval. But mixing these two concepts in one line is confusing.
**Fix:** Clarify CLAUDE.md to distinguish between heartbeat polling interval (10 min, controlled by OpenClaw) and cron check-in interval (2 hours, controlled by jobs-config.json) and the "due" threshold (240 min, controlled by poll-config.json).

### 7. CLAUDE.md says dev1 uses model "google/gemini-3.1-pro" but cron config says "fw-mm25"

**File:** `CLAUDE.md` line "Model: google/gemini-3.1-pro" vs jobs-config.json line "model: fw-mm25"
**Problem:** The cron config for dev1 uses model "fw-mm25" but CLAUDE.md says "google/gemini-3.1-pro". One of these is stale.
**Impact:** Misleading documentation.
**Fix:** Align CLAUDE.md with the actual cron config.

### 8. remove-agent.sh CLAUDE.md section removal uses IGNORECASE but exact string match

**File:** `scripts/remove-agent.sh`, lines 152-157
**Problem:** The awk script uses `IGNORECASE=1` but does exact string comparison with `$0 == display || $0 == raw`. With IGNORECASE, this should work case-insensitively, but the `==` operator in awk with IGNORECASE applies to string comparison only in GNU awk (gawk). macOS ships with nawk/mawk where IGNORECASE is not supported. Since this is running on macOS (darwin), the IGNORECASE directive may be silently ignored.
**Impact:** On macOS, if the heading case does not exactly match the generated title-case display name, the section will not be removed.
**Fix:** Use `tolower()` for comparison instead of relying on IGNORECASE, or use a regex match instead of `==`.

### 9. cron-utils.sh add_cron_job everyMs is hardcoded to 7200000 (2 hours)

**File:** `scripts/lib/cron-utils.sh`, line 122
**Problem:** The `add_cron_job` function hardcodes `everyMs: 7200000` in the job template. This is not configurable via arguments. If a different polling interval is needed for a new agent, you must manually edit the config after creation.
**Impact:** All agents get the same cron interval. No way to customize per-agent without post-creation editing.
**Suggestion:** Add an optional `--interval` flag to create-agent.sh that passes through to add_cron_job.

### 10. create-agent.sh trap on line 250 overrides the signal, may leave lock/temp files

**File:** `scripts/create-agent.sh`, line 250
**Problem:** `trap 'rm -f "$_claude_tmp"' EXIT` is set during the CLAUDE.md edit step, and then `trap - EXIT` clears it after. But if the script is interrupted between setting the trap and clearing it, only the claude tmp file gets cleaned up -- any other cleanup traps would be lost. More importantly, this trap pattern is fragile if additional cleanup steps are added later.
**Impact:** Low risk currently, but poor trap hygiene.
**Fix:** Use a single cleanup function with trap, accumulating cleanup actions.

---

## MINOR Issues

### 11. sync-agents.sh does not sync new files added to the type automatically

**File:** `scripts/sync-agents.sh`, line 15
**Problem:** The `SHARED_FILES` array is a hardcoded list: `(SOUL.md AGENTS.md TOOLS.md HEARTBEAT.md BOOTSTRAP.md poll-config.json)`. If a new file is added to the type directory (e.g., `WORKFLOW.md`), it will NOT be synced until someone manually updates this array.
**Impact:** Easy to forget when extending the type. The scripts directory is handled with rsync (good), but top-level files are not.
**Fix:** Consider using a glob of all non-template, non-directory files in the type dir, or maintain a manifest file.

### 12. create-agent.sh summary lists "poll-config.json" but sync-agents.sh is what copies it

**File:** `scripts/create-agent.sh`, line 277
**Problem:** The summary message says "Shared files synced from types/dev-pa/: SOUL.md, AGENTS.md, TOOLS.md, HEARTBEAT.md, BOOTSTRAP.md, poll-config.json" but this list is duplicated from sync-agents.sh's SHARED_FILES. If SHARED_FILES changes, the summary becomes inaccurate.
**Impact:** Cosmetic -- misleading success output.
**Fix:** Either derive the list from sync-agents.sh output or remove the specific file listing.

### 13. create-agent.sh does not create the .stow-local-ignore for the .openclaw directory

**File:** `scripts/create-agent.sh`
**Problem:** The `.stow-local-ignore` exists at the repo root to prevent stowing repo-only files (types/, scripts/, etc). However, stow operates from `.openclaw/` directory (line 205), so the root-level `.stow-local-ignore` is the correct location. There is no issue here, but worth noting that if the stow source directory changes, the ignore file location must change too.
**Impact:** None currently. Just a note for future changes.

### 14. Missing `scripts/` entry in .stow-local-ignore

**File:** `.stow-local-ignore`
**Problem:** The file contains `types` but not `scripts`. Since stow runs from `.openclaw/` (not from repo root), and `scripts/` is at the repo root, this is not an issue. But the `.stow-local-ignore` is also at the repo root, which is confusing -- stow does not operate from the repo root.
**Impact:** None. The `.stow-local-ignore` at repo root is not used by the stow command in the scripts (which cd to `.openclaw/` first). It may be a leftover or for a different purpose.

### 15. apply-cron.sh uses eval for command execution

**File:** `scripts/apply-cron.sh`, lines 206, 244
**Problem:** `eval "$CMD_STR"` is used to execute the built command string. While `build_cmd_args` uses `printf '%q'` to safely quote arguments, eval is generally fragile and a security concern. If any argument contains unexpected characters that survive printf %q, it could lead to command injection.
**Impact:** Low risk since the inputs come from a controlled JSON config file, not user input. But eval is a code smell.
**Fix:** Return the command as an array instead of a string, avoiding eval entirely. Use `declare -p` or a nameref to pass the array back.

### 16. apply-cron.sh GATEWAY_COUNT check missing for empty gateway

**File:** `scripts/apply-cron.sh`, line 175
**Problem:** If `openclaw cron list --json` fails, `GATEWAY_JOBS` defaults to `{"jobs":[]}` which is fine. But if it returns malformed JSON, jq on line 175 could fail. The `2>/dev/null || echo '{"jobs":[]}'` only catches command failures, not stdout containing bad JSON.
**Impact:** Edge case -- openclaw would need to output invalid JSON.
**Fix:** Validate the JSON before using it, or pipe through `jq '.' 2>/dev/null || echo '{"jobs":[]}'`.

### 17. jobs-config.json has inconsistent message payloads

**File:** `.openclaw/cron/jobs-config.json`
**Problem:** The `dev1` job has an extended message that includes GitHub activity fetching (step 2: "Fetch recent GitHub activity..."), while all other agents have a simpler 4-step message. This difference was likely an intentional manual edit for dev1, but it means `create-agent.sh` will create agents with the simpler message template (from cron-utils.sh), and dev1's message would be lost if recreated.
**Impact:** The cron-utils.sh template and the actual dev1 config have diverged. This is expected for manual customization but worth documenting.

### 18. DRY_RUN in sync-agents.sh does not quote properly

**File:** `scripts/sync-agents.sh`, line 24
**Problem:** `if $DRY_RUN; then` works because `$DRY_RUN` is either `true` or `false` and bash executes the word as a command. While this is a common bash idiom, it is fragile -- if DRY_RUN is ever set to an unexpected value, it would execute that value as a command. The other scripts use `[ "$DRY_RUN" = true ]` which is safer.
**Impact:** Works correctly but inconsistent with the safer pattern used in other scripts.
**Fix:** Use `[ "$DRY_RUN" = true ]` for consistency.

---

## SUGGESTIONS

### S1. Add a list-agents.sh script

There is no way to list all agents and their metadata (type, slack-id, model) without manually inspecting files. A `list-agents.sh` that reads agent directories and cron config would be useful for operations.

### S2. Store agent type metadata per-agent

Create a `.agent-type` file in each agent directory during creation. sync-agents.sh would read this file instead of hardcoding "dev-pa". This enables multi-type support.

### S3. Add validation for duplicate Slack IDs

create-agent.sh validates that the agent name doesn't already exist, but does not check whether the Slack ID is already bound to another agent. Two agents with the same Slack ID would cause routing conflicts.

### S4. Add --type flag support to sync-agents.sh

Currently sync-agents.sh has no --type filter. When there are multiple types, you may want to sync only agents of a specific type.

### S5. Consider adding a health-check or validate-agent.sh

A script that verifies an agent's directory has all expected files, cron config exists, openclaw.json entry exists, and CLAUDE.md section exists would be useful for debugging broken agents.

### S6. HEARTBEAT.md template is wrapped in a code block

The HEARTBEAT.md file in types/dev-pa/ contains a markdown code block wrapping the actual content. When copied to an agent, the agent receives a file that looks like documentation about what to put in HEARTBEAT.md rather than an actual functional heartbeat config. This may be intentional (agents are expected to edit it), but is worth verifying.

### S7. create-agent.sh CLAUDE.md insert adds extra blank lines

The `INSERT_BLOCK` variable on line 239 starts with a newline, and the insertion before "## Useful Commands" will add an extra blank line gap. Over time, repeated agent creations could accumulate whitespace.

---

## End-to-End Walkthrough

### Creating a new agent: `scripts/create-agent.sh --name "test-agent" --slack-id "<slack-id>"`

1. **Validation** -- Checks name format, slack-id format, type dir exists, agent doesn't exist, jq/stow installed. All good.
2. **Directory creation** -- Creates `.openclaw/agents/test-agent/memory/`. Good.
3. **Template copy** -- Copies IDENTITY.md.template and USER.md.template as IDENTITY.md and USER.md. No substitution. Working as designed.
4. **Poll state** -- Creates `memory/poll-state.json`. Good.
5. **Sync** -- Runs sync-agents.sh which copies SOUL.md, AGENTS.md, TOOLS.md, HEARTBEAT.md, BOOTSTRAP.md, poll-config.json, and scripts/. Good.
6. **Cron** -- Adds job to jobs-config.json via cron-utils.sh, then runs apply-cron.sh. Good.
7. **Stow** -- Stows `.openclaw/` to `~/.openclaw/`. Good.
8. **openclaw.json** -- Registers agent entry and slack binding (if file exists). Good.
9. **CLAUDE.md** -- Inserts agent section before "## Useful Commands". Good.

**Issue:** Step 5 runs sync-agents.sh which syncs ALL agents, not just the new one. This is harmless (idempotent) but wasteful for large numbers of agents.

### Removing an agent: `scripts/remove-agent.sh --name "test-agent" --force`

1. **Source libraries** -- Sources openclaw-utils.sh unconditionally (CRITICAL issue #1).
2. **Validation** -- Checks agent dir exists, jq/stow installed. Good.
3. **Cron removal** -- Removes from jobs-config.json, runs apply-cron.sh. Good.
4. **Directory removal** -- Deletes repo dir and live dir. Good.
5. **Re-stow** -- Re-stows remaining agents. Good.
6. **openclaw.json** -- Removes agent entry and binding. Good.
7. **CLAUDE.md** -- Removes agent section using awk. Works but has macOS IGNORECASE issue (#8).

### Syncing type changes: `scripts/sync-agents.sh`

1. Iterates over all agent directories in `.openclaw/agents/`.
2. Hardcodes type to "dev-pa" (issue #2).
3. Copies shared files, syncs scripts dir with rsync --delete.
4. Copies template files only if target doesn't exist (correct -- preserves customized files).

**Gap:** If a new shared file is added to the type, it must be manually added to the SHARED_FILES array.

---

## Quality Assessment

| Aspect | Rating | Notes |
|--------|--------|-------|
| Error handling | Good | set -euo pipefail everywhere, error arrays, graceful warnings |
| Dry-run support | Good | All scripts support --dry-run consistently |
| Idempotency | Good | sync-agents.sh and openclaw-utils.sh are idempotent |
| Quoting | Good | Mostly proper quoting throughout |
| Dependency checks | Good | jq, stow, openclaw checked before use |
| Documentation | Fair | CLAUDE.md has several inaccuracies (issues #5, #6, #7) |
| Extensibility | Fair | Hardcoded type and file lists limit extensibility |
| Locking | Good | apply-cron.sh has proper locking with stale detection |
| Atomic writes | Good | cron-utils.sh and openclaw-utils.sh use tmp+mv pattern |
