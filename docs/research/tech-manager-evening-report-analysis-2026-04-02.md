# Tech-Manager Evening Report Analysis (April 1, 2026)

## Date: 2026-04-02
## Classification: Actionable
## Status: Investigation Complete

---

## Problem Statement

The tech-manager's EOD report on April 1, 2026 had several problems:
1. Only showed dev1' commits (10), missed activity from other developers
2. Completely missed "foundry work" (likely dev10's subscription/infrastructure work)
3. The tech-manager's self-diagnosis was wrong -- claimed it "cannot run gh commands"
4. Asked dev1 to run a script manually -- wrong behavior for an autonomous agent

## Intended Data Flow (Evening Report)

The evening report cron job (`d5f7b0c2`) fires at 20:00 CET daily. The payload instructs the tech-manager to:

1. **Step 1:** `bash scripts/collect-daily-notes.sh` -- collect all dev-pa daily summaries
2. **Step 2:** `scripts/check-status.sh --agents <all 17>` -- team status
3. **Step 3:** `scripts/check-missed-checkins.sh --agents <all 17>` -- compliance
4. **Step 4:** For each agent, find `github-activity.sh` in their scripts dir, read their USER.md for GitHub usernames, run with `--since 12`
5. **Step 5:** Read IDENTITY.md for Slack channel ID
6. **Step 6:** Synthesize ONE consolidated evening report
7. **Step 7:** Send via `openclaw message send`

### Data Source 1: Daily Notes (`collect-daily-notes.sh`)

- Iterates over `$HOME/.openclaw/agents/*/`
- Filters for `.agent-type == "dev-pa"` only
- Reads `memory/YYYY-MM-DD.md` for today's date
- Outputs plain text with `# DisplayName` headers

**Daily notes that existed for 2026-04-01:**
| Agent | Has Note | Content Quality |
|-------|----------|----------------|
| dev1 | Yes | Minimal ("None mentioned" for Focus, notes about GitHub tracking setup) |
| dev10 | Yes | Rich content (Cloudflare, Subscription, Justus Truths v2, iPhone app) |
| dev10 | Yes | Rich content (Bootstrap session, team structure, role clarification) |
| dev10 | Yes | Very rich (Subscription briefings, status updates, operational priorities) |
| dev10 | Yes | Minimal (SA reminder cadence, dev7 API down, dev5 review) |
| dev7 | Yes | Minimal (no response from developer) |
| dev10-jean | Yes | Minimal (no response to check-ins) |
| tech-manager | Yes | Own activity log (not a dev-pa, correctly excluded by script) |

**Key finding:** Daily notes existed for 7 dev-pa agents. The `collect-daily-notes.sh` script should have returned all of them. dev10's note clearly mentions Justus Truths v2, Expo Web SPA. dev10's note describes the entire subscription/foundry infrastructure work.

### Data Source 2: GitHub Activity (`github-activity.sh`)

The script:
- Requires `gh` CLI installed and authenticated
- Uses GitHub Search API (not Events API)
- Accepts `--user <username>` and `--since <hours>`
- Scoped to `<your-org>` org only
- Supports comma-separated usernames

**Critical constraint:** The tech-manager's AGENTS.md explicitly says:
> "NEVER run gh CLI commands."

However, `github-activity.sh` itself runs `gh api` commands internally. The tech-manager is instructed to run the SCRIPT (not gh directly). The script is a wrapper that uses gh under the hood.

**This is a design ambiguity.** The red line says "NEVER run gh CLI commands" but the evening report cron instructs "run the script." The script itself calls `gh api`. If the tech-manager interprets the red line literally, it would refuse to run a script that internally uses `gh`. This is likely what happened -- the tech-manager's self-diagnosis "cannot run gh commands" may have been triggered by reading its own AGENTS.md red line about gh CLI.

### Data Source 3: check-status.sh

Returns JSON with per-agent status including session activity, poll state, work schedule, bootstrap status. This is pure bash/jq -- no gh dependency. Should work fine.

### Data Source 4: check-missed-checkins.sh

Returns JSON with missed check-in alerts. Pure bash/jq. Should work fine.

## What the Tech-Manager Actually Reported (from its own notes)

```
- 18:00 UTC: Evening report sent to #tech-management
  - dev1: 29 GitHub events (7 PRs merged, 5 issues opened, 6 issues closed)
  - dev10: 8 GitHub events (Justus Truth V2, Expo Web SPA PR)
  - dev10-Jean: 12 GitHub events (tob-sa-api, LLM retry)
  - dev7: 1 GitHub event (PR merged in tob-twenty)
  - No daily notes collected, no blockers reported
```

**Critical observation:** The tech-manager DID get GitHub data for 4 developers (dev1, dev10, dev10-Jean, dev7), contradicting the claim that it "cannot run gh commands." The github-activity.sh script clearly worked.

**BUT:** It says "No daily notes collected, no blockers reported." This means `collect-daily-notes.sh` either:
- Was not run
- Returned empty output
- Was run but its output was ignored/not parsed

This is the root cause of the missing "foundry work" -- dev10's detailed daily notes about subscription management, briefings, and operational priorities were in his `memory/2026-04-01.md` file but never made it into the report.

## Root Cause Analysis

### Problem 1: "Only dev1' commits"
**Not exactly accurate.** The tech-manager's own notes show it captured GitHub activity for 4 developers (dev1, dev10, dev10-Jean, dev7). The issue is that developers WITHOUT GitHub usernames configured or without `github-activity.sh` available were skipped. The evening report cron says "For each agent, check if github-activity.sh exists" -- agents without the script or without configured GitHub usernames would simply be skipped.

**Missing from GitHub data:** dev10, dev10, dev10, and others. These agents may not have had their USER.md properly configured with GitHub usernames, or their scripts directory may not have contained github-activity.sh (depends on bootstrap status and sync).

### Problem 2: Missed "foundry work" (dev10's subscription infrastructure)
**Root cause:** The daily notes were not collected or not used. dev10's `memory/2026-04-01.md` contains extremely detailed notes about subscription management, briefings, operational status, and priorities. The `collect-daily-notes.sh` script should have picked this up. The tech-manager's report says "No daily notes collected" -- this is the key failure.

Possible reasons why daily notes were not collected:
1. **Timing issue:** The daily summary cron for dev-pa agents fires at 19:30 CET. The evening report fires at 20:00 CET. This is only a 30-minute gap. If the daily summary cron was delayed or failed, the notes would not exist yet when collect-daily-notes.sh ran.
2. **But notes DO exist now.** The files are present in the repo. So either they were written after the report ran, or the script failed to find them.
3. **Script path issue:** `collect-daily-notes.sh` looks in `$HOME/.openclaw/agents/*/` and checks `.agent-type`. If the stow state was broken or `.agent-type` files were missing for some agents, they would be silently skipped.

### Problem 3: Wrong self-diagnosis ("cannot run gh commands")
The tech-manager's AGENTS.md has a red line: "NEVER run gh CLI commands." But the evening report cron instructs it to run `github-activity.sh`, which internally uses `gh api`. The tech-manager likely encountered this contradiction and:
- Either refused to run the script (contradicted by the fact that it DID get GitHub data)
- Or ran it successfully but then retroactively claimed it "cannot run gh commands" when trying to diagnose why data was incomplete

**This suggests a mid-session reasoning failure** where the tech-manager confused its own red lines with script capabilities.

### Problem 4: Asked dev1 to run a script manually
This is wrong behavior. The tech-manager should be autonomous -- it has the scripts and the instructions to run them. Asking a human to run a script violates the agent's design principle of autonomous operation.

**Likely cause:** When the tech-manager hit a perceived limitation (the gh red line or the empty daily notes), it escalated to the human instead of diagnosing the actual issue. This is a behavior pattern of the LLM being overly cautious.

## Recommendations

### Immediate Fixes

1. **Clarify the gh CLI red line in AGENTS.md.** Change from:
   > "NEVER run gh CLI commands."

   To:
   > "NEVER run gh CLI commands directly. You may run scripts that internally use gh (e.g., github-activity.sh)."

2. **Add a buffer between daily summary and evening report timing.** Currently:
   - Dev-pa daily summaries: 19:30 CET
   - Tech-manager evening report: 20:00 CET
   - Buffer: 30 minutes

   Consider moving the evening report to 20:30 CET to give more buffer for slow summary crons.

3. **Add error logging to collect-daily-notes.sh.** The script currently logs to stderr with `log` but does not output diagnostics about WHY no notes were found. Add output like "Checked X agents, found Y with .agent-type=dev-pa, Z had notes for date."

4. **Add explicit instruction in evening report cron payload:** "If collect-daily-notes.sh returns no notes, investigate why before reporting 'no daily notes collected.' Check if the daily summary crons have run yet."

### Structural Improvements

5. **Prevent the "ask human to run script" behavior.** Add to AGENTS.md:
   > "NEVER ask your developer to run a script that you have access to. If a script fails, report the error in your report."

6. **Consider adding dev10's GitHub username to his configuration** (if not already present) to capture his activity in GitHub reports.

## Files Examined

- `/Users/<hostname>/openclaw-agents/types/manager/AGENTS.md`
- `/Users/<hostname>/openclaw-agents/types/manager/scripts/collect-daily-notes.sh`
- `/Users/<hostname>/openclaw-agents/types/manager/scripts/check-status.sh`
- `/Users/<hostname>/openclaw-agents/types/manager/scripts/check-bottlenecks.sh`
- `/Users/<hostname>/openclaw-agents/types/manager/scripts/check-missed-checkins.sh`
- `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/github-activity.sh`
- `/Users/<hostname>/openclaw-agents/types/dev-pa/DAILY-SUMMARY.template.md`
- `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json`
- `/Users/<hostname>/openclaw-agents/.openclaw/agents/*/memory/2026-04-01.md` (7 dev-pa agents + tech-manager)
