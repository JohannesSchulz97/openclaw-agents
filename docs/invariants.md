# Architectural Invariants

Rules that protect the openclaw-agents architecture from accidental breakage. This file is the single source of truth — hooks, validation scripts, and CI checks reference it.

## Enforcement Tags

- **[ENFORCED]** — Machine-validated by `scripts/validate-invariants.sh` (runs in CI before every deploy + PostToolUse hooks during editing)
- **[HOOKED]** — A Claude Code PreToolUse hook fires before edits, but no machine validation
- **[DOCUMENTED]** — Convention only, no automation. Enforced by code review.

## How Enforcement Works

```
PreToolUse hooks          → force reading skills before editing sensitive files
PostToolUse hooks         → run validate-invariants.sh after edits, report failures
CI deploy gate            → validate-invariants.sh hard-fails deploy if any check fails
```

See `.claude/settings.json` for hook configuration, `scripts/validate-invariants.sh` for check implementations.

---

## Area 1: Cron Configuration

Source file: `.openclaw/cron/jobs-config.json`

### 1.1 Session Key Format [ENFORCED]

`sessionKey` must match `agent:<agentId>:cron:<type>` where `<type>` is one of:
- dev-pa: `morning`, `midday`, `evening`, `summary`
- manager: `monitoring`, `morning-report`, `evening-report`

The `<agentId>` in the sessionKey must match the job's `agentId` field.

**Rationale:** Session keys determine session isolation. Wrong format causes cron noise to pollute interactive sessions or sessions to be mismatched during `apply-cron.sh` reconciliation. Fixed in `cd45db7`, `1996ee6`.

### 1.2 Session Key Uniqueness [ENFORCED]

No two jobs may share the same `sessionKey`. Each job runs in its own session.

**Rationale:** `apply-cron.sh` matches gateway jobs by sessionKey. Duplicates cause one job to be treated as an orphan and deleted. Fixed in `a366867`.

### 1.3 Session Target Format [ENFORCED]

`sessionTarget` must be one of:
- `session:slack:direct:<slack-user-id-lowercase>` — for dev-pa agents (DM sessions)
- `session:slack:channel:<channel-id-lowercase>` — for tech-manager (channel sessions)

The Slack ID / channel ID **must be lowercase**.

**Rationale:** Using `session:main` disconnects cron from the DM conversation — agent can't see prior context, hallucinates responses. Fixed 4 separate times: `cd45db7`, `7d59255`, `829c495`, `ecb2957`.

### 1.4 Session Target Consistency [ENFORCED]

All jobs for the same dev-pa agent must share the same `sessionTarget` (same Slack user ID).

**Rationale:** Inconsistent targets would split an agent's cron jobs across different sessions, breaking context continuity between morning/midday/evening check-ins.

### 1.5 Delivery Mode [ENFORCED]

`delivery.mode` must always be `"none"`. The agent controls message delivery via `openclaw message send` in its payload instructions.

**Rationale:** `apply-cron.sh` only handles `"none"` (passes `--no-deliver`). Any other value is silently ignored, causing unexpected delivery behavior.

### 1.6 Wake Mode [ENFORCED]

`wakeMode` must always be `"now"`.

**Rationale:** No other value has been used or tested. Hardcoded in `cron-utils.sh`.

### 1.7 Payload Kind [ENFORCED]

`payload.kind` must always be `"agentTurn"`.

**Rationale:** The CLI infers this from the `--message` flag. Other kinds are not used in our setup.

### 1.8 No Model Field [ENFORCED]

`payload.model` must be absent or null. Agents inherit their model from the gateway default. **Exception:** jobs with sessionKey in the allowed list in `validate-invariants.sh` may override the model (currently: `agent:tech-manager:cron:update-check` uses `gemini-pro` for higher-quality risk analysis).

**Rationale:** Leftover model fields caused 9 unnecessary gateway restarts in one day when `apply-cron.sh` tried to clear them non-idempotently. Fixed in `a70e779`, `593ccaa`, `3c64a1e`.

### 1.9 Thinking Level [ENFORCED]

`payload.thinking` must be one of: `off`, `minimal`, `low`, `medium`, `high`, `xhigh`.

**Rationale:** `"on"` was used across 11 jobs and is not a valid OpenClaw thinking level. Caused undefined runtime behavior. Fixed in `5c5e3c3`.

### 1.10 Timeout Minimum [ENFORCED]

`payload.timeoutSeconds` must be >= 300.

**Rationale:** 180s caused timeout errors with GLM-5 via Fireworks even when the agent completed its work. Fixed in `a693ec4`.

### 1.11 Summary Timezone [ENFORCED]

All daily summary jobs (sessionKey ending in `:summary`) must use `schedule.tz = "Europe/Berlin"` regardless of the developer's local timezone.

**Rationale:** Summaries must run at a coordinated time (20:00 CET) so the tech-manager's evening report can collect them. The tech-manager evening report also runs at 20:00 CET.

### 1.12 Summary Schedule [ENFORCED]

All daily summary jobs must use `cronExpr` of `"0 20 * * *"` (works weekends) or `"0 20 * * 1-5"` (weekdays only).

**Rationale:** Summary must run after the evening check-in to capture the full day. Collision at 19:30 with evening check-ins broke 3 agents. Fixed in `559bb7b`.

### 1.13 No Duplicate Agent+Type [ENFORCED]

No two jobs may have the same `agentId` combined with the same sessionKey type suffix (the part after the last `:`).

**Rationale:** 16 legacy every-2h jobs coexisted with new 3-per-day jobs, causing duplicate check-ins. Fixed in `a366867`.

---

## Area 2: Sync / Deploy Pipeline

### 2.1 Types Directory is Source of Truth [HOOKED]

All shared agent configuration must be edited in `types/<type>/`, never in `.openclaw/agents/*/`. The sync script (`sync-agents.sh`) copies from `types/` to `.openclaw/agents/*/` on every deploy, overwriting anything there.

**Rationale:** Git prohibition was initially added only to deployed copies, not `types/`. Sync overwrote the fix. Manager scripts were created directly in `.openclaw/` and wiped by sync. Fixed in `c152482`, `4e975ff`.

**Enforcement:** PreToolUse hard-block hooks deny edits to `.openclaw/agents/*/` shared files and scripts.

### 2.2 Shared Files Not in Git [DOCUMENTED]

Files generated by `sync-agents.sh` are gitignored. The `.gitignore` must contain patterns for:
- `.openclaw/agents/*/SOUL.md`, `AGENTS.md`, `TOOLS.md`, `HEARTBEAT.md`, `BOOTSTRAP.md`
- `.openclaw/agents/*/scripts/`
- `.openclaw/agents/*/poll-config.json`

**Rationale:** These are generated output. Tracking them causes merge conflicts and stale content. Fixed in `aac6c8d`.

### 2.3 Runtime Files Not in Git [DOCUMENTED]

Per-agent runtime files must be gitignored:
- `memory/` (daily notes, poll-state)
- `reports/`
- `.BOOTSTRAP.md.done`
- `sessions/`

Runtime cron state: `.openclaw/cron/jobs.json`

**Rationale:** Each new file category leaked into git reactively (4 incidents). Fixed in `aac6c8d`, `528d5b4`, `5823cf9`.

### 2.4 Per-Agent Files Excluded from Stow [DOCUMENTED]

`.openclaw/.stow-local-ignore` must exclude per-agent runtime files: `IDENTITY.md`, `USER.md`, `.agent-type`, `work-schedule.json`, `bootstrap-state.json`, `.BOOTSTRAP.md.done`, `memory/`, `reports/`, `outbox/`.

**Rationale:** Stow was overwriting per-agent customizations. Fixed in `24d6888`.

### 2.5 Deploy Sequence [DOCUMENTED]

`deploy.sh` must run strictly sequentially: `sync-agents.sh` -> `stow --adopt --no-folding` -> `stow --no-folding` -> `apply-cron.sh`. Running out of order destroys changes.

**Rationale:** Running stow --adopt before sync completes overwrites freshly-synced files with stale copies from `~/.openclaw/`.

### 2.6 No Symlinks Outside Workspace Root [DOCUMENTED]

OpenClaw's boundary security rejects symlinks that resolve outside the agent workspace root. This is why `sync-agents.sh` copies files instead of symlinking.

**Rationale:** Initial symlink approach was abandoned same day. Fixed in `62081b5`.

### 2.7 Workspace Path is Live Stow Path [DOCUMENTED]

Agent workspace in `openclaw.json` must point to `~/.openclaw/agents/<name>`, not `openclaw-agents/.openclaw/agents/<name>` (the repo path).

**Rationale:** Repo path caused split-brain: memory written to repo dir, read from live dir. Root cause of daily summaries not appearing. Fixed in `5386631`.

### 2.8 Deploy Verifies GITHUB_SHA [DOCUMENTED]

`deploy.sh` compares HEAD against `GITHUB_SHA` after fetch, retries once after 5s, and fails hard if mismatched.

**Rationale:** Push webhook fires before git ref propagates. Deploy ran against stale code silently. Fixed in `680efd1`, `c3aa505`.

### 2.9 Deploy Concurrency Serialized [DOCUMENTED]

`deploy.yml` uses `concurrency: { group: deploy, cancel-in-progress: false }`. Queuing, not cancellation.

**Rationale:** Rapid successive deploys caused 9 unnecessary gateway restarts. Fixed in `3c64a1e`.

### 2.10 GitHub Actions: $HOME not ~ [DOCUMENTED]

`working-directory` in GitHub Actions YAML must use `$HOME`, not `~`. Tilde does not expand.

**Rationale:** Deploy job failed with "No such file or directory". Fixed in `d04e2c9`.

### 2.11 No actions/checkout in Deploy [DOCUMENTED]

The self-hosted runner IS the host with a persistent repo clone. `actions/checkout` would create a disconnected second clone.

### 2.12 Template Files are Write-Once [DOCUMENTED]

`sync-agents.sh` only copies `.template` files if the target doesn't exist (`[[ ! -f "$dst" ]]`). This prevents overwriting per-agent customizations.

---

## Area 3: Agent Governance

### 3.1 No Git Commands in Agent Red Lines [DOCUMENTED]

`types/dev-pa/AGENTS.md` and `types/manager/AGENTS.md` must contain explicit prohibition of all git operations. Agent workspaces are stow-symlinked to the repo.

**Rationale:** Original AGENTS.md encouraged git usage. Agent committed directly to main. Fixed in `d79511a`, `5823cf9`.

### 3.2 gh CLI: Blanket Ban for dev-pa, Structured for Manager [DOCUMENTED]

dev-pa agents: blanket `gh` ban in Red Lines. Wrapper scripts (`github-activity.sh`, `create-issue.sh`) are the only escape hatch.

Manager agent: structured allow/prohibit list because it needs read access for reporting.

**Rationale:** First attempt to relax dev-pa Red Lines was reversed within the same PR.

### 3.3 Agents Never Self-Modify Config Files [DOCUMENTED]

Agents must not edit their own `AGENTS.md`, `SOUL.md`, `IDENTITY.md`, or other configuration files. Only memory files are writable.

**Rationale:** dev10 instructed tech-manager to change its AGENTS.md. Agent complied, rewrote config, sent 16+ messages without admin approval. Fixed in `a70e779`, issue #87.

### 3.4 GitHub Scoped to <your-org> Org [DOCUMENTED]

Agents must use `github-activity.sh` (enforces org filtering), never raw `gh api` calls.

**Rationale:** Personal repos were visible. Agent bypassed script to use raw API. Fixed in `3cd128f`, issues #132, #88.

### 3.5 Bootstrap Uses .done Marker [DOCUMENTED]

Bootstrap completion is signaled by `.BOOTSTRAP.md.done` existing alongside `BOOTSTRAP.md`. Never delete `BOOTSTRAP.md` — it's stow-managed and would be recreated.

**Rationale:** Original instructions said "Delete this file." Fixed in `80bf3fe`.

### 3.6 IDENTITY.md Name is Actual Person's Name [DOCUMENTED]

Not agent-chosen creative names, not accidental overwrites.

**Rationale:** dev10 had name "Daily report", dev10-Jean had "Chimchar". Fixed in `a70e779`.

---

## Area 4: Script / CLI Conventions

### 4.1 Script Docs Match Actual Flags [HOOKED]

Documented invocations in `AGENTS.md` must match the script's actual argument parser. Positional vs named arguments must be verified.

**Rationale:** Docs said positional arg, script required `--user`. All agents got BAD_ARG errors. Fixed in `0090a58`.

### 4.2 openclaw CLI Flags [DOCUMENTED]

- `openclaw message send` uses `--message`, not `--text`
- `openclaw cron add` uses `"1m"`, not `"+1m"`

**Rationale:** Wrong flags used 3 times. Fixed in `97d2ea3`, `b9a3bf6`.

### 4.3 macOS/BSD Compatible [HOOKED]

No `grep -oP` (Perl regex, GNU-only). No GNU awk `IGNORECASE`. Use `sed` for regex extraction, `tolower()` for awk case folding.

**Rationale:** Dev machine is macOS with BSD tools. Broken in `d902733`, issue #161.

### 4.4 Template Placeholders Substituted [DOCUMENTED]

`create-agent.sh` must run sed substitution on IDENTITY.md after copying from template.

**Rationale:** 14 agents had raw `<slack-user-id>` placeholder text. Fixed in `a232928`.

### 4.5 Consistent Path Resolution [DOCUMENTED]

Don't mix `${repo_root}/.openclaw/` with `$HOME/.openclaw/`. Don't traverse `../../` without verifying depth.

**Rationale:** Repo vs live path bug, two-levels-up bug, double-slash paths. Fixed in `5386631`, `e9d24ef`, `d4c342b`.

---

## Area 5: Slack / Messaging

### 5.1 No Markdown Tables in Slack [DOCUMENTED]

Slack doesn't render markdown tables. Use bullet lists.

**Rationale:** Tech-manager reports were unreadable garbled text. Fixed in `984cb84`.

### 5.2 Mentions Use <@USER_ID> Format [DOCUMENTED]

Literal `@Name` doesn't ping anyone in Slack.

**Rationale:** Fixed in `984cb84`.

### 5.3 One Consolidated Message Per Operation [DOCUMENTED]

Multi-step tool operations must produce one message, not narrate each step separately.

### 5.4 Alert Routing [DOCUMENTED]

- Operational alerts -> `#<manager-agent>-feedback` (<channel-id>)
- Status reports -> `#tech-management` (<channel-id>)

**Rationale:** Operational alerts polluted the team-facing channel. Fixed in `ecb2957`.
