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

## Important

- **`sessionKey` is required.** It determines which session the job runs in. Jobs with different session keys are isolated from each other and from chat.
- **Cron sessions are separate from chat.** The agent cannot see DM conversation history from a cron session.
- **`delivery.mode` is always `"none"`** in our setup. Agents decide whether and how to message via `openclaw message send` in their payload instructions.
- **Do not set `payload.model`** unless there's a specific reason. Jobs use the agent's default model.
- **Slack IDs must be lowercase** in `sessionTarget`.
- When modifying existing jobs, match by `sessionKey` to find the right entry.
