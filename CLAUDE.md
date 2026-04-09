# CLAUDE.md

This is the private agent configuration repository for Kais (autonomous AI worker bots on OpenClaw).

## Vision & Goals

These organizational goals guide all PM orchestration -- delegation, report reviews, and agent coordination should serve them. Start with the tech team, then expand company-wide.

1. **Priority steering** -- Visibility into what the team is working on and whether it aligns with what matters most
2. **Bottleneck detection** -- Recognize blockers early before they cascade into missed deadlines
3. **Workload visibility** -- Accurately assess team capacity and utilization across projects
4. **Communication acceleration** -- Reduce information lag so decisions flow faster across the team

**Scope:** Tech team first, then company-wide.

**Philosophy:** Organizational transparency matters more than perfect buy-in. Achieve these goals quickly.

## Deployment Architecture

The repo on the OpenClaw host is a **deployment cache**, not a development workspace. All changes go through PRs from a dev machine.

```
Dev Machine  ──PR──▶  GitHub (main)  ──Actions──▶  OpenClaw Host (deploy cache)
```

**Key rules:**
- **Never develop on the host.** The host repo has git hooks blocking commits and branch switches. It always tracks `main`.
- **All changes go through PRs.** Push to main triggers `.github/workflows/deploy.yml`, which runs `deploy.sh --pull` on the self-hosted runner.
- **`deploy.sh` handles the full sequence:** git pull → `sync-agents.sh` → stow (adopt then push) → `apply-cron.sh`. Always sequential, never parallel.
- **Deploy failures notify `#<manager-agent>-feedback`** (Slack channel `<channel-id>`) automatically.

This separation prevents the class of incidents where development operations (branch switching, manual stow, direct commits) corrupt live agent state. See issue #99 for the full incident history.

**Issues and tasks must clearly distinguish work by machine.** When creating issues or planning tasks, always separate what needs to happen on the dev machine (code changes, PRs) from what needs to happen on the OpenClaw host (runtime config like `openclaw.json`, memory file operations, gateway restarts, cron triggers). Use clear labels like "Dev machine:" and "Host:" in task lists.

## Issue Hygiene

GitHub issues are the paper trail for everything that happens in this project. Nothing operational should go unlogged.

### Every change gets an issue

Before starting work — whether it's a bug fix, feature, config change, version upgrade/downgrade, or host-side fix — create or find the relevant issue. The issue documents:
- **What** is being changed and **why**
- **What we expect** to happen (and what could go wrong)
- **What actually happened** — observations, side effects, verification results

If the work is reactive (e.g. fixing a production incident), it's fine to create the issue during or right after — but it must exist before the work is considered done.

### Issues stay maintained

Issues are living documents, not fire-and-forget tickets:
- **Add comments as work progresses.** Intermediate findings, decisions, and pivots go into comments so the full story is traceable.
- **Link related issues.** If an investigation reveals a new problem, open a new issue and cross-reference both. Don't bury multiple root causes in one thread.
- **Close with a resolution summary.** When closing, state what was done and what the outcome was. If a PR fixes it, the link alone is not enough — summarize what the PR actually changed and why.
- **Don't let issues go stale.** If work is paused or deprioritized, say so in a comment. An issue with no activity and no explanation is a blind spot.

### What counts as "operational"

This isn't limited to code changes. All of the following need issue documentation:
- Version changes (OpenClaw, LCM, QMD) — including what the new version changed in config
- Config changes to `openclaw.json`
- Gateway restarts with unusual circumstances
- Fixes applied directly on the host
- Agent creation or removal
- Cron schedule changes
- Incident investigation and resolution

## One-Way Sync Model

Sync is **one-way: repo → host**. There is no reverse path.

- **Shared agent files** (`SOUL.md`, `AGENTS.md`, `TOOLS.md`, etc.) flow from `types/` → `sync-agents.sh` → `.openclaw/agents/*/` → stow → `~/.openclaw/` on the host.
- **Per-agent runtime files** (`IDENTITY.md`, `USER.md`, `work-schedule.json`, `bootstrap-state.json`, `memory/`) are created on the host and owned by agents from that point on. They are **not in git**.
- To inspect an agent's current runtime config, check the host directly. The repo does not reflect live agent state.
- Slack IDs and GitHub usernames are duplicated in the agent listings below as a dev-machine reference, since the per-agent files that hold this data are host-only.

## Agent Types

Types live in `types/` at the repo root. Each type contains canonical shared configuration files that agents receive as real copies via `sync-agents.sh`.

Current types:
- **`dev-pa`** -- Developer Personal Assistant (17 agents)
- **`manager`** -- Tech Manager (1 agent: tech-manager)

To create a new type, add a directory under `types/` with the shared files (`SOUL.md`, `AGENTS.md`, `TOOLS.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`, `scripts/`, and `.template` files for per-agent configs). Edit a type's files once, then commit and push -- `deploy.sh` runs `sync-agents.sh` on the host automatically.

## OpenClaw Boundary Security

OpenClaw rejects symlinks that resolve outside the agent workspace root. This is why agent directories contain real file copies instead of symlinks. The source of truth for shared files is `types/<type>/`, and `sync-agents.sh` propagates changes from there into each agent directory.

## File Categories

### Category 1: Repo only (not stowed)

Dev tooling, repo-level files, and type definitions that never appear in `~/.openclaw/`:

- `types/` -- shared agent type definitions and templates
- `scripts/` -- repo-level automation (`deploy.sh`, `sync-agents.sh`, `create-agent.sh`, `apply-cron.sh`, etc.)
- `.claude/`, `.github/`, `docs/`, `CLAUDE.md`

### Category 2: Repo → stowed to ~/.openclaw (shared files)

Agent configuration generated by `sync-agents.sh` from `types/`. Gitignored (source of truth is `types/`). Stow creates symlinks from `~/.openclaw/` pointing to these:

- `SOUL.md`, `AGENTS.md`, `TOOLS.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`
- `scripts/`, `poll-config.json`, `DAILY-SUMMARY.template.md`

### Category 3: Host only (per-agent runtime)

Per-agent files created by `create-agent.sh` or by agents during bootstrap/runtime. Not in git, not managed by stow (excluded via `.stow-local-ignore`). Live only in `~/.openclaw/` on the host:

- `IDENTITY.md`, `USER.md`, `work-schedule.json`, `.agent-type`
- `bootstrap-state.json`, `.BOOTSTRAP.md.done`
- `memory/`, `reports/`, `outbox/`

### Category 4: Host only (OpenClaw runtime)

Created and managed by OpenClaw itself:

- Sessions, credentials, SQLite DBs, logs
- `openclaw.json` and its backups
- `cron/jobs.json` (runtime; generated by `apply-cron.sh`)

## Creating a New Agent

```bash
scripts/create-agent.sh --name <agent-name> --slack-id <slack-user-id>
```

Options:
- `--name NAME` (required) -- kebab-case agent name
- `--slack-id ID` (required) -- Slack user ID (e.g., <slack-id>)
- `--type TYPE` -- agent type (default: dev-pa)
- `--model MODEL` -- model for cron job (default: fw-mm25)
- `--display-name NAME` -- human-readable name (default: title-cased from name)
- `--dry-run` -- preview without making changes

The script automatically adds the developer's Slack ID to the `channels.slack.allowFrom` array in `openclaw.json`, which is required for DM delivery when `dmPolicy` is set to `"allowlist"`. After creating an agent, restart the gateway for changes to take effect:

```bash
openclaw gateway restart
```

To remove an agent:

```bash
scripts/remove-agent.sh --name <agent-name>
```

## Cron Management

All periodic agent behavior (check-ins, daily summaries, monitoring) runs through **cron jobs**, not heartbeat.

### Source of truth

`.openclaw/cron/jobs-config.json` is the declarative config. `apply-cron.sh` reconciles the gateway's runtime state with this file (add/edit/remove phases). It runs automatically as part of `deploy.sh`.

### Job patterns

Each dev-pa agent has 4 cron jobs:

| Job | Session key pattern | Purpose |
|-----|-------------------|---------|
| Morning check-in | `agent:<name>:cron:morning` | Start-of-day greeting + priorities |
| Midday check-in | `agent:<name>:cron:midday` | Mid-day status check |
| Evening check-in | `agent:<name>:cron:evening` | End-of-day wrap-up |
| Daily summary | `agent:<name>:cron:summary` | GitHub activity summary |

The tech-manager agent has 3 jobs: `monitoring` (hourly), `morning-report`, `evening-report`.

### Key fields in a cron job entry

```json
{
  "agentId": "dev10",
  "name": "dev10 Morning Check-in",
  "enabled": true,
  "schedule": {
    "kind": "cron",
    "cronExpr": "0 9 * * *",
    "tz": "Europe/Vienna"
  },
  "sessionTarget": "session:slack:direct:<slack-user-id-lowercase>",
  "wakeMode": "now",
  "payload": {
    "kind": "agentTurn",
    "message": "...",
    "timeoutSeconds": 300,
    "thinking": "medium"
  },
  "sessionKey": "agent:dev10:cron:morning",
  "delivery": { "mode": "none" }
}
```

### Session keys and session sharing

- **`sessionTarget`** is the primary control for which conversation a cron job runs in. It supports three modes:
  - `"main"` -- injects system events into the default agent's main session (requires `payload.kind: "systemEvent"`)
  - `"isolated"` -- creates a brand-new session every run (no conversation history)
  - `"session:<id>"` -- the `<id>` portion **overrides** the `sessionKey` for session lookup. `"session:main"` maps to the agent's main DM session (`agent:<name>:main`).
- **`sessionKey`** has two roles: (1) cron scheduler matching in `apply-cron.sh`, and (2) fallback session identity only when `sessionTarget` does **not** start with `session:`. When `sessionTarget` starts with `session:`, the sessionKey is overridden.
- **With `sessionTarget: "session:main"`** (current config), all cron jobs for an agent share the **same conversation history** as the agent's Slack DM session. The different `sessionKey` values (`agent:X:cron:morning`, `:midday`, etc.) do not create separate sessions -- they only serve as identifiers for `apply-cron.sh` reconciliation.
- To get **isolated cron sessions** with their own history, use `sessionTarget: "session:agent:<name>:cron:<type>"`. To get no-history one-shot runs, use `sessionTarget: "isolated"`.
- **`delivery.mode: "none"`** means the agent's response stays in the cron session only and is not delivered to the user as a notification. The agent itself decides whether to send a Slack message using `openclaw message send`.
- See `docs/research/openclaw-session-key-vs-target-2026-04-09.md` for the full source-code analysis.

### Adding a new cron job

1. Add an entry to `.openclaw/cron/jobs-config.json`
2. Commit and push -- `deploy.sh` runs `apply-cron.sh` automatically
3. To test before deploying, run on the host: `bash scripts/apply-cron.sh --dry-run`
4. To manually trigger a job on the host: `openclaw cron run <job-id>`

### Schedule formats

- **Cron expression:** `"kind": "cron", "cronExpr": "0 9 * * *", "tz": "Europe/Berlin"` (standard 5-field cron)
- **Interval:** `"kind": "every", "everyMs": 3600000` (milliseconds)

## Architectural Invariants

This repo has a formal invariants system to prevent recurring breakage. See `docs/invariants.md` for the full catalog.

### Enforcement

- **`scripts/validate-invariants.sh`** — 14 machine checks (cron config + gitignore). Runs in CI as a hard-fail deploy gate and via PostToolUse hooks during editing.
- **PreToolUse hooks** — hard-block edits to `.openclaw/agents/*/` shared files and scripts (must use `types/` instead), block `deploy.yml` edits without approval, and fire-once deny on `jobs-config.json`, type scripts, workspace config files, and `CLAUDE.md` to force reading the relevant skill first.
- **PostToolUse hooks** — validate `jobs-config.json` and `.gitignore` after every edit, report violations immediately.

### Keeping invariants up to date

When fixing a bug or correcting a broken pattern, ask yourself: **is this a rule that must always hold?** If a fix reveals a structural constraint (e.g., "sessionTarget must be lowercase", "scripts must be BSD-compatible"), it's likely an invariant.

**Workflow for new invariants:**
1. When you discover a potential invariant during a fix, ask the user: *"This looks like an architectural invariant — should I add it to `docs/invariants.md`?"*
2. If confirmed, add it to `docs/invariants.md` with the appropriate tag:
   - `[ENFORCED]` — if you also add a check to `scripts/validate-invariants.sh`
   - `[HOOKED]` — if a PreToolUse hook covers it but no machine validation
   - `[DOCUMENTED]` — if it's convention-only
3. If machine-enforceable, add a check function to `validate-invariants.sh` (the CI gate will enforce it automatically).
4. Reference the fix commit/issue in the rationale.

**Do not add invariants silently.** Always confirm with the user first — not every fix implies a permanent rule.

## Agents

| Agent | Slack ID | GitHub | Type |
|-------|----------|--------|------|
| dev1 | <slack-id> | <github-username>, <manager-agent> | dev-pa |
| dev10 | <slack-id> | <github-username> | dev-pa |
| dev10 | <slack-id> | <github-username> | dev-pa |
| dev10 Jean | <slack-id> | <github-username> | dev-pa |
| dev10 | <slack-id> | <github-username> | dev-pa |
| <your-org> | <slack-id> | -- | dev-pa |
| dev3 | <slack-id> | <github-username> | dev-pa |
| dev4 | <slack-id> | <github-username> | dev-pa |
| dev5 | <slack-id> | <github-username> | dev-pa |
| dev6 | <slack-id> | <github-username> | dev-pa |
| dev7 | <slack-id> | <github-username> | dev-pa |
| dev8 | <slack-id> | <github-username> | dev-pa |
| dev9 | <slack-id> | <github-username> | dev-pa |
| dev10 | <slack-id> | <github-username> | dev-pa |
| dev10 | <slack-id> | <github-username> | dev-pa |
| dev10 | <slack-id> | <github-username> | dev-pa |
| dev10 | <slack-id> | <github-username> | dev-pa |
| Tech Manager | <channel-id> (`#tech-management`) | -- | manager |

## OpenClaw Plugins

### Lossless Claw (LCM)

Lossless Context Management plugin by Martian Engineering. Replaces OpenClaw's built-in sliding-window compaction with a DAG-based summarization system that preserves every message while keeping active context within model token limits. See `docs/research/lossless-claw-research-2026-03-27.md` for details.

### QMD Memory Backend

Alternative memory backend by Tobi Lutke. Installed via `npm i -g @tobilu/qmd`. Configured in `~/.openclaw/openclaw.json` under `memory.backend`.

## Models

- **Primary:** `openai-codex/gpt-5.4` -- conversations and routine cron jobs
- **Fallback:** `fw-glm5` -- unlimited, auto-activates on rate limit
- **Specialist:** `google/gemini-3.1-pro-preview` (alias `gemini-pro`) -- difficult cron tasks only, not in fallback chain

Configured in `openclaw.json` under `agents.defaults.model`. Per-agent overrides removed; all agents inherit defaults. Cron jobs inherit too (no model field in payloads), except the weekly update-check job which uses `gemini-pro` for higher-quality risk analysis. Google API key at `~/.openclaw/credentials/gemini-nano-banana.json` (shared with image generation).

## Web Search

All agents use DuckDuckGo for web search (free, no API key). Configured in `openclaw.json` as `tools.web.search.provider: "duckduckgo"`. If better quality is needed, switch to Brave Search (`provider: "brave"`) which requires an API key from brave.com/search/api.

## Image Generation (Gemini Nano Banana)

API key stored at `~/.openclaw/credentials/gemini-nano-banana.json`. Default model: Nano Banana 2, fallback: Nano Banana Pro. Do NOT commit this key to the repository.

## OpenClaw Installation

```bash
npm i -g openclaw
```

## Updating OpenClaw & Plugins

Three components are tracked: OpenClaw (`npm i -g openclaw`), lossless-claw (`openclaw plugins install`), and QMD (`npm i -g @tobilu/qmd`).

### Automated weekly check

Every Monday at 00:00 CET, the tech-manager runs `check-updates.sh` via cron (using Gemini Pro for analysis). It compares versions, fetches changelogs, and assesses impact against our setup:
- **Low risk** (patch only, no breaking changes): writes `/tmp/openclaw-update-requested` marker and notifies `#<manager-agent>-feedback`. A launchd job at 00:30 picks up the marker and runs the update.
- **Risky** (major/minor bump, breaking changes): notifies `#<manager-agent>-feedback` with analysis and manual command only.

### Manual update

```bash
# Check versions (no changes)
bash scripts/update-openclaw.sh

# Apply all updates
bash scripts/update-openclaw.sh --apply

# Update a single component
bash scripts/update-openclaw.sh --apply --component openclaw
```

The apply sequence: backup `openclaw.json` → update packages → `openclaw doctor --fix` → `openclaw config validate` → restart gateway (if validation passes) → notify Slack.

**Constraints:**
- `openclaw doctor --fix` is required after every OpenClaw update (LaunchAgent plist hardcodes binary path)
- Never restart the gateway without running `openclaw config validate` first
- `openclaw.json` is backed up to `~/.openclaw/backups/` before every update


## Useful Commands

```bash
# Manually trigger a cron job (host only)
openclaw cron run <job-id>

# Apply cron config to runtime (host only, usually done by deploy.sh)
bash scripts/apply-cron.sh

# Restart gateway after config changes (host only)
openclaw gateway restart
```

Job IDs are defined in `.openclaw/cron/jobs-config.json`.
