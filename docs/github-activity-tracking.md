# GitHub Activity Tracking Setup Guide

## Overview

Each Pro Agent (dev-pa type) can fetch GitHub activity for its developer from the `<your-org>` organization. This data is used to enrich check-in conversations with recent context about what the developer has been working on, and is also available on-demand during regular conversations.

## Prerequisites

- **`gh` CLI installed and authenticated** -- run `gh auth login` if not already configured.
- **Token scopes** -- the authenticated token needs `repo` and `read:org` scopes.
- **Org membership** -- the developer must be a member of the `<your-org>` GitHub organization.

## Steps to Enable for a New Agent

### 1. Get the developer's GitHub username

The username must match their `<your-org>` org membership. Verify with:

```bash
gh api orgs/<your-org>/members --jq '.[].login' | grep -i <name>
```

If no results appear, the developer may not yet be a member of the organization. Have an org admin send an invite first.

### 2. Add GitHub username to the agent's USER.md

Edit `.openclaw/agents/<agent-name>/USER.md` and add a GitHub section:

```markdown
## GitHub
- **GitHub Username:** <github-username>
- **Organization:** <your-org>
```

This tells the agent which GitHub user to query when fetching activity.

### 3. Update USER.md.template if creating a new agent type

The template at `types/dev-pa/USER.md.template` already includes the GitHub section. If you are creating a new agent type, make sure to include the GitHub fields in your type's `USER.md.template` so that `scripts/create-agent.sh` populates them automatically for new agents.

### 4. Sync agent files

Run the sync script to propagate the `github-activity.sh` script (and any other shared file updates) from `types/dev-pa/scripts/` into each agent's directory:

```bash
bash scripts/sync-agents.sh
```

This copies the script into `.openclaw/agents/<agent-name>/scripts/github-activity.sh` for every dev-pa agent.

### 5. Stow to runtime

Deploy the updated agent configuration into the OpenClaw runtime directory:

```bash
cd ~/openclaw-agents/.openclaw && stow --no-folding -t ~/.openclaw .
```

### 6. Apply cron config (if cron payload was updated)

If the cron job payload in `.openclaw/cron/jobs-config.json` was modified to include a GitHub activity step in the check-in flow, apply the changes:

```bash
bash scripts/apply-cron.sh
```

Each agent's check-in job runs on a 2-hour schedule (`everyMs: 7200000`) and is defined in `jobs-config.json`. The cron payload instructs the agent to run `scripts/poll-check.sh` first, then compose a check-in message when one is due. The GitHub activity script can be called as part of that flow to provide recent commit and PR context.

### 7. Test the script manually

Run the activity script directly to verify it works for the target developer:

```bash
bash .openclaw/agents/<agent-name>/scripts/github-activity.sh --user <github-username> --since 48
```

The `--since` flag specifies how many hours of history to fetch. Use `48` for the last two days.

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

## Architecture Notes

- The `github-activity.sh` script lives in `types/dev-pa/scripts/` and is synced to all dev-pa agents via `scripts/sync-agents.sh`. It follows the same patterns as `poll-check.sh` (uses `set -euo pipefail`, sources `lib/json-response.sh` for structured JSON output, and derives its agent context from the script directory path).
- Activity data is fetched on-demand and is not stored persistently. Every invocation queries the GitHub API for fresh data.
- The cron check-in flow (defined in `jobs-config.json`) calls `poll-check.sh` first to determine if a check-in is due. When `data.due == 1`, the agent can invoke `github-activity.sh` to gather recent work context before composing the check-in message.
- Agents can also call this script during live conversations when the developer asks about their recent work or needs a summary of org activity.
- The script uses the `gh` CLI under the hood, so authentication and rate limits are governed by the locally configured GitHub token.
