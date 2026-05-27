# openclaw-agents

Configuration and automation layer for running a fleet of autonomous AI agents across a distributed software engineering team. 19 developer personal assistants and one manager agent, all deployed from a single repository.

---

## What it does

A distributed team of **19 developers across 5 countries** used Slack for all communication but had no structured way to surface blockers before they became problems, track daily work, or give the tech lead visibility without micromanaging.

This system deploys one dedicated AI agent per developer, living in their Slack DMs. Each agent operates autonomously — it knows the developer's working hours, timezone, and GitHub activity, runs scheduled check-ins adapted to their schedule, and maintains persistent memory across every session. A separate manager agent monitors the whole team, detects bottlenecks, and posts structured status reports to leadership. No developer files a status update. The agents produce it as a side effect of their normal operation.

**Outcomes:**
- 3 scheduled check-ins per developer per day (morning planning, midday progress, evening recap), each adjusted to local timezone and work schedule
- Daily work reports generated from GitHub activity — commits, PRs, issues — delivered automatically per developer
- Persistent cross-session memory: the agent remembers what was discussed, decided, and blocked across every conversation
- Manager agent runs hourly bottleneck detection across all 19 agents and produces morning and evening team reports
- Zoom transcript delivery: opt-in routing from Twenty CRM webhook to each developer's Slack DM
- Voice message support: agents transcribe and integrate voice replies into memory, allowing hands-free check-in responses
- Single-command provisioning for new agents; the agent bootstraps itself through a natural onboarding conversation

---

## How it works

### Agent types

**`dev-pa` — Developer Personal Assistant**

Each developer gets a dedicated agent. On first contact, the agent runs a bootstrap conversation: it introduces itself, collects the developer's preferred name and communication style, asks about working hours and timezone, then writes the work schedule configuration and activates the three cron jobs. From that point, all check-ins fire at the right local time automatically.

During check-ins, the agent pulls a DM digest (recent conversation context) and the developer's latest GitHub activity, then sends a contextual message. The developer can reply by text or voice. That reply gets integrated into memory. At the end of the day, a separate cron job generates a work report from GitHub and writes it to durable memory. A nightly summary distills the day's conversations into a dated memory file.

**`manager` — Tech Manager**

A single agent monitors the entire fleet from a dedicated Slack channel. It has read access to every developer agent's `memory/` directory. Hourly: it checks for missed check-ins and agents stuck in loops. Morning and evening: it aggregates daily notes, correlates GitHub activity with reported progress, and posts structured reports. No developer has to do anything — the manager reads what the developer agents write.

### Memory architecture

Agent memory is split by intent across three layers:

| Layer | Mechanism | Scope |
|-------|-----------|-------|
| Durable memory | QMD (vector search over dated markdown files) | Persistent, cross-session |
| Session recall | LCM — DAG-based compaction | Current session only |
| Legacy index | Root `MEMORY.md` | Backward compatibility |

Two cron jobs write durable memory per agent per day:

- `daily-summary.sh` — conversation context: what the developer worked on, discussed, decided, blocked on
- `work-report.sh` — work output: GitHub activity fetched via Search API (not Events API, which misses private repos)

Both files land under `memory/` and are indexed by QMD automatically. The agent can search across all past sessions with `memory_search`. LCM manages the active conversation context using DAG-based summarization — every message is preserved in the graph while the active context window stays within model token limits.

### Cron isolation

Scheduled check-ins run in **isolated sessions**, completely separate from the developer's DM conversation. Context is passed explicitly via a DM digest helper (`scripts/lib/dm-inject.js`), not by sharing the session. This prevents cron noise from polluting interactive sessions — a lesson learned after session sizes grew to 43 MB and LCM accumulated 2.2 M tokens of cron output before the isolation was introduced.

### Type system

All agents of the same type share a single source of truth in `types/`. Edit `types/dev-pa/SOUL.md` once — `sync-agents.sh` propagates the change to every agent on the next deploy. There is no per-agent duplication to drift out of sync. Per-agent files (`IDENTITY.md`, `USER.md`, `work-schedule.json`) are generated once at provisioning and never overwritten by sync.

### Invariant enforcement

`docs/invariants.md` catalogs 30+ architectural rules across cron configuration, the sync/deploy pipeline, agent governance, and plugin config. Rules are tagged by enforcement level:

- **[ENFORCED]** — validated by `scripts/validate-invariants.sh`, which runs as a hard-fail CI gate on every deploy and as a PostToolUse hook during editing
- **[HOOKED]** — a Claude Code PreToolUse hook fires before edits to sensitive files (e.g., blocking direct edits to `.openclaw/agents/*/` — those must go through `types/`)
- **[DOCUMENTED]** — convention enforced by code review

The invariants exist because failures were real: wrong session key formats caused cron jobs to pollute DM sessions, null `agentId` fields routed one developer's check-ins to another developer's DM, leftover model fields in cron config caused 9 unnecessary gateway restarts in a single day. Each invariant traces back to a specific incident and commit.

---

## Repo structure

```
types/
├── dev-pa/               # Developer PA type — shared config for all dev agents
│   ├── SOUL.md           # Personality and behavior principles
│   ├── AGENTS.md         # Instructions, memory model, tool usage, red lines
│   ├── BOOTSTRAP.md      # First-run onboarding flow
│   ├── HEARTBEAT.md      # Check-in behavior
│   ├── TOOLS.md          # Available tools and usage guidance
│   └── scripts/          # check-in, work-report, daily-summary, github-activity, etc.
└── manager/              # Tech Manager type
    ├── SOUL.md
    ├── AGENTS.md
    └── scripts/          # bottleneck detection, missed check-in checks, evening reports

scripts/                  # Repo-level automation
├── deploy.sh             # Full deploy sequence: pull → validate → sync → stow → cron
├── sync-agents.sh        # Fan-out from types/ to per-agent directories
├── create-agent.sh       # Onboard a new developer agent (one command)
├── remove-agent.sh       # Remove an agent cleanly (flock-based race protection)
├── apply-cron.sh         # Reconcile declarative cron config with gateway runtime
├── update-openclaw.sh    # Safe OpenClaw upgrades with LCM config preservation
├── session-watchdog.sh   # Detects and alerts on stuck agent sessions
└── validate-invariants.sh # Machine checks — CI deploy gate

.openclaw/cron/
└── jobs-config.json      # Declarative cron job config (single source of truth)

.github/workflows/
└── deploy.yml            # CI/CD: triggers deploy.sh on host when main is pushed

docs/                     # Architecture, memory model, invariants, troubleshooting
```

---

## Deployment pipeline

The host is a Mac mini running as a read-only deployment target. Git hooks block commits and branch switches on it — it always tracks main. Development happens on a dev machine via pull requests.

```
Dev Machine ──PR──▶ GitHub (main) ──Actions──▶ OpenClaw Host (Mac mini)
                                                      │
                                              deploy.sh --pull
                                              openclaw config validate
                                              validate-invariants.sh   ← hard-fail gate
                                              sync-agents.sh
                                              stow --restow
                                              apply-cron.sh
```

`apply-cron.sh` diffs `.openclaw/cron/jobs-config.json` against the gateway's runtime cron state and applies changes (add / edit / remove) declaratively. Cron changes go through PRs like any other change.

The gateway runs as a launchd service with automatic restart on crash. `caffeinate` prevents system sleep during operations. Runtime state (conversations, memory, credentials) never touches GitHub — credentials stay on-host, conversation privacy is preserved, and the repo remains the single source of truth for configuration.

---

## Provisioning a new agent

```bash
scripts/create-agent.sh --name dev1 --slack-id <slack-user-id>
```

This generates the directory structure, substitutes templates with agent identity and user info, registers Slack bindings, updates allowlists, creates cron schedules, and deploys. The agent then bootstraps itself: it introduces itself to the developer, establishes its operating style through natural conversation, collects working hours and timezone, and activates its schedule — all without manual configuration.

---

## Stack

| Component | Role |
|-----------|------|
| [OpenClaw](https://openclaws.io) | Local-first AI agent platform — gateway, sessions, cron, Slack integration |
| [Lossless Claw (LCM)](https://openclaws.io/plugins/lcm) | DAG-based context management, replaces sliding-window compaction |
| [QMD](https://github.com/tobilu/qmd) | Vector memory backend — BM25 + semantic search over dated markdown files |
| GNU Stow | Symlink-based config deployment from repo into the host's home directory |
| GitHub Actions | CI/CD trigger: self-hosted runner on the Mac mini host |
| Slack | Primary agent communication surface |
| GPT-5.4 (Codex) | Default model — used for both scheduled and interactive modes to prevent personality drift |
| GLM-5 via Fireworks | Fallback model (202K context window) |
