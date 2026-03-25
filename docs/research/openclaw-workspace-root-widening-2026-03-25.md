# OpenClaw Workspace Root Widening Analysis

**Date:** 2026-03-25
**Subject:** Impact of setting dev1 workspace root to `/Users/<hostname>/openclaw-agents` instead of `.openclaw/agents/dev1`
**Status:** ACTIONABLE -- contains risks and recommendations

---

## Executive Summary

**Bootstrap file discovery uses FIXED FILENAMES at the workspace root -- NOT recursive scanning.** This means widening the workspace root to the repo root is structurally safe from a "loading the wrong files" perspective, because no bootstrap files (SOUL.md, AGENTS.md, etc.) currently exist at `/Users/<hostname>/openclaw-agents/`. However, the symlink boundary check would become MORE permissive, and there are important side effects around onboarding detection and workspace state.

**Verdict: Feasible but with caveats. The symlink problem is solved, but new risks are introduced.**

---

## Finding 1: Bootstrap File Discovery Is Fixed-Path, Not Recursive

**Source:** `agent-scope-DvYJ0Ktc.js`, lines 364-417

The `loadWorkspaceBootstrapFiles(dir)` function constructs an explicit, hardcoded list of exactly 7 filenames (plus an optional MEMORY.md), joined directly to the workspace root directory:

```
AGENTS.md        -> path.join(resolvedDir, "AGENTS.md")
SOUL.md          -> path.join(resolvedDir, "SOUL.md")
TOOLS.md         -> path.join(resolvedDir, "TOOLS.md")
IDENTITY.md      -> path.join(resolvedDir, "IDENTITY.md")
USER.md          -> path.join(resolvedDir, "USER.md")
HEARTBEAT.md     -> path.join(resolvedDir, "HEARTBEAT.md")
BOOTSTRAP.md     -> path.join(resolvedDir, "BOOTSTRAP.md")
MEMORY.md        -> (resolved dynamically, also at root)
```

**There is ZERO recursive scanning.** No `readdir`, no `glob`, no `walkDir` calls exist in the agent-scope module. The function iterates over its hardcoded list, attempts to read each file via `readWorkspaceFileWithGuards`, and marks files as `missing: true` if they don't exist.

**Implication:** OpenClaw would NOT discover `.openclaw/agents/dev1/SOUL.md`, `.openclaw/agents/<your-org>/SOUL.md`, or `types/dev-pa/SOUL.md` if the workspace root were `/Users/<hostname>/openclaw-agents`. It would ONLY look for `/Users/<hostname>/openclaw-agents/SOUL.md`, which does not exist.

---

## Finding 2: Current Symlink Boundary Problem Explained

**Source:** `openclaw-root-3m-COvjr.js`, lines 76-100, 227, 531-533

The `readWorkspaceFileWithGuards` function calls `openBoundaryFile` which performs a **boundary path resolution** check. This check:

1. Resolves the canonical (real) path of the file via `realpath`
2. Asserts that the canonical path is **inside** the workspace root's canonical path

Currently, with workspace = `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1`:

- `SOUL.md` is a symlink -> `../../../types/dev-pa/SOUL.md`
- Canonical path resolves to `/Users/<hostname>/openclaw-agents/types/dev-pa/SOUL.md`
- The boundary root is `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1`
- `/Users/<hostname>/openclaw-agents/types/dev-pa/SOUL.md` is OUTSIDE the boundary root
- **Result: The symlink is rejected** with "Path resolves outside workspace root"

If workspace were `/Users/<hostname>/openclaw-agents`:

- Same symlink resolves to `/Users/<hostname>/openclaw-agents/types/dev-pa/SOUL.md`
- Boundary root is `/Users/<hostname>/openclaw-agents`
- `/Users/<hostname>/openclaw-agents/types/dev-pa/SOUL.md` IS inside the boundary root
- **Result: The symlink would be accepted**

---

## Finding 3: No Bootstrap Files Exist at Repo Root (Currently Safe)

Verified scan of `/Users/<hostname>/openclaw-agents/`:

```
AGENTS.md     -> MISSING
SOUL.md       -> MISSING
TOOLS.md      -> MISSING
IDENTITY.md   -> MISSING
USER.md       -> MISSING
HEARTBEAT.md  -> MISSING
BOOTSTRAP.md  -> MISSING
MEMORY.md     -> MISSING
```

Since none of these files exist at the repo root, OpenClaw would mark all bootstrap files as `missing: true` and the agent would have NO personality, NO instructions, NO tools guidance, and NO agents configuration.

**This means you CANNOT simply set workspace to the repo root.** You must ALSO place (or symlink) the bootstrap files there.

---

## Finding 4: CLAUDE.md Is NOT Loaded by OpenClaw

OpenClaw's bootstrap loader has NO awareness of `CLAUDE.md`. That filename does not appear in any of the bootstrap file lists. `CLAUDE.md` is a Claude Code concept, not an OpenClaw concept. There is no information leakage risk from CLAUDE.md.

---

## Finding 5: Other Agent Contamination Is Not Possible

Since discovery is fixed-filename-at-root (not recursive), even with workspace = `/Users/<hostname>/openclaw-agents`:

- `.openclaw/agents/<your-org>/SOUL.md` would NOT be found (not at root)
- `.openclaw/agents/dev1/AGENTS.md` would NOT be found (not at root)
- Only `openclaw-agents/SOUL.md`, `openclaw-agents/AGENTS.md`, etc. would be checked

**No cross-agent contamination risk from widening.**

---

## Finding 6: Workspace Onboarding Detection Side Effects

**Source:** `agent-scope-DvYJ0Ktc.js`, lines 256-335

The `ensureAgentWorkspace` function has "brand new workspace" detection. It checks whether the workspace directory contains ANY of these files/dirs:

```
AGENTS.md, SOUL.md, TOOLS.md, IDENTITY.md, USER.md, HEARTBEAT.md
memory/, MEMORY.md, .git/
```

If ALL are missing, it considers the workspace "brand new" and:
1. Writes template bootstrap files from defaults
2. Runs `git init`
3. Sets onboarding state

At `/Users/<hostname>/openclaw-agents`, `.git/` exists, so it would NOT be considered brand new. However, it WOULD write template files for any missing bootstrap files (SOUL.md, AGENTS.md, etc.) because `writeFileIfMissing` is called unconditionally for each. **This would create default template files at the repo root**, polluting it with generic OpenClaw templates.

---

## Finding 7: resolveAgentWorkspaceDir Configuration Path

**Source:** `agent-scope-DvYJ0Ktc.js`, lines 550-561

The workspace directory for dev1 is resolved from:
```json
{
  "id": "dev1",
  "workspace": "/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1"
}
```

To change it, you would modify `openclaw.json`:
```json
"workspace": "/Users/<hostname>/openclaw-agents"
```

---

## Finding 8: MINIMAL_BOOTSTRAP_ALLOWLIST for Subagent Sessions

**Source:** `agent-scope-DvYJ0Ktc.js`, lines 418-428

For subagent and cron sessions, a MINIMAL_BOOTSTRAP_ALLOWLIST filters loaded files to only:
- AGENTS.md
- TOOLS.md
- SOUL.md
- IDENTITY.md
- USER.md

HEARTBEAT.md and BOOTSTRAP.md are excluded from subagent sessions.

---

## Risk Assessment

### If Workspace = `/Users/<hostname>/openclaw-agents` (Repo Root)

| Risk | Severity | Description |
|------|----------|-------------|
| Empty bootstrap | CRITICAL | No bootstrap files at root -> agent has no personality/instructions |
| Template pollution | HIGH | `ensureAgentWorkspace` writes default templates to repo root |
| Wider boundary | LOW | Symlinks can now point anywhere within repo (intentional) |
| Workspace state dir | MEDIUM | `.openclaw/` subdir at repo root becomes workspace state dir |
| No cross-agent contamination | NONE | Fixed-filename discovery prevents this |
| No CLAUDE.md leakage | NONE | OpenClaw does not load CLAUDE.md |

### If Workspace = `/Users/<hostname>/openclaw-agents` WITH Symlinks at Root

If you symlink bootstrap files at the repo root:
```
/Users/<hostname>/openclaw-agents/SOUL.md -> types/dev-pa/SOUL.md
/Users/<hostname>/openclaw-agents/AGENTS.md -> types/dev-pa/AGENTS.md
...
```

| Risk | Severity | Description |
|------|----------|-------------|
| Symlinks resolve inside boundary | SOLVED | The original problem is fixed |
| Template overwrite | LOW | `writeFileIfMissing` won't overwrite existing symlinks |
| Git noise | MEDIUM | New symlinks in repo root tracked by git |
| Shared bootstrap | LOW | If both agents point to same root, they share bootstrap files |

---

## Recommendations

### Option A: Keep Current Workspace, Fix Symlinks (SAFEST)

Instead of widening the workspace root, restructure symlinks so their targets are INSIDE the workspace:

```
.openclaw/agents/dev1/
  types/dev-pa/    <-- copy or mount the shared files HERE
  SOUL.md -> types/dev-pa/SOUL.md   (now resolves inside boundary)
```

This avoids all workspace-widening side effects.

### Option B: Widen Workspace with Root-Level Symlinks (MODERATE RISK)

1. Change `openclaw.json`: `"workspace": "/Users/<hostname>/openclaw-agents"`
2. Create symlinks at repo root: `SOUL.md -> types/dev-pa/SOUL.md`, etc.
3. Add `IDENTITY.md` and `USER.md` as real files at repo root (agent-specific)
4. Add them to `.gitignore` if they shouldn't be tracked
5. Prevent template pollution by ensuring `ensureBootstrapFiles` finds them

### Option C: Use a Dedicated Workspace Subdir (CLEANEST)

Create `/Users/<hostname>/openclaw-agents/workspace-dev1/` as a dedicated workspace dir that:
- Contains the bootstrap symlinks
- Has `types/dev-pa/` as a relative ancestor within the same repo
- Keeps the repo root clean

---

## Key Source Files Examined

- `openclaw/dist/agent-scope-DvYJ0Ktc.js` -- Bootstrap file loading, workspace resolution
- `openclaw/dist/openclaw-root-3m-COvjr.js` -- Boundary path validation, symlink security
- `openclaw/dist/auth-profiles-DRjqKE3G.js` -- Session bootstrap injection, compaction
- `~/.openclaw/openclaw.json` -- Agent configuration (workspace paths)

---

## Conclusion

**Bootstrap file discovery is safe to widen** -- it uses fixed filenames, not recursive scanning, so it will never load the wrong files. **But widening creates operational side effects** (template pollution, workspace state location, need for root-level symlinks) that must be handled. The cleanest solutions are Option A (restructure symlinks within current workspace) or Option C (dedicated workspace subdir within the repo).
