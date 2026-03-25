# Investigation: dev1 Agent Ignores BOOTSTRAP.md on Fresh Start

**Date:** 2026-03-25
**Status:** Root cause identified -- model behavior issue, not file loading issue
**Severity:** High -- agent cannot self-initialize

---

## Summary

The dev1 agent was reset to a fresh state but did NOT enter the bootstrap flow when messaged on Slack. Instead it gave a generic "Hey! How can I help?" response. Investigation confirms that **OpenClaw correctly loads BOOTSTRAP.md into the system prompt**, but the **model (gpt-5.4 with thinkingLevel: low) ignored the instructions**.

---

## Root Cause Analysis

### Finding 1: BOOTSTRAP.md IS loaded into the system prompt (NOT the bug)

OpenClaw's file loading pipeline works correctly:

1. `loadWorkspaceBootstrapFiles()` in `agent-scope-DvYJ0Ktc.js` (line 364) loads all workspace files including BOOTSTRAP.md
2. `filterBootstrapFilesForSession()` (line 425) only filters for subagent/cron sessions -- main sessions get ALL files
3. `buildBootstrapContextFiles()` in `reply-Bm8VrLQh.js` (line 13988) converts loaded files into context embedded in the system prompt
4. The session is a direct Slack DM (not subagent, not cron), so BOOTSTRAP.md is NOT filtered out

**Evidence:** The `MINIMAL_BOOTSTRAP_ALLOWLIST` filtering only applies when `isSubagentSessionKey()` or `isCronSessionKey()` returns true. For a direct Slack DM, the filter is bypassed and all files pass through.

### Finding 2: AGENTS.md correctly instructs bootstrap detection (NOT the bug)

AGENTS.md (line 5-7) contains clear first-run instructions:
```
## First Run
If `BOOTSTRAP.md` exists, that's your birth certificate. Follow it, figure out who you are,
then delete it. You won't need it again.
```

The Session Startup section (line 9-18) tells the agent to read SOUL.md, USER.md, and memory files. BOOTSTRAP.md check is in the "First Run" section that precedes "Session Startup".

### Finding 3: The ACTUAL problem -- model + thinking level mismatch

The session transcript reveals:

- **Model:** `gpt-5.4` via `openai-codex` provider (openai-codex-responses API)
- **Thinking level:** `low`
- **Total input tokens:** 4,477 (including system prompt with all workspace files)
- **Output tokens:** 55 (just the greeting)
- **Response:** `"[[reply_to_current]] Hey dev1! How can I help?"`

The model received 4,477 input tokens which INCLUDES the system prompt with AGENTS.md, SOUL.md, BOOTSTRAP.md, etc. But with `thinkingLevel: low`, the model produced minimal reasoning and defaulted to a generic greeting instead of following the multi-step bootstrap procedure.

### Finding 4: Model configuration mismatch

- **CLAUDE.md says:** Model should be `google/gemini-3.1-pro`
- **Actual openclaw.json config:** `"model": "openai-codex/gpt-5.4"`
- **This is a significant discrepancy** -- the agent is running on a different model than documented

### Finding 5: workspace-state.json confirms bootstrap was seeded

```json
{
  "version": 1,
  "bootstrapSeededAt": "2026-03-25T07:30:35.971Z"
}
```

`bootstrapSeededAt` is set but `onboardingCompletedAt` is NOT set, confirming:
- OpenClaw detected BOOTSTRAP.md exists and marked it as seeded
- The agent never completed onboarding (never deleted BOOTSTRAP.md)
- The `bootstrapSeededAt` flag does NOT prevent BOOTSTRAP.md from being loaded into the system prompt (it's only used in workspace setup logic, not in the prompt builder)

### Finding 6: IDENTITY.md is still blank template

The IDENTITY.md in the repo still contains the blank template ("Fill this in during your first conversation"), confirming the bootstrap flow was never executed.

---

## File Accessibility Verification

| File | Exists | Symlink Target | Accessible |
|------|--------|---------------|------------|
| `~/.openclaw/agents/dev1/BOOTSTRAP.md` | Yes | `openclaw-agents/.openclaw/agents/dev1/BOOTSTRAP.md` | Yes |
| `openclaw-agents/.openclaw/agents/dev1/BOOTSTRAP.md` | Yes | `types/dev-pa/BOOTSTRAP.md` | Yes |
| `types/dev-pa/BOOTSTRAP.md` | Yes | (actual file) | Yes |
| `~/.openclaw/agents/dev1/AGENTS.md` | Yes | `openclaw-agents/.openclaw/agents/dev1/AGENTS.md` | Yes |
| `openclaw-agents/.openclaw/agents/dev1/AGENTS.md` | Yes | `types/dev-pa/AGENTS.md` | Yes |

The double-symlink chain resolves correctly. All files are readable.

---

## OpenClaw File Loading Pipeline (Verified)

```
loadWorkspaceBootstrapFiles(workspaceDir)
  |-- Loads: AGENTS.md, SOUL.md, TOOLS.md, IDENTITY.md, USER.md, HEARTBEAT.md, BOOTSTRAP.md, MEMORY.md
  |-- Each file: readWorkspaceFileWithGuards() -> { name, path, content, missing }
  v
filterBootstrapFilesForSession(files, sessionKey)
  |-- IF subagent or cron: filter to MINIMAL_BOOTSTRAP_ALLOWLIST (AGENTS, TOOLS, SOUL, IDENTITY, USER)
  |-- IF main session (direct DM): pass ALL files through (including BOOTSTRAP.md)
  v
applyBootstrapHookOverrides()
  |-- Allow hooks to modify the file list
  v
sanitizeBootstrapFiles()
  |-- Validate each file has valid .path field
  v
buildBootstrapContextFiles()
  |-- Convert to EmbeddedContextFile[] for system prompt injection
  |-- Respects maxChars (default 20,000 per file) and totalMaxChars (default 150,000)
  v
buildAgentSystemPrompt({ contextFiles: ... })
  |-- Embeds all context files into the system prompt sent to the model
```

---

## Recommendations

### Immediate Fix (Priority 1): Increase thinking level for bootstrap

The `thinkingLevel: low` with gpt-5.4 is insufficient for the multi-step bootstrap procedure. Options:

1. **Set thinkingLevel to "medium" or "high" for new sessions** where BOOTSTRAP.md exists
2. **Switch to the documented model** (`google/gemini-3.1-pro`) which may handle the instructions better
3. **Add explicit first-message detection** in AGENTS.md that is harder for low-thinking models to ignore

### Structural Fix (Priority 2): Make bootstrap harder to miss

The current AGENTS.md puts the bootstrap check in a "First Run" section that a model can easily skip if it jumps to "Session Startup". Consider:

1. Move BOOTSTRAP.md detection to the TOP of "Session Startup" as step 0
2. Add stronger language: "STOP. Before reading anything else, check if BOOTSTRAP.md exists."
3. Consider having OpenClaw add a `[FIRST RUN - BOOTSTRAP REQUIRED]` marker in the system prompt when BOOTSTRAP.md exists and onboarding is not complete

### Configuration Fix (Priority 3): Align model config

Update `openclaw.json` to use the intended model:
```json
"model": "google/gemini-3.1-pro"
```
Or update CLAUDE.md to reflect the actual model being used (`openai-codex/gpt-5.4`).

---

## Files Examined

- `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/AGENTS.md` (symlink -> types/dev-pa/AGENTS.md)
- `/Users/<hostname>/openclaw-agents/types/dev-pa/BOOTSTRAP.md` (actual file, 55 lines)
- `/Users/<hostname>/openclaw-agents/.openclaw/agents/dev1/IDENTITY.md` (blank template)
- `/Users/<hostname>/.openclaw/agents/dev1/.openclaw/workspace-state.json`
- `/Users/<hostname>/.openclaw/agents/dev1/sessions/16f4aa5f-9fef-4910-9a4f-6b510ef75974.jsonl`
- `/Users/<hostname>/.openclaw/agents/dev1/sessions/sessions.json`
- `/Users/<hostname>/.openclaw/openclaw.json` (agent config, model config)
- OpenClaw source: `dist/agent-scope-DvYJ0Ktc.js` (workspace loading)
- OpenClaw source: `dist/reply-Bm8VrLQh.js` (bootstrap file resolution, system prompt building)
- OpenClaw source: `dist/plugin-sdk/agents/workspace.d.ts` (type definitions)
