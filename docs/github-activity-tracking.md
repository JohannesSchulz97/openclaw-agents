# GitHub Activity Tracking Setup Guide

## Overview

Each Pro Agent (dev-pa type) can fetch GitHub activity for its developer from the `<your-org>` organization. This data is used to enrich check-in conversations with recent context about what the developer has been working on, and is also available on-demand during regular conversations.

The script uses the **GitHub Search API** (not the Events API), which means it works correctly with **private repositories** in the organization.

## How It Works

The cron check-in payload is **unified across all agents** -- every agent receives the same generic payload in `jobs-config.json`. No per-agent payload customization is needed. Instead, each agent dynamically reads its configuration at runtime:

1. The agent reads its **GitHub username(s)** from the `## GitHub` section in `USER.md`.
2. The agent reads its **target Slack user ID** from `IDENTITY.md`.
3. The agent calls `scripts/github-activity.sh --user <github-usernames> --since 24` with the username(s) from step 1.
4. If no GitHub username is configured, or the script returns no data, the agent skips GitHub enrichment and proceeds without it.

**Multi-user support:** Developers who use multiple GitHub accounts can list them as comma-separated values in `USER.md`. The script accepts comma-separated usernames and queries activity for all of them.

## Prerequisites

- **`gh` CLI installed and authenticated** -- run `gh auth login` if not already configured.
- **Token scopes** -- the authenticated token needs `repo` and `read:org` scopes.
- **Org membership** -- the developer must be a member of the `<your-org>` GitHub organization.

## Current Agent Mapping

| Agent | GitHub Username(s) |
|---|---|
| dev1 | <github-username>, <manager-agent> |
| dev10 | <github-username> |
| dev10 | <github-username> |
| dev10 | <github-username> |
| dev10-jean | <github-username> |
| <your-org> | _(not tracked -- shared/admin account)_ |

The `<your-org>` agent is a shared/admin account and does not need GitHub activity tracking.

## Steps to Enable for a New Agent

### 1. Add Slack ID to IDENTITY.md

Edit `.openclaw/agents/<agent-name>/IDENTITY.md` and ensure the Slack User ID is set in the `## Slack` section:

```markdown
## Slack

- **Slack User ID:** <slack-id>
```

The agent reads this at runtime to know where to send check-in messages. The `IDENTITY.md.template` at `types/dev-pa/IDENTITY.md.template` includes a placeholder for this field.

### 2. Add GitHub username(s) to USER.md

Edit `.openclaw/agents/<agent-name>/USER.md` and add the developer's GitHub username(s) in the `## GitHub` section:

```markdown
## GitHub
- **GitHub Usernames:** <github-username>
- **Organization:** <your-org>
- **Note:** Comma-separated if developer uses multiple accounts
```

If the developer uses multiple GitHub accounts, list them comma-separated:

```markdown
- **GitHub Usernames:** primary-account, secondary-account
```

This tells the agent which GitHub user(s) to query when fetching activity.

### 3. Verify org membership

The username(s) must match their `<your-org>` org membership. Verify with:

```bash
gh api orgs/<your-org>/members --jq '.[].login' | grep -i <name>
```

If no results appear, the developer may not yet be a member of the organization. Have an org admin send an invite first.

### 4. No cron payload changes needed

The cron payload in `.openclaw/cron/jobs-config.json` is **generic and unified** across all agents. It instructs every agent to read `USER.md` and `IDENTITY.md` at runtime. You do not need to modify the cron config when adding a new agent -- just ensure the agent has a cron job entry (which `scripts/create-agent.sh` handles automatically).

### 5. Sync agent files

Run the sync script to propagate the `github-activity.sh` script (and any other shared file updates) from `types/dev-pa/scripts/` into each agent's directory:

```bash
bash scripts/sync-agents.sh
```

This copies the script into `.openclaw/agents/<agent-name>/scripts/github-activity.sh` for every dev-pa agent.

### 6. Stow to runtime

Deploy the updated agent configuration into the OpenClaw runtime directory:

```bash
cd ~/openclaw-agents/.openclaw && stow --no-folding -t ~/.openclaw .
```

### 7. Test the script manually

Run the activity script directly to verify it works for the target developer:

```bash
bash .openclaw/agents/<agent-name>/scripts/github-activity.sh --user <github-username> --since 48
```

The `--since` flag specifies how many hours of history to fetch. Use `48` for the last two days. For multiple usernames, pass them comma-separated:

```bash
bash .openclaw/agents/<agent-name>/scripts/github-activity.sh --user account1,account2 --since 48
```

### 8. Test a cron dry run

Trigger the agent's check-in job manually to confirm the full flow works end-to-end:

```bash
openclaw cron run <agent-check-in-job-id>
```

Job IDs for each agent are listed in `.openclaw/cron/jobs-config.json`. For example:

| Agent        | Job ID                                 |
|--------------|----------------------------------------|
| dev1     | `1e14ae94-94b2-4ab3-81d0-d36814d90eaf` |
| dev10        | `bfba28e9-b95d-42e8-87c2-1932e3a212c8` |
| dev10        | `282695e2-9346-489f-a6eb-0078562aa0da` |
| dev10         | `4b088f23-bb17-46db-b6bc-805ac3f8a9ed` |
| dev10-jean  | `052701dd-ad8f-48fe-8e3d-51018945055b` |

## Troubleshooting

- **`gh` auth fails** -- Run `gh auth login` and ensure the token has `repo` and `read:org` scopes. You can check current scopes with `gh auth status`.
- **No events returned** -- The user may not have recent activity in the org. Try a wider window with `--since 168` (1 week).
- **Wrong repos appear** -- Verify the org filter is set to `<your-org>`. Activity from personal repos or other orgs should be excluded by the script's org filter.
- **Script not found in agent directory** -- Run `bash scripts/sync-agents.sh` to copy the script from `types/dev-pa/scripts/` into the agent directory, then re-stow.
- **Permission denied** -- Ensure the script is executable: `chmod +x .openclaw/agents/<agent-name>/scripts/github-activity.sh`.
- **Multi-account not working** -- Ensure usernames are comma-separated with no spaces in `USER.md`, and that all accounts are members of the `<your-org>` organization.

## Architecture Notes

- The `github-activity.sh` script lives in `types/dev-pa/scripts/` and is synced to all dev-pa agents via `scripts/sync-agents.sh`. It follows the same patterns as `poll-check.sh` (uses `set -euo pipefail`, sources `lib/json-response.sh` for structured JSON output, and derives its agent context from the script directory path).
- The script uses the **GitHub Search API** (`gh api search/issues`, `gh api search/commits`) rather than the Events API. This allows it to work with **private repositories** that the authenticated token has access to, whereas the Events API only returns public events.
- Activity data is fetched on-demand and is not stored persistently. Every invocation queries the GitHub API for fresh data.
- The cron check-in flow (defined in `jobs-config.json`) uses a **unified payload** -- the same message text is used for all agents. The payload instructs the agent to read `USER.md` for GitHub usernames and `IDENTITY.md` for the Slack target, making per-agent customization unnecessary.
- The cron payload calls `poll-check.sh` first to determine if a check-in is due. When `data.due == 1`, the agent reads its config files, invokes `github-activity.sh` to gather recent work context, and composes the check-in message.
- Agents can also call this script during live conversations when the developer asks about their recent work or needs a summary of org activity.
- The script uses the `gh` CLI under the hood, so authentication and rate limits are governed by the locally configured GitHub token.
