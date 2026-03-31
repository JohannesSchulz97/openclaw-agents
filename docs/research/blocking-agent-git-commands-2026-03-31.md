# Blocking Agent Git Commands - Research

**Date:** 2026-03-31
**Status:** Actionable
**Problem:** OpenClaw agents run in workspaces stow-symlinked to openclaw-agents git repo. Any `git` command the agent executes directly affects the live repo (commits, pushes, branch switches, resets).

---

## Summary of Findings

Six approaches were investigated. The **recommended approach** is a combination of **Approach 1 (OpenClaw tool restrictions)** for defense-in-depth plus **Approach 2 (Claude Code hooks)** for granular git blocking. Either can work alone, but together they provide layered security.

---

## Approach 1: OpenClaw Tool Restrictions (tools.deny)

**Verdict: VIABLE -- strongest enforcement, but coarse-grained**

OpenClaw has a built-in tool policy system (`tools.allow` / `tools.deny`) that operates at the Gateway level. This is the most robust option because it works **independently of agent personality files** -- even if the agent is instructed to bypass rules, the Gateway blocks the tool call.

### How it works

In `openclaw.json`, each agent in `agents.list[]` can have per-agent tool restrictions:

```json
{
  "id": "dev1",
  "tools": {
    "deny": ["exec"]
  }
}
```

Or globally:

```json
{
  "tools": {
    "deny": ["exec"]
  }
}
```

Tool groups are also available: `group:runtime` covers `exec, bash, process, code_execution`.

### The catch

**This is all-or-nothing for shell execution.** Denying `exec` (or `group:runtime`) blocks ALL shell commands, not just `git`. Agents need shell access for their scripts (`github-activity.sh`, `poll-check.sh`, etc.), so fully denying `exec` would break core agent functionality.

There is **no built-in way to deny specific shell commands** (like `git`) while allowing others. The tool restriction system operates at the tool level (exec, read, write, etc.), not at the shell-command level.

### Tradeoffs

| Pro | Con |
|-----|-----|
| Gateway-enforced (cannot be bypassed by prompt injection) | Cannot selectively block `git` while allowing other shell commands |
| Per-agent granularity | Denying `exec` breaks agent scripts |
| Well-documented, stable feature | No command-level granularity within exec |

### Recommendation

Not suitable as the sole approach because agents need shell access. However, useful as a **secondary layer** if combined with approach 2 or 3.

---

## Approach 2: Claude Code Hooks (PreToolUse)

**Verdict: BEST APPROACH -- granular, proven pattern, already in use**

The project already uses Claude Code `PreToolUse` hooks in `.claude/settings.json` to intercept and block specific commands. Four blockers already exist:
- `openclaw.sh` -- blocks `openclaw` CLI commands
- `launchctl.sh` -- blocks launchctl commands
- `keychain.sh` -- blocks keychain commands
- `workspace.sh` -- blocks `.openclaw` file operations

### Implementation

Add a new hook to `.claude/settings.json`:

```json
{
  "matcher": "Bash",
  "inputPatterns": [".*\\bgit\\b.*"],
  "hooks": [
    {
      "type": "command",
      "command": ".claude/hooks/blockers/git.sh"
    }
  ]
}
```

The blocker script (`.claude/hooks/blockers/git.sh`) would follow the existing pattern:

```bash
#!/bin/bash
INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

case "$COMMAND" in
    *git\ *)
        jq -n \
            --arg msg "Git commands are not allowed. Agents must not modify the git repository. If you need to check project status, use file reading tools instead." \
            '{permissionDecision: "deny", additionalContext: $msg}'
        exit 0
        ;;
esac

jq -n '{permissionDecision: "allow"}'
exit 0
```

### Important: Scope

This hooks file lives in `/Users/<hostname>/openclaw-agents/.claude/settings.json`, which is the **openclaw-agents project-level** settings. OpenClaw agents run with their own workspace roots, NOT within the openclaw-agents Claude Code project. So this hook applies to **your** Claude Code sessions in openclaw-agents, not to the agents themselves.

**For agent enforcement**, you need to understand how OpenClaw invokes the LLM:
- OpenClaw agents use the Gateway, which calls models via API (OpenAI Codex, etc.)
- The models have tool-use capabilities (exec/bash) provided by OpenClaw's tool system
- Claude Code hooks are a **Claude Code CLI feature**, not an OpenClaw feature
- OpenClaw has its own hook system (`openclaw hooks`) but the 4 bundled hooks are for boot, bootstrap, command logging, and session memory -- none for command blocking

**This means Claude Code hooks work for YOUR sessions but NOT for the agents running through the OpenClaw Gateway.**

### OpenClaw Hooks Alternative

OpenClaw has a plugin/hook system. The `command-logger` hook already intercepts all command events. A custom OpenClaw plugin could intercept and block `exec` tool calls containing `git`. However:
- The hook system currently only supports bundled hooks + installed plugin packs
- Writing a custom plugin requires TypeScript and the OpenClaw plugin API
- No documented "command blocker" hook type exists (only logging)

### Tradeoffs

| Pro | Con |
|-----|-----|
| Granular (blocks `git` specifically, allows other commands) | Claude Code hooks only work in Claude Code CLI, not OpenClaw Gateway |
| Proven pattern (4 blockers already exist) | OpenClaw agents bypass this entirely |
| Easy to implement | Would need a custom OpenClaw plugin for agent enforcement |

### Recommendation

**Best for blocking git in YOUR sessions** (when you work in openclaw-agents via Claude Code). For agent enforcement, needs to be combined with approach 3 or 6.

---

## Approach 3: Git Wrapper / PATH Approach

**Verdict: VIABLE -- simple, universal enforcement**

Create a wrapper script that replaces `git` in the agent's PATH.

### Implementation

1. Create a wrapper at a known location (e.g., `/Users/<hostname>/openclaw-agents/scripts/git-blocker.sh`):

```bash
#!/bin/bash
# Block git commands from agents
echo "ERROR: git commands are not permitted in agent workspaces." >&2
exit 1
```

2. Set up a restricted bin directory:

```bash
mkdir -p ~/.openclaw/restricted-bin
ln -s /Users/<hostname>/openclaw-agents/scripts/git-blocker.sh ~/.openclaw/restricted-bin/git
chmod +x ~/.openclaw/restricted-bin/git
```

3. Prepend this to the agent's PATH. The challenge is: **how does OpenClaw set the agent's environment?**

OpenClaw agents inherit the shell environment from the gateway process. You could:
- Set `PATH=~/.openclaw/restricted-bin:$PATH` in the gateway's launch environment
- But this would also block git for ALL processes launched by the gateway, including legitimate cron scripts

### Alternative: Per-agent shell wrapper

Instead of PATH manipulation, modify the agent's exec tool to wrap commands:

```bash
# In a shell init file or wrapper
git() {
  echo "ERROR: git is blocked in agent context" >&2
  return 1
}
export -f git
```

This would need to be injected into the shell environment that OpenClaw uses for exec calls.

### Tradeoffs

| Pro | Con |
|-----|-----|
| Works regardless of LLM provider | Agents could bypass with `/usr/bin/git` (full path) |
| Simple to implement | Hard to inject into OpenClaw's exec environment cleanly |
| No OpenClaw config changes needed | PATH manipulation affects all gateway children |
| Agent sees a clear error message | Doesn't block `command git` or backtick variants |

### Recommendation

Reasonable as a **defense-in-depth layer** but not foolproof. An agent that knows the full path to git or uses other git tooling could bypass it.

---

## Approach 4: File System / Git Hooks

**Verdict: PARTIAL -- blocks writes but not reads/status**

### Option A: Read-only .git directory

```bash
chmod -R a-w /Users/<hostname>/openclaw-agents/.git
```

**Problem:** This breaks YOUR git operations too. You'd need to toggle permissions constantly.

### Option B: Git server-side hooks (pre-commit, pre-push)

Add hooks that check the caller:

```bash
# .git/hooks/pre-commit
#!/bin/bash
# Block commits from agent processes
if [[ "$OPENCLAW_AGENT_ID" != "" ]]; then
    echo "ERROR: Agent commits are not allowed"
    exit 1
fi
```

**Problem:** OpenClaw doesn't set an `OPENCLAW_AGENT_ID` environment variable in exec contexts (not documented). You'd need to identify agent processes by other means (parent PID, user, etc.), which is fragile.

### Option C: git config for the repo

```bash
# In openclaw-agents/.git/config
[receive]
    denyCurrentBranch = refuse
```

This only affects pushes to the repo, not local operations.

### Tradeoffs

| Pro | Con |
|-----|-----|
| Prevents actual damage to repo | Hard to distinguish agent vs. human git operations |
| Git hooks are a standard mechanism | Only blocks write operations (commit, push, reset) |
| No OpenClaw changes needed | Read operations (status, log, diff) still work (may be fine) |
| | chmod approach breaks human workflows |

### Recommendation

Git hooks are a decent **last line of defense** but hard to target agents specifically. Best combined with other approaches.

---

## Approach 5: OpenClaw Agent Permissions (openclaw.json agents config)

**Verdict: SAME AS APPROACH 1 -- per-agent tool policy**

Examined `openclaw.json` `agents.list[]` entries. The per-agent config supports:
- `model` -- which model to use
- `workspace` / `agentDir` -- workspace paths
- `tools.allow` / `tools.deny` -- tool restrictions (same as Approach 1)

There is no agent-level `commands.deny` or `shell.blocklist` configuration. The `nodes.denyCommands` key exists but is for OpenClaw-native commands (like `camera.snap`), not shell commands.

No additional permission mechanisms were found beyond what Approach 1 covers.

---

## Approach 6: Instructional Guards (AGENTS.md / SOUL.md)

**Verdict: ALREADY PARTIALLY IN PLACE -- weakest enforcement**

### Current state

- `AGENTS.md` Red Lines section says: "Don't run destructive commands without asking" and "trash > rm"
- `AGENTS.md` Proactive work section says: "Commit and push your own changes" -- this **actively encourages** git usage
- No explicit git prohibition exists anywhere

### Implementation

Add to `AGENTS.md` Red Lines:

```markdown
- **Never run git commands.** Your workspace is symlinked to a live repository.
  Git operations (commit, push, checkout, reset, branch) can corrupt the repo.
  If you need project status, read files directly.
```

Add to `types/dev-pa/SOUL.md` or a new `<channel-id>.md`:

```markdown
## Hard Constraints
- NEVER execute git commands (git commit, git push, git checkout, git reset, etc.)
- Your workspace shares a git repository -- any git operation affects all agents
```

### Tradeoffs

| Pro | Con |
|-----|-----|
| Zero infrastructure changes | Can be ignored or overridden by prompt injection |
| Immediate to implement | LLMs may "forget" or rationalize exceptions |
| Clear documentation of intent | No enforcement mechanism |
| Works across all models | Weaker with less capable models |

### Recommendation

Should be done regardless as a baseline, but **never relied upon as the sole mechanism**. The existing line "Commit and push your own changes" in AGENTS.md must be removed.

---

## Recommended Strategy (Layered)

### Priority Order

1. **Instructional guard (Approach 6)** -- Do immediately. Remove "Commit and push your own changes" from AGENTS.md. Add explicit git prohibition to Red Lines. Cost: 5 minutes. Effectiveness: ~70% (most models will comply most of the time).

2. **Claude Code hook (Approach 2)** -- Implement for your own sessions. Add `git.sh` blocker to `.claude/hooks/blockers/`. Cost: 10 minutes. Effectiveness: 100% for Claude Code sessions.

3. **Git wrapper (Approach 3)** -- Create `~/.openclaw/restricted-bin/git` wrapper that blocks execution. Inject into gateway environment. Cost: 30 minutes. Effectiveness: ~85% (bypassable with full path).

4. **Git hooks (Approach 4)** -- Add pre-commit and pre-push hooks as last-resort safety net. Cost: 15 minutes. Effectiveness: Blocks write operations even if other layers fail.

### What NOT to do

- Do NOT deny `exec`/`group:runtime` in OpenClaw tool policy -- breaks agent functionality
- Do NOT make `.git/` read-only -- breaks your own workflow
- Do NOT rely solely on instructional guards -- insufficient for security

### The "simplest reliable" approach

**Approach 6 (instructions) + Approach 2 (Claude Code hook) + Approach 3 (PATH wrapper)** together provide layered defense:
- Instructions prevent 70% of cases (model compliance)
- PATH wrapper catches the remaining cases where the agent tries `git`
- Claude Code hook protects your own sessions
- Total implementation time: ~45 minutes

### Ideal but requires development

A custom **OpenClaw plugin** that intercepts `exec` tool calls and regex-matches against `git` commands before execution would be the most robust solution. This would mirror what Claude Code hooks do but at the Gateway level. This requires TypeScript plugin development against the OpenClaw plugin API.

---

## Files Referenced

- `/Users/<hostname>/openclaw-agents/.claude/settings.json` -- existing Claude Code hooks
- `/Users/<hostname>/openclaw-agents/.claude/hooks/blockers/` -- existing blocker scripts
- `/Users/<hostname>/.openclaw/openclaw.json` -- OpenClaw configuration
- `/Users/<hostname>/openclaw-agents/types/dev-pa/AGENTS.md` -- agent operating manual
- `/Users/<hostname>/openclaw-agents/types/dev-pa/TOOLS.md` -- agent tools notes
- OpenClaw docs: https://docs.openclaw.ai/tools/index, https://docs.openclaw.ai/concepts/delegate-architecture
