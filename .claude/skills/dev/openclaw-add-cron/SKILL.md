---
name: openclaw-add-cron
description: Add or modify a cron job in jobs-config.json following our conventions (session keys, schedule formats, delivery modes)
argument-hint: [agent-name]
disable-model-invocation: true
---

# Add/Modify Cron Job

Add or modify a cron job for agent `$ARGUMENTS` in the declarative config.

## Source of Truth

The file `.openclaw/cron/jobs-config.json` is the declarative cron config. Never edit `jobs.json` directly — it's a runtime file on the host. `deploy.sh` runs `apply-cron.sh` which reconciles the gateway's runtime state with `jobs-config.json`.

## Steps

1. **Read current config:** Read `.openclaw/cron/jobs-config.json` to see existing jobs and conventions.

2. **Determine the job type.** Each dev-pa agent has 4 standard jobs:

   | Job | Session key | Purpose |
   |-----|------------|---------|
   | Morning check-in | `agent:<name>:cron:morning` | Start-of-day greeting + priorities |
   | Midday check-in | `agent:<name>:cron:midday` | Mid-day status check |
   | Evening check-in | `agent:<name>:cron:evening` | End-of-day wrap-up |
   | Daily summary | `agent:<name>:cron:summary` | GitHub activity summary |

   The tech-manager agent has: `monitoring` (hourly), `morning-report`, `evening-report`.

   If adding a non-standard job, ask the user for: purpose, schedule, and message content.

3. **Look up the agent's Slack ID** in `CLAUDE.md` (agent table) for the `sessionTarget`.

4. **Generate a UUID:**
   ```bash
   python3 -c "import uuid; print(uuid.uuid4())"
   ```

5. **Create the job entry** following this exact structure:

```json
{
  "id": "<generated-uuid>",
  "agentId": "<agent-name>",
  "name": "<Agent Display Name> <Job Description>",
  "enabled": true,
  "schedule": {
    "kind": "cron",
    "cronExpr": "<5-field cron expression>",
    "tz": "<IANA timezone>"
  },
  "sessionTarget": "session:slack:direct:<slack-id-lowercase>",
  "wakeMode": "now",
  "payload": {
    "kind": "agentTurn",
    "message": "<task instructions for the agent>",
    "timeoutSeconds": 300,
    "thinking": "medium"
  },
  "sessionKey": "agent:<name>:cron:<type>",
  "delivery": {
    "mode": "none"
  }
}
```

For channel-targeted jobs (tech-manager): use `"session:slack:channel:<channel-id-lowercase>"`.

6. **Add the entry** to the `jobs` array in `.openclaw/cron/jobs-config.json`.

7. **Commit and push** via PR. `deploy.sh` runs `apply-cron.sh` on the host automatically.

## Field Reference

| Field | Value | Notes |
|-------|-------|-------|
| `schedule.kind` | `"cron"` or `"every"` | Cron for exact times, every for intervals |
| `schedule.cronExpr` | 5-field cron | Only with `"kind": "cron"`. Standard syntax (minute hour day month weekday) |
| `schedule.tz` | IANA timezone | Only with `"kind": "cron"`. e.g., `"Europe/Berlin"`, `"Asia/Tbilisi"`. Omitting defaults to UTC |
| `schedule.everyMs` | milliseconds | Only with `"kind": "every"`. No `cronExpr` or `tz` needed |
| `sessionTarget` | `session:slack:direct:<id>` | Slack user ID, lowercase |
| `sessionKey` | `agent:<name>:cron:<type>` | Determines session isolation. Different keys = different sessions |
| `delivery.mode` | `"none"` | Agent sends messages itself via `openclaw message send` |
| `payload.thinking` | `"medium"` | Standard for check-ins |
| `payload.timeoutSeconds` | `300` | Standard 5-minute timeout |

## Schedule Invariants

- **Summary jobs always use `Europe/Berlin`** timezone, regardless of the developer's local timezone. This ensures all summaries fire at 20:00 CET so the tech-manager evening report can collect them.
- **Summary cron expression** must be `0 20 * * *` (works weekends) or `0 20 * * 1-5` (weekdays only).
- **Check-in time ordering:** morning < midday < evening < summary (20:00 CET). Evening check-ins must finish before the summary runs.
- **Weekday field must match `works_weekends`:** If the developer doesn't work weekends (`works_weekends: false` in `work-schedule.json`), use `1-5` in the day-of-week cron field. If they do, use `*`.

## Important

- **`sessionKey` is required.** It determines which session the job runs in. Jobs with different session keys are isolated from each other and from chat.
- **Session routing:** `sessionTarget` points to the developer's Slack DM session (`session:slack:direct:<id>`). The cron job executes within that DM session context, but does **not** have access to prior chat history — it only sees messages from previous cron runs in the same session.
- **`delivery.mode` is always `"none"`** in our setup. Agents decide whether and how to message via `openclaw message send` in their payload instructions.
- **Do not set `payload.model`** — ever. Jobs inherit the agent's default model from gateway config. Leftover model fields have caused unnecessary gateway restarts.
- **Slack IDs must be lowercase** in `sessionTarget`.
- When modifying existing jobs, match by `sessionKey` to find the right entry.

## Validation

A PostToolUse hook runs `scripts/validate-invariants.sh --target cron` after every edit to `jobs-config.json`. It checks 13 invariants (session key format, uniqueness, delivery mode, thinking level, timeouts, etc.) and reports failures immediately.

The same script runs as a hard-fail gate in the CI deploy pipeline — broken cron config cannot reach the host.

See `docs/invariants.md` (Area 1) for the complete list of enforced rules.
