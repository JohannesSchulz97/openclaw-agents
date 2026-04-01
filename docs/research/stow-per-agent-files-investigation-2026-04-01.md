# Stow Per-Agent Files Overwrite Investigation

**Date:** 2026-04-01
**Status:** PARTIALLY FIXED -- residual risk remains
**Branch:** feature/bootstrap-improvements

---

## Executive Summary

The `.stow-local-ignore` file is correctly configured and GNU Stow 2.4.1 respects the regex patterns, meaning stow will NOT create symlinks for per-agent files (IDENTITY.md, USER.md, .agent-type, memory/). However, the **current live data for dev10-jean is already stale** -- the live `~/.openclaw/` copy has template placeholders while the repo copy has enriched data. This means a previous `stow --adopt` already pulled stale data into the live directory, and the protection was added after the damage occurred but before the live files were restored.

## Findings

### 1. `.stow-local-ignore` -- Correctly Configured

File at `/Users/<hostname>/openclaw-agents/.openclaw/.stow-local-ignore` contains:

```
agents/[^/]+/IDENTITY\.md
agents/[^/]+/USER\.md
agents/[^/]+/\.agent-type
agents/[^/]+/memory
agents/[^/]+/\.BOOTSTRAP\.md\.done
```

**Verification:** A `stow --no-folding -t ~/.openclaw -n -vv .` dry-run shows zero mentions of IDENTITY.md, USER.md, .agent-type, or memory files. Stow correctly ignores them.

### 2. `sync-agents.sh` -- Correctly Skips Per-Agent Files

The script at line 98-106 handles template files (IDENTITY.md, USER.md) with an explicit guard:

```bash
if [[ -f "$template" && ! -f "$dst" ]]; then
    sync_file "$template" "$dst"
fi
```

Templates are only copied when the destination file **does not exist**. Existing per-agent files are never overwritten by sync.

### 3. `migrate-per-agent-files.sh` -- Exists and Works

The script converts any per-agent symlinks back to real files. It handles IDENTITY.md, USER.md, .agent-type, and memory/ contents. It is idempotent and safe to run repeatedly.

### 4. Current File Status in `~/.openclaw/` -- All Real Files (Not Symlinks)

Checked agents: dev10-jean, dev10, dev10, dev10. All per-agent files are regular files, not symlinks:

```
-rw-r--r--  dev10-jean/IDENTITY.md
-rw-r--r--  dev10-jean/USER.md
-rw-r--r--  dev10/IDENTITY.md
-rw-r--r--  dev10/USER.md
```

Shared files (SOUL.md, AGENTS.md) are correctly symlinked:

```
lrwxr-xr-x  dev10-jean/SOUL.md -> ../../../openclaw-agents/.openclaw/agents/dev10-jean/SOUL.md
```

### 5. CRITICAL: dev10-Jean Live Data is STALE

The live file at `~/.openclaw/agents/dev10-jean/USER.md` contains **empty template fields**:

```
- **Name:**
- **What to call them:**
- **Timezone:**
- **Notes:**
```

But the repo file at `openclaw-agents/.openclaw/agents/dev10-jean/USER.md` has **enriched data**:

```
- **Name:** dev10-Jean
- **What to call them:** PJ
- **Timezone:** Europe/Zurich
- **Notes:** French, lives in Lausanne, Switzerland...
```

This means the `.stow-local-ignore` protection was added AFTER a careless stow already overwrote the live data with template content. The repo was later updated (likely via bootstrap or manual edit on 2026-03-31), but the live copy was never refreshed from the repo because `.stow-local-ignore` now prevents stow from touching it.

**The protection is working as designed, but it also prevents recovery of the enriched data.**

### 6. Other Agents -- Minor Drift Only

- **dev10:** Only trailing newline difference (harmless)
- **dev7:** Only trailing newline difference (harmless)
- **dev10, dev10:** Not checked in detail but appear consistent

## Can the Issue Recur?

### Scenario Analysis

| Scenario | Protected? | Notes |
|----------|-----------|-------|
| Normal `stow` (no --adopt) | YES | `.stow-local-ignore` prevents symlink creation |
| `stow --adopt` | YES | `.stow-local-ignore` prevents adoption of ignored files |
| `sync-agents.sh` alone | YES | Only copies templates when destination missing |
| Creating a new agent | SAFE | `create-agent.sh` creates real files from templates |
| Manual `cp` or `rsync` from repo to live | NO | Bypasses stow entirely -- would overwrite |
| Deleting live file + running stow | PARTIAL | Stow ignores the file, but `sync-agents.sh` would recreate from template (since `! -f "$dst"` would be true) |

### Remaining Risks

1. **Manual file operations** that bypass stow (cp, rsync directly) are not protected.
2. **Deleting a per-agent file** in `~/.openclaw/` and then running `sync-agents.sh` would recreate it from the blank template, losing any agent-populated data.
3. **The repo copy diverging from the live copy** creates confusion about which is authoritative. Right now, PJ's repo copy is richer than the live copy.

## Recommendations

### Immediate (fix PJ's live data)

Copy the enriched repo data to the live location for dev10-jean:

```bash
cp /Users/<hostname>/openclaw-agents/.openclaw/agents/dev10-jean/USER.md ~/.openclaw/agents/dev10-jean/USER.md
```

### Structural

1. **Document the "no recovery" side effect** -- `.stow-local-ignore` protects against overwrites but also prevents stow from restoring enriched data. Recovery requires manual `cp`.

2. **Add a `restore-per-agent-files.sh` script** that copies per-agent files FROM repo TO live (inverse of `stow --adopt`). This would be the safe way to push repo-side changes to live without risking stow-related issues.

3. **Consider making the repo NOT store per-agent files at all** -- if they are truly runtime-only and agent-managed, they should not be in git. The repo would only have templates in `types/`, and live files would be authoritative. This eliminates the "which copy is right?" confusion entirely.

## Conclusion

The `.stow-local-ignore` fix is correctly implemented and prevents stow from overwriting per-agent files going forward. The `sync-agents.sh` script also correctly guards against overwriting existing files. The `migrate-per-agent-files.sh` script exists as a safety net. **The core issue cannot recur through normal stow/sync workflows.**

However, dev10-jean's live USER.md is currently stale (has template placeholders instead of enriched data), which is a residual artifact from the original incident that needs manual correction.
