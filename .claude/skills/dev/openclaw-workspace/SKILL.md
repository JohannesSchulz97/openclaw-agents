---
name: openclaw-workspace
description: "Audit and improve OpenClaw agent workspaces — understand which file controls which behavior, diagnose issues by layer, and make targeted improvements. Use when editing types/dev-pa/ or types/manager/ config files."
disable-model-invocation: true
---

## When to Use

Use when improving, auditing, or understanding agent workspace files as a working system. This includes editing files in `types/dev-pa/` or `types/manager/`.

This skill should also activate when asking why an agent behaves a certain way, how to make it more proactive or sharper, how to tune tone or autonomy, or how to evolve the workspace.

## Our Architecture

Agent workspace files are managed in `types/<type>/` and synced to all agents of that type via `sync-agents.sh`. Changes go through PRs on the dev machine — `deploy.sh` handles sync + stow on the host.

**Shared files (synced, overwritten on every deploy):**
SOUL.md, AGENTS.md, TOOLS.md, HEARTBEAT.md, BOOTSTRAP.md, scripts/, poll-config.json, DAILY-SUMMARY.template.md

**Per-agent files (host-only, never overwritten):**
IDENTITY.md, USER.md, MEMORY.md, work-schedule.json, memory/

**Key constraint:** Shared files cannot contain per-agent customizations. Any instruction like "make it yours" or "evolve this file" in a shared file is a broken promise — sync will overwrite it. Per-agent behavioral rules must live in USER.md or MEMORY.md (the only per-agent files loaded by OpenClaw).

## Improvement Surface

| Layer | Improve Here When | What Good Looks Like |
|------|-------------------|----------------------|
| SOUL.md | Tone, personality, confidence, warmth, bluntness, humor | Intentional, stable, human — not generic |
| IDENTITY.md | Name, vibe markers, self-description, emoji | Consistent self-presentation across sessions (per-agent) |
| AGENTS.md | Startup behavior, work style, boundaries, escalation rules | Starts strong, acts resourcefully, stays inside clear rules |
| TOOLS.md | Tool usage conventions, local notes, environment quirks | Uses tools better without pretending new tools exist |
| USER.md | Stable facts about the human, preferences, identity cues | Adapts to the person without a creepy dossier (per-agent) |
| MEMORY.md | Durable lessons, recurring priorities, long-term preferences | Sharp recall without bloat or staleness (per-agent, main session only) |
| memory/ daily notes | Recent context, current projects, recent mistakes or wins | Reasons from recency, not just old summaries (per-agent) |
| scripts/ | Deterministic operations, data fetching, state management | Reliable JSON output, proper error handling, follows json-response conventions |

## Core Rules

### 1. Diagnose by Layer, Not Generic Advice

Do not give vague "make it more proactive" advice without locating which file controls that behavior.

- Voice and personality → SOUL.md
- Stable self-presentation → IDENTITY.md
- Startup routines, decision defaults, red lines, escalation rules → AGENTS.md
- Tool notes and environment specifics → TOOLS.md
- Human-specific context → USER.md
- Durable recall → MEMORY.md; recent raw context → memory/ daily files
- Repeated domain workflows → scripts or narrower supporting files

### 2. Keep Bootstrap Files Compact and High-Leverage

AGENTS.md, SOUL.md, and TOOLS.md are bootstrap context loaded every session. Every line should earn its place.

- Move heavy procedures, niche runbooks, and long examples into scripts
- If behavior is inconsistent, check for prompt bloat, duplicate rules, contradictory instructions, and stale sections before adding more text
- Prefer one sharp rule in the right file over five overlapping paragraphs

### 3. Make the Smallest Change That Fixes the Behavior

Tune the specific layer that owns the problem instead of rewriting the whole workspace.

- Personality issues should not trigger a memory rewrite
- Identity issues should not trigger an AGENTS rewrite if IDENTITY.md is the real owner
- Memory drift should not trigger a SOUL rewrite
- Missing capability should not be patched into AGENTS.md if it belongs in a script
- Show concrete diffs and explain the expected behavioral change

### 4. Respect the Shared vs Per-Agent Boundary

- SOUL.md, AGENTS.md, TOOLS.md are **shared** — changes affect all agents of that type
- IDENTITY.md, USER.md, MEMORY.md are **per-agent** — changes affect one agent
- Before editing a shared file, consider whether the change applies to all agents or just one
- If it's agent-specific, it must go in a per-agent file

### 5. Respect Privacy and Session Boundaries

- MEMORY.md is high-trust personal context — do not copy into shared behavior files
- **Main sessions** load all 8 bootstrap files: SOUL, IDENTITY, USER, AGENTS, TOOLS, HEARTBEAT, BOOTSTRAP, MEMORY
- **Cron sessions** load only 5: AGENTS, TOOLS, SOUL, IDENTITY, USER (no MEMORY, HEARTBEAT, or BOOTSTRAP)
- Cron sessions are isolated from chat — agents cannot see DM history from a cron job
- Never recommend hidden workspace rewrites; improvements should be explicit and reviewable

## Common Traps

| Trap | Why It Fails | Better Move |
|------|--------------|-------------|
| Stuffing everything into AGENTS.md | Bootstrap context becomes noisy, contradictory, or truncated | Keep lean, move procedures into scripts |
| Treating SOUL.md as an execution manual | Personality and execution policy become one unstable blob | SOUL.md = identity and tone; AGENTS.md = operating rules |
| Ignoring IDENTITY.md | Name and vibe drift across sessions | Keep stable identity markers in IDENTITY.md |
| Using TOOLS.md to "enable" tools | Agent only has tools granted by runtime | TOOLS.md is for usage hints and local conventions only |
| Putting durable preferences in daily notes | Important context gets buried in recency noise | Promote stable patterns into MEMORY.md or USER.md |
| Putting current project churn in MEMORY.md | Long-term memory becomes stale and bloated | Keep fresh work in memory/ daily files |
| Editing shared files for per-agent needs | sync-agents.sh overwrites on next deploy | Use USER.md or MEMORY.md for per-agent rules |

## Default Audit Output

When auditing, produce:

1. **Current behavior map:** which files are driving tone, startup, memory, and capabilities
2. **Evidence:** stale rules, duplication, contradictions, missing layers
3. **Recommended changes:** low-risk and structural improvements with exact target files
4. **Next move:** specific diffs to review or apply
