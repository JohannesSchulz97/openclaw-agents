---
name: openclaw-status
description: Check OpenClaw gateway health, agent status, channel connectivity, cron jobs, and recent errors
disable-model-invocation: true
allowed-tools: Bash, Read, Grep
---

# OpenClaw Status Check

Comprehensive health check of the single-gateway Slack-only deployment.

## Steps

1. **Overall status:**
```bash
openclaw status
```
This shows gateway health, agents, channels, cron, memory backend, and plugins in one view.

2. **Cron job status:**
```bash
openclaw cron list
```
Check last run times, next scheduled runs, and error counts for all jobs.

3. **Agent routing verification:**
```bash
openclaw agents bindings
```
Confirm all 18 agents have correct Slack bindings.

4. **Channel connectivity:**
```bash
openclaw channels list
```
Verify Slack connection is active.

5. **Recent errors:**
```bash
tail -50 ~/.openclaw/logs/gateway.log | grep -iE "error|fail|crash"
```

6. **Report to user** as a summary table:
   - Gateway: running/stopped, PID, uptime
   - Slack: connected / disconnected
   - Agents: total count, any without bindings
   - Cron: jobs with errors or overdue runs
   - Recent errors (if any)

## Deep check (optional)

For more detail, run:
```bash
openclaw status --deep
```
This includes per-agent session info and memory backend health (LCM + QMD).
