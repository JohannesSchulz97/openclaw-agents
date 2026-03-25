# CLAUDE.md

This is the private agent configuration repository for Kais (autonomous AI worker bots on OpenClaw).

## Structure

```
openclaw-agents/
├── types/                           # Agent type definitions (not stowed)
│   └── dev-pa/                      # Developer Personal Assistant type
│       ├── SOUL.md                  # Shared personality/principles
│       ├── AGENTS.md                # Shared operating manual
│       ├── TOOLS.md                 # Shared tools config
│       ├── HEARTBEAT.md             # Shared periodic tasks
│       ├── BOOTSTRAP.md             # Shared first-run onboarding
│       ├── IDENTITY.md.template     # Template: copied for new agents
│       ├── USER.md.template         # Template: copied for new agents
│       └── scripts/                 # Shared scripts
│           ├── poll-check.sh
│           └── lib/json-response.sh
├── .openclaw/                       # Stowed into ~/.openclaw/
│   ├── agents/
│   │   └── <agent-name>/
│   │       ├── SOUL.md → ../../../types/<type>/SOUL.md      # symlink
│   │       ├── AGENTS.md → ../../../types/<type>/AGENTS.md  # symlink
│   │       ├── TOOLS.md → (symlink)
│   │       ├── HEARTBEAT.md → (symlink)
│   │       ├── BOOTSTRAP.md → (symlink)
│   │       ├── scripts → (symlink to dir)
│   │       ├── IDENTITY.md          # Per-agent (real file)
│   │       ├── USER.md              # Per-agent (real file)
│   │       └── memory/              # Per-agent runtime state
│   └── cron/
│       └── jobs.json
├── docs/
├── .claude/
└── CLAUDE.md
```

Files fall into three categories based on where they live and how they get there.

### Category 1: openclaw-agents only (not stowed)

Dev tooling, repo-level files, and type definitions that never appear in `~/.openclaw/`:

- `types/` directory (shared agent type definitions and templates)
- `.claude/` directory (skills, settings, hooks)
- `docs/`, `CLAUDE.md`, `.stow-local-ignore`, `.gitignore`

These are excluded from stow via `.stow-local-ignore`. They exist only in the repo for development purposes.

### Category 2: openclaw-agents -> symlinked to ~/.openclaw

Agent configuration we maintain in git. Stow creates symlinks so OpenClaw reads them from `~/.openclaw/`.

- **Agent configs (symlinked to type):** `SOUL.md`, `AGENTS.md`, `TOOLS.md`, `BOOTSTRAP.md`, `HEARTBEAT.md`, `scripts/`
- **Agent configs (per-agent real files):** `IDENTITY.md`, `USER.md`
- **Agent runtime state:** `memory/` state files (e.g., `poll-state.json`)
- **Cron config:** `cron/jobs.json`

The source of truth for shared files lives in `types/<type>/`. Per-agent files live directly in the agent directory. When creating new files in this category, re-run stow afterward to create the symlink.

### Category 3: ~/.openclaw only (never in repo)

Runtime data that OpenClaw creates and manages. Never committed to openclaw-agents:

- Sessions, credentials, SQLite DBs, logs
- Devices, media, delivery-queue, canvas, completions
- Telegram state
- `openclaw.json` and its backups

## Agent Types

Types live in `types/` at the repo root. Each type contains shared configuration files that multiple agents can inherit via symlinks.

Current types:
- **`dev-pa`** - Developer Personal Assistant

To create a new type, add a directory under `types/` with the shared files (`SOUL.md`, `AGENTS.md`, `TOOLS.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`, `scripts/`, and `.template` files for per-agent configs). Edit a type's files once and all agents of that type inherit the change.

## Creating a New Agent

1. Create the agent directory:
   ```bash
   mkdir -p .openclaw/agents/<name>/memory
   ```

2. Copy templates for per-agent files:
   ```bash
   cp types/<type>/IDENTITY.md.template .openclaw/agents/<name>/IDENTITY.md
   cp types/<type>/USER.md.template .openclaw/agents/<name>/USER.md
   ```

3. Create symlinks from agent dir to type:
   ```bash
   cd .openclaw/agents/<name>
   ln -s ../../../types/<type>/SOUL.md SOUL.md
   ln -s ../../../types/<type>/AGENTS.md AGENTS.md
   ln -s ../../../types/<type>/TOOLS.md TOOLS.md
   ln -s ../../../types/<type>/HEARTBEAT.md HEARTBEAT.md
   ln -s ../../../types/<type>/BOOTSTRAP.md BOOTSTRAP.md
   ln -s ../../../types/<type>/scripts scripts
   ```

4. Add a cron entry in `.openclaw/cron/jobs.json`.

5. Re-run stow:
   ```bash
   cd ~/openclaw-agents/.openclaw && stow --no-folding -t ~/.openclaw .
   ```

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

Stow from `.openclaw/` directly into `~/.openclaw/`, which avoids needing to exclude non-openclaw repo files:

```bash
cd ~/openclaw-agents/.openclaw && stow --no-folding -t ~/.openclaw .
```

`.stow-local-ignore` is kept as a safety net but is no longer the primary mechanism for filtering.

To pull live changes from `~/.openclaw/` back into the repo (e.g., if OpenClaw modified a symlinked file in place):

```bash
cd ~/openclaw-agents/.openclaw && stow --adopt --no-folding -t ~/.openclaw .
```

After creating any new category 2 file, always re-run `stow --no-folding -t ~/.openclaw .` from `~/openclaw-agents/.openclaw` to create the symlink.

## Agent: dev1

- Slack ID: <slack-id>
- Polling: every 10 minutes, check-in due after 240 min of no interaction
- Model: google/gemini-3.1-pro
