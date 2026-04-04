---
name: openclaw-add-script
description: Create a new deterministic shell script for agents following our json-response conventions (JSON stdout, stderr logging, structured output)
argument-hint: [script-name]
disable-model-invocation: true
---

# Create Agent Script

Create a new deterministic script following our conventions.

## Where Scripts Live

Scripts are shared across all agents of the same type via `sync-agents.sh`. The source of truth is:

- `types/dev-pa/scripts/` — for dev-pa agent scripts
- `types/manager/scripts/` — for manager agent scripts

After adding a script here, `sync-agents.sh` copies it to all agents of that type, and `deploy.sh` handles the rest on the host.

The shared library lives at `types/<type>/scripts/lib/json-response.sh`.

## json-response Library

All scripts source `lib/json-response.sh` which provides 5 functions:

| Function | Signature | Output |
|----------|-----------|--------|
| `log` | `log "message"` | `[timestamp] message` → stderr |
| `json_timestamp` | `json_timestamp` | ISO 8601 UTC string |
| `json_success` | `json_success <operation> <data_json>` | `{success: true, operation, timestamp, data}` → stdout |
| `json_error` | `json_error <operation> <code> <message> [details]` | `{success: false, operation, timestamp, error: {code, message}}` → stdout |
| `parse_quiet_flag` | `parse_quiet_flag "$@"` | Sets `$QUIET` and `$REMAINING_ARGS` |

## Steps

1. **Ask the user** what the script should do:
   - Purpose (what data does it fetch/process?)
   - Inputs (what arguments does it take?)
   - Output (what JSON structure should it return?)
   - External commands it calls (gh, curl, jq, etc.)

2. **Create the script** in the appropriate type directory using this template:

```bash
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/json-response.sh"

# ── Dependency check ─────────────────────────
if ! command -v jq &>/dev/null; then
    echo '{"success":false,"operation":"<operation-name>","error":{"code":"MISSING_DEP","message":"jq is required but not found"}}' >&2
    exit 1
fi

# ── Args ──────────────────────────────────────
ARG1="${1:-}"
if [[ -z "$ARG1" ]]; then
  json_error "<operation-name>" "MISSING_ARG" "Usage: $0 <arg1>"
  exit 1
fi

# ── Main Logic ────────────────────────────────
log "Starting <operation> for $ARG1..."

# Implementation here

RESULT="placeholder"

# ── Output ────────────────────────────────────
json_success "<operation-name>" "$(jq -n --arg r "$RESULT" '{result: $r}')"
```

3. **Make it executable:**
   ```bash
   chmod +x types/<type>/scripts/<script-name>.sh
   ```

4. **Document it** in `types/<type>/AGENTS.md` under the "Available Scripts" section:
   ```markdown
   ### `scripts/<script-name>.sh`
   <one-line description>

   ```bash
   bash scripts/<script-name>.sh <args>
   ```

   Options:
   - `--arg VALUE` — description

   Output: JSON with `success`, `data.<fields>`.
   ```

5. **Commit and push** via PR. `deploy.sh` runs `sync-agents.sh` which copies the script to all agents of that type.

## Output Protocol

- **stdout is sacred** — only JSON output goes there (via `json_success` / `json_error`)
- **stderr is for logging** — use `log()` for all human-readable output
- **Exit code is law** — non-zero means the operation failed
- **Use `jq` for JSON construction** — never echo raw JSON strings
- **For state changes:** verify → act → verify → report

## Existing Scripts (dev-pa)

Reference these for patterns:

| Script | Purpose |
|--------|---------|
| `github-activity.sh` | Query GitHub activity within <your-org> org |
| `checkin-guard.sh` | Skip check-in if recent activity within 20 min |
| `daily-summary.sh` | Prepare/finalize daily summary (two-phase) |
| `generate-image.sh` | Generate images via Gemini Nano Banana API |
| `create-issue.sh` | Create GitHub issues in <your-org> repos |
| `bootstrap-check.sh` | Bootstrap progress tracking |
| `poll-check.sh` | Poll state management |

## Important

- Scripts go in `types/<type>/scripts/`, NOT in `.openclaw/agents/<name>/scripts/`. The type directory is the source of truth.
- New `.sh` files in `types/<type>/scripts/` are automatically picked up by `sync-agents.sh` (it rsyncs the entire `scripts/` directory). No need to edit `SHARED_FILES`.
- Dependency check: if the script needs `jq`, `gh`, `curl`, etc., check for it early and fail with `json_error` if missing.
- The `parse_quiet_flag` function is available in json-response.sh but optional — use it if your script benefits from a quiet mode.
