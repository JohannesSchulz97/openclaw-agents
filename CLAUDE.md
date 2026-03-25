# CLAUDE.md

This is the private agent configuration repository for Kais (autonomous AI worker bots on OpenClaw).

## Structure

Files fall into three categories based on where they live and how they get there.

### Category 1: openclaw-agents only (not stowed)

Dev tooling and repo-level files that never appear in `~/.openclaw/`:

- `.claude/` directory (skills, settings, hooks)
- `docs/`, `CLAUDE.md`, `.stow-local-ignore`, `.gitignore`

These are excluded from stow via `.stow-local-ignore`. They exist only in the repo for development purposes.

### Category 2: openclaw-agents -> symlinked to ~/.openclaw

Agent configuration we maintain in git. Stow creates symlinks so OpenClaw reads them from `~/.openclaw/`.

- **Agent configs:** `SOUL.md`, `IDENTITY.md`, `USER.md`, `AGENTS.md`, `TOOLS.md`, `BOOTSTRAP.md`, `HEARTBEAT.md`, `SECURITY.md`
- **Agent scripts and state:** `scripts/`, `memory/` state files (e.g., `poll-state.json`)
- **Cron config:** `cron/jobs.json`

The source of truth for these files lives in the repo. When creating new files in this category, re-run stow afterward to create the symlink.

### Category 3: ~/.openclaw only (never in repo)

Runtime data that OpenClaw creates and manages. Never committed to openclaw-agents:

- Sessions, credentials, SQLite DBs, logs
- Devices, media, delivery-queue, canvas, completions
- Telegram state
- `openclaw.json` and its backups

## OpenClaw Installation

Install via pnpm (not from fork):
```bash
pnpm add -g openclaw
```

## QMD Memory Backend

QMD is an alternative memory backend by Tobi Lütke. To enable:

1. Install: `bun install -g https://github.com/tobi/qmd`
2. Set in `~/.openclaw/openclaw.json`:
   ```json
   {
     "memory": {
       "backend": "qmd"
     }
   }
   ```

**Note:** There are known issues with QMD (GitHub issue #11308) - timeouts, fallback bugs, collection mismatches. Consider using `memory.backend: "local"` as fallback until resolved.

## Stow Workflow

Symlink category 2 files from the repo into `~/.openclaw/`:

```bash
cd ~/openclaw-agents && stow --no-folding -t ~ .
```

`.stow-local-ignore` excludes category 1 files (dev tooling, docs, etc.) so only `.openclaw/` contents get symlinked.

To pull live changes from `~/.openclaw/` back into the repo (e.g., if OpenClaw modified a symlinked file in place):

```bash
cd ~/openclaw-agents && stow --adopt --no-folding -t ~ .
```

After creating any new category 2 file, always re-run `stow --no-folding -t ~ .` to create the symlink.

## Agent: dev1

- Slack ID: <slack-id>
- Polling: every 10 minutes, check-in due after 240 min of no interaction
- Model: google/gemini-3.1-pro
