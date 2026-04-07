---
name: openclaw-restart
description: Restart the OpenClaw gateway after config changes — validates config first, then restarts and verifies health
disable-model-invocation: true
---

# Restart OpenClaw Gateway

Restart the single gateway after manual config changes. Normal deploys already handle restarts via `deploy.sh` — this skill is for manual `openclaw.json` edits on the host.

## Steps

1. **Validate config first (hard gate — never skip):**
```bash
openclaw config validate
```
If validation fails, fix the config before restarting. Do NOT proceed.

2. **Restart the gateway:**
```bash
openclaw gateway restart
```

3. **Verify it came back up:**
```bash
openclaw gateway status
```
Confirm the gateway is running and the PID changed.

4. **Check logs for errors:**
```bash
tail -30 ~/.openclaw/logs/gateway.log
```
Look for `[slack] socket mode connected` and any error lines.

5. **Report to user:**
   - Gateway PID, port (18789)
   - Slack connection status
   - Any errors from the log

## When to use

- After editing `~/.openclaw/openclaw.json` on the host
- After `openclaw doctor --fix` (updates LaunchAgent plist)
- After manual plugin updates

## When NOT to use

- After a normal PR merge — `deploy.sh` handles the full restart sequence
- For stow conflicts — use `openclaw-stow` first
