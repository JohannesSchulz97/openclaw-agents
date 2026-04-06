# Lossless-Claw Per-Agent DB Isolation: Full Research & Implementation Plan

**Date:** 2026-04-06
**Status:** Implementation plan ready
**Related issues:** #166 (parent incident), #183 (Phase 0), #184 (Phase 1a), #185 (Phase 1b), #186 (Phase 2)
**Fork repo:** `/Users/dev1/Projects/<your-org>/lossless-claw` (<your-org>/lossless-claw)

---

## What is lossless-claw?

An OpenClaw **context engine plugin** (`@martian-engineering/lossless-claw`, MIT, by Martian Engineering). It replaces OpenClaw's built-in sliding-window context compaction with a DAG-based summarization system. Every message is persisted to SQLite, older messages are summarized by a cheap LLM into a tree of summaries, and agents get tools (`lcm_grep`, `lcm_describe`, `lcm_expand`) to search/recall compacted history. Without it (or something like it), agents lose context during long sessions — critical instructions can vanish during compaction.

## The problem

The plugin creates **one shared SQLite database** (`~/.openclaw/lcm.db`) for all 18 agents. This causes:

- **WAL contention** → `database is locked` errors (SQLite WAL serializes writes)
- **Blocked Node.js event loop** → Slack WebSocket keepalive dies (5s timeout) → message delivery fails silently
- **DB grew to 3.67 GB** because compaction never worked — model auth misconfigured since install (provider resolves as `"accounts"` instead of `"fw-mm25"`, see `lcm-compaction-api-key-failure-2026-03-31.md`)
- **108 auth failures**, 54 fallback-to-truncation events, 15-20 seconds wasted per attempt

## The fix: per-agent database isolation

When `databasePath` config contains `{agentId}` (e.g., `~/.openclaw/agents/{agentId}/lcm.db`), the plugin should create separate `DatabaseSync` connections and `LcmContextEngine` instances per agent instead of sharing one.

---

## Codebase Structure

```
src/
├── plugin/
│   ├── index.ts          (1,645 lines — plugin registration, register() function)
│   ├── lcm-command.ts    (the /lcm CLI command)
│   ├── lcm-doctor-*.ts   (doctor scan/apply)
├── db/
│   ├── config.ts         (247 lines — LcmConfig type, resolveLcmConfig())
│   ├── connection.ts     (124 lines — createLcmDatabaseConnection(), connection tracking)
│   ├── migration.ts      (690 lines — schema creation, runLcmMigrations())
│   ├── features.ts       (FTS5 detection)
├── store/
│   ├── conversation-store.ts  (messages, conversations table access)
│   ├── summary-store.ts       (summaries, DAG, context_items)
├── engine.ts             (3,457 lines — LcmContextEngine class)
├── assembler.ts          (context assembly from DAG)
├── compaction.ts         (incremental compaction logic)
├── retrieval.ts          (BM25-lite search)
├── expansion.ts          (sub-agent expansion)
├── types.ts              (165 lines — LcmDependencies interface)
├── openclaw-bridge.ts    (re-exports from openclaw/plugin-sdk)
```

---

## Key Code Locations

### `register()` — the main entry point to modify

**File:** `src/plugin/index.ts`, lines 1564-1642

```typescript
register(api: OpenClawPluginApi) {
    const deps = createLcmDependencies(api);
    const database = createLcmDatabaseConnection(deps.config.databasePath);
    const lcm = new LcmContextEngine(deps, database);

    api.on("before_reset", async (event, ctx) => {
        await lcm.handleBeforeReset({ reason: event.reason, sessionId: ctx.sessionId, sessionKey: ctx.sessionKey });
    });
    api.on("before_prompt_build", () => ({ prependSystemContext: LOSSLESS_RECALL_POLICY_PROMPT }));
    api.on("session_end", async (event) => {
        await lcm.handleSessionEnd({ reason, sessionId, sessionKey, nextSessionId, nextSessionKey });
    });

    api.registerContextEngine("lossless-claw", () => lcm);  // zero-arg factory
    api.registerContextEngine("default", () => lcm);         // same instance

    api.registerTool((ctx) => createLcmGrepTool({ deps, lcm, sessionKey: ctx.sessionKey }));
    api.registerTool((ctx) => createLcmDescribeTool({ deps, lcm, sessionKey: ctx.sessionKey }));
    api.registerTool((ctx) => createLcmExpandTool({ deps, lcm, sessionKey: ctx.sessionKey }));
    api.registerTool((ctx) => createLcmExpandQueryTool({ deps, lcm, sessionKey: ctx.sessionKey, requesterSessionKey: ctx.sessionKey }));

    api.registerCommand(createLcmCommand({ db: database, config: deps.config, deps }));
}
```

**Critical observation:** `registerContextEngine` factory callback is `() => lcm` — zero arguments, no session context. This means we cannot route at the factory level. The routing must happen inside the engine itself.

### `parseAgentSessionKey()` — how agentId is extracted

**File:** `src/plugin/index.ts`, lines 22-37

```typescript
function parseAgentSessionKey(sessionKey: string): { agentId: string; suffix: string } | null {
    const value = sessionKey.trim();
    if (!value.startsWith("agent:")) return null;
    const parts = value.split(":");
    if (parts.length < 3) return null;
    const agentId = parts[1]?.trim();
    const suffix = parts.slice(2).join(":").trim();
    if (!agentId || !suffix) return null;
    return { agentId, suffix };
}
```

Input: `"agent:dev1:main"` → `{ agentId: "dev1", suffix: "main" }`
Input: `"agent:dev10:cron:morning"` → `{ agentId: "dev10", suffix: "cron:morning" }`
Returns `null` for non-agent session keys.

Also: `normalizeAgentId()` (lines 40-43) returns `"main"` for empty/undefined agentId.

### Database initialization

**File:** `src/db/connection.ts`, lines 82-87

```typescript
export function createLcmDatabaseConnection(dbPath: string): DatabaseSync {
    ensureDbDirectory(dbPath);
    const db = configureConnection(new DatabaseSync(dbPath));
    trackConnection(dbPath, db);
    return db;
}
```

Configures: `PRAGMA journal_mode = WAL`, `PRAGMA busy_timeout = 5000`, `PRAGMA foreign_keys = ON`.
Connections are tracked by normalized path in a `Map`. `closeLcmDatabaseConnection(path)` exists for cleanup.

### Config resolution

**File:** `src/db/config.ts`, line 155

`databasePath` defaults to `~/.openclaw/lcm.db`. Three-tier precedence: env vars > plugin config > defaults. The field can be set via `LCM_DATABASE_PATH` env var or `plugins.entries.lossless-claw.config.databasePath` in openclaw.json.

### LcmContextEngine constructor

**File:** `src/engine.ts`, lines 1177-1275

```typescript
constructor(deps: LcmDependencies, database: DatabaseSync) {
    this.deps = deps;
    this.db = database;
    // Runs migrations eagerly
    runLcmMigrations(this.db, { fts5Available: ... });
    // Creates stores, assembler, compaction engine, retrieval engine
    this.conversationStore = new ConversationStore(this.db, ...);
    this.summaryStore = new SummaryStore(this.db, ...);
    this.assembler = new ContextAssembler(...);
    this.compaction = new CompactionEngine(...);
    this.retrieval = new RetrievalEngine(...);
}
```

Each instance is self-contained with its own DB connection and stores. Creating multiple instances with different DB paths is safe — no shared mutable state between instances.

---

## ContextEngine Interface (8 methods + 1 property)

`LcmContextEngine implements ContextEngine` (src/engine.ts:1146). The interface requires:

| Method/Property | Signature | Has sessionKey? |
|----------------|-----------|-----------------|
| `info` | `ContextEngineInfo` (property) | n/a |
| `bootstrap(params)` | `{ sessionId, sessionFile, sessionKey? }` → `Promise<BootstrapResult>` | yes |
| `ingest(params)` | `{ sessionId, sessionKey?, message, isHeartbeat? }` → `Promise<IngestResult>` | yes |
| `ingestBatch(params)` | `{ sessionId, sessionKey?, messages, isHeartbeat? }` → `Promise<IngestBatchResult>` | yes |
| `assemble(params)` | `{ sessionId, sessionKey?, messages, tokenBudget?, prompt? }` → `Promise<AssembleResult>` | yes |
| `compact(params)` | `{ sessionId, sessionKey?, sessionFile, tokenBudget?, ... }` → `Promise<CompactResult>` | yes |
| `prepareSubagentSpawn(params)` | `{ parentSessionKey, childSessionKey, ttlMs? }` → `Promise<SubagentSpawnPreparation \| undefined>` | yes (parentSessionKey) |
| `onSubagentEnded(params)` | `{ childSessionKey, reason }` → `Promise<void>` | yes (childSessionKey) |
| `dispose()` | `() → Promise<void>` | no |

**Plus 2 lifecycle methods** (not part of ContextEngine interface, called from event handlers):
- `handleBeforeReset({ reason?, sessionId?, sessionKey? })` → `Promise<void>`
- `handleSessionEnd({ reason?, sessionId?, sessionKey?, nextSessionId?, nextSessionKey? })` → `Promise<void>`

**Key finding:** Every single method receives a session key that can be parsed for agentId. The router pattern is clean.

### ContextEngineInfo

```typescript
{
    id: "lcm",
    name: "Lossless Context Management Engine",
    version: "0.1.0",
    ownsCompaction: boolean  // true when migration succeeded
}
```

### dispose()

Currently a no-op (src/engine.ts:3283-3289). Comment explains: "OpenClaw's runner calls dispose() after every run, but the plugin registers a single engine instance reused by the factory. Closing the DB here would break subsequent runs."

---

## Database Schema (8 core tables)

All data chains through `conversation_id`. The DAG never spans conversations — no cross-agent foreign keys. This makes splitting by agent clean.

| Table | Purpose | Key columns |
|-------|---------|-------------|
| `conversations` | One row per session | `conversation_id` (PK), `session_id`, `session_key`, `active` |
| `messages` | Every raw message | `message_id` (PK), `conversation_id` (FK), `seq`, `role`, `content`, `token_count` |
| `message_parts` | Structured content blocks | `part_id` (PK), `message_id` (FK), tool/file/patch metadata |
| `summaries` | DAG nodes (leaf + condensed) | `summary_id` (PK), `conversation_id` (FK), `kind`, `depth`, `content` |
| `summary_messages` | Leaf → source messages | `summary_id` (FK), `message_id` (FK) |
| `summary_parents` | Condensed → parent summaries | `summary_id` (FK), `parent_summary_id` (FK) |
| `context_items` | What the model currently sees | `conversation_id` (FK), `ordinal`, `item_type`, `message_id` or `summary_id` |
| `large_files` | Externalized large file metadata | `file_id` (PK), `conversation_id` (FK) |

Plus 3 FTS5 virtual tables for full-text search (conditional on SQLite FTS5 availability).

---

## Implementation Plan

### Architecture: Router Engine Pattern

Since `registerContextEngine` factory is zero-arg (can't route there), we create a **router engine** that implements `ContextEngine` and delegates to per-agent instances.

```
OpenClaw → registerContextEngine("lossless-claw", () => router)
                                                         │
         ┌──────────────────────────────────────────────┘
         ▼
    LcmEngineRouter (implements ContextEngine)
         │
         ├── ingest({ sessionKey: "agent:dev1:main", ... })
         │       → parseAgentSessionKey() → agentId = "dev1"
         │       → getOrCreateEngine("dev1") → LcmContextEngine (own DB)
         │       → delegate ingest()
         │
         ├── assemble({ sessionKey: "agent:dev10:cron:morning", ... })
         │       → agentId = "dev10" → delegate to dev10's engine
         │
         └── compact({ sessionKey: "session:slack:direct:...", ... })
                 → parseAgentSessionKey() returns null → use "default" engine
```

### Step 1: Create `LcmEngineRouter` (new file: `src/engine-router.ts`)

A new class that:
- Implements `ContextEngine` (same interface as `LcmContextEngine`)
- Holds `Map<string, LcmContextEngine>` cache keyed by agentId
- Stores the `databasePath` template (with `{agentId}` placeholder) and `deps`
- On each method call:
  1. Extract sessionKey from params
  2. Parse agentId via `parseAgentSessionKey()`
  3. If null (non-agent session), use `"default"` as the key
  4. Look up or lazily create a `LcmContextEngine` for that agentId
  5. Delegate the method call to the resolved engine
- Lazy creation: `createLcmDatabaseConnection(template.replace("{agentId}", agentId))` → `new LcmContextEngine(deps, db)`
- `dispose()`: iterate all cached engines, call `dispose()` on each (still no-op, but forward-compatible)
- Also expose `handleBeforeReset()` and `handleSessionEnd()` with same routing logic (these are called from event handlers, not from the ContextEngine interface)
- Expose `getOrCreateEngine(agentId)` for use by tools and commands

### Step 2: Modify `register()` in `src/plugin/index.ts`

- Check if `deps.config.databasePath` contains `{agentId}`
- If yes: create `LcmEngineRouter` instead of single `LcmContextEngine`
- If no: keep current behavior (backwards compatible)
- Event handlers (`before_reset`, `session_end`): route through router's `handleBeforeReset`/`handleSessionEnd`
- Tools (`lcm_grep`, etc.): they already receive `ctx.sessionKey`, use router to resolve the correct engine
- `/lcm` command: receives `ctx.sessionKey` and `ctx.sessionId` — route through router

```typescript
// Pseudocode for modified register()
register(api: OpenClawPluginApi) {
    const deps = createLcmDependencies(api);
    const usePerAgent = deps.config.databasePath.includes("{agentId}");

    let engine: ContextEngine;
    let resolveEngine: (sessionKey?: string) => LcmContextEngine;

    if (usePerAgent) {
        const router = new LcmEngineRouter(deps);
        engine = router;
        resolveEngine = (sk) => router.getOrCreateEngine(sk);
    } else {
        const database = createLcmDatabaseConnection(deps.config.databasePath);
        const lcm = new LcmContextEngine(deps, database);
        engine = lcm;
        resolveEngine = () => lcm;
    }

    api.registerContextEngine("lossless-claw", () => engine);
    api.registerContextEngine("default", () => engine);
    // ... event handlers and tools use resolveEngine(ctx.sessionKey)
}
```

### Step 3: Tests

- Existing tests should pass unchanged (they use single-DB mode without `{agentId}`)
- New tests:
  - Two different sessionKeys create two separate engines with separate DBs
  - Non-agent sessionKey (no `agent:` prefix) uses default engine
  - Same agentId from different session suffixes (`:main` vs `:cron:morning`) shares one engine
  - Backwards compat: databasePath without `{agentId}` uses single engine (current behavior)

### What NOT to change

- Schema (`migration.ts`) — no changes needed
- `ConversationStore`, `SummaryStore` — they just take a `DatabaseSync`, agnostic to routing
- `LcmContextEngine` class itself — stays as-is, just gets instantiated per-agent
- Compaction, assembly, retrieval logic — unchanged
- `resolveLcmConfig()` — no changes, `{agentId}` is just a string in the path

---

## Migration Script (Phase 2, separate from fork)

After the fork is working, a migration script splits the existing shared DB:

1. Open source `lcm.db` read-only
2. `SELECT DISTINCT session_key FROM conversations` → group by agentId
3. For each agent: create new DB, copy rows filtered by `conversation_id` set
4. Optionally compact old messages during insertion (summarize chunks older than freshTailCount)
5. Rebuild FTS5 indexes

This can live in the fork repo as a standalone script.

---

## Config for deployment

After fork is installed:

```json
{
    "plugins": {
        "entries": {
            "lossless-claw": {
                "config": {
                    "databasePath": "~/.openclaw/agents/{agentId}/lcm.db",
                    "summaryModel": "fw-mm25/accounts/fireworks/models/qwen3-8b",
                    "expansionModel": "fw-mm25/accounts/fireworks/models/qwen3-8b",
                    "pruneHeartbeatOk": true,
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

---

## Upstream Context

- [Martian-Engineering/lossless-claw#200](https://github.com/Martian-Engineering/lossless-claw/issues/200) — "LCM should support agent-scoped conversation isolation" (open, 2026-03-28)
- [Martian-Engineering/lossless-claw#260](https://github.com/Martian-Engineering/lossless-claw/issues/260) — documents the exact WAL contention we're hitting
- [Martian-Engineering/lossless-claw#261](https://github.com/Martian-Engineering/lossless-claw/issues/261) — PR adding per-DB transaction mutex (hotfix, doesn't solve multi-agent)
- OpenClaw doesn't support per-agent plugin config overrides (openclaw#55401)
- `memory-lancedb` plugin has an analogous issue with a confirmed working local patch
