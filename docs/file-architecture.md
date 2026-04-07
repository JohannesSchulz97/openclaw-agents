# File Architecture: What's in the Repo and What's Not

## Overview

This repository (`openclaw-agents`) contains **agent type definitions, automation scripts, cron configuration, and documentation**. It does **not** contain conversation history, per-agent runtime state, credentials, or the OpenClaw platform configuration.

The system follows a **one-way sync model**: changes flow from the dev machine through GitHub to the OpenClaw host. There is no reverse path. The host is a deployment target, not a development environment.

```
┌─────────────┐         ┌──────────────┐         ┌────────────────────────────────────┐
│  Dev Machine │──push──▶│  GitHub Repo │──CI/CD──▶│  OpenClaw Host                     │
│             │         │              │         │                                    │
│ Edit files  │         │ Source of    │         │ deploy.sh pulls from main          │
│ Open PRs    │         │ truth for    │         │ sync-agents.sh copies type files   │
│ Branch work │         │ code & config│         │ stow links shared files            │
│             │         │              │         │ apply-cron.sh reconciles cron jobs  │
└─────────────┘         └──────────────┘         └────────────────────────────────────┘
                                                          │
                                                          ▼
                                                 ┌────────────────────┐
                                                 │ ~/.openclaw/        │
                                                 │                    │
                                                 │ agents/            │
                                                 │   ├── shared files │◀── symlinks from stow
                                                 │   ├── runtime files│◀── created by agents
                                                 │   └── sessions/    │◀── managed by OpenClaw
                                                 │ openclaw.json      │◀── platform config
                                                 │ credentials/       │◀── API keys
                                                 │ cron/jobs.json     │◀── runtime cron state
                                                 └────────────────────┘
```

### Why this separation?

- **Security**: Credentials, API keys, and `openclaw.json` never leave the host. They are not version-controlled.
- **Privacy**: Conversation sessions, chat history, and agent memory are runtime-only. Developers' interactions with their agents are not tracked in Git.
- **Single source of truth**: Shared agent files (like `SOUL.md`) are authored once in `types/` and copied to each agent by `sync-agents.sh`. The copies are gitignored — `types/` is the source of truth.
- **Deployment safety**: The host repo has git hooks that block commits and branch switches. It always tracks `main`. This prevents the class of incidents where development operations corrupt live agent state.

---

## The Four Tiers

| Tier | Location | On GitHub? | Deployed to host? | Examples |
|------|----------|------------|-------------------|----------|
| **1. Repo-only** | Repo root | Yes | No (not stowed) | `types/`, `scripts/`, `docs/`, `.github/`, `CLAUDE.md` |
| **2. Repo → Stowed** | `.openclaw/agents/*/` | Partially | Yes (via stow symlinks) | `SOUL.md`, `AGENTS.md`, `TOOLS.md`, `scripts/` per agent |
| **3. Host-only (agent runtime)** | `~/.openclaw/agents/*/` on host | No | N/A (created on host) | `IDENTITY.md`, `USER.md`, `memory/`, `work-schedule.json` |
| **4. Host-only (platform runtime)** | `~/.openclaw/` on host | No | N/A (created on host) | `openclaw.json`, `credentials/`, sessions, chat history |

---

## Tier 1: Repo-only (on GitHub, not stowed)

These files are the development and CI/CD layer. They exist in the GitHub repo but are never deployed into `~/.openclaw/` directly.

### What's here

| Path | Purpose |
|------|---------|
| `types/dev-pa/` | Canonical shared files for the dev-pa agent type (17 agents) |
| `types/manager/` | Canonical shared files for the manager agent type (1 agent) |
| `scripts/` | Deployment and automation (`deploy.sh`, `sync-agents.sh`, `apply-cron.sh`, `create-agent.sh`, etc.) |
| `docs/` | Documentation and research notes |
| `.github/workflows/deploy.yml` | CI/CD: triggers `deploy.sh` on the host when `main` is updated |
| `CLAUDE.md` | Project instructions for Claude Code |
| `.gitignore` | Defines what's excluded from version control |

### Type definitions in detail

Each type directory contains the **master copies** of shared agent files plus `.template` files for per-agent config:

```
types/dev-pa/
├── SOUL.md                      # Agent personality and behavior
├── AGENTS.md                    # Agent directory (who's who)
├── TOOLS.md                     # Available tools documentation
├── BOOTSTRAP.md                 # First-run onboarding instructions
├── HEARTBEAT.md                 # Periodic check-in behavior
├── DAILY-SUMMARY.template.md    # Template for daily summaries
├── poll-config.json             # Polling configuration
├── scripts/                     # Agent scripts (checkin, github-activity, etc.)
├── IDENTITY.md.template         # Template — filled per-agent on host
├── USER.md.template             # Template — filled per-agent on host
├── work-schedule.json.template  # Template — filled per-agent on host
└── bootstrap-state.json.template
```

The `.template` files are used by `create-agent.sh` to generate per-agent runtime files on the host. They are **not** deployed directly.

---

## Tier 2: Repo → Stowed to ~/.openclaw (partially on GitHub)

These are the per-agent copies of shared files that live under `.openclaw/agents/*/` in the repo. They are generated by `sync-agents.sh` from `types/` and deployed to the host via stow.

### What's tracked vs. gitignored

The `.openclaw/` directory has a split personality:

| Tracked in Git | Purpose |
|----------------|---------|
| `.openclaw/.stow-local-ignore` | Tells stow which files to skip (per-agent runtime files) |
| `.openclaw/cron/jobs-config.json` | Declarative cron job configuration |

That's it. Only **2 files** under `.openclaw/` are version-controlled.

| Gitignored (generated by sync-agents.sh) | Purpose |
|------------------------------------------|---------|
| `.openclaw/agents/*/SOUL.md` | Copied from `types/<type>/SOUL.md` |
| `.openclaw/agents/*/AGENTS.md` | Copied from `types/<type>/AGENTS.md` |
| `.openclaw/agents/*/TOOLS.md` | Copied from `types/<type>/TOOLS.md` |
| `.openclaw/agents/*/BOOTSTRAP.md` | Copied from `types/<type>/BOOTSTRAP.md` |
| `.openclaw/agents/*/HEARTBEAT.md` | Copied from `types/<type>/HEARTBEAT.md` |
| `.openclaw/agents/*/DAILY-SUMMARY.template.md` | Copied from `types/<type>/` |
| `.openclaw/agents/*/poll-config.json` | Copied from `types/<type>/` |
| `.openclaw/agents/*/scripts/` | Copied from `types/<type>/scripts/` |

These files are **identical copies** of their type source. They exist per-agent because OpenClaw's boundary security rejects symlinks that resolve outside the agent workspace. The `sync-agents.sh` script copies them, and stow then creates symlinks from `~/.openclaw/agents/*/` pointing back to these repo copies.

### Why are generated copies gitignored?

Because `types/` is the source of truth. Tracking the copies would create N duplicate copies of each file in Git (one per agent) with no added value. Edit `types/`, commit, push — `sync-agents.sh` handles the rest on deploy.

---

## Tier 3: Host-only (agent runtime) — NOT on GitHub

These files are created on the OpenClaw host and owned by agents from that point on. They are **never committed to Git** and do not exist in this repository.

| File | Created by | Purpose |
|------|------------|---------|
| `IDENTITY.md` | `create-agent.sh` | Agent's name, Slack ID, identity context |
| `USER.md` | `create-agent.sh` | Developer profile (name, GitHub username, timezone) |
| `.agent-type` | `create-agent.sh` | Marker file indicating agent type (e.g., `dev-pa`) |
| `work-schedule.json` | `create-agent.sh` | Developer's working hours and timezone |
| `bootstrap-state.json` | `create-agent.sh` / agent | Bootstrap progress tracking |
| `.BOOTSTRAP.md.done` | Agent | Marker that bootstrap is complete |
| `MEMORY.md` | Agent | Memory index file |
| `memory/` | Agent | Agent's persistent memory files |
| `memory/daily/` | Agent | Daily interaction logs |
| `memory/archives/` | Agent | Archived memory |
| `memory/poll-state.json` | Agent | Check-in poll tracking state |
| `reports/` | Agent | Generated reports (daily summaries, etc.) |
| `outbox/` | Agent | Queued outbound messages |
| `TEAM.md` | Agent | Team context (manager type) |
| `sessions/` | OpenClaw | Conversation session data |

### How to inspect these

Since these files don't exist in the repo, you must check the host directly:

```bash
# On the host
ls ~/.openclaw/agents/dev1/
cat ~/.openclaw/agents/dev1/IDENTITY.md
```

---

## Tier 4: Host-only (OpenClaw platform) — NOT on GitHub

Platform-level configuration and runtime state managed by OpenClaw itself. These live on the host under `~/.openclaw/` but outside the agent directories.

| File / Directory | Purpose |
|-----------------|---------|
| `openclaw.json` | Main platform configuration (model settings, Slack integration, agent defaults, plugin config) |
| `credentials/` | API keys (Gemini, etc.) — **never version-controlled** |
| `cron/jobs.json` | Runtime cron state — generated by `apply-cron.sh` from `jobs-config.json` |
| `backups/` | Automatic backups of `openclaw.json` before updates |
| SQLite databases | Session storage, LCM (Lossless Context Management) data |
| Logs | Gateway and agent execution logs |
| Plugin data | QMD memory backend data, LCM DAG state |

### Conversation history specifically

**Chat history and conversation sessions are stored in OpenClaw's session storage on the host.** They are not in Git, not backed up to the repo, and not accessible from the dev machine. Each agent's conversations with their developer are ephemeral platform state — they live in OpenClaw's SQLite databases and session files.

---

## Quick Reference: "Is this on GitHub?"

| Item | On GitHub? |
|------|-----------|
| Agent type definitions (`SOUL.md`, `TOOLS.md`, etc.) | Yes — in `types/` |
| Automation scripts | Yes — in `scripts/` |
| Cron job configuration | Yes — `.openclaw/cron/jobs-config.json` |
| CI/CD workflows | Yes — `.github/workflows/` |
| Documentation | Yes — `docs/` |
| Per-agent copies of shared files | No — gitignored, generated by `sync-agents.sh` |
| Agent identity/profile (`IDENTITY.md`, `USER.md`) | No — host-only, created by `create-agent.sh` |
| Agent memory and reports | No — host-only, created by agents |
| Conversation history / chat sessions | No — host-only, managed by OpenClaw |
| OpenClaw config (`openclaw.json`) | No — host-only |
| API credentials | No — host-only |
| Cron runtime state (`jobs.json`) | No — host-only, generated by `apply-cron.sh` |

---

## The Deployment Pipeline

For completeness, here's how changes flow from a code edit to a live agent:

```
1. Developer edits types/dev-pa/SOUL.md on dev machine
2. Developer opens PR, merges to main
3. GitHub Actions triggers deploy.yml
4. deploy.yml runs deploy.sh --pull on the host (self-hosted runner)
5. deploy.sh executes:
   a. git pull                    — fetches latest main
   b. sync-agents.sh             — copies types/ files into .openclaw/agents/*/
   c. stow --adopt --restow      — creates symlinks from ~/.openclaw/ to repo
   d. apply-cron.sh              — reconciles cron jobs with jobs-config.json
6. All 18 agents now have the updated SOUL.md via their stow symlinks
```

No step in this pipeline touches conversation history, agent memory, or credentials.
