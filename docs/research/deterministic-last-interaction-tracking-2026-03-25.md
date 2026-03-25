# Deterministic Last-Interaction Tracking for OpenClaw Agents

**Date:** 2026-03-25
**Status:** Actionable -- multiple viable approaches identified
**Goal:** Track "last human interaction" without relying on the LLM to update a file

---

## Executive Summary

OpenClaw provides **three deterministic, non-LLM mechanisms** to track last human interaction. The best approach is **querying the sessions store** via `openclaw sessions --agent dev1 --json`, which already tracks `updatedAt` timestamps per session key. The Slack DM session key `agent:dev1:slack:direct:u09l59gj3qt` contains the exact epoch-millisecond timestamp of the last human interaction.

**Recommended approach:** Replace the manual `poll-state.json` with a one-liner that extracts `updatedAt` from the sessions store.

---

## Findings by Investigation Area

### 1. OpenClaw Sessions API (PRIMARY SOLUTION)

**Command:** `openclaw sessions --agent dev1 --json`

The sessions store at `~/.openclaw/agents/dev1/sessions/sessions.json` tracks every session with an `updatedAt` epoch-ms timestamp. Sessions are keyed by type:

- **Human interactions:** `agent:dev1:slack:direct:u09l59gj3qt` (Slack DM)
- **Cron runs:** `agent:dev1:cron:1e14ae94-...` (automated)

**Current last human interaction:**
```json
{
  "key": "agent:dev1:slack:direct:u09l59gj3qt",
  "updatedAt": 1774336541676,
  "updatedAtISO": "2026-03-24T07:15:41Z"
}
```

**Extraction one-liner:**
```bash
openclaw sessions --agent dev1 --json 2>/dev/null \
  | jq '[.sessions[] | select(.key | test("cron") | not)] | sort_by(-.updatedAt) | .[0].updatedAt'
```

Or directly from the JSON file (no gateway required):
```bash
jq '[to_entries[] | select(.key | test("cron") | not) | .value] | sort_by(-.updatedAt) | .[0].updatedAt' \
  ~/.openclaw/agents/dev1/sessions/sessions.json
```

**Advantages:**
- Deterministic (written by gateway on every inbound message)
- No LLM involvement
- Works offline (direct JSON file read)
- Distinguishes human sessions from cron sessions by key pattern
- Millisecond precision

**Limitations:**
- `updatedAt` reflects last agent *response*, not inbound message receipt (close enough for check-in purposes)
- Requires gateway to have been running (sessions.json exists from first interaction)

### 2. OpenClaw Hooks System (CUSTOM HOOK APPROACH)

**Command:** `openclaw hooks list`

OpenClaw has a hook system with event subscriptions. The existing `command-logger` hook subscribes to `command` events and writes JSONL to `~/.openclaw/logs/commands.log`.

**Hook events observed:** `command` (for /new, /reset, etc.)

A custom hook could be installed that fires on `message` events (if supported) to write the timestamp. However, the current bundled hooks only demonstrate `command` events, not raw inbound message events.

**To investigate further:**
```bash
openclaw hooks install <custom-hook-path>
```

A custom hook pack could be created that:
1. Subscribes to inbound message events
2. Writes `last_interaction` timestamp to a file
3. Filters by agent ID

**Status:** Viable but requires writing a hook pack. The sessions approach is simpler.

### 3. SQLite Databases (MEMORY ONLY, NOT SESSIONS)

**Location:** `~/.openclaw/memory/dev1.sqlite`

The SQLite databases contain the **memory/embedding layer**, not session metadata:
- Tables: `files`, `chunks`, `chunks_fts`, `chunks_vec`, `embedding_cache`, `meta`
- Schema is for vector search / FTS over memory files
- No session or message timestamp tables

**Verdict:** Not useful for tracking last interaction.

### 4. Session Store JSON File (DIRECT FILE ACCESS)

**Location:** `~/.openclaw/agents/dev1/sessions/sessions.json`

This file is the backing store for `openclaw sessions`. It can be read directly without the CLI:

```bash
jq 'to_entries
    | map(select(.key | test("cron") | not))
    | sort_by(-.value.updatedAt)
    | .[0]
    | {key: .key, updatedAt: .value.updatedAt, iso: (.value.updatedAt / 1000 | todate)}' \
  ~/.openclaw/agents/dev1/sessions/sessions.json
```

**Advantages over CLI:** No gateway needed, faster, works in cron context.

### 5. Gateway Heartbeat System

**Command:** `openclaw system heartbeat last --json`

Returns:
```json
{
  "ts": 1774409084420,
  "status": "skipped",
  "reason": "target-none",
  ...
}
```

This tracks heartbeat cycle timestamps but not inbound human messages specifically. Not directly useful.

### 6. Claude Code Hooks (EXISTING)

**Location:** `/Users/<hostname>/openclaw-agents/.claude/settings.json`

Existing hooks are `PreToolUse` blockers (openclaw.sh, launchctl.sh, keychain.sh, workspace.sh). These are Claude Code session hooks, not OpenClaw gateway hooks. Not relevant for tracking inbound Slack messages.

### 7. Message Read API

**Command:** `openclaw message read --channel slack --target <id> --json`

Can read recent messages from Slack with timestamps. However:
- Requires specifying channel and target
- Returns messages (not just timestamps)
- Heavier than sessions query
- Requires active Slack connection

Could be used as a fallback but sessions store is better.

---

## Recommended Implementation

### Option A: Replace poll-state.json entirely (RECOMMENDED)

Modify `poll-check.sh` to query sessions.json directly instead of reading poll-state.json:

```bash
#!/usr/bin/env bash
set -euo pipefail

AGENT_ID="dev1"
SESSIONS_FILE="$HOME/.openclaw/agents/$AGENT_ID/sessions/sessions.json"
INTERVAL_MINUTES=240

if [[ ! -f "$SESSIONS_FILE" ]]; then
  echo '{"error": "sessions file not found"}' >&2
  exit 1
fi

# Get latest non-cron session updatedAt (epoch ms)
LAST_MS=$(jq '[to_entries[]
  | select(.key | test("cron") | not)
  | .value.updatedAt // 0]
  | max' "$SESSIONS_FILE")

if [[ "$LAST_MS" == "null" || "$LAST_MS" == "0" ]]; then
  echo '{"due": 1, "reason": "no_human_sessions"}'
  exit 0
fi

LAST_EPOCH=$((LAST_MS / 1000))
NOW_EPOCH=$(date -u +%s)
ELAPSED_MINUTES=$(( (NOW_EPOCH - LAST_EPOCH) / 60 ))
DUE=$((ELAPSED_MINUTES >= INTERVAL_MINUTES ? 1 : 0))
LAST_ISO=$(date -u -r "$LAST_EPOCH" '+%Y-%m-%dT%H:%M:%SZ')

jq -n \
  --argjson due "$DUE" \
  --argjson interval "$INTERVAL_MINUTES" \
  --arg last "$LAST_ISO" \
  --argjson elapsed "$ELAPSED_MINUTES" \
  '{due: $due, interval_minutes: $interval, last_interaction: $last, elapsed_minutes: $elapsed, source: "sessions.json"}'
```

**Benefits:**
- Zero LLM dependency
- poll-state.json becomes unnecessary
- Automatically accurate (gateway maintains sessions.json)
- No manual timestamp updates ever needed

### Option B: Hybrid (sessions.json + poll-state.json fallback)

Keep poll-state.json as a fallback but prefer sessions.json:

```bash
# Try sessions.json first
LAST_MS=$(jq '...' "$SESSIONS_FILE" 2>/dev/null)
if [[ -z "$LAST_MS" || "$LAST_MS" == "null" ]]; then
  # Fallback to poll-state.json
  LAST_INTERACTION=$(jq -r '.last_interaction' "$POLL_STATE_FILE")
fi
```

### Option C: Custom OpenClaw Hook (FUTURE)

Create a hook pack that writes a timestamp file on every inbound message. This would be the most precise approach but requires:
1. Understanding the full hook event schema (beyond `command` events)
2. Writing and installing a hook pack
3. Testing event subscription for `message.inbound` or similar

---

## Key Data Points

| Source | Location | Human Interaction? | Deterministic? |
|--------|----------|-------------------|---------------|
| sessions.json | `~/.openclaw/agents/dev1/sessions/sessions.json` | Yes (filter by key) | Yes |
| openclaw sessions CLI | `openclaw sessions --agent dev1 --json` | Yes | Yes (requires gateway) |
| commands.log | `~/.openclaw/logs/commands.log` | Commands only | Yes |
| gateway.log | `~/.openclaw/logs/gateway.log` | Possible (grep) | Fragile |
| dev1.sqlite | `~/.openclaw/memory/dev1.sqlite` | No (memory only) | N/A |
| poll-state.json | Manual file | Only if LLM updates it | No (current problem) |
| heartbeat last | `openclaw system heartbeat last` | No (heartbeat cycle) | Yes but wrong data |

---

## Action Items

1. **Implement Option A** in poll-check.sh -- replace poll-state.json reads with sessions.json queries
2. **Remove LLM dependency** -- the agent no longer needs to update poll-state.json manually
3. **Keep poll-state.json** for `interval_minutes` config only (or move to agent config)
4. **Test** by comparing sessions.json `updatedAt` against known Slack interaction times
5. **Consider** writing a custom OpenClaw hook for even more precise tracking in the future
