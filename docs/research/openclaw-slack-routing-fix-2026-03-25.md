# OpenClaw Slack DM Routing Investigation

**Date:** 2026-03-25
**Status:** Root cause identified, fix ready to apply
**Classification:** Actionable -- requires config change + session cleanup + gateway restart

---

## Problem Statement

Inbound Slack DMs from specific users (<slack-id>, <slack-id>) all route to agent `main` instead of their assigned agents (`<your-org>`, `dev1`).

**Goal:** When <slack-id> sends a Slack DM, it should create session `agent:<your-org>:slack:direct:u07h87k34qj`, NOT `agent:main:slack:direct:u07h87k34qj`.

---

## Root Cause

**The bindings use the wrong match field.** The current config uses `match.accountId` to specify Slack user IDs, but `accountId` refers to the **bot's channel account identity** (for multi-account setups), NOT the sender's user ID.

To match on the **person sending the DM**, you must use `match.peer` with `{ kind: "direct", id: "<slack_user_id>" }`.

### Current (BROKEN) bindings:

```json
{
  "bindings": [
    {
      "type": "route",
      "agentId": "dev1",
      "match": {
        "channel": "slack",
        "accountId": "<slack-id>"      // WRONG: accountId = bot account, not sender
      }
    },
    {
      "type": "route",
      "agentId": "<your-org>",
      "match": {
        "channel": "slack",
        "accountId": "<slack-id>"      // WRONG: accountId = bot account, not sender
      }
    }
  ]
}
```

### Why it fails silently

- `accountId` is compared against **configured Slack account names** (e.g., multi-account setups like `channels.slack.accounts.work`).
- Since there is no Slack account named "<slack-id>" or "<slack-id>", the match **never fires**.
- The gateway falls through to the default agent: `main`.
- The config validates successfully (`openclaw config validate` = valid) because `accountId` accepts any string.

### Corroborating evidence

1. **Gateway error logs** showed binding validation failures on 2026-03-24:
   ```
   [reload] config reload skipped (invalid config): bindings.0: Invalid input
   ```
   This occurred during an earlier config edit attempt.

2. **Session listing** proves routing goes to `main`:
   ```
   agent:main:slack:direct:u07h87k34qj     (19m ago, agentId: main)
   agent:main:slack:direct:u09l59gj3qt     (924m ago, agentId: main)
   ```

3. **<your-org> has ZERO Slack sessions** despite being bound.

4. **dev1 has ONE old Slack session** (`agent:dev1:slack:direct:u09l59gj3qt`, 1390m ago) -- likely from a previous working config or manual test.

5. **`openclaw agents bindings`** shows the bindings are registered but they match on `accountId` (wrong field).

---

## Routing Priority Reference

OpenClaw evaluates bindings in this order (most specific wins):

1. `match.peer` (exact conversation/sender match) -- **THIS IS WHAT WE NEED**
2. `match.guildId` (Discord)
3. `match.teamId` (Teams/Slack)
4. `match.accountId` (exact bot account match)
5. `match.accountId: "*"` (channel-wide fallback)
6. Default agent (`main`)

---

## Fix: Corrected Bindings

### Required config change in `~/.openclaw/openclaw.json`:

Replace the `bindings` array with:

```json
{
  "bindings": [
    {
      "type": "route",
      "agentId": "dev1",
      "match": {
        "channel": "slack",
        "peer": {
          "kind": "direct",
          "id": "<slack-id>"
        }
      }
    },
    {
      "type": "route",
      "agentId": "<your-org>",
      "match": {
        "channel": "slack",
        "peer": {
          "kind": "direct",
          "id": "<slack-id>"
        }
      }
    }
  ]
}
```

### Post-fix steps:

1. **Restart gateway** to reload bindings:
   ```bash
   openclaw gateway restart
   ```

2. **Verify bindings loaded**:
   ```bash
   openclaw agents bindings
   ```
   Expected output should show peer-based matching.

3. **Clean up stale sessions** under `main` agent (optional but recommended):
   The old `agent:main:slack:direct:u07h87k34qj` and `agent:main:slack:direct:u09l59gj3qt` sessions will remain in the `main` session store. New messages will create fresh sessions under the correct agents.

4. **Test**: Send a Slack DM from <slack-id> and verify it creates `agent:<your-org>:slack:direct:u07h87k34qj`.

---

## Additional Findings

### session.dmScope is correctly set
- Value: `per-channel-peer` (recommended for multi-user inboxes)
- This means session keys include both channel and sender: `agent:<agentId>:slack:direct:<userId>`
- This is correct for the desired behavior.

### channels.slack.dmPolicy is "pairing"
- DMs require pairing approval first. Both users appear to be approved since messages do arrive (they just go to wrong agent).

### No channel-level routing override
- `channels.slack` has no `routing` or `agentMapping` key.
- Routing is purely binding-driven, which is correct.

### Gateway hot-reloads bindings
- Gateway logs show: `[reload] config change applied (dynamic reads: bindings)`
- So after editing the config, the gateway should pick up changes automatically.
- However, `openclaw gateway restart` is recommended to ensure clean state.

### Config validation passes with wrong bindings
- `openclaw config validate` reports "Config valid" even with the incorrect `accountId` usage.
- This is a usability gap -- the validator does not warn when `accountId` contains what appears to be a Slack user ID instead of an account name.

---

## Environment Details

- OpenClaw version: 2026.3.13 (61d171a)
- Platform: macOS Darwin 24.6.0
- Gateway mode: local, port 18789
- Slack mode: socket (Socket Mode)
- Agents configured: main, dev1, <your-org>
