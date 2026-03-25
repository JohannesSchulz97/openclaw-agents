# Agent Memory Isolation Audit

**Date:** 2026-03-24
**Scope:** Verify that agents `dev1` and `<your-org>` do NOT share memories or sessions
**Verdict:** No shared memories or sessions detected. One concern: orphaned shared memory directory.

---

## 1. Memory Files Per Agent

### dev1 (.openclaw/agents/dev1/memory/)

| File | Contents |
|------|----------|
| `poll-state.json` | `interval_minutes: 240`, `last_interaction: 2026-03-24T05:48:00Z` |
| `2026-03-24.md` | Daily journal: bootstrapping notes, met human from Homburg, Germany |

### <your-org> (.openclaw/agents/<your-org>/memory/)

| File | Contents |
|------|----------|
| `poll-state.json` | `interval_minutes: 240`, `last_interaction: 2026-03-24T08:10:17Z`, `last_check: 2026-03-24T08:10:17Z`, `message_sent: true` |

**Observation:** <your-org> has NO daily journal files (no equivalent of `2026-03-24.md`). dev1 has a richer memory state. The two `poll-state.json` files have different schemas (<your-org> includes `last_check` and `message_sent` fields that dev1 lacks) and different timestamps, confirming they are independent.

---

## 2. Session and Workspace State

### dev1 (.openclaw/agents/dev1/.openclaw/workspace-state.json)
```json
{ "version": 1, "bootstrapSeededAt": "2026-03-23T07:40:00.010Z" }
```

### <your-org> (.openclaw/agents/<your-org>/.openclaw/workspace-state.json)
```json
{ "version": 1, "bootstrapSeededAt": "2026-03-24T06:09:18.682Z" }
```

**Observation:** Different bootstrap timestamps (dev1 seeded ~22 hours earlier). Each agent maintains its own `.openclaw/workspace-state.json`. No session IDs or session files found beyond these workspace states.

---

## 3. Cross-References Between Agents

| Check | Result |
|-------|--------|
| Grep for "<your-org>" in dev1/ | No matches |
| Grep for "dev1" in <your-org>/ | No matches |
| Symlinks anywhere under .openclaw/agents/ | None found |
| References to "agents/memory" (shared dir) in any agent file | None found |
| QMD / kuzu database files | None found |

**Observation:** Zero cross-references. Neither agent mentions the other. No symlinks exist anywhere in the agents tree.

---

## 4. Shared Directory: .openclaw/agents/memory/

| File | Contents |
|------|----------|
| `poll-state.json` | `interval_minutes: 240`, `last_interaction: 2026-03-23T15:19:57Z` |

**Analysis:** This directory sits at the agents level (peer to `dev1/` and `<your-org>/`), not inside either agent workspace. It contains a single `poll-state.json` with a timestamp (2026-03-23T15:19:57Z) that is older than both agents' own poll states. Key observations:

- It is NOT referenced by any file in either agent workspace.
- It is NOT symlinked to or from either agent.
- Its timestamp predates both agents' current poll states, suggesting it may be a leftover from an earlier configuration or a default/template.
- No agent configuration file points to this shared directory.

**Cross-contamination risk: LOW but present.** If the OpenClaw runtime ever falls back to `.openclaw/agents/memory/` as a default memory path (e.g., when an agent name is not resolved correctly), both agents could inadvertently read from or write to this shared location. The risk is theoretical -- no evidence it is currently happening.

**Recommendation:** Either (a) delete `.openclaw/agents/memory/` if it is orphaned, or (b) clarify its purpose and ensure no agent runtime path resolves to it.

---

## 5. QMD Memory References

No QMD databases (`.qmd`, `.db`, `.sqlite`) found under `.openclaw/agents/`. The CLAUDE.md mentions QMD as an alternative memory backend with known issues (GitHub issue #11308), but it is not deployed for either agent. Both agents use file-based memory only.

---

## 6. Summary

| Question | Answer |
|----------|--------|
| Do the agents share any memory files? | NO |
| Do the agents share any session files? | NO |
| Are there any symlinks between agents? | NO |
| Do any files cross-reference the other agent? | NO |
| Does `.openclaw/agents/memory/` reference either agent? | NO |
| Is QMD deployed? | NO |
| Is there any cross-contamination risk? | LOW -- orphaned shared `memory/` directory could theoretically be hit by a runtime fallback path |

**Overall verdict: The two agents have fully isolated memory and session state.** The only item warranting attention is the orphaned `.openclaw/agents/memory/` directory, which should be investigated for purpose or removed.
