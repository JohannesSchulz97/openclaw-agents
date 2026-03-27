# QMD Memory Backend Research

**Date:** 2026-03-27
**Related Issue:** openclaw-agents #21 (Integrate QMD as memory layer for dev-pa agents)
**Status:** NOT ACTIVATED, NOT INSTALLED

---

## 1. Current Activation Status

### Is QMD installed?
**NO.** `qmd` binary is not found in PATH. Neither `bun pm ls -g` nor `which qmd` return results.

### Is QMD configured?
**NO.** `~/.openclaw/openclaw.json` has no `memory` key set at all (returns "NOT SET"). No individual agent has a memory backend override. The system is running on OpenClaw's default memory backend (which is `local` when nothing is specified).

### Summary
- `memory.backend` in openclaw.json: **not set** (defaults to local)
- `qmd` binary: **not installed**
- Per-agent memory overrides: **none** (checked all 20 agents)

---

## 2. What is QMD?

QMD ("Query Markup Documents") is an **on-device search engine** created by Tobi Lutke. It indexes markdown notes, meeting transcripts, documentation, and knowledge bases for local search.

### Core capabilities:
- **BM25 full-text search** for keyword matching
- **Vector semantic search** using local embeddings (node-llama-cpp with GGUF models)
- **LLM re-ranking** for improved result quality
- All processing happens locally -- no external APIs required

### Search modes:
- `qmd search "query"` -- Fast keyword search (BM25)
- `qmd vsearch "query"` -- Semantic search via embeddings
- `qmd query "query"` -- Hybrid search + LLM reranking (highest quality)
- `qmd get "path/file.md"` -- Retrieve specific documents

### Integration options:
- **MCP server** for Claude Desktop and LLM clients
- **Claude Code plugin** via marketplace
- **HTTP MCP server** for persistent/shared instances
- **SDK/Library** for Node.js/Bun programmatic use

### As OpenClaw memory backend:
QMD can serve as an alternative to OpenClaw's default `local` memory backend, providing richer semantic search over agent memory/context. Configuration is via `memory.backend: "qmd"` in `openclaw.json`.

---

## 3. How to Activate QMD

### Step 1: Install QMD
```bash
bun install -g https://github.com/tobi/qmd
# OR
npm install -g @tobilu/qmd
```

### Step 2: Verify installation
```bash
qmd --version
```

### Step 3: Configure OpenClaw
Edit `~/.openclaw/openclaw.json` and add:
```json
{
  "memory": {
    "backend": "qmd"
  }
}
```

### Step 4: Restart the gateway
```bash
openclaw gateway restart
```

### Step 5: Verify
Check that agents can recall memory across sessions. Test with a single agent first before rolling out to all 19 dev-pa agents.

---

## 4. Known Issues -- CRITICAL

### Upstream Issue #11308 (CLOSED but problems persist)

The upstream OpenClaw issue #11308 ("QMD Memory Backend: Systemic Issues Requiring Comprehensive Fix") documents **20+ open sub-issues and 15+ unmerged PRs** indicating systemic problems:

#### Timeout and Performance Issues
- QMD too slow on CPU-only systems, causing timeouts
- Fallback becomes permanent after timeout, never recovers
- Boot embed timeout (120s) not configurable
- QMD embed fails at ~5% with exit code 1

#### Search and Results Issues
- `memory_search` never actually calls `qmd search` (!)
- Returns empty when backend=qmd but CLI works fine
- Collection name mismatch causes empty results
- Silently returns empty in Discord channels

#### Configuration and Integration Issues
- `memory.qmd.paths` doesn't generate index.yml
- Requires OpenAI auth even when not needed
- Searches all collections, not just managed ones
- Not restarted after gateway restart
- Ignores `memory.backend=qmd`, tries cloud providers

#### Root Causes
1. **Architectural flaw**: Subprocess per query instead of persistent MCP server
2. **Configuration complexity**: Multiple overlapping configs cause confusion
3. **Performance assumptions**: Assumes fast LLM inference on CPU, but reality is 10-20s+

### Upstream Recommended Workaround
Switch to `memory.backend: "local"` until QMD issues are resolved:
```json
{
  "memory": {
    "backend": "local",
    "citations": "auto",
    "local": {
      "embeddingModel": "hf:ggml-org/embeddinggemma-300M-GGUF/embeddinggemma-300M-Q8_0.gguf"
    }
  }
}
```

---

## 5. Recommendation

**DO NOT activate QMD at this time.** The upstream integration has fundamental architectural issues that make it unreliable as an OpenClaw memory backend. Specific concerns:

1. **Search does not work through OpenClaw** -- even when QMD CLI works fine directly, the OpenClaw integration fails to call it properly
2. **Permanent fallback state** -- once QMD times out, it never recovers without a restart
3. **No merged fixes** -- 15+ PRs attempting fixes remain unmerged upstream
4. **CPU performance** -- our agents likely run on systems where QMD's local LLM inference would be too slow

### Next Steps (for issue #21)
- [ ] Monitor upstream OpenClaw repo for merged fixes to the QMD integration
- [ ] Watch for Phase 1 stabilization (increased timeouts, fallback recovery fixes)
- [ ] Watch for Phase 2 architecture change (MCP server mode instead of subprocess)
- [ ] Consider testing QMD standalone (not as OpenClaw backend) for supplementary memory
- [ ] Re-evaluate once upstream issues are resolved and PRs are merged
- [ ] If memory improvement is urgent, configure `memory.backend: "local"` with the embedding model shown above as an interim improvement

---

## References
- openclaw-agents issue #21: Integrate QMD as memory layer
- OpenClaw upstream issue #11308: QMD systemic issues
- QMD repository: https://github.com/tobi/qmd
- CLAUDE.md QMD section in this repo
