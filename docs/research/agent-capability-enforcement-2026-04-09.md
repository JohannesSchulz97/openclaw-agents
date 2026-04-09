# Agent Capability Enforcement: Research & Architecture Options

**Date:** 2026-04-09
**Status:** Research complete, ready for architecture decisions
**Scope:** Mechanisms to enforce restrictions on what OpenClaw agents can do at runtime, beyond prompt-level instructions

---

## Table of Contents

1. [Problem Statement](#1-problem-statement)
2. [Current State](#2-current-state)
3. [OpenClaw Built-in Mechanisms](#3-openclaw-built-in-mechanisms)
   - 3.1 Tool Allow/Deny Policies
   - 3.2 Tool Profiles
   - 3.3 Exec Approvals (Allowlist + Denylist)
   - 3.4 Docker Sandboxing
   - 3.5 Plugin Hook System
   - 3.6 OpenClaw Hooks (Automation)
4. [Community & Third-Party Solutions](#4-community--third-party-solutions)
   - 4.1 ClawBands
   - 4.2 OpenClaw PRISM
   - 4.3 SlowMist Security Practice Guide
   - 4.4 APort Agent Guardrail
5. [OS-Level & Infrastructure Approaches](#5-os-level--infrastructure-approaches)
   - 5.1 Anthropic Sandbox Runtime
   - 5.2 PATH Wrappers / Restricted Shells
   - 5.3 macOS Seatbelt (sandbox-exec)
   - 5.4 Linux: Landlock + seccomp-BPF
6. [Enforcement Matrix: What We Need](#6-enforcement-matrix-what-we-need)
7. [Recommended Architecture](#7-recommended-architecture)
8. [Implementation Roadmap](#8-implementation-roadmap)
9. [Open Questions & Risks](#9-open-questions--risks)
10. [Sources](#10-sources)

---

## 1. Problem Statement

We run 18 agents on OpenClaw (17 dev-pa + 1 manager). Currently, agent behavior is restricted only through documentation in their system prompt files (AGENTS.md, SOUL.md). These instruct agents not to run git commands, not to use gh CLI write operations, etc.

This is fragile. An LLM can ignore instructions due to:
- Prompt injection (via fetched content, user messages, or tool outputs)
- Context window pressure (instructions forgotten as context grows)
- Model reasoning failures (the model decides to "helpfully" bypass a rule)
- Momentum pressure (the model is mid-task and rationalizes an exception)

We have already observed agents violating documented restrictions (e.g., running git commands, crashing the gateway by running `openclaw gateway stop`). The question is: what mechanisms exist -- or can we build -- to enforce these restrictions at a layer the LLM cannot bypass?

### Specific restrictions needed

| Resource | Policy |
|----------|--------|
| `gh` CLI | Read-only allowed; writes (create, close, comment, merge, etc.) blocked |
| `git` | Completely blocked |
| Filesystem | Restricted to agent workspace directory |
| Network | Restricted to known-safe endpoints |
| `openclaw` CLI | Blocked except `openclaw message send` |
| System commands | Block `launchctl`, `sudo`, `rm -rf`, etc. |

---

## 2. Current State

### What we have today

**Instructional guards (AGENTS.md Red Lines):**
- "NEVER run git commands"
- "NEVER run gh CLI write commands"
- "Read-only gh commands are allowed"
- "Don't run destructive commands without asking"

**Wrapper scripts for controlled write access:**
- `scripts/create-issue.sh` -- wraps `gh issue create` with duplicate detection
- `scripts/comment-on-issue.sh` -- wraps `gh issue comment`
- `scripts/github-activity.sh` -- wraps `gh` with org-scoping

**Claude Code hooks (dev machine only, NOT agent-facing):**
- `.claude/hooks/host/block-git-write.sh` -- blocks git write ops on the host
- `.claude/hooks/dev/block-direct-shared-edit.sh` -- blocks editing shared agent files
- These are Claude Code CLI hooks, not OpenClaw hooks. They only apply to human Claude Code sessions, not to agents running through the OpenClaw Gateway.

**Previous research:**
- `blocking-agent-git-commands-2026-03-31.md` -- investigated 6 approaches for git blocking
- `clawbands-openclaw-research-2026-03-27.md` -- evaluated ClawBands middleware
- `openclaw-production-best-practices-2026-04-01.md` -- noted per-agent tool isolation as a gap

### What we lack

- No Gateway-level enforcement of command restrictions
- No exec approval configuration (`exec-approvals.json` not configured)
- No Docker sandboxing (agents run directly on host)
- No per-agent tool policy differentiation
- No network egress restrictions
- No filesystem confinement beyond what OpenClaw's workspace root provides

---

## 3. OpenClaw Built-in Mechanisms

### 3.1 Tool Allow/Deny Policies

**How it works:** OpenClaw has a multi-layered tool filtering pipeline. At session creation, `resolveEffectiveToolPolicy` merges global settings (`config.tools`) with per-agent settings (`agents[].tools`). Within each layer, deny wins over allow.

**Configuration in `openclaw.json`:**

```json
{
  "tools": {
    "deny": ["exec"]
  }
}
```

Or per-agent:

```json
{
  "agents": {
    "list": [
      {
        "id": "dev1",
        "tools": {
          "deny": ["exec"]
        }
      }
    ]
  }
}
```

**Tool groups available:**
- `group:runtime` -- covers `exec`, `bash`, `process`, `code_execution`
- Individual tools: `exec`, `read`, `write`, `edit`, `apply_patch`, `process`, `web_search`, `web_fetch`, `browser`, `gateway`, `nodes`

**Assessment for our needs:**
- Denying `exec` or `group:runtime` would block ALL shell commands, including the legitimate scripts our agents run (`github-activity.sh`, `checkin-guard.sh`, `generate-image.sh`, etc.)
- There is NO built-in way to deny specific shell commands (like `git`) while allowing others at this level
- This is a blunt instrument -- useful for agents that genuinely need no shell access, but not for our dev-pa agents

**Verdict:** Not directly useful as the primary mechanism. Could be used for a future "read-only" agent type that needs no exec.

### 3.2 Tool Profiles

**How it works:** `tools.profile` sets a base allowlist before allow/deny is applied. Profiles are preset levels of tool access.

**Available profiles:**
- `minimal` -- basic read-only tools only (observe-only agents)
- `coding` -- read, write, edit, exec, apply_patch (standard development)
- `messaging` -- adds messaging tools
- `full` -- all tools enabled

**Per-agent override:** `agents.list[].tools.profile`

**Per-provider override:** `tools.byProvider` can restrict tools for specific model providers

**Assessment:** The `minimal` profile would be too restrictive for dev-pa agents. `coding` is approximately what we need but doesn't solve the granular command-level restriction problem. Profiles control which tool types are available, not what commands can be run within the `exec` tool.

**Verdict:** Useful as a base layer (ensure agents use `coding` not `full`), but does not solve command-level filtering.

### 3.3 Exec Approvals (Allowlist + Denylist)

**This is the most promising built-in mechanism.**

**How it works:** Exec approvals are a guardrail system for shell command execution. They operate via `~/.openclaw/exec-approvals.json` on the host. Commands are allowed only when policy + allowlist + (optional) user approval all agree.

**Configuration file:** `~/.openclaw/exec-approvals.json`

```json
{
  "version": 1,
  "defaults": {
    "security": "allowlist",
    "ask": "off",
    "askFallback": "deny"
  },
  "agents": {
    "dev1": {
      "security": "allowlist",
      "ask": "off",
      "askFallback": "deny",
      "allowlist": [
        {
          "id": "agent-scripts",
          "pattern": "*/bash"
        },
        {
          "id": "cat",
          "pattern": "*/cat"
        },
        {
          "id": "ls",
          "pattern": "*/ls"
        }
      ],
      "denylist": [
        {
          "id": "block-git",
          "pattern": "*/git",
          "argsMatch": "*"
        },
        {
          "id": "block-openclaw",
          "pattern": "*/openclaw",
          "argsMatch": "gateway*"
        }
      ]
    }
  }
}
```

**Security modes:**
- `deny` -- block all exec requests
- `allowlist` -- only allow commands matching allowlist patterns
- `full` -- allow all commands (no restrictions)

**Ask modes:**
- `off` -- trust allowlist/denylist without prompting (required for autonomous agents)
- `on-miss` -- prompt if command not in allowlist
- `always` -- prompt for every command
- Fallback: `deny` means unanswered prompts default to denial

**Denylist feature (PR #47848):**
The denylist matches against the full command string (not just binary path) and is evaluated BEFORE the allowlist. This is critical -- it means we can:
1. Allow `bash` (for running our scripts)
2. Deny specific commands within bash (e.g., `git`, `gh issue create`)

**Denylist entry structure:**
```json
{
  "id": "block-git",
  "pattern": "*/git",
  "argsMatch": "*"
}
```

- `pattern` -- glob against the resolved binary path
- `argsMatch` -- glob against the command arguments string

**Per-agent isolation:** Per-agent allowlists and denylists prevent one agent's approvals from leaking into others. Each agent can have completely different approval policies.

**Known limitations:**
- Allowlist matching is against the resolved binary path. Allowlisting `/bin/zsh` means ANY command run through zsh is allowed (issue #23276). This is a significant bypass risk.
- Command-content deny patterns (issue #41140) are now available via the denylist feature, addressing the binary-path-only limitation.
- Redirections (`>`, `<`) are not supported in allowlist mode.
- Command substitution (`$()`, backticks) is rejected by the allowlist parser.

**Assessment for our needs:**
This is the strongest built-in mechanism. With `security: "allowlist"` + a carefully crafted denylist, we can:
- Allow agents to run `bash scripts/...` (their normal workflow)
- Block `git` commands via denylist
- Block `gh issue create`, `gh pr create`, etc. via denylist while allowing `gh issue view`, `gh pr list`
- Block `openclaw gateway` commands via denylist
- Block `sudo`, `launchctl`, `rm -rf /` via denylist

**Verdict: PRIMARY MECHANISM.** This should be the foundation of our enforcement strategy. Gateway-enforced, per-agent granularity, cannot be bypassed by prompt injection.

### 3.4 Docker Sandboxing

**How it works:** OpenClaw can run tool execution (exec, read, write, edit, browser) inside ephemeral Docker containers instead of directly on the host.

**Configuration in `openclaw.json`:**

```json
{
  "agents": {
    "defaults": {
      "sandbox": {
        "backend": "docker",
        "docker": {
          "image": "openclaw-sandbox:latest",
          "network": "none",
          "binds": [
            "/path/to/workspace:/workspace:rw"
          ],
          "setupCommand": "apt-get install -y jq"
        }
      }
    }
  }
}
```

**Key features:**
- **Network isolation:** Default `network: "none"` -- no outbound network from the container
- **Filesystem isolation:** Only explicitly mounted directories are accessible
- **Per-agent configuration:** `agents.list[].sandbox` can override defaults
- **Scope:** Per-agent (default), per-session, or shared

**Assessment for our needs:**
Docker sandboxing would give us:
- Complete filesystem confinement (agents can only access mounted workspace)
- Network isolation (no egress by default, explicitly allowed endpoints only)
- Process isolation (no access to host processes)
- Git blocking inherently (if `git` is not installed in the container)
- `openclaw` CLI blocking inherently (not in container)

However:
- Our agents currently run on macOS. Docker on macOS uses a Linux VM, adding overhead.
- We would need a custom Docker image with our agent scripts and their dependencies (`jq`, `gh`, `bash`, `curl`).
- `openclaw message send` (which agents need) requires Gateway access, which would need special handling in a sandboxed environment.
- The sandbox has a tool policy layer (`tools.sandbox.tools`) separate from the agent tool policy, adding complexity.
- Migration from unsandboxed to sandboxed is non-trivial for 18 agents.

**Verdict:** The most complete isolation mechanism, but high migration cost and operational complexity. Best as a medium-term goal, not immediate solution. Would solve filesystem and network restrictions comprehensively.

### 3.5 Plugin Hook System

**How it works:** OpenClaw plugins can register hooks via the Plugin SDK. The SDK exposes 28 hooks covering model resolution, agent lifecycle, message flow, tool execution, subagent coordination, and gateway lifecycle.

**Relevant hooks:**
- `before_tool_call` -- intercept tool calls before execution
- `tool_result_persist` -- transform tool results before persistence
- `agent_end` -- post-processing after agent turn

**Current status:**
- Issue #5943 (`before_tool_call` not wired up) was opened Feb 2026 and is now CLOSED -- suggesting the hook IS now wired into the execution pipeline.
- Issue #5513 reported that plugin hooks were never invoked; this appears to have been fixed.
- Issue #60943 (Pre/Post Tool Use Hooks) was opened Apr 4, 2026 -- this is a feature request for shell-script-based hooks (like Claude Code hooks), which is DIFFERENT from the plugin SDK hooks.

**What a custom plugin could do:**
```typescript
api.on('before_tool_call', async (context) => {
  if (context.tool === 'exec') {
    const command = context.input.command;
    if (/\bgit\b/.test(command)) {
      return { action: 'deny', reason: 'git commands are blocked' };
    }
  }
  return { action: 'allow' };
});
```

**Assessment:**
- Writing a custom OpenClaw plugin requires TypeScript and the Plugin SDK
- The `before_tool_call` hook appears to now be functional (issue closed)
- This would provide the most flexible, programmatic command filtering
- However, plugin development, testing, and maintenance is a significant investment
- No community example of a "command blocker" plugin exists yet

**Verdict:** High potential, high effort. Would be the ideal solution if exec-approvals denylist proves insufficient. Worth monitoring as the plugin ecosystem matures.

### 3.6 OpenClaw Hooks (Automation)

**How it works:** OpenClaw has two kinds of hooks: internal hooks (run inside the Gateway on events like `/new`, `/reset`, `/stop`) and webhooks (external HTTP endpoints).

**Current hook events:** `command:new`, `gateway:startup`, `tool_result_persist`, `session:patch`, `session:compact:before/after`, `agent:bootstrap`

**Assessment:** These hooks are lifecycle hooks, not tool-execution hooks. They cannot intercept or block individual tool calls. The feature request for Pre/Post Tool Use Hooks (issue #60943, April 2026) would add shell-script hooks at the tool execution level -- essentially bringing Claude Code's hook model to OpenClaw. This is NOT yet implemented.

**Verdict:** Not usable today for capability enforcement. Watch issue #60943 for future availability.

---

## 4. Community & Third-Party Solutions

### 4.1 ClawBands

**Repository:** https://github.com/SeyZ/clawbands
**Author:** dev10 Munda (RootCX)
**License:** MIT
**Maturity:** v1.0.0, 2 commits, 95 stars

**What it does:** Security middleware that intercepts every tool execution and applies a policy engine (ALLOW, BLOCK, ASK). Maps tools to modules (FileSystem, Shell, Network, Browser, Gateway) with configurable policies per module.

**Key features:**
- In-process interception (no external API calls, zero latency)
- Three decision types: ALLOW (auto-approve reads), ASK (prompt on writes), DENY (block deletes)
- Append-only JSON Lines audit trail
- Messaging channel integration (WhatsApp, Telegram) for remote approval

**Assessment for our needs:**
- The ASK model conflicts with autonomous agent operation (18 agents would generate approval fatigue)
- However, the ALLOW/DENY policies could be configured to auto-approve routine operations and auto-deny dangerous ones, without human-in-the-loop
- Very early-stage (2 commits) -- production readiness is uncertain
- Would need custom policy profiles for dev-pa workflows

**Verdict:** Worth evaluating if exec-approvals denylist is insufficient. The policy engine is conceptually what we need, but maturity is a concern.

### 4.2 OpenClaw PRISM

**Paper:** arxiv.org/abs/2603.11853 (Frank Li, March 2026)

**What it is:** A zero-fork, defense-in-depth runtime security layer for OpenClaw. Combines an in-process plugin with optional sidecar services, distributing enforcement across ten lifecycle hooks.

**Key capabilities:**
- Hybrid heuristic-plus-LLM scanning pipeline for prompt injection detection
- Conversation- and session-scoped risk accumulation with TTL-based decay
- Policy-enforced controls over tools, paths, private networks, domain tiers, and outbound secret patterns
- Tamper-evident audit and operations plane with integrity verification
- Hot-reloadable policy

**Assessment:** This is an academic/research implementation, not a production-ready tool. However, it validates the architecture we need: enforcement distributed across lifecycle hooks with policy-based tool control. The approach of using the `before_tool_call` hook for deterministic, non-bypassable policy enforcement is exactly right.

**Verdict:** Architecturally informative. Not directly deployable but confirms the design direction.

### 4.3 SlowMist Security Practice Guide

**Repository:** https://github.com/slowmist/openclaw-security-practice-guide

**What it is:** An agent-facing security guide designed to be injected into OpenClaw's system prompt. Implements a "Mental Seal" approach -- reshaping the agent's baseline judgment through detailed pre-action/in-action/post-action policies.

**Key features:**
- Three-layer defense matrix (pre-action, in-action, post-action)
- Four core principles: zero-friction ops, high-risk confirmation, explicit auditing, zero-trust by default
- Automated nightly audit script
- 6-step automated deployment workflow

**Assessment:** This is essentially a more sophisticated version of what we already do with AGENTS.md Red Lines. It acknowledges its own limitation: "This guide does not make OpenClaw 'fully secure.'" It's instructional, not enforcement.

**Verdict:** Could improve our instructional layer, but does not solve the enforcement gap. Worth reviewing for ideas to strengthen AGENTS.md.

### 4.4 APort Agent Guardrail

**Context:** Referenced in OpenClaw issue #46441 (Pluggable Guardrail Provider Interface)

**What it does:** A skill that runs in the platform's `before_tool_call` hook, checking every tool call before execution. Implements pre-action authorization at the runtime/platform level.

**Key insight from the issue:**
> "Pre-action authorization must run in the runtime/platform (OpenClaw's before_tool_call), so the platform invokes the guardrail for every tool call regardless of what the model outputs. That's the only way to get deterministic, non-bypassable policy enforcement."

**Verdict:** Confirms the architectural principle: enforcement must happen at the Gateway level, not in the prompt.

---

## 5. OS-Level & Infrastructure Approaches

### 5.1 Anthropic Sandbox Runtime (`@anthropic-ai/sandbox-runtime`)

**Repository:** https://github.com/anthropic-experimental/sandbox-runtime
**Package:** `npm install -g @anthropic-ai/sandbox-runtime`
**Purpose:** Lightweight OS-level sandboxing without containers

**How it works:**
- **macOS:** Uses Apple's Seatbelt framework (`sandbox-exec`) for filesystem restrictions
- **Linux:** Uses bubblewrap + seccomp-BPF for syscall filtering + Landlock for filesystem
- **Network:** Runs HTTP and SOCKS5 proxy servers that filter all network requests based on permission rules
- **Filesystem:** Define exactly which directories can be read/written

**Usage:**
```bash
srt --allow-dir /path/to/workspace:rw \
    --allow-net api.github.com:443 \
    --deny-net '*' \
    -- bash -c "your-command-here"
```

**Assessment for our needs:**
- Lightweight (no Docker overhead)
- Works on macOS natively (Seatbelt)
- Network filtering via proxy is elegant
- Could wrap OpenClaw's exec tool invocations

**Challenges:**
- Apple marks `sandbox-exec` as deprecated (still works but long-term uncertain)
- Integration with OpenClaw's exec pipeline would require either:
  - A custom plugin that wraps commands with `srt`
  - Modifying the Gateway's exec tool to use `srt`
  - Using it as the sandbox backend (not natively supported)

**Verdict:** Excellent technology, but integration with OpenClaw is the challenge. Most useful if we can hook into the exec pipeline.

### 5.2 PATH Wrappers / Restricted Shells

**How it works:** Create wrapper scripts that replace dangerous commands in the agent's PATH.

```bash
# ~/.openclaw/restricted-bin/git
#!/bin/bash
echo "ERROR: git commands are not permitted in agent workspaces." >&2
exit 1
```

Then prepend to the gateway's PATH:
```bash
PATH=~/.openclaw/restricted-bin:$PATH openclaw gateway start
```

**Assessment:**
- Simple to implement
- Works regardless of LLM provider
- Agent sees a clear error message

**Limitations:**
- Bypassable with full path (`/usr/bin/git`)
- Affects ALL processes spawned by the gateway (including legitimate cron scripts)
- Agents can discover the bypass through `/usr/bin/which git` or `command -v git`
- Does not handle commands run through `bash -c "git ..."` (bash resolves PATH internally)
- Cannot selectively allow read-only `gh` while blocking write `gh`

**Verdict:** Defense-in-depth layer only. Not reliable as primary enforcement.

### 5.3 macOS Seatbelt (sandbox-exec)

**How it works:** macOS built-in sandboxing via SBPL (Sandbox Profile Language) policies.

```bash
sandbox-exec -f /path/to/agent.sb -- bash -c "agent-command"
```

**What it can restrict:**
- File read/write per path
- Network access per address/port
- Process execution per binary
- Mach port access
- Signal delivery

**Assessment:**
- No container overhead
- Fine-grained filesystem and network control
- Binary execution restrictions could block `git` at the kernel level

**Limitations:**
- Apple deprecated `sandbox-exec` (undocumented, may break in future macOS)
- SBPL is undocumented and complex
- Integration with OpenClaw exec pipeline is not straightforward
- Would need a custom OpenClaw plugin or exec wrapper

**Verdict:** Technically powerful, practically risky due to deprecation. The Anthropic sandbox-runtime (5.1) is a better wrapper around this technology.

### 5.4 Linux: Landlock + seccomp-BPF

**How it works:**
- **Landlock:** Capability-based filesystem access restrictions (kernel 5.13+)
- **seccomp-BPF:** System call filtering at the kernel level
- Used by Codex CLI for sandboxing

**Assessment:** Not applicable to our macOS deployment, but relevant if we ever move to a Linux host. The most robust enforcement mechanism available on Linux.

**Verdict:** Not applicable now. Relevant for future Linux migration.

---

## 6. Enforcement Matrix: What We Need

For each restriction, here's which mechanisms can enforce it:

### `git`: Completely blocked

| Mechanism | Effectiveness | Effort | Notes |
|-----------|-------------|--------|-------|
| Exec-approvals denylist | **HIGH** | Low | `pattern: "*/git", argsMatch: "*"` |
| PATH wrapper | Medium | Low | Bypassable with full path |
| Docker sandbox | **HIGH** | High | git not installed in container |
| Instructional (AGENTS.md) | Low-Medium | None | Already in place |
| Custom plugin | **HIGH** | High | Programmatic filtering |

**Recommended:** Exec-approvals denylist (primary) + PATH wrapper (defense-in-depth) + instructions (baseline)

### `gh` CLI: Read-only allowed, writes blocked

| Mechanism | Effectiveness | Effort | Notes |
|-----------|-------------|--------|-------|
| Exec-approvals denylist | **HIGH** | Medium | Need deny patterns for each write command |
| Wrapper scripts | Medium | Already done | `create-issue.sh`, `comment-on-issue.sh` |
| Custom plugin | **HIGH** | High | Regex-based command inspection |
| Instructional (AGENTS.md) | Medium | None | Already in place |

**Recommended:** Exec-approvals denylist with entries for `gh issue create`, `gh issue close`, `gh issue comment`, `gh pr create`, `gh pr merge`, `gh api` (with mutation detection). Read commands (`gh issue view`, `gh issue list`, `gh pr view`, `gh pr list`) remain allowed.

**Challenge:** The denylist matches on patterns and argsMatch. We'd need entries like:
```json
{"pattern": "*/gh", "argsMatch": "issue create*"},
{"pattern": "*/gh", "argsMatch": "issue close*"},
{"pattern": "*/gh", "argsMatch": "issue comment*"},
{"pattern": "*/gh", "argsMatch": "issue edit*"},
{"pattern": "*/gh", "argsMatch": "issue delete*"},
{"pattern": "*/gh", "argsMatch": "pr create*"},
{"pattern": "*/gh", "argsMatch": "pr merge*"},
{"pattern": "*/gh", "argsMatch": "pr close*"},
{"pattern": "*/gh", "argsMatch": "pr comment*"},
{"pattern": "*/gh", "argsMatch": "pr edit*"},
{"pattern": "*/gh", "argsMatch": "pr review*"},
{"pattern": "*/gh", "argsMatch": "repo *"},
{"pattern": "*/gh", "argsMatch": "api *"}
```

This is verbose but manageable. The `gh api` entry is tricky -- we'd need to block all `gh api` calls (they can do mutations) OR find a way to allow GET-only. The safest approach is to block `gh api` entirely since agents don't need it.

### Filesystem: Restrict to agent workspace only

| Mechanism | Effectiveness | Effort | Notes |
|-----------|-------------|--------|-------|
| Docker sandbox | **HIGH** | High | Only mounted dirs accessible |
| Seatbelt/sandbox-runtime | **HIGH** | Medium | File-level restrictions |
| OpenClaw workspace root | Medium | None | Already limits agent's view |
| Exec-approvals allowlist | Low | Medium | Can restrict binaries, not file access |

**Recommended:** Docker sandbox (medium-term) or Anthropic sandbox-runtime integration. In the short term, OpenClaw's workspace root provides basic confinement, but agents can still access files outside workspace via shell commands.

### Network: Restrict to allowed endpoints

| Mechanism | Effectiveness | Effort | Notes |
|-----------|-------------|--------|-------|
| Docker sandbox (`network: "none"`) | **HIGH** | High | No network by default, explicit exceptions |
| Anthropic sandbox-runtime proxy | **HIGH** | Medium | HTTP/SOCKS5 proxy filtering |
| Tool deny (`web_fetch`, `web_search`) | Medium | Low | Blocks web tools but not curl/wget in exec |
| Firewall rules | Medium | Medium | Per-user iptables/pf rules |

**Recommended:** Docker sandbox (medium-term). Short-term, deny `web_fetch` and `web_search` tools if agents don't need them, and add `curl`/`wget` to exec-approvals denylist.

### `openclaw` CLI: Block except `openclaw message send`

| Mechanism | Effectiveness | Effort | Notes |
|-----------|-------------|--------|-------|
| Exec-approvals denylist | **HIGH** | Low | Deny `*/openclaw` with `argsMatch: "gateway*"`, `argsMatch: "cron*"`, etc. |
| PATH wrapper | Medium | Low | Can't selectively allow `message send` |

**Recommended:** Exec-approvals denylist with specific dangerous subcommands blocked:
```json
{"pattern": "*/openclaw", "argsMatch": "gateway*"},
{"pattern": "*/openclaw", "argsMatch": "cron*"},
{"pattern": "*/openclaw", "argsMatch": "config*"},
{"pattern": "*/openclaw", "argsMatch": "agents*"},
{"pattern": "*/openclaw", "argsMatch": "plugins*"},
{"pattern": "*/openclaw", "argsMatch": "security*"}
```

This allows `openclaw message send` while blocking administrative commands.

---

## 7. Recommended Architecture

### Tier 1: Immediate (exec-approvals denylist) -- 1-2 hours

**The single highest-impact change we can make.**

Configure `~/.openclaw/exec-approvals.json` on the host with:

1. **Default security:** `"allowlist"` with `ask: "off"` and `askFallback: "deny"`
2. **Per-agent denylists** blocking:
   - `git` (all commands)
   - `gh` write operations (issue create/close/comment/edit/delete, pr create/merge/close/comment/edit, repo, api)
   - `openclaw` administrative commands (gateway, cron, config, agents, plugins, security)
   - Dangerous system commands (`sudo`, `launchctl`, `rm -rf`)
3. **Per-agent allowlists** permitting:
   - `bash` (for running agent scripts)
   - `cat`, `ls`, `head`, `tail`, `grep`, `find`, `wc`, `sort`, `jq` (standard read tools)
   - `curl` (needed for some scripts; consider restricting later)
   - `gh` (binary allowed, writes blocked by denylist)
   - `openclaw` (binary allowed, admin commands blocked by denylist)

**Important:** The allowlist matches on binary path (`*/bash`), while the denylist matches on the full command string. This means we allow `bash` execution but deny specific commands within bash via the denylist.

**Caveat:** There is a known bypass where allowlisting a shell binary (`/bin/bash`, `/bin/zsh`) means any command run through that shell is treated as allowed (issue #23276). The denylist DOES still apply in this case (it's evaluated before the allowlist), so as long as our deny patterns are comprehensive, this is mitigated. But it means we must be thorough with deny patterns.

### Tier 2: Short-term (defense-in-depth layers) -- 2-4 hours

1. **PATH wrappers** for `git` and dangerous commands
   - Create `~/.openclaw/restricted-bin/git` that returns an error
   - Prepend to gateway's PATH
   - Not foolproof but catches simple cases

2. **Git hooks** as last-resort safety net
   - Add pre-commit and pre-push hooks to the openclaw-agents repo on the host
   - These already exist per the prior research

3. **Strengthen instructional guards**
   - Review and update AGENTS.md Red Lines
   - Add explicit consequences: "If you attempt git/gh write commands, the exec-approvals system will block the command. Do not retry."

### Tier 3: Medium-term (Docker sandboxing) -- 1-2 weeks

1. **Create a custom Docker image** for dev-pa agents with:
   - `bash`, `jq`, `curl`, `gh` (read-only config)
   - Agent scripts from `types/dev-pa/scripts/`
   - NO `git`, NO `sudo`, NO `openclaw` CLI
   - Network: `none` by default (or specific allowed endpoints)

2. **Configure per-agent sandbox** in `openclaw.json`:
   ```json
   {
     "agents": {
       "defaults": {
         "sandbox": {
           "backend": "docker",
           "docker": {
             "image": "openclaw-agents/dev-pa-sandbox:latest",
             "network": "none",
             "binds": [
               "~/.openclaw/agents/AGENT_ID:/workspace:rw",
               "~/.openclaw/media/AGENT_ID:/media:rw"
             ]
           }
         }
       }
     }
   }
   ```

3. **Handle `openclaw message send`** -- agents need Gateway access for messaging. Options:
   - Bind-mount the OpenClaw socket into the container
   - Use a network bridge to allow only Gateway communication
   - Create a wrapper that proxies message-send requests

### Tier 4: Long-term (custom plugin or upstream features) -- ongoing

1. **Monitor issue #60943** (Pre/Post Tool Use Hooks) -- when this ships, we get Claude Code-style shell script hooks at the Gateway level. This would be the cleanest enforcement mechanism.

2. **Monitor issue #46441** (Pluggable Guardrail Provider Interface) -- a standard interface for tool authorization that would let us write a simple guardrail provider.

3. **Evaluate writing a custom OpenClaw plugin** if the exec-approvals denylist proves too coarse:
   - TypeScript plugin using the Plugin SDK
   - Register `before_tool_call` hook
   - Regex-based command inspection with per-agent policies
   - Full audit logging

4. **Evaluate ClawBands** if it matures beyond v1.0.0 -- the policy engine architecture is exactly what we need, but maturity is a concern.

---

## 8. Implementation Roadmap

### Phase 1: Exec-Approvals Configuration (Week 1)

**Dev machine tasks:**
1. Draft `exec-approvals.json` with default denylist + per-agent overrides
2. Create a validation script to verify denylist completeness
3. Document the configuration in CLAUDE.md and invariants

**Host tasks:**
1. Deploy `exec-approvals.json` to `~/.openclaw/`
2. Test with one agent first (e.g., dev1) -- verify:
   - Agent scripts still work (bash, scripts/*.sh)
   - `gh issue view` works (read-only)
   - `gh issue create` is blocked (write)
   - `git` commands are blocked
   - `openclaw message send` works
   - `openclaw gateway stop` is blocked
3. Roll out to all agents
4. Monitor for false positives (legitimate commands blocked)

### Phase 2: Defense-in-Depth (Week 2)

**Dev machine tasks:**
1. Create PATH wrapper scripts
2. Update AGENTS.md with enforcement documentation

**Host tasks:**
1. Deploy PATH wrappers
2. Verify git hooks are in place
3. Run `openclaw security audit` to verify configuration

### Phase 3: Docker Sandboxing Evaluation (Week 3-4)

**Dev machine tasks:**
1. Create Dockerfile for dev-pa sandbox image
2. Test locally on dev machine
3. Document sandbox configuration

**Host tasks:**
1. Install Docker (if not present)
2. Deploy sandbox image
3. Test with one agent
4. Evaluate performance impact (Docker on macOS overhead)
5. Decision: proceed with Docker or wait for upstream features

---

## 9. Open Questions & Risks

### Open questions

1. **Exec-approvals denylist availability:** Is the denylist feature (PR #47848) in our current OpenClaw version? Need to check on host. If not, we need to update OpenClaw first.

2. **Shell bypass:** If we allowlist `bash`, can an agent run `bash -c "git push"` and have the denylist catch it? The denylist matches the full command string, but the question is whether `bash -c "git push"` is seen as the command string or just `bash`. This needs testing.

3. **`gh api` filtering:** `gh api` can perform mutations (POST, PUT, DELETE, PATCH). We could block all `gh api` calls, or we could try to match `--method` args. Blocking all is safer.

4. **Cron job scripts:** Cron job payloads instruct agents to run scripts. Do these scripts inherit the same exec-approvals? They should, since they run through the same exec tool.

5. **Performance impact:** Does exec-approvals add measurable latency to command execution? With 18 agents running concurrent commands, this matters.

6. **Docker on macOS:** What is the actual performance overhead? Our host is a Mac.

### Risks

1. **False positives:** Overly restrictive denylist could block legitimate agent work. Mitigation: test thoroughly with one agent, maintain an audit log, iterate.

2. **Incomplete denylist:** Missing deny patterns leave gaps. Mitigation: start with comprehensive patterns, add as new bypass vectors are discovered. Consider a periodic audit script.

3. **OpenClaw version dependency:** Denylist feature may not be in our version. Mitigation: check version, update if needed (existing update pipeline handles this).

4. **Shell bypass via encoded commands:** An agent could theoretically encode a command as base64 and decode+execute it. Mitigation: this is an edge case that instructional guards + denylist together make very unlikely.

5. **Breaking existing functionality:** Agents currently run scripts, send messages, and interact with GitHub. Any restriction must preserve this. Mitigation: thorough testing phase.

---

## 10. Sources

### OpenClaw Official Documentation
- [Sandboxing - OpenClaw](https://docs.openclaw.ai/gateway/sandboxing)
- [Security - OpenClaw](https://docs.openclaw.ai/gateway/security)
- [Exec Approvals - OpenClaw](https://docs.openclaw.ai/tools/exec-approvals)
- [Tools and Plugins - OpenClaw](https://docs.openclaw.ai/tools)
- [Hooks - OpenClaw](https://docs.openclaw.ai/automation/hooks)
- [Permissions, Sandbox & Security Settings - OpenClaw Help](https://www.getopenclaw.ai/en/help/permissions-sandbox-security)

### OpenClaw GitHub Issues
- [Feature: Tiered agent permissions with sandboxed tool policies #5641](https://github.com/openclaw/openclaw/issues/5641) -- closed, not planned
- [Wire up before_tool_call plugin hook #5943](https://github.com/openclaw/openclaw/issues/5943) -- closed (fixed)
- [Plugin hooks never invoked #5513](https://github.com/openclaw/openclaw/issues/5513)
- [Sandbox write tool restriction inconsistent #9348](https://github.com/openclaw/openclaw/issues/9348)
- [Feature: Pre/Post Tool Use Hooks #60943](https://github.com/openclaw/openclaw/issues/60943) -- open, April 2026
- [Feature: tool:pre hook event for security validation #12311](https://github.com/openclaw/openclaw/issues/12311)
- [Pluggable Guardrail Provider Interface #46441](https://github.com/openclaw/openclaw/issues/46441)
- [Exec approvals command-content deny patterns #41140](https://github.com/openclaw/openclaw/issues/41140)
- [Exec-approvals denylist PR #47848](https://github.com/openclaw/openclaw/pull/47848)
- [Exec denylist for dangerous commands #6459](https://github.com/openclaw/openclaw/issues/6459)
- [Exec approvals /bin/zsh allowlist bypass #23276](https://github.com/openclaw/openclaw/issues/23276)
- [Per-agent tools.selfDeny #44253](https://github.com/openclaw/openclaw/issues/44253)
- [Network Access Control (allowedDomains/denyDomains) #39685](https://github.com/openclaw/openclaw/issues/39685)
- [Pre-container-creation hook for dynamic sandbox bind mounts #61673](https://github.com/openclaw/openclaw/issues/61673)
- [Security by Intent: Progressive Permission Pattern Generalization #48532](https://github.com/openclaw/openclaw/issues/48532)

### Community & Third-Party
- [ClawBands - GitHub](https://github.com/SeyZ/clawbands) -- security middleware, MIT license
- [ClawBands - Security Boulevard coverage](https://securityboulevard.com/2026/02/clawbands-github-project-looks-to-human-controls-on-openclaw-ai-agents/)
- [OpenClaw PRISM paper (arxiv 2603.11853)](https://arxiv.org/abs/2603.11853) -- defense-in-depth runtime security layer
- [SlowMist OpenClaw Security Practice Guide](https://github.com/slowmist/openclaw-security-practice-guide) -- agent-facing security hardening
- [Anthropic Sandbox Runtime](https://github.com/anthropic-experimental/sandbox-runtime) -- OS-level sandboxing
- [Tool Policies & Filtering - DeepWiki](https://deepwiki.com/openclaw/openclaw/3.4.1-exec-tool-and-exec-approvals)

### Security Research & Guides
- [OpenClaw Security Guide 2026 - Contabo](https://contabo.com/blog/openclaw-security-guide-2026/)
- [How to Harden OpenClaw Security - 3-Tier Guide](https://aimaker.substack.com/p/openclaw-security-hardening-guide)
- [OpenClaw Security Configuration Guide - BetterLink](https://eastondev.com/blog/en/posts/ai/20260204-openclaw-secure-deployment/)
- [Securing OpenClaw - Auth0](https://auth0.com/blog/five-step-guide-securing-moltbot-ai-agent/)
- [OpenClaw Security Engineer's Cheat Sheet - Semgrep](https://semgrep.dev/blog/2026/openclaw-security-engineers-cheat-sheet/)
- [A Systematic Security Evaluation of OpenClaw](https://arxiv.org/html/2604.03131v1)
- [Escaping the Agent: Bypass OpenClaw's Security Sandbox - Snyk Labs](https://labs.snyk.io/resources/bypass-openclaw-security-sandbox/)
- [How to Sandbox AI Agents in 2026 - Northflank](https://northflank.com/blog/how-to-sandbox-ai-agents)

### Agent Sandboxing (General)
- [Run OpenClaw Securely in Docker Sandboxes - Docker](https://www.docker.com/blog/run-openclaw-securely-in-docker-sandboxes/)
- [AI Agent Sandbox Environment - Setup Guide 2026](https://fast.io/resources/ai-agent-sandbox-environment/)
- [Deep Dive into AI Agent Sandboxes - UBOS](https://ubos.tech/news/deep-dive-into-ai-agent-sandboxes-security-models-and-codex-permissions/)
- [Sandboxing Claude Code on macOS - Infralovers](https://www.infralovers.com/blog/2026-02-15-sandboxing-claude-code-macos/)

### Prior Internal Research
- `docs/research/blocking-agent-git-commands-2026-03-31.md`
- `docs/research/clawbands-openclaw-research-2026-03-27.md`
- `docs/research/openclaw-production-best-practices-2026-04-01.md`
- `docs/research/openclaw-cron-shell-capabilities-2026-04-02.md`
