# Lossless Claw Integration Guide for openclaw-agents

**Date:** 2026-03-27
**Classification:** Actionable (integration required)
**Package:** `@martian-engineering/lossless-claw` v0.5.2 (published 2026-03-26)
**License:** MIT
**Dependencies:** @mariozechner/pi-agent-core, @mariozechner/pi-ai, @sinclair/typebox 0.34.48

---

## What Is Lossless Claw?

Lossless Claw is a **context engine plugin** for OpenClaw that replaces the built-in sliding-window compaction with a DAG-based summarization system. It is **not** an MCP server and **not** middleware -- it is an OpenClaw plugin that fills the `contextEngine` slot.

**How it works:**
1. Persists every message in a SQLite database (`~/.openclaw/lcm.db`)
2. Summarizes chunks of older messages using a configurable LLM
3. Condenses summaries into higher-level DAG nodes as they accumulate
4. Assembles context each turn by combining summaries + recent raw messages
5. Provides agent tools (`lcm_grep`, `lcm_describe`, `lcm_expand`) for recall

**Key difference from memory systems:** Memory (QMD, local) is for searching information external to the current context window. Lossless Claw manages what happens _within_ a conversation -- preventing information loss during context compaction. Both can be used together.

---

## Installation Steps

### Step 1: Install the plugin

```bash
openclaw plugins install @martian-engineering/lossless-claw
```

The install command records the plugin, enables it, and applies compatible slot selection (including `contextEngine`). In most cases, **no manual JSON edits are needed** after this command.

For local development/testing:
```bash
openclaw plugins install --link /path/to/lossless-claw
```

### Step 2: Verify/set the context engine slot

The installer should set this automatically, but verify in `~/.openclaw/openclaw.json`:

```json
{
  "plugins": {
    "slots": {
      "contextEngine": "lossless-claw"
    }
  }
}
```

### Step 3: Configure the plugin

Add under `plugins.entries` in `~/.openclaw/openclaw.json`:

```json
{
  "plugins": {
    "slots": {
      "contextEngine": "lossless-claw"
    },
    "entries": {
      "lossless-claw": {
        "enabled": true,
        "config": {
          "freshTailCount": 32,
          "contextThreshold": 0.75,
          "incrementalMaxDepth": -1,
          "summaryModel": "anthropic/claude-haiku-4-5",
          "expansionModel": "anthropic/claude-haiku-4-5",
          "ignoreSessionPatterns": [
            "agent:*:cron:**",
            "agent:tech-manager:monitoring",
            "agent:tech-manager:morning-report",
            "agent:tech-manager:evening-report"
          ]
        }
      }
    }
  }
}
```

### Step 4: (Optional) Configure expansion model trust

If using a dedicated expansion model, add the subagent trust policy:

```json
{
  "models": {
    "anthropic/claude-haiku-4-5": {}
  },
  "plugins": {
    "entries": {
      "lossless-claw": {
        "enabled": true,
        "subagent": {
          "allowModelOverride": true,
          "allowedModels": ["anthropic/claude-haiku-4-5"]
        },
        "config": {
          "expansionModel": "anthropic/claude-haiku-4-5"
        }
      }
    }
  }
}
```

The expansion model must also be in the top-level `models` map.

### Step 5: Increase session idle timeout

LCM preserves history through compaction but does NOT change session reset policy. Increase idle timeout to prevent premature session resets:

```json
{
  "session": {
    "reset": {
      "mode": "idle",
      "idleMinutes": 10080
    }
  }
}
```

Useful values: 1440 (1 day), 10080 (7 days), 43200 (30 days).

### Step 6: Restart the gateway

```bash
openclaw gateway restart
```

---

## Configuration Reference

### Recommended starting config

| Setting | Value | Purpose |
|---------|-------|---------|
| `freshTailCount` | 32 | Protect last 32 messages from compaction |
| `incrementalMaxDepth` | -1 | Unlimited automatic DAG condensation |
| `contextThreshold` | 0.75 | Trigger compaction at 75% of context window |
| `summaryModel` | `anthropic/claude-haiku-4-5` | Use cheap model for summarization (cost control with 19 agents) |
| `expansionModel` | `anthropic/claude-haiku-4-5` | Use cheap model for expansion queries |

### Environment variables (override plugin config)

| Variable | Default | Description |
|----------|---------|-------------|
| `LCM_ENABLED` | `true` | Enable/disable the plugin |
| `LCM_DATABASE_PATH` | `~/.openclaw/lcm.db` | SQLite database path |
| `LCM_CONTEXT_THRESHOLD` | `0.75` | Fraction of context window that triggers compaction |
| `LCM_FRESH_TAIL_COUNT` | `32` | Recent messages protected from compaction |
| `LCM_INCREMENTAL_MAX_DEPTH` | `0` | DAG depth (0=leaf only, -1=unlimited) |
| `LCM_LEAF_CHUNK_TOKENS` | `20000` | Max source tokens per leaf chunk |
| `LCM_LEAF_TARGET_TOKENS` | `1200` | Target tokens for leaf summaries |
| `LCM_CONDENSED_TARGET_TOKENS` | `2000` | Target tokens for condensed summaries |
| `LCM_MAX_EXPAND_TOKENS` | `4000` | Token cap for expansion queries |
| `LCM_LARGE_FILE_TOKEN_THRESHOLD` | `25000` | Files above this size are intercepted/stored separately |
| `LCM_SUMMARY_MODEL` | `""` | Model override for summarization |
| `LCM_EXPANSION_MODEL` | `""` | Model override for expansion |
| `LCM_AUTOCOMPACT_DISABLED` | `false` | Disable auto-compaction after turns |
| `LCM_PRUNE_HEARTBEAT_OK` | `false` | Retroactively delete HEARTBEAT_OK turn cycles |
| `LCM_IGNORE_SESSION_PATTERNS` | `""` | Comma-separated session key globs to exclude |
| `LCM_STATELESS_SESSION_PATTERNS` | `""` | Sessions that read LCM but never write |
| `LCM_SKIP_STATELESS_SESSIONS` | `true` | Enable stateless-session write skipping |

**Priority:** Environment variables > plugin config > OpenClaw defaults.

---

## Gotchas and Considerations for openclaw-agents

### 1. Cron session exclusion is critical

Our cron jobs use `sessionTarget: "isolated"` with session keys like `agent:dev1:main`. These cron sessions produce low-value HEARTBEAT_OK / NO_ACTION messages that would pollute the LCM database.

**Configure `ignoreSessionPatterns` to exclude cron-only sessions:**

```json
"ignoreSessionPatterns": [
  "agent:*:cron:**"
]
```

However, note that our current cron jobs use `sessionKey: "agent:<name>:main"` -- the same session key as the main interactive session. This means LCM will persist cron turn data into the main conversation DAG. There are two approaches:

**Option A (recommended):** Change cron sessionKeys to use a cron-specific pattern (e.g., `agent:dev1:cron:checkin`) and exclude them via `ignoreSessionPatterns`. This requires updating `jobs-config.json`.

**Option B:** Keep current sessionKeys and use `LCM_PRUNE_HEARTBEAT_OK=true` to retroactively remove HEARTBEAT_OK cycles from LCM storage.

### 2. Tech-manager sessions should be excluded or stateless

Tech-manager monitoring, morning-report, and evening-report sessions generate ephemeral reports. These should be excluded entirely or made stateless:

```json
"ignoreSessionPatterns": [
  "agent:tech-manager:monitoring",
  "agent:tech-manager:morning-report",
  "agent:tech-manager:evening-report"
]
```

### 3. SQLite database growth with 19 agents

With 19 dev-pa agents + 1 tech-manager running continuously with 10-minute heartbeats, the LCM SQLite database will grow steadily. Monitor `~/.openclaw/lcm.db` size.

### 4. Cost implications of summarization

Every compaction pass calls the summarization LLM. With 19 agents, pin `summaryModel` and `expansionModel` to a cheap model like `anthropic/claude-haiku-4-5` to keep costs manageable.

### 5. Node.js version requirement

Lossless Claw requires Node.js 22+. Verify your runtime:

```bash
node --version  # Must be >= 22
```

### 6. FTS5 for fast full-text search

For best `lcm_grep` performance, use a Node.js runtime compiled with SQLite FTS5 support. Without FTS5, full-text retrieval falls back to slower search. See lossless-claw docs for FTS5 enablement.

### 7. Session reset vs. LCM

LCM does NOT override OpenClaw's session reset policy. If sessions reset too frequently, conversation continuity is lost even with LCM. Increase `session.reset.idleMinutes` to at least 7 days (10080).

### 8. Plugin context engine support required

OpenClaw must have plugin context engine support (introduced in v2026.3.7 with the pluggable ContextEngine architecture). Verify your OpenClaw version supports the `plugins.slots.contextEngine` configuration.

---

## Recommended Rollout Plan

1. **Verify OpenClaw version** supports pluggable ContextEngine (v2026.3.7+)
2. **Pilot with one agent** (e.g., dev1 or <your-org>)
3. **Install plugin:** `openclaw plugins install @martian-engineering/lossless-claw`
4. **Configure with recommended settings** (see Step 3 above)
5. **Consider updating cron sessionKeys** to separate cron from interactive sessions
6. **Increase session idle timeout** to 7 days minimum
7. **Restart gateway:** `openclaw gateway restart`
8. **Monitor for 24-48 hours:** Check database growth, summarization costs, agent behavior
9. **Roll out to all agents** if pilot succeeds
10. **Enable `LCM_PRUNE_HEARTBEAT_OK=true`** if heartbeat noise is excessive

---

## Complete openclaw.json Example

```json
{
  "session": {
    "reset": {
      "mode": "idle",
      "idleMinutes": 10080
    }
  },
  "models": {
    "anthropic/claude-haiku-4-5": {}
  },
  "plugins": {
    "slots": {
      "contextEngine": "lossless-claw"
    },
    "entries": {
      "lossless-claw": {
        "enabled": true,
        "subagent": {
          "allowModelOverride": true,
          "allowedModels": ["anthropic/claude-haiku-4-5"]
        },
        "config": {
          "freshTailCount": 32,
          "contextThreshold": 0.75,
          "incrementalMaxDepth": -1,
          "summaryModel": "anthropic/claude-haiku-4-5",
          "expansionModel": "anthropic/claude-haiku-4-5",
          "ignoreSessionPatterns": [
            "agent:*:cron:**",
            "agent:tech-manager:monitoring",
            "agent:tech-manager:morning-report",
            "agent:tech-manager:evening-report"
          ]
        }
      }
    }
  }
}
```

Note: This shows only lossless-claw-related keys. Merge with your existing `openclaw.json` -- do NOT replace the entire file. Remember that `openclaw.json` is Category 3 (runtime-only, never in repo).

---

## Sources

- [Martian-Engineering/lossless-claw (GitHub)](https://github.com/Martian-Engineering/lossless-claw)
- [@martian-engineering/lossless-claw (npm)](https://www.npmjs.com/package/@martian-engineering/lossless-claw)
- [OpenClaw v2026.3.7 ContextEngine Guide](https://www.shareuhack.com/en/posts/openclaw-v2026-3-7-contextengine-guide)
- [Lossless Claw Deep Dive (vibetools.net)](https://vibetools.net/posts/say-goodbye-to-openclaw-amnesia-a-deep-dive-and-complete-guide-to-lossless-claw)
- [OpenClaw Setup - Lossless Claw Announcement](https://openclaw-setup.me/blog/product-updates/lossless-claw-openclaw-setup/)
- [Lossless Context Management Visualization](https://losslesscontext.ai)
