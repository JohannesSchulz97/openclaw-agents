---
name: openclaw-stow
description: "Emergency manual stow intervention — only use when deploy.sh stow step fails or symlinks are broken"
disable-model-invocation: true
---

# Emergency Manual Stow

**This is an emergency-only skill.** Normal deployments go through `deploy.sh` which handles `stow --adopt` then `stow` automatically. Only use this when deploy.sh fails or symlinks are visibly broken.

## Critical Warning

`stow --adopt` MUST run before regular `stow`, or per-agent runtime files (IDENTITY.md, USER.md, work-schedule.json) get overwritten with templates. This destroyed agent data on 2026-03-30. Never skip the adopt step.

## Steps

1. **Remove the known `jobs.json` conflict:**
```bash
rm -f ~/.openclaw/cron/jobs.json
```
The gateway overwrites `jobs.json` as a real file on every startup, breaking the stow symlink. This is expected.

2. **Adopt first (captures any host-side changes):**
```bash
cd ~/Projects/<your-org>/openclaw-agents && stow --adopt --no-folding -t ~ .
```

3. **Then push symlinks:**
```bash
cd ~/Projects/<your-org>/openclaw-agents && stow --no-folding -t ~ .
```

4. **Verify key symlinks:**
```bash
ls -la ~/.openclaw/cron/jobs-config.json    # Should be symlink → repo
ls -la ~/.openclaw/openclaw.json            # Should be REAL FILE (Category 3, not symlinked)
ls -la ~/.openclaw/agents/dev1/SOUL.md  # Should be symlink → repo
```

`openclaw.json` is Category 3 (host-only runtime) — it must NOT be a symlink. If it is, something went wrong.

5. **If stow reports other conflicts:**
   - Gateway-created files (sessions, auth tokens): safe to remove, then re-stow
   - User-created content (memory/, reports/): back up first, then investigate

6. **Restart gateway after fixing stow:**
   Follow the `openclaw-restart` skill (validate config first).

## Files that should be symlinks (Category 2)

These point from `~/.openclaw/` into the repo:
- `agents/*/SOUL.md`, `AGENTS.md`, `TOOLS.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`
- `agents/*/scripts/` (entire directory)
- `cron/jobs-config.json`
- `agents/*/DAILY-SUMMARY.template.md`, `poll-config.json`

## Files that must NOT be symlinks (Category 3/4)

- `openclaw.json` — host-only runtime config
- `agents/*/IDENTITY.md`, `USER.md`, `work-schedule.json` — per-agent runtime
- `agents/*/memory/`, `reports/`, `outbox/` — agent-owned data
- `cron/jobs.json` — gateway runtime (recreated on startup)
