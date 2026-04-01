# Oversized Sessions Investigation (>500KB)

**Date:** 2026-04-01
**Investigator:** Research Agent
**Scope:** All OpenClaw agent sessions exceeding 500KB

---

## Summary

5 oversized sessions detected. **3 are retry/delivery loops** requiring cleanup. 1 is a legitimate long conversation. 1 is a normal long-running cron session.

| # | Agent | Session ID | Size | Lines | Verdict |
|---|-------|------------|------|-------|---------|
| 1 | dev1 | c9fdfb95-... | 4.1MB | 1851 | **LOOP - NEEDS_CLEANUP** |
| 2 | main | f4595f8d-... | 1.4MB | 1813 | **LOOP - NEEDS_CLEANUP** |
| 3 | tech-manager | 594481d2-... | 1.3MB | 912 | **LOOP - NEEDS_CLEANUP** |
| 4 | dev10-jean | cc0a7f88-... | 678KB | 287 | **NORMAL** |
| 5 | tech-manager | b28664d5-... | 644KB | 89 | **NORMAL** |

---

## Session 1: dev1 / c9fdfb95

- **Size:** 4.1MB, 1851 lines
- **Timespan:** 2026-03-26 to 2026-04-01 (6 days)
- **Session type:** Main session (persistent)

### Duplicate Pattern: SEVERE LOOP

The same Slack DM message was retried **874 times**:
```
874x: "System: [2026-03-31 16:33:03 GMT+2] Slack DM from dev1 Schulz: Hey, can you generate another wiz..."
```

### Error Analysis

- 748 lines contain `"error"` strings
- 800 out of 851 assistant responses are **empty** (93.9% empty)
- Pattern: Message delivered -> model produces empty response -> message re-queued -> repeat

### Verdict: LOOP - NEEDS_CLEANUP

The agent received a Slack DM about image generation ("generate another wiz...") on 2026-03-31. The model failed to produce a substantive response (empty assistant content), so OpenClaw re-delivered the message. This created a tight retry loop that bloated the session by ~3.5MB of duplicate entries.

**Recent activity (tail):** The session does have legitimate recent messages (2026-04-01, debugging Slack WebSocket issues with dev1). The loop happened mid-session but the session recovered.

### Recommended Action

- Truncate the 874 duplicate message entries and their empty responses
- Keep the legitimate conversation before and after the loop
- Alternatively: archive the session and start fresh (main session can be recreated)
- Investigate why image generation requests produce empty responses (likely model capability limitation or tool routing issue)

---

## Session 2: main / f4595f8d (tech-manager main session)

- **Size:** 1.4MB, 1813 lines
- **Timespan:** 2026-03-27 to 2026-04-01 (5 days)
- **Session type:** Heartbeat/cron session

### Duplicate Pattern: SEVERE LOOP

The heartbeat trigger message was retried **749 times**:
```
749x: "Read HEARTBEAT.md if it exists (workspace context). Follow it strictly. Do not infer or repeat old t..."
```

Additionally, the same ENOENT error response appeared 88 times, and the HEARTBEAT.md content appeared 87 times.

### Error Analysis

- 681 lines contain `"error"` strings
- 682 out of 824 assistant responses are **empty** (82.8% empty)
- Pattern: Heartbeat cron fires -> delivers same message -> model produces empty/error response -> cron fires again -> appends to same session

### Verdict: LOOP - NEEDS_CLEANUP

This is the tech-manager's heartbeat session where cron jobs append to the same session file. Each heartbeat trigger adds the same instruction message, but the model repeatedly fails to produce useful output. The session accumulated ~749 identical heartbeat triggers.

### Recommended Action

- Archive/truncate this session file
- Investigate why the "main" agent has a heartbeat session (this is the `main` agent directory, not `tech-manager` -- check if this is a misconfigured agent)
- Ensure heartbeat cron uses isolated sessions (`--session isolated`) rather than appending to a persistent session
- The 88x ENOENT errors suggest the agent is trying to read files that don't exist in its workspace

---

## Session 3: tech-manager / 594481d2

- **Size:** 1.3MB, 912 lines
- **Timespan:** 2026-03-26 to 2026-03-31 (5 days)
- **Session type:** Persistent session (appears to be main session)

### Duplicate Pattern: SEVERE LOOP

A Slack channel message was retried **434 times**:
```
434x: "System: [2026-03-31 16:32:36 GMT+2] Slack message in #tech-management from dev1 Schulz: Please w..."
```

### Error Analysis

- 408 lines contain `"error"` strings
- 407 out of 422 assistant responses are **empty** (96.4% empty)
- 10x ENOENT file read errors
- 3x "Session history visibility restricted" errors

### Verdict: LOOP - NEEDS_CLEANUP

Same pattern as Session 1. A message from #tech-management was delivered to the tech-manager agent, which produced empty responses, triggering re-delivery 434 times. This is the highest empty-response ratio (96.4%) of all sessions.

### Recommended Action

- Truncate duplicate entries (keep the ~15 legitimate messages)
- Check if the message content ("Please w...") was something the model could not handle
- Consider implementing a max-retry limit on message delivery to prevent future loops

---

## Session 4: dev10-jean / cc0a7f88

- **Size:** 678KB, 287 lines
- **Timespan:** Active session (recent bootstrap + interactions)
- **Session type:** Main session

### Duplicate Pattern: NONE (no significant duplicates)

Top duplicates are normal operational patterns:
```
7x: ENOENT file read errors (normal for new agent)
5x: Empty search results (normal for new workspace)
5x: Plugin discovery messages (system messages)
4x: USER.md reads (normal - agent reads its own config)
```

### Error Analysis

- 0 error stopReasons
- ENOENT errors are expected (new agent, files not yet created)

### Verdict: NORMAL

This is dev10-Jean's active bootstrap/interaction session. The agent was recently bootstrapped (2026-03-30), set up its identity as "Chimchar" (fire monkey), and is actively working -- setting up email summaries, creating cron jobs, reading emails. The 678KB size is reasonable for a multi-day interactive session with tool calls and email content.

### Recommended Action

- No action needed
- Session will naturally grow; monitor if it crosses 1MB

---

## Session 5: tech-manager / b28664d5

- **Size:** 644KB, 89 lines
- **Timespan:** Active cron session
- **Session type:** Hourly monitoring cron session

### Duplicate Pattern: NONE (expected repetition)

```
9x: "[cron:...] Tech Manager Hourly Monitoring" (expected -- one per hourly cron run)
2x: "NO_ACTION" (normal output)
```

### Error Analysis

- 5 error mentions (from failed cron activation script calls)
- Most responses are substantive (not empty)

### Verdict: NORMAL

This is the tech-manager's hourly monitoring cron session. It accumulates one entry per cron run, which is expected. The 644KB size comes from each monitoring run including tool outputs (agent status checks, cron activation scans). At 89 lines for ~9 hourly runs, this is a healthy session with proportional growth.

### Recommended Action

- No action needed
- Consider rotating cron sessions periodically (e.g., daily) to prevent unbounded growth
- The session recently activated dev10-jean's cron jobs (logged to memory/2026-04-01.md)

---

## Root Cause Analysis

The 3 loop sessions share a common pattern:

1. **Message delivered to agent session** (Slack DM, Slack channel message, or heartbeat trigger)
2. **Model produces empty response** (content is empty text blocks with no actual content)
3. **OpenClaw interprets empty response as delivery failure** and re-queues the message
4. **Message re-delivered to same session**, appending duplicate entries
5. **Cycle repeats** hundreds of times until something breaks the loop

### Why Empty Responses?

- **dev1 (874x):** Image generation request -- the model may lack image generation tools or the request exceeded capability
- **main (749x):** Heartbeat instructions -- possibly the "main" agent is misconfigured or lacks the tools referenced in HEARTBEAT.md
- **tech-manager (434x):** Slack message -- possibly the message content triggered a capability the model could not handle

### Systemic Issues

1. **No retry limit:** OpenClaw has no maximum retry count for message delivery, allowing infinite loops
2. **Empty response = retry:** The gateway treats empty assistant responses as failures requiring re-delivery
3. **Session bloat:** All retries append to the same session file, causing unbounded growth
4. **No alerting:** There is no mechanism to detect and alert on retry loops

---

## Recommendations

### Immediate (Cleanup)

1. **Truncate the 3 loop sessions** by removing duplicate entries, or archive them and start fresh
2. **Session IDs to clean:**
   - `dev1/c9fdfb95-f853-4c73-8f67-341721ce44a6.jsonl`
   - `main/f4595f8d-a7c8-4f9f-9ed3-85826e9eb83e.jsonl`
   - `tech-manager/594481d2-63a4-4c4c-bb47-626697ace504.jsonl`

### Short-Term (Prevention)

3. **Implement max retry limit** in OpenClaw message delivery (e.g., max 3 retries per message)
4. **Add session size monitoring** as a cron job (the check-session-sizes.sh script referenced in the task does not exist yet -- create it)
5. **Investigate the "main" agent** -- why does `~/.openclaw/agents/main/` have a heartbeat session?

### Long-Term (Architecture)

6. **File a GitHub issue** for OpenClaw retry loop bug (empty response should not trigger infinite retries)
7. **Implement session rotation** for long-running cron sessions (daily rotation)
8. **Add dead letter queue** for messages that fail N times, rather than infinite retry
