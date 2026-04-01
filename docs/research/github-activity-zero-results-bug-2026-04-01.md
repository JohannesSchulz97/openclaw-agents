# GitHub Activity Script: Zero Results Bug Investigation

**Date:** 2026-04-01
**Test Case:** dev10 Jean (GitHub: <github-username>)
**Status:** Bug confirmed -- documentation mismatch causes silent failure

## Executive Summary

The `github-activity.sh` script itself works correctly. The bug is in the **documentation** that tells agents how to invoke it. Both `types/dev-pa/AGENTS.md` and `types/manager/AGENTS.md` document a **positional argument** invocation that the script rejects as `BAD_ARG`, producing zero results.

## Root Cause

### The Documentation Says (WRONG)

In `types/dev-pa/AGENTS.md` (line 114):
```bash
bash scripts/github-activity.sh <github-username>
```

In `types/manager/AGENTS.md` (line 79):
```bash
bash <agent-dir>/scripts/github-activity.sh <github-username>
```

### The Script Expects (CORRECT)

The script uses `--user` as a named flag (lines 28-47):
```bash
bash scripts/github-activity.sh --user <github-username>
```

### What Happens When an Agent Follows the Docs

```
$ bash github-activity.sh <github-username>
{
  "success": false,
  "operation": "github-activity",
  "error": {
    "code": "BAD_ARG",
    "message": "Unknown argument: <github-username>"
  }
}
```

The script exits with code 1 and returns a JSON error. If the agent doesn't properly handle this error, it reports zero activity.

## Verification: dev10 Jean Has Significant Activity

Running the script correctly produces 14 events in the last 24 hours alone:

```
$ bash github-activity.sh --user <github-username>
summary: {
  total_events: 14,
  commits: 1,
  prs_opened: 0,
  prs_merged: 1,
  issues_opened: 9,
  issues_closed: 3,
  comments: 0
}
```

Over the past 7 days (`--since 168`): 16 events including 2 merged PRs, 2 commits, 9 issues opened, 3 issues closed.

Independent verification via `gh search prs --author=<github-username> --merged` confirms 27 total merged PRs across `tob-llm-pipelines`, `tob-oracle`, and other repos.

## Impact

This affects **every agent** that follows the documented invocation:

1. **Dev-PA agents** (17 agents) -- when they try to fetch their own GitHub activity during check-ins, they get BAD_ARG errors instead of activity data. The check-in message template tells them to run the script, and the AGENTS.md documentation shows the wrong syntax.

2. **Tech-manager agent** -- when it tries to fetch developer GitHub activity for morning/evening reports, it gets BAD_ARG errors. Reports show zero developer activity even when developers are actively shipping code.

## Fixes Required (2 files)

### Fix 1: `types/dev-pa/AGENTS.md` (line 114)

Change:
```bash
bash scripts/github-activity.sh <github-username>
```
To:
```bash
bash scripts/github-activity.sh --user <github-username>
```

### Fix 2: `types/manager/AGENTS.md` (line 79)

Change:
```bash
bash <agent-dir>/scripts/github-activity.sh <github-username>
```
To:
```bash
bash <agent-dir>/scripts/github-activity.sh --user <github-username>
```

### Post-Fix: Sync and Stow

After editing, propagate to all agents:
```bash
bash scripts/sync-agents.sh && cd ~/openclaw-agents/.openclaw && stow --adopt --no-folding -t ~/.openclaw . && stow --no-folding -t ~/.openclaw .
```

## Additional Observations

1. **The script is well-written.** It handles multiple comma-separated users, date ranges, org filtering, deduplication, and structured JSON output. The only problem is the docs.

2. **`--since` flag also undocumented.** Neither AGENTS.md mentions that you can pass `--since <hours>` to control the lookback window (default: 24 hours). The tech-manager research docs reference `--since 24` and `--since 10` but the agent-facing docs omit this.

3. **`prs_reviewed` is always 0.** The script tracks `prs_reviewed: 0` as a hardcoded value (line 198). The GitHub Search API doesn't directly support searching for PR reviews by user. This is a known limitation, not a bug.

4. **Error handling in agents may be weak.** Even after fixing the docs, agents should be instructed to check the `success` field in the JSON response and handle errors gracefully rather than silently reporting zero activity.

## Files Referenced

- `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/github-activity.sh` -- the script (working correctly)
- `/Users/<hostname>/openclaw-agents/types/dev-pa/AGENTS.md` -- dev-pa documentation (wrong invocation on line 114)
- `/Users/<hostname>/openclaw-agents/types/manager/AGENTS.md` -- manager documentation (wrong invocation on line 79)
- `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/lib/json-response.sh` -- shared JSON response library
