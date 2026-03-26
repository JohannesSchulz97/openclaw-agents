# OpenClaw Slack Bulk User Onboarding Research

**Date:** 2026-03-26
**Scope:** How OpenClaw handles Slack user approval; methods for bulk-adding ~20 developers
**Status:** Actionable -- three viable approaches identified

---

## Executive Summary

OpenClaw's Slack DM access is controlled by `channels.slack.dmPolicy`, currently set to `"pairing"` (the default). This mode requires each new user to send a DM, receive a pairing code, and have the admin approve it one-by-one via CLI. There is **no built-in bulk-approve or batch-pairing CLI command**.

However, there are **three practical approaches** to onboard ~20 developers without manual approval codes:

| Approach | Effort | Risk | Recommended |
|----------|--------|------|-------------|
| **A: Switch to allowlist mode** | Low (10 min) | Low | Yes -- best for known team |
| **B: Switch to open mode** | Very low (2 min) | Medium | Only if workspace is private |
| **C: Script pairing approvals** | Medium (30 min) | Low | Fallback if pairing preferred |

---

## Current Configuration

From `~/.openclaw/openclaw.json`:

```json
"channels": {
  "slack": {
    "dmPolicy": "pairing",
    "groupPolicy": "allowlist"
  }
}
```

Current approved users (from `~/.openclaw/credentials/slack-default-allowFrom.json`):

```json
{
  "version": 1,
  "allowFrom": [
    "<slack-id>",   // dev1
    "<slack-id>",   // <your-org>
    "<slack-id>",   // dev10
    "<slack-id>",   // dev10
    "<slack-id>"    // dev10 Jean
  ]
}
```

**Note:** dev10's Slack ID (`<slack-id>`) is in the routing bindings but NOT in the allowFrom file. This may mean dev10 was added via routing binding but has not yet completed DM pairing.

---

## Available dmPolicy Values

| Value | Behavior |
|-------|----------|
| `pairing` (default) | Unknown senders get a pairing code; admin must approve via `openclaw pairing approve slack <code>` |
| `allowlist` | Only users listed in `allowFrom` can DM the bot; others are silently rejected |
| `open` | Anyone can DM the bot; requires `allowFrom: ["*"]` as explicit opt-in |
| `disabled` | DMs completely blocked |

---

## Approach A: Switch to Allowlist Mode (RECOMMENDED)

Best for a known team of ~20 developers. Pre-populate the user list, no pairing codes needed.

### Step 1: Collect Slack User IDs

Use the OpenClaw directory resolver to look up IDs by name:

```bash
openclaw channels resolve --channel slack "Alice Smith"
openclaw channels resolve --channel slack "Bob Jones"
# ... repeat for all 20 developers
```

Or look up in bulk via Slack admin panel or API.

### Step 2: Switch dmPolicy and Set allowFrom

```bash
# Switch to allowlist mode
openclaw config set channels.slack.dmPolicy allowlist

# Set the allowFrom list with all user IDs
openclaw config set channels.slack.allowFrom '["<slack-id>","<slack-id>","<slack-id>","<slack-id>","<slack-id>","<slack-id>","UNEW_USER_1","UNEW_USER_2","UNEW_USER_3"]'
```

Alternatively, edit `~/.openclaw/openclaw.json` directly (the `channels.slack` section) and add:

```json
{
  "channels": {
    "slack": {
      "dmPolicy": "allowlist",
      "allowFrom": [
        "<slack-id>",
        "<slack-id>",
        "<slack-id>",
        "<slack-id>",
        "<slack-id>",
        "<slack-id>",
        "UNEW_USER_1",
        "UNEW_USER_2"
      ]
    }
  }
}
```

### Step 3: Validate and Reload

```bash
openclaw config validate
# The allowFrom changes hot-reload -- no gateway restart required
```

### Important Notes

- `dmPolicy: "allowlist"` with an empty `allowFrom: []` is rejected by config validation.
- The `allowFrom` in `openclaw.json` takes precedence; the credentials file (`slack-default-allowFrom.json`) is managed by the pairing system.
- Use stable Slack user IDs (U-prefixed), not display names.

---

## Approach B: Switch to Open Mode

Simplest but least restrictive. Only appropriate if your Slack workspace itself is private/controlled.

```bash
openclaw config set channels.slack.dmPolicy open
openclaw config set channels.slack.allowFrom '["*"]'
```

**Risks:**
- Anyone in the Slack workspace can DM the bot
- If exec tools, file access, or calendar integrations are enabled, any workspace member can interact with them
- Run `openclaw doctor` after switching to surface any security warnings

**Mitigations:**
- Ensure `session.dmScope` is set to `per-channel-peer` (already configured) so each user gets isolated context
- Rely on Slack workspace membership as the access boundary
- Use `groupPolicy: "allowlist"` (already configured) to control channel access separately

---

## Approach C: Script Pairing Approvals

If you prefer to keep `pairing` mode, you can partially automate the process with a script.

### How Pairing Works

1. User sends DM to bot
2. Bot replies with 8-character pairing code (expires in 1 hour, max 3 pending per channel)
3. Admin runs `openclaw pairing approve slack <CODE>`
4. User is added to the local allowlist

### Scripted Batch Approval

```bash
#!/usr/bin/env bash
# batch-approve.sh -- Approve all pending Slack pairing requests
# Prerequisite: all 20 users must have already sent a DM to the bot

set -euo pipefail

PENDING=$(openclaw pairing list slack --json)
CODES=$(echo "$PENDING" | jq -r '.requests[].code')

if [ -z "$CODES" ]; then
  echo "No pending pairing requests."
  exit 0
fi

echo "Approving all pending Slack pairing requests..."
for CODE in $CODES; do
  echo "  Approving: $CODE"
  openclaw pairing approve slack "$CODE" --notify
done

echo "Done. All pending requests approved."
```

### Limitation

- Max 3 pending requests per channel at a time
- All users must DM the bot first (cannot pre-approve)
- Must run approval in batches of 3, then wait for next batch to DM
- For 20 users: ~7 rounds of coordination

---

## CLI Reference

| Command | Purpose |
|---------|---------|
| `openclaw config set channels.slack.dmPolicy <value>` | Change DM policy |
| `openclaw config set channels.slack.allowFrom '<json-array>'` | Set allowed user IDs |
| `openclaw config get channels.slack` | View current Slack config |
| `openclaw config validate` | Validate configuration |
| `openclaw pairing list slack` | List pending pairing requests |
| `openclaw pairing list slack --json` | List pending requests as JSON |
| `openclaw pairing approve slack <CODE>` | Approve a pairing code |
| `openclaw pairing approve slack <CODE> --notify` | Approve and notify the user |
| `openclaw channels resolve --channel slack "<name>"` | Look up Slack user ID by name |
| `openclaw doctor` | Health check including DM policy warnings |

---

## Relevant Files

| File | Purpose |
|------|---------|
| `~/.openclaw/openclaw.json` | Main config (dmPolicy, allowFrom, bindings) |
| `~/.openclaw/credentials/slack-default-allowFrom.json` | Pairing-managed allowlist (auto-populated by approve) |
| `~/.openclaw/credentials/slack-pairing.json` | Pending pairing requests |
| `/Users/<hostname>/openclaw-agents/scripts/create-agent.sh` | Agent creation (adds routing bindings, not DM approval) |

---

## Recommendation

For onboarding ~20 known developers:

1. **Use Approach A (allowlist mode)** -- collect all 20 Slack user IDs upfront, set them in `allowFrom`, switch `dmPolicy` to `"allowlist"`.
2. The change hot-reloads, so no gateway restart is needed.
3. If any of these developers need their own isolated agent (like the existing 6 agents), also run `create-agent.sh` for each one to set up routing bindings and agent workspaces.
4. If the developers only need to DM the default/main agent, the allowlist change alone is sufficient.

---

## Sources

- [OpenClaw Slack Documentation](https://docs.openclaw.ai/channels/slack)
- [OpenClaw DM Policy Explained (Stack Junkie)](https://www.stack-junkie.com/blog/openclaw-dm-policy-explained-pairing-allowlist-open-and-disabled)
- [OpenClaw Pairing CLI Docs](https://docs.openclaw.ai/cli/pairing)
- [OpenClaw Pairing Overview](https://docs.openclaw.ai/channels/pairing)
- [GitHub Issue #35763 - Device pairing regression](https://github.com/openclaw/openclaw/issues/35763)
