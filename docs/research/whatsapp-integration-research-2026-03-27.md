# WhatsApp Integration Research for OpenClaw Agents

**Date:** 2026-03-27
**Issue:** [#18 - Investigate WhatsApp and Telegram channel integration for dev-pa agents](https://github.com/<your-org>/openclaw-agents/issues/18)
**Classification:** Actionable

---

## Issue #18 Summary

The issue requests investigating WhatsApp (and Telegram) integration for dev-pa agents. Currently all 18 agents communicate via Slack DMs. The BOOTSTRAP.md already mentions WhatsApp as an optional channel, and the codebase has formatting rules for WhatsApp (no markdown tables, no headers, use bold/CAPS). The question is whether it actually works and what is required.

### Issue Tasks

- Document how WhatsApp integration works (QR pairing, wacli setup)
- Test WhatsApp message delivery end-to-end
- Determine if cron check-in jobs can target multiple channels
- Assess whether multi-channel delivery is desirable
- Update BOOTSTRAP.md if needed

---

## Finding 1: WhatsApp Plugin is Built-In and Available

The WhatsApp plugin (`@openclaw/whatsapp`) ships as a stock plugin with OpenClaw v2026.3.24. It is currently **disabled** on this machine.

```
@openclaw/whatsapp  | whatsapp | openclaw | disabled | stock:whatsapp/index.js | 2026.3.24
```

**To enable:** `openclaw plugins install whatsapp` or `openclaw channels add --channel whatsapp`

The plugin uses **Baileys** -- a reverse-engineered implementation of the WhatsApp Web multi-device protocol. It does NOT use the WhatsApp Business API (no Meta approval, no per-message charges).

---

## Finding 2: Requirements and Costs

### What You Need

| Requirement | Details |
|---|---|
| Phone number | Any WhatsApp-capable number. Separate number recommended but personal works. |
| WhatsApp account | Active account on that number |
| QR code scan | `openclaw channels login --channel whatsapp` displays a QR code |
| Linked device slot | WhatsApp allows up to 4 linked devices; OpenClaw uses one slot |
| Node.js runtime | Required (Bun is incompatible) |
| Meta Business account | NOT required (Baileys bypasses the Business API) |
| Meta developer account | NOT required |

### Costs

| Item | Cost |
|---|---|
| WhatsApp plugin | Free (bundled with OpenClaw) |
| Baileys library | Free (open source) |
| Per-message cost | Zero (unlike Business API at $0.005-$0.08/msg) |
| Phone number | Cost of a SIM card if using a separate number ($5-20) |

**Total cost: $0 (or $5-20 for a dedicated SIM)**

---

## Finding 3: Setup Process

### Step-by-step

1. **Install/enable the plugin:**
   ```bash
   openclaw channels add --channel whatsapp
   ```

2. **Log in via QR code:**
   ```bash
   openclaw channels login --channel whatsapp
   ```
   Scan the QR code with WhatsApp on the phone (Settings > Linked Devices > Link a Device).

3. **Configure access control in openclaw.json:**
   ```json
   {
     "channels": {
       "whatsapp": {
         "dmPolicy": "allowlist",
         "allowFrom": ["+4915512345678"],
         "groupPolicy": "allowlist"
       }
     }
   }
   ```

4. **Add agent binding:**
   ```json
   {
     "agentId": "dev1",
     "match": { "channel": "whatsapp" }
   }
   ```

5. **Restart gateway:**
   ```bash
   openclaw gateway restart
   ```

### Existing Skill Support

The codebase already has a Claude Code skill at `.claude/skills/cc-openclaw/openclaw-add-channel/SKILL.md` that documents the WhatsApp binding process. The BOOTSTRAP.md also guides new agents through WhatsApp setup as an optional step.

---

## Finding 4: Configuration Options

| Setting | Default | Description |
|---|---|---|
| `dmPolicy` | "pairing" | Access control: pairing, allowlist, open, disabled |
| `allowFrom` | [] | E.164 phone numbers allowed to message |
| `groupPolicy` | "allowlist" | Group chat access control |
| `textChunkLimit` | 4000 | Max characters per message chunk |
| `chunkMode` | "length" | "length" or "newline" (paragraph-aware splitting) |
| `mediaMaxMb` | 50 | Max media file size (MB) |
| `sendReadReceipts` | true | Whether to send read receipts |

Multi-account support is available via `channels.whatsapp.accounts.<id>`.

---

## Finding 5: Known Issues and Risks

### Active Bugs (March 2026)

1. **Stale socket desync (Issue #55098):** After health monitor restart, outbound sends can fail with "unsupported channel: whatsapp" even though status reports healthy. This is a regression in recent versions.

2. **Plugin silently broken after upgrade (Issue #52838):** Upgrading from 2026.3.13 to 2026.3.22 silently broke WhatsApp. The npm release tarball didn't include optional bundled clusters. Fixed in 2026.3.24 but worth monitoring.

3. **WhatsApp restart loops:** Known issue where WhatsApp channel enters a restart loop. Fix: delete `~/.openclaw/credentials/whatsapp/default/` and re-authenticate.

### Terms of Service Risk

Baileys is a **reverse-engineered** implementation of WhatsApp Web. It is NOT an official Meta API. Risks include:

- WhatsApp could block/ban the linked number at any time
- Meta has historically taken action against unofficial clients
- No SLA or support from Meta
- Using a dedicated number mitigates the ban risk to personal accounts

### Recommendation: Use a dedicated SIM card, not developers' personal numbers.

---

## Finding 6: Multi-Channel Feasibility

### Can cron check-in jobs target multiple channels?

Yes. OpenClaw supports multiple simultaneous channels per agent. Each channel adapter runs in its own thread. The `bindings` array in openclaw.json routes messages to channels:

```json
[
  {"agentId": "dev1", "match": {"channel": "slack", "accountId": "dev1"}},
  {"agentId": "dev1", "match": {"channel": "whatsapp"}}
]
```

The agent would be reachable on both Slack and WhatsApp simultaneously. Outbound message routing can be configured via MESSAGING.md rules.

### Should multi-channel be enabled by default?

**Recommendation: No.** Reasons:

1. Slack is the team's primary communication tool and works reliably
2. WhatsApp has active bugs (stale socket, restart loops)
3. Baileys carries ToS risk that Slack's official Bolt SDK does not
4. Each WhatsApp channel needs a phone number and QR pairing (operational overhead for 18 agents)
5. WhatsApp formatting is more limited (no tables, no headers)

**Better approach:** Offer as opt-in per developer. Some developers may prefer WhatsApp for mobile notifications while keeping Slack as primary.

---

## Finding 7: Setup Complexity Assessment

| Factor | Rating | Notes |
|---|---|---|
| Technical difficulty | Low | Plugin is built-in, CLI-guided setup |
| Operational overhead | Medium | QR pairing per agent, phone number per agent, session monitoring |
| Maintenance burden | Medium-High | Restart loops, stale sockets, upgrade breakage |
| Scaling to 18 agents | High | 18 phone numbers, 18 QR pairings, 18 sessions to monitor |
| Risk | Medium | ToS concerns with Baileys, active bugs |

### Effort Estimate

| Task | Time |
|---|---|
| Enable plugin + test with 1 agent | 30 min |
| Document the process | 1 hour |
| Scale to all 18 agents | 4-6 hours (phone numbers, QR pairing, config) |
| Ongoing monitoring/maintenance | 30 min/week |

---

## Recommendations

### Immediate (Low Effort)

1. **Test with one agent** -- Enable the WhatsApp plugin for a single agent (e.g., dev1) using a dedicated test SIM. Validate end-to-end message delivery including cron check-ins.

2. **Document the process** -- Update BOOTSTRAP.md with more specific WhatsApp setup steps based on testing results.

### Short-Term (If Testing Succeeds)

3. **Offer opt-in** -- Let individual developers enable WhatsApp if they want mobile notifications. Do not make it default.

4. **Add monitoring** -- The tech-manager agent's check-status.sh could monitor WhatsApp restart loops across agents.

### Do NOT Do

5. **Do not scale to all 18 agents immediately** -- The operational overhead and active bugs make this premature.

6. **Do not use developers' personal phone numbers** -- Use dedicated SIMs to mitigate ban risk.

---

## Sources

- [OpenClaw WhatsApp Documentation](https://docs.openclaw.ai/channels/whatsapp)
- [OpenClaw Channels Overview](https://docs.openclaw.ai/channels)
- [MarkTechPost: Getting Started with OpenClaw + WhatsApp](https://www.marktechpost.com/2026/02/14/getting-started-with-openclaw-and-connecting-it-with-whatsapp/)
- [Bug #55098: Stale socket desync](https://github.com/openclaw/openclaw/issues/55098)
- [Bug #52838: Plugin broken after upgrade](https://github.com/openclaw/openclaw/issues/52838)
- [DeepWiki: OpenClaw Channel Architecture](https://deepwiki.com/openclaw/openclaw/4.1-channel-architecture)
- [OpenClaw npm package](https://www.npmjs.com/package/openclaw)
