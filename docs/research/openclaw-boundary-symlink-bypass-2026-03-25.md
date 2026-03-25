# OpenClaw Boundary Security Check: Symlink Analysis

**Date:** 2026-03-25
**Status:** Actionable findings with recommended solutions

---

## Problem Statement

OpenClaw's workspace boundary check rejects files whose real path (after resolving symlinks) falls outside the agent's configured workspace directory. We use `stow` to symlink `.openclaw/` from the `openclaw-agents` repo to `~/.openclaw/`, and the repo itself contains symlinks pointing to shared "types" (`types/dev-pa/`). The boundary check follows the full symlink chain and rejects the file.

## Current Symlink Chain

```
Agent workspace (configured):
  /Users/<hostname>/openclaw-agents/.openclaw/agents/dev1

Stow creates (in ~/.openclaw/):
  ~/.openclaw/agents/dev1/SOUL.md
    -> ../../../openclaw-agents/.openclaw/agents/dev1/SOUL.md

Repo file is ALSO a symlink:
  /Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/SOUL.md
    -> ../../../types/dev-pa/SOUL.md

Final realpath:
  /Users/<hostname>/openclaw-agents/types/dev-pa/SOUL.md
```

The workspace root is `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1`.
The realpath `/Users/<hostname>/openclaw-agents/types/dev-pa/SOUL.md` is NOT inside that root.
The boundary check fires.

## How the Boundary Check Works

Source file: `boundary-file-read-Bb0WDUIN.js` (in openclaw dist)

### Key Function: `resolveBoundaryPath()`

1. Takes `rootPath` (workspace dir), `absolutePath` (file being read), and optional `rootCanonicalPath`
2. Resolves `rootCanonicalPath` via `resolvePathViaExistingAncestor()` (uses `fs.realpathSync`)
3. For each path segment from root to target, calls `lstat()` to detect symlinks
4. When a symlink is found, resolves it via `realpath()` and calls `applyResolvedSymlinkHop()`
5. `applyResolvedSymlinkHop()` checks: `isPathInside(rootCanonicalPath, linkCanonical)`
6. If the resolved symlink target is NOT inside the canonical root, throws `symlinkEscapeError`

### Key Function: `isPathInside(root, target)`

Simple relative-path check: resolves both paths, computes `path.relative()`, and rejects if it starts with `..` or is absolute.

### Key Function: `assertInsideBoundary()`

Called at multiple points. Throws: `"Path resolves outside workspace root (~/.openclaw/agents/dev1): ~/openclaw-agents/types/dev-pa/SOUL.md"`

### `readWorkspaceFileWithGuards()` (in agent-scope)

This is the entry point. It calls `openBoundaryFile()` with:
- `absolutePath`: the file being read
- `rootPath`: the workspace directory (from config)
- `boundaryLabel`: `"workspace root"`

### No User-Facing Config Options

There is **no** config key for:
- `boundary`, `security`, `trusted`, `trustedPaths`, `allowedPaths`, `openBoundary`, `disableBoundary`
- No per-agent boundary override
- No allowlist mechanism

The `skipLexicalRootCheck` parameter exists but is only used internally by OpenClaw's own code (auth profiles, gateway CLI, etc.) -- never exposed to user config.

## Solutions (Ranked by Invasiveness)

### OPTION 1: Set workspace root to the repo root (RECOMMENDED -- Least Invasive)

**Change:**
```json
{
  "agents": {
    "list": [
      {
        "id": "dev1",
        "workspace": "/Users/<hostname>/openclaw-agents",
        ...
      }
    ]
  }
}
```

**Why it works:** The boundary check resolves the workspace root's canonical path. If workspace = `/Users/<hostname>/openclaw-agents`, then `types/dev-pa/SOUL.md` is inside that root. The symlink chain resolves to `/Users/<hostname>/openclaw-agents/types/dev-pa/SOUL.md` which IS inside `/Users/<hostname>/openclaw-agents`.

**Trade-off:** The agent can "see" ALL files in the repo, not just its own directory. This means SOUL.md, IDENTITY.md, etc. for OTHER agents (e.g. `<your-org>`) would also be readable. But since this is a private config repo (not a shared production system), this is acceptable.

**Bootstrap file loading impact:** `loadWorkspaceBootstrapFiles()` looks for `SOUL.md`, `IDENTITY.md`, `AGENTS.md`, etc. directly in the workspace directory. If workspace = repo root, it would look for `/Users/<hostname>/openclaw-agents/SOUL.md` (not found) instead of `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/SOUL.md`. You would need to also place symlinks or files at the repo root for the agent to find them -- OR use a nested workspace path that still contains `types/`.

**Better variant:** Set workspace to `/Users/<hostname>/openclaw-agents/.openclaw` instead of the full repo root. This way `types/dev-pa/` (which lives at `.openclaw/../types/dev-pa/` relative to the repo) would still escape. So this does NOT work.

**Actually:** The symlink target is `../../../types/dev-pa/SOUL.md` from `.openclaw/agents/dev1/`. That resolves to `/Users/<hostname>/openclaw-agents/types/dev-pa/SOUL.md`. The workspace root must be at or above `/Users/<hostname>/openclaw-agents` for this to be inside.

**Conclusion:** Set `"workspace": "/Users/<hostname>/openclaw-agents"` and ensure bootstrap files (SOUL.md, IDENTITY.md, etc.) exist at `/Users/<hostname>/openclaw-agents/SOUL.md` (or use a subdirectory layout). This breaks the current bootstrap file discovery.

### OPTION 2: Move shared types INSIDE the workspace directory (Moderate)

**Change:** Instead of `types/dev-pa/` at repo root, place shared files under `.openclaw/agents/dev1/_shared/` or `.openclaw/shared/`.

For dev1, restructure so that:
```
openclaw-agents/.openclaw/agents/dev1/
  _shared/          <-- actual shared files live here
    SOUL.md
    AGENTS.md
    TOOLS.md
    ...
  SOUL.md -> _shared/SOUL.md     (symlinks within workspace)
  AGENTS.md -> _shared/AGENTS.md
```

**Why it works:** Symlinks resolve to paths inside the workspace root.

**Trade-off:** Duplicates the "shared" concept per agent. If `<your-org>` needs the same files, they would each have their own `_shared/` or you would symlink between agents (which again escapes boundary).

**Stow compatibility:** stow --no-folding would create individual file symlinks. The `_shared/` dir would need to be actual files in the repo, not symlinks themselves.

### OPTION 3: Eliminate the inner symlinks (Simple but less DRY)

**Change:** In the repo, replace the `types/dev-pa/SOUL.md` symlinks with actual file copies. Only stow-level symlinks remain.

```
openclaw-agents/.openclaw/agents/dev1/
  SOUL.md      <-- actual file (not symlink)
  AGENTS.md    <-- actual file
  IDENTITY.md  <-- actual file
```

**Why it works:** `realpath(~/.openclaw/agents/dev1/SOUL.md)` = `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/SOUL.md` -- inside workspace root.

**Trade-off:** Lose the DRY benefit of shared types. Each agent has its own copy of shared files. Acceptable if you use a script or git hook to sync them.

### OPTION 4: Use hardlinks instead of symlinks for the inner hop (Moderate)

**Change:** Replace the inner symlinks (`agents/dev1/SOUL.md -> types/dev-pa/SOUL.md`) with hardlinks.

**Why it works:** `lstat()` on a hardlink does NOT report `isSymbolicLink()`. The boundary check only follows symlinks, not hardlinks. The `realpathSync()` on a hardlink returns the path of the hardlink itself, not the other name.

**Trade-off:**
- Hardlinks don't work across filesystems
- Git does not track hardlinks (they appear as regular files)
- The `rejectHardlinks` check in `openVerifiedFileSync` (line 612-613): `if (params.rejectHardlinks && preOpenStat.isFile() && preOpenStat.nlink > 1)` -- this REJECTS hardlinks with nlink > 1! So **hardlinks would also be rejected**.

**Conclusion:** NOT viable due to `rejectHardlinks` check.

### OPTION 5: Patch the boundary check (Nuclear)

**Change:** Edit `boundary-file-read-Bb0WDUIN.js` to add an allowlist or skip check.

**Trade-off:** Breaks on every `openclaw` update. Not maintainable.

## RECOMMENDED APPROACH

**Option 3 (Eliminate inner symlinks)** is the simplest and most reliable approach.

The two-level symlink chain (stow symlink -> repo symlink -> shared types) is where the problem lies. The stow-level symlinks alone would work fine IF the repo files were actual files.

**Implementation:**

1. Move actual content from `types/dev-pa/` into each agent's directory:
   ```bash
   cd /Users/<hostname>/openclaw-agents
   # For each symlink in .openclaw/agents/dev1/
   for f in .openclaw/agents/dev1/*.md; do
     if [ -L "$f" ]; then
       target=$(readlink "$f")
       # resolve and copy
       cp --remove-destination "$(cd .openclaw/agents/dev1 && realpath "$target")" "$f"
     fi
   done
   ```

2. If you need to share files between agents, use a Makefile/script:
   ```bash
   # sync-shared.sh
   cp types/dev-pa/SOUL.md .openclaw/agents/dev1/SOUL.md
   cp types/dev-pa/SOUL.md .openclaw/agents/<your-org>/SOUL.md
   ```

3. Stow continues to work as before (`stow --no-folding -t ~ .`) since the stow-level symlinks resolve to real files in the repo.

**If DRY is essential**, consider Option 2 (move shared files inside each workspace directory) with symlinks that stay within the workspace boundary.

## Alternative: Lobby for an `allowedPaths` config

The codebase has no config option for this. Consider filing a feature request with OpenClaw for:
```json
{
  "agents": {
    "list": [{
      "id": "dev1",
      "workspace": "...",
      "boundary": {
        "additionalRoots": ["/Users/<hostname>/openclaw-agents/types"]
      }
    }]
  }
}
```

This would be the proper long-term fix.

## Technical Details for Reference

### Files analyzed:
- `boundary-file-read-Bb0WDUIN.js` - Core boundary path resolution (767 lines)
- `path-alias-guards-DSeY3vyo.js` - Hardlink and symlink guards (40 lines)
- `path-safety-Z97FO1K-.js` - `isWithinDir` utility (12 lines)
- `agent-scope-DvYJ0Ktc.js` - Agent workspace resolution, `readWorkspaceFileWithGuards` (607 lines)

### Key error messages:
- `"Path resolves outside workspace root (root): path"` - from `assertInsideBoundary`
- `"Symlink escapes workspace root (root): symlinkPath"` - from `symlinkEscapeError`
- `"Path escapes workspace root (root): path"` - from `pathEscapeError`
- `"Hardlinked path is not allowed under workspace root"` - from `assertNoHardlinkedFinalPath`

### Boundary check flow:
```
readWorkspaceFileWithGuards()
  -> openBoundaryFile(rootPath=workspaceDir, boundaryLabel="workspace root")
    -> resolveBoundaryPath()
      -> for each segment: lstat()
        -> if symlink: realpath() -> isPathInside(rootCanonical, linkCanonical)
          -> if outside: throw symlinkEscapeError
      -> assertInsideBoundary(rootCanonical, finalCanonical)
```
