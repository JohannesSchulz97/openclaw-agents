# Thinking/Reasoning Leak into Slack Messages - Investigation

**Date:** 2026-03-31
**Type:** Actionable Research
**Status:** Complete

## Summary

Investigation into agents leaking internal reasoning/thinking into Slack messages. Found **no specific GitHub issue** documenting this as a past bug fix. However, the current configuration has a critical defense (`delivery.mode: "none"`) that prevents automatic delivery of agent output (including thinking traces) to Slack. Additionally, a separate **thinking level misconfiguration** was discovered: all 17 cron jobs use `"thinking": "on"` which is NOT a valid OpenClaw thinking level.

---

## Key Findings

### Finding 1: `delivery.mode: "none"` Is the "Fix" (Currently In Place)

Every cron job in `.openclaw/cron/jobs-config.json` has:

```json
"delivery": {
  "mode": "none"
}
```

This is applied via `--no-deliver` flag in `scripts/apply-cron.sh` (line 168):

```bash
[ "$DELIVERY_MODE" = "none" ] && CMD+=(--no-deliver)
```

**What this does:** When delivery mode is `"none"`, OpenClaw does NOT auto-deliver the agent's output text to any Slack channel or user. Instead, agents send messages themselves via `openclaw message send`. This is the primary mechanism that prevents thinking/reasoning traces from leaking -- the agent controls what text is sent, not the platform.

**The alternative modes:**
- `"announce"` -- delivers agent output to target + posts summary to main session (DEFAULT for isolated sessions)
- `"webhook"` -- POSTs to URL
- `"none"` -- internal only, no delivery

**Risk scenario:** If `delivery.mode` were changed to `"announce"` (or if it were missing, since `"announce"` is the default for isolated sessions), the raw agent output -- which may include thinking traces, system instructions, or debug output -- would be automatically sent to Slack.

### Finding 2: No GitHub Issue Documents the Original Fix

Searched all GitHub issues for: "thinking", "reasoning", "delivery", "silent", "leak", "internal". **No issue was found** that specifically tracks "agents leaking thinking/reasoning into Slack messages." The closest related items:

- Issue #76 (CLOSED): "Clean up #tech-management Slack channel" -- about noisy messages, not thinking leaks
- Issue #15 (CLOSED): "Tech Manager responds only when @mentioned despite requireMention: false"
- Commit `7013d85`: "refactor(manager): strengthen silent-by-default channel presence rules" -- about when the tech-manager should respond in channels, not about thinking leaks

### Finding 3: Early Research Documents Acknowledge the Pattern

From `docs/openclaw-cron-jobs.md` (line 37):
> "Keep prompts simple - agent tends to include system text in response"

From `docs/research/<your-org>-slack-failure-2025-03-25.md` (line 28):
> "The thinking trace shows the agent looping -- the final thinking block is ~8,000+ characters of the agent going in circles"

This confirms that agents DO produce thinking traces in their output, and the `delivery.mode: "none"` + manual `openclaw message send` pattern is the architectural decision to prevent those traces from reaching users.

### Finding 4: `"thinking": "on"` Is an INVALID Value (All 17 Cron Jobs Affected)

**All 17 cron jobs** in `jobs-config.json` set `"thinking": "on"`.

The valid values per `openclaw agent --help` are:
```
off | minimal | low | medium | high | xhigh
```

`"on"` is NOT in this list. The `scripts/lib/cron-utils.sh` also hardcodes `thinking: "on"` (lines 129 and 223).

**The global default** in `openclaw.json` is `"thinkingDefault": "low"`. When `"on"` is passed as an invalid value, OpenClaw may:
1. Fall back to the default (`"low"`)
2. Interpret it as a truthy value and use some internal default
3. Silently ignore it

This is undocumented behavior and a potential source of unpredictable thinking levels.

From MEMORY.md:
> `--thinking` flag accepts: off/minimal/low/medium/high/xhigh (NOT "on")

### Finding 5: Slack Streaming Configuration Is Separate

Current Slack config:
```json
{
  "streaming": "partial",
  "nativeStreaming": true
}
```

Streaming controls the **live preview** of responses (how text appears in Slack as the model generates). This is separate from the delivery mode question. Streaming applies to interactive messages (DMs), not to cron-triggered jobs with `delivery.mode: "none"`.

### Finding 6: Per-Agent `reasoning` Field Is Model Metadata Only

The `reasoning` field found in `openclaw.json` (lines 31, 47, 63, 79, 93) is in the **model definitions** section under `agents.defaults.models`, describing whether each model supports reasoning. It is NOT a per-agent behavioral setting. No agent has per-agent `reasoning`, `thinking`, `delivery`, or `deliveryMode` overrides -- all return `null` in the agent list.

---

## Risk Assessment

### Current State: PROTECTED

The `delivery.mode: "none"` on all cron jobs is the defense. Agents compose their own messages via `openclaw message send`, giving them full control over what text reaches Slack.

### Reversion Risk: MEDIUM

If someone:
1. Removes the `delivery` block from a cron job (defaults to `"announce"` for isolated sessions)
2. Changes `delivery.mode` to `"announce"`
3. Creates a new cron job without specifying delivery mode

...then raw agent output (potentially including thinking traces, system instructions, or debug text) would be auto-delivered to Slack.

### Thinking Level Risk: LOW-MEDIUM

The `"thinking": "on"` misconfiguration on all 17 cron jobs is not causing visible harm (OpenClaw likely falls back to a default), but it means thinking levels are not explicitly controlled as intended.

---

## Action Items

### 1. Fix Invalid Thinking Level in Cron Jobs (All 17 Jobs)

Replace `"thinking": "on"` with a valid value. Recommended: `"thinking": "medium"` for check-in jobs (they need to parse JSON, read context, compose messages) or `"thinking": "low"` for simpler jobs like the hourly monitoring.

**Files to update:**
- `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json` -- all 17 occurrences
- `/Users/<hostname>/openclaw-agents/scripts/lib/cron-utils.sh` -- lines 129 and 223

### 2. Document the `delivery.mode: "none"` Convention

The fact that `delivery.mode: "none"` is the primary defense against thinking leaks is not documented anywhere as a deliberate architectural decision. Add this to CLAUDE.md or a dedicated doc:

> All agent cron jobs MUST use `delivery.mode: "none"` to prevent raw agent output (including thinking traces) from being auto-delivered to Slack. Agents handle their own message delivery via `openclaw message send`.

### 3. Add Validation to create-agent.sh / cron-utils.sh

Ensure any new cron job always gets `delivery.mode: "none"` and a valid thinking level. The `cron-utils.sh` `add_cron_jobs` function should enforce this.

### 4. Create GitHub Issue for Thinking Level Fix

Track the `"thinking": "on"` remediation as a proper issue.

---

## Configuration Reference

### openclaw.json (relevant settings)

| Setting | Location | Current Value | Purpose |
|---------|----------|---------------|---------|
| `agents.defaults.thinkingDefault` | Global | `"low"` | Default thinking level for all agents |
| `agents.defaults.subagents.thinking` | Global | `"low"` | Thinking level for subagents |
| `channels.slack.streaming` | Slack channel | `"partial"` | Live preview mode for interactive messages |
| `channels.slack.nativeStreaming` | Slack channel | `true` | Use Slack native streaming API |

### jobs-config.json (per-job settings)

| Setting | Current Value | Valid Values | Notes |
|---------|---------------|--------------|-------|
| `payload.thinking` | `"on"` (INVALID) | off, minimal, low, medium, high, xhigh | All 17 jobs affected |
| `delivery.mode` | `"none"` | none, announce, webhook | Defense against thinking leaks |
| `sessionTarget` | `"isolated"` | main, isolated, current, session:ID | Isolated = fresh session each run |

---

## Sources

- `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json` -- All cron job definitions
- `/Users/<hostname>/openclaw-agents/scripts/apply-cron.sh` -- Cron application script (--no-deliver logic)
- `/Users/<hostname>/openclaw-agents/scripts/lib/cron-utils.sh` -- Cron job creation utility (hardcoded thinking: "on")
- `~/.openclaw/openclaw.json` -- Global agent configuration
- `/Users/<hostname>/openclaw-agents/docs/openclaw-cron-jobs.md` -- Cron jobs documentation
- `/Users/<hostname>/openclaw-agents/docs/research/openclaw-slack-streaming-modes-2026-03-26.md` -- Streaming modes research
- `/Users/<hostname>/openclaw-agents/docs/research/<your-org>-slack-failure-2025-03-25.md` -- Evidence of thinking traces in output
- `openclaw agent --help` -- Valid thinking level values
