# OpenClaw Cron: Shell Script / Non-LLM Execution Capabilities

**Date:** 2026-04-02
**Status:** Definitive findings

---

## Executive Summary

**OpenClaw cron jobs do NOT support running shell scripts/commands outside of an LLM agent turn.** Every cron job is an `agentTurn` payload -- there is no `shell`, `script`, or `command` payload kind. However, several workarounds exist, ranging from the already-used launchd pattern to OpenClaw's `--system-event` flag and potentially the disabled `lobster` workflow plugin.

---

## Finding 1: Cron Job Payload Types

### What exists

The `openclaw cron add` command supports exactly **two payload types**:

1. **`--message <text>`** -- Creates an `agentTurn` payload (LLM agent processes the message)
2. **`--system-event <text>`** -- Creates a `systemEvent` payload (injected into main session)

Both require an LLM turn. There is **no** `--shell`, `--command`, `--script`, `--exec`, `--pre-command`, `--post-command`, or `--hook` flag.

### Cron job schema (from jobs-config.json)

Every job object has this structure:
```json
{
  "id": "uuid",
  "agentId": "agent-name",
  "name": "Human-readable name",
  "enabled": true,
  "schedule": {
    "kind": "every|cron",
    "everyMs": 3600000,         // for kind=every
    "cronExpr": "0 20 * * *",  // for kind=cron
    "tz": "Europe/Berlin"       // for kind=cron
  },
  "sessionTarget": "session:main",
  "wakeMode": "now",
  "payload": {
    "kind": "agentTurn",        // ONLY observed value
    "message": "...",
    "timeoutSeconds": 180,
    "thinking": "medium"
  },
  "sessionKey": "agent:name:cron:type",
  "delivery": { "mode": "none" }
}
```

The `payload.kind` field is always `"agentTurn"`. No `"shell"`, `"script"`, `"webhook"`, or `"command"` kind exists.

### Schedule kinds

- `"every"` -- interval-based (`everyMs`)
- `"cron"` -- cron expression (`cronExpr` + `tz`)
- One-shot via `--at` flag (ISO datetime or `+duration`)

---

## Finding 2: System Events (Partial Alternative)

### `openclaw system event`

```
openclaw system event --text "Some event text" [--mode now|next-heartbeat]
```

This enqueues a system event into the agent's main session. It still triggers an LLM turn (the agent processes the event text). However, it can be combined with `--system-event` on cron jobs:

```
openclaw cron add --system-event "deployment completed" --cron "0 * * * *"
```

**Verdict:** System events are NOT non-LLM -- they still require the agent to process them. They differ from `--message` only in that they are injected as system context rather than user messages.

---

## Finding 3: Hooks System

### Internal hooks (openclaw.json)

OpenClaw has an internal hooks system, but it is for **agent lifecycle events**, not for arbitrary script execution:

| Hook | Purpose |
|------|---------|
| `boot-md` | Run BOOT.md on gateway startup |
| `bootstrap-extra-files` | Inject additional workspace files |
| `command-logger` | Log command events to audit file |
| `session-memory` | Save session context on /new or /reset |

These hooks are:
- Triggered by OpenClaw internal events (gateway start, session commands)
- NOT configurable to run arbitrary shell scripts
- NOT attachable to cron jobs
- Managed via `openclaw hooks enable/disable`

**Verdict:** Hooks are internal agent lifecycle hooks. They cannot run shell scripts on a schedule.

---

## Finding 4: Plugin System

### Relevant disabled plugins

Two bundled plugins are potentially relevant but both are **disabled by default**:

1. **`lobster`** -- "Typed workflow tool with resumable approvals"
   - Could potentially define multi-step workflows
   - Still operates within the LLM agent context
   - Not a shell execution mechanism

2. **`llm-task`** -- "Generic JSON-only LLM tool for structured tasks callable from workflows"
   - Designed for workflow-to-LLM calls
   - Still LLM-based, not shell-based

### Installed plugins

The only non-stock plugin is `lossless-claw` (context management). No shell-execution plugins exist.

**Verdict:** The plugin system is extensible but no existing plugin provides non-LLM shell execution for cron jobs.

---

## Finding 5: No Pre/Post Hooks on Cron Jobs

The `openclaw cron add` and `openclaw cron edit` commands have **no** fields for:
- `preCommand` / `postCommand`
- `beforeRun` / `afterRun`
- `shell` / `exec` / `script`
- `webhook` (for calling external URLs)

The only action a cron job can perform is sending a message or system event to an agent.

---

## Finding 6: Existing Workarounds

### Pattern A: macOS launchd (already in use)

The session watchdog already demonstrates this pattern:

```xml
<!-- ~/Library/LaunchAgents/com.openclaw-agents.session-watchdog.plist -->
<dict>
    <key>Label</key>
    <string>com.openclaw-agents.session-watchdog</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/<hostname>/openclaw-agents/scripts/session-watchdog.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>300</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <false/>
</dict>
```

This runs a pure shell script every 5 minutes, completely outside OpenClaw. The script can then call `openclaw` CLI commands as needed.

**Pros:**
- No LLM cost
- Full shell capabilities
- Can call `openclaw agent`, `openclaw cron run`, `openclaw message send`, etc.
- Already proven pattern in this project

**Cons:**
- macOS-specific (launchd)
- Not managed by OpenClaw (separate lifecycle)
- Requires manual plist management
- No OpenClaw dashboard visibility

### Pattern B: launchd wrapper around openclaw agent

A shell script that:
1. Runs pre-processing (pure shell, no LLM)
2. Calls `openclaw agent --message "..." --agent <agent>` with pre-processed data
3. Runs post-processing (pure shell)

```bash
#!/bin/bash
# Pre-processing (no LLM)
DATA=$(curl -s https://api.example.com/data)
PROCESSED=$(echo "$DATA" | jq '.summary')

# LLM turn (only if needed)
if [ -n "$PROCESSED" ]; then
    openclaw agent --agent tech-manager \
        --message "Process this data: $PROCESSED" \
        --session-id "agent:tech-manager:main"
fi

# Post-processing (no LLM)
echo "$(date): completed" >> /tmp/job.log
```

### Pattern C: Hybrid -- OpenClaw cron triggers agent, agent runs scripts

This is **the current pattern** in all existing cron jobs. The LLM agent receives a message telling it to `bash scripts/checkin-guard.sh` and conditionally acts. The shell script runs within the agent's sandbox.

**Key limitation:** The LLM turn still costs tokens and has latency, even if the script says "skip".

### Pattern D: openclaw cron + system event for lightweight triggers

Use `--system-event` instead of `--message` for cron jobs that only need to inject context:

```bash
openclaw cron add \
    --system-event "Daily data refresh completed at $(date)" \
    --cron "0 6 * * *" \
    --tz "Europe/Berlin" \
    --agent tech-manager \
    --session-key "agent:tech-manager:cron:data-refresh"
```

Still triggers an LLM turn, but lighter context injection.

---

## Definitive Answers

### Q1: Can OpenClaw cron run shell scripts without an LLM turn?
**No.** All cron payloads are `agentTurn` or `systemEvent`, both requiring LLM processing.

### Q2: Is there a `kind` field supporting "shell" or "command"?
**No.** `schedule.kind` supports only `"every"` and `"cron"` (schedule types). `payload.kind` is always `"agentTurn"`.

### Q3: Can OpenClaw hooks run scripts on a schedule?
**No.** Hooks are internal lifecycle events (boot, session management), not schedulable.

### Q4: Is there a plugin/extension mechanism for this?
**Theoretically yes** (the plugin system is extensible), but no existing plugin provides scheduled shell execution. Someone could write one.

### Q5: What is the best workaround?
**macOS launchd** (Pattern A/B above). It is already proven in this project via the session watchdog. A launchd plist can run any shell script on a schedule, and that script can call OpenClaw CLI commands when LLM processing is actually needed.

### Q6: Can `openclaw message send` be called without an LLM turn?
**Yes.** `openclaw message send` is a direct CLI command that sends messages without any LLM involvement. A launchd script can call it directly.

---

## Recommendation

For tasks that need periodic shell execution (data collection, file cleanup, API polling, health checks) without paying for an LLM turn:

1. **Use launchd** for the scheduling and shell execution
2. **Call `openclaw` CLI** from within the script when you need to interact with agents or channels
3. **Reserve OpenClaw cron** for tasks that genuinely need LLM reasoning

This is exactly the pattern already established with the session watchdog.
