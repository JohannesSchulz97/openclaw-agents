# openclaw-agents

A production-grade framework for deploying and operating teams of autonomous AI agents on [OpenClaw](https://openclaws.io). Designed to scale: one configuration change propagates to every agent on the next deploy.

---

## What this is

This repo is the configuration and automation layer for running two types of AI agents across a software engineering team:

**Developer Personal Assistants (`dev-pa`)** — each developer gets a dedicated agent that lives in their Slack DMs. It runs autonomously on a schedule, with no developer intervention required:
- Morning, midday, and evening check-ins adapted to each developer's working hours and timezone
- End-of-day work reports generated from GitHub activity
- Persistent memory across sessions — the agent remembers past conversations, decisions, and blockers
- Automatic Zoom transcript delivery — developers who opt in receive their meeting transcripts via Slack DM, with configurable language preference (English, German, or both)
- Natural conversation via Slack DM at any time

**Tech Manager (`manager`)** — a single agent that monitors the entire team. It reads across all developer agents' memory files, detects missed check-ins and blocked work, and delivers structured reports to leadership. It is the AI layer that makes team activity visible without any developer needing to file status updates.

---

## Why this architecture is worth looking at

### Type system for agent configuration

All agents of the same type share a single source of truth in `types/`. Edit `types/dev-pa/SOUL.md` once — `sync-agents.sh` propagates the change to every agent on deploy. There is no per-agent duplication to keep in sync. Adding a new developer takes one command:

```bash
scripts/create-agent.sh --name dev1 --slack-id <slack-user-id>
```

The agent bootstraps itself: it introduces itself to the developer, establishes its identity and vibe through natural conversation, collects working hours, and activates its check-in schedule — all without manual configuration.

### Three-layer memory architecture

Agent memory is split by intent, not by mechanism:

| Layer | Tool | What it stores |
|-------|------|----------------|
| Durable memory | QMD (vector search) | Curated knowledge: daily notes, work reports, decisions, blockers |
| Session recall | LCM (DAG compaction) | What was said in the current conversation |
| Legacy compatibility | Root `MEMORY.md` | Backward-compatible index |

Cron jobs write two memory files per agent per day: a conversation summary (what the developer discussed, decided, was blocked on) and a work report (GitHub activity, PRs, issues). Both are indexed by QMD and searchable with `memory_search` across all sessions. LCM manages the active conversation context using a DAG-based compaction strategy — every message is preserved in the graph while the active context window stays within model token limits.

### Cron jobs as isolated sessions

Scheduled check-ins run in fresh isolated sessions, completely separate from the developer's DM conversation. Conversation context is passed explicitly via a DM digest helper (`scripts/lib/dm-digest.sh`), not by sharing the session. This prevents scheduled work from polluting interactive sessions and was key to keeping DM sessions clean and responsive.

### Manager agent with cross-team read access

The tech-manager agent has read access to every developer agent's `memory/` directory. It aggregates daily notes, detects missed check-ins based on session timestamps, correlates GitHub activity with reported progress, and posts structured team reports to leadership. No developer has to file a status update — the agents write it as a side effect of their normal operation.

### Declarative cron management

`.openclaw/cron/jobs-config.json` is the single source of truth for all scheduled behavior. `apply-cron.sh` diffs the declared config against the gateway's runtime state and applies changes (add / edit / remove) in order. Cron changes go through PRs like any other change.

### Formal invariants with machine enforcement

`docs/invariants.md` catalogs architectural rules with enforcement tags:
- `[ENFORCED]` — validated by `scripts/validate-invariants.sh`, which runs as a hard-fail CI gate on every deploy
- `[HOOKED]` — a Claude Code PreToolUse hook fires before editing sensitive files
- `[DOCUMENTED]` — convention enforced by code review

PreToolUse hooks block direct edits to shared agent files (must go through `types/`) and force reading the relevant skill before editing sensitive config. PostToolUse hooks run validation after every edit and surface failures immediately.

---

## Repo structure

```
types/
├── dev-pa/          # Developer PA type — shared config for all dev agents
│   ├── SOUL.md      # Agent personality and behavior principles
│   ├── AGENTS.md    # Instructions, memory model, tool usage, red lines
│   ├── BOOTSTRAP.md # First-run onboarding flow
│   ├── HEARTBEAT.md # Check-in behavior
│   └── scripts/     # check-in, work-report, daily-summary, github-activity, etc.
└── manager/         # Tech Manager type
    ├── SOUL.md
    └── scripts/     # bottleneck detection, missed check-ins, evening reports

scripts/             # Repo-level automation
├── deploy.sh        # Full deploy sequence: pull → sync → stow → cron
├── sync-agents.sh   # Fan-out from types/ to per-agent directories
├── create-agent.sh  # Onboard a new developer agent
├── remove-agent.sh  # Remove an agent cleanly
├── apply-cron.sh    # Reconcile declarative cron config with gateway runtime
└── validate-invariants.sh  # 14 machine checks — CI deploy gate

.openclaw/cron/
└── jobs-config.json # Declarative cron job config (source of truth)

.github/workflows/
└── deploy.yml       # CI/CD: triggers deploy.sh on host when main is pushed

docs/                # Architecture, memory model, invariants, troubleshooting
```

---

## Deployment pipeline

All changes flow one-way: dev machine → GitHub → OpenClaw host. The host is a deployment cache — git hooks block commits and branch switches on it. Development always happens on a dev machine via pull requests.

```
Dev Machine ──PR──▶ GitHub (main) ──Actions──▶ OpenClaw Host
                                                     │
                                             deploy.sh --pull
                                             sync-agents.sh
                                             stow --restow
                                             apply-cron.sh
```

---

## Stack

- **[OpenClaw](https://openclaws.io)** — local-first AI agent platform
- **[Lossless Claw (LCM)](https://openclaws.io/plugins/lcm)** — DAG-based context management, replaces sliding-window compaction
- **[QMD](https://github.com/tobilu/qmd)** — vector memory backend with BM25 + semantic search
- **GNU Stow** — symlink-based config deployment from repo to host
- **GitHub Actions** — CI/CD trigger for host deploys
- **Slack** — primary agent communication surface
