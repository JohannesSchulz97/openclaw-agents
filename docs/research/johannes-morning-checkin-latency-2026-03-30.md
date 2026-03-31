# Research: dev1 Morning Check-in Latency Investigation
Date: 2026-03-30
Agent: dev1
Session key: agent:dev1:cron:morning

## Summary

The 5-minute response time for dev1's morning check-in is expected behavior given the
combination of features configured in the cron job. Multiple compounding factors each add
latency. No single bug is responsible; this is an architectural cost of the current design.

## Findings

### 1. `thinking: "on"` is enabled (primary cost driver)

In `jobs-config.json`, the dev1 morning check-in payload includes:

```json
"thinking": "on",
"model": "openai-codex/gpt-5.4"
```

The `--thinking` flag causes the model to perform extended reasoning before generating a
response. Based on OpenClaw CLI documentation, valid values are off/minimal/low/medium/high/xhigh.
"on" likely maps to a medium or high level. Extended thinking on a capable model
(gpt-5.4) adds substantial processing time -- easily 60-120+ seconds before the first
output token is produced.

This same flag is set on all three dev1 check-in jobs (morning, midday, evening) and
on all three tech-manager jobs. It appears to be a universal default across all cron jobs.

### 2. GitHub activity lookup via `github-activity.sh` (secondary cost driver)

The morning check-in prompt instructs the agent to:

> "If GitHub usernames configured, run scripts/github-activity.sh --user <github-usernames>
> --since 16 (overnight activity). Parse for recent PRs, commits, reviews."

`github-activity.sh` makes **three separate GitHub Search API calls** per configured user:
1. `search/issues` -- issues and PRs authored by the user
2. `search/commits` -- commits by the user
3. `search/issues` (commenter query) -- issues where the user commented

dev1 has two GitHub usernames configured (<github-username>, <manager-agent>), meaning the
script makes **6 API calls** at morning check-in time. Each API call has network round-trip
latency, and the GitHub Search API can be slow under load. Total script execution: likely
10-30 seconds.

### 3. Multiple file reads before composing the message

The prompt requires the agent to:
1. Run `checkin-guard.sh` and parse its JSON output
2. Read `USER.md` (developer context and GitHub usernames)
3. Read `IDENTITY.md` (Slack user ID)
4. Run `github-activity.sh` (6 API calls as above)
5. Review conversation history and memory for recent context
6. Compose the message
7. Send via `openclaw message send`

Each step involves a tool call with round-trip overhead. With extended thinking active,
the model also reasons about all of this before acting.

### 4. `timeoutSeconds: 180` confirms expected long duration

The job is configured with a 3-minute timeout, which is a clear signal the authors
anticipated this would take a while. A 5-minute response would actually exceed that
timeout limit, which is worth investigating -- either the timeout is not strictly enforced
or the wall-clock time was measured from cron fire to Slack delivery (including
OpenClaw's own scheduling overhead).

### 5. `checkin-guard.sh` itself is lightweight

The guard script does only local work: reads `sessions.json`, reads `poll-state.json`,
does date arithmetic, writes updated state. No network calls, no heavy computation.
It is not a latency contributor.

## Breakdown of Expected Time Budget

| Step | Estimated time |
|------|---------------|
| checkin-guard.sh execution | <1 second |
| Model thinking (extended) | 60-120 seconds |
| File reads (USER.md, IDENTITY.md, memory) | 2-5 seconds |
| github-activity.sh (6 API calls) | 10-30 seconds |
| Message composition + send | 5-15 seconds |
| Total | 77-171 seconds (1.3 - 2.8 min typical) |

A 5-minute (300 second) run would be on the high end but plausible if:
- GitHub Search API was slow or rate-limited
- The model used a high thinking budget
- There was OpenClaw session startup overhead

## Options to Reduce Latency

### Option A: Reduce or remove `thinking` level (highest impact)
Change `"thinking": "on"` to `"thinking": "minimal"` or `"off"` for check-in jobs.
Check-ins are short conversational messages (2-3 sentences) -- they do not benefit
from extended reasoning. Estimated saving: 60-120 seconds.

### Option B: Make GitHub activity optional/async (medium impact)
The morning prompt already says "Skip if no username or script fails." Consider
whether GitHub activity context is worth the latency at 5 AM IST when the developer
hasn't started work yet. Overnight activity data could be cached from a prior run.
Estimated saving: 10-30 seconds.

### Option C: Pre-fetch and cache GitHub activity separately
A dedicated cron job could run `github-activity.sh` and write results to a file
(e.g., `memory/github-activity-cache.json`) every few hours. The check-in job would
then read the cached file rather than making live API calls. Estimated saving:
same as Option B but with fresher data.

### Option D: Accept current latency
5 minutes is slow but within acceptable range for a non-interactive background job
that fires once per day. The developer receives the message and responds at their
own pace -- the delivery delay may be imperceptible in practice.

## Recommendation

Option A (reduce thinking level) is the highest-leverage change with no functional
tradeoff. Morning check-ins are low-complexity tasks; the model does not need extended
reasoning to greet someone and ask what they're working on.

Changing `"thinking": "on"` to `"thinking": "minimal"` on all three dev1 check-in
jobs (and potentially all dev-pa check-in jobs) would likely cut response time to
under 60 seconds.

Option B or C can be evaluated separately as a follow-on improvement.

## Files Examined

- `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json` -- cron job definitions
- `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/checkin-guard.sh` -- guard script
- `/Users/<hostname>/openclaw-agents/types/dev-pa/scripts/github-activity.sh` -- GitHub API script
- `/Users/<hostname>/openclaw-agents/types/dev-pa/AGENTS.md` -- agent operating manual
- `/Users/<hostname>/openclaw-agents/types/dev-pa/HEARTBEAT.md` -- heartbeat template
