# OpenClaw Agent Configuration - Confirmed Insights

## Current Setup (2026-03-24)

### Agents and Bindings

| Agent ID | Bound User | Workspace |
|----------|------------|------------|
| dev1 | <slack-id> | /Users/<hostname>/openclaw-agents/.openclaw/agents/dev1 |
| <your-org> | <slack-id> | /Users/<hostname>/openclaw-agents/.openclaw/agents/<your-org> |

### Cron Jobs

| Job ID | Agent | Schedule | Model | Delivery Mode |
|--------|-------|----------|-------|---------------|
| 1e14ae94... | dev1 | */10 * * * * | fw-mm25 | none |
| b2c7a3d1... | <your-org> | */10 * * * * | fw-mm25 | none |

### Configuration Files

- `~/.openclaw/openclaw.json` - Main config with agents and bindings
- `~/.openclaw/cron/jobs.json` - Cron job definitions
- `~/.openclaw/agents/dev1/sessions/sessions.json` - Session metadata
- `~/.openclaw/agents/<your-org>/sessions/sessions.json` - Session metadata

---

## Confirmed Issues and Solutions

### Issue 1: Session Isolation Leak

**Symptoms:**
- dev1 agent knew information that was only given to <your-org> user
- Message: "I got that information directly from my own local configuration files. Specifically, it's written in the USER.md file located in my workspace"

**Root Cause:**
```json
// BROKEN - matched ALL Slack users
{"agentId": "dev1", "match": {"channel": "slack"}}
```

**Solution (Confirmed Working):**
```json
// FIXED - specific user binding
{"agentId": "dev1", "match": {"channel": "slack", "accountId": "<slack-id>"}}
{"agentId": "<your-org>", "match": {"channel": "slack", "accountId": "<slack-id>"}}
```

**Steps to Apply:**
1. Edit `~/.openclaw/openclaw.json` bindings section
2. Delete old cross-contaminated sessions from `sessions.json`
3. Restart gateway: `pkill -f "openclaw gateway" && openclaw gateway &`

---

### Issue 2: Duplicate Responses

**Symptoms:**
- Both agents responding to messages from both users
- Same answer appearing twice

**Root Causes:**
1. Old sessions in `sessions.json` not cleaned up after binding changes
2. Gateway needed restart to apply new bindings

**Solution:**
```bash
# Remove old sessions for wrong user from dev1
python3 -c "
import json
with open('/Users/<hostname>/.openclaw/agents/dev1/sessions/sessions.json', 'r') as f:
    data = json.load(f)
keys_to_remove = [k for k in data.keys() if 'u07h87k34qj' in k.lower()]
for k in keys_to_remove:
    del data[k]
with open('/Users/<hostname>/.openclaw/agents/dev1/sessions/sessions.json', 'w') as f:
    json.dump(data, f, indent=2)
"
```

---

### Issue 3: API Rate Limits

**Confirmed Limits:**
- Google (gemini-3.1-pro): 250 requests/day - EXCEEDED
- Fireworks (minimax-m2p5): Rate limited per minute

**Impact:**
- "API rate limit reached. Please try again later." errors
- Jobs fall back to other providers or fail

**Workaround Applied:**
- Set cron jobs to use `fw-mm25` (Fireworks minimax) instead of Google
- Using `--model fw-mm25` in cron edit or `"model": "fw-mm25"` in payload

---

### Issue 4: Gateway Not Responding

**Symptoms:**
- `openclaw status` shows "Gateway: unreachable"
- Messages not being processed

**Solution:**
```bash
pkill -f "openclaw gateway" 2>/dev/null
sleep 3
openclaw gateway &
```

Note: Gateway may show "unreachable" in status but still be functional (health check returns OK)

---

### Issue 5: User Pairing

**Confirmed Allow List:**
```json
{
  "allowFrom": [
    "<slack-id>",
    "<slack-id>"
  ]
}
```

Location: `~/.openclaw/credentials/slack-default-allowFrom.json`

Both users are pre-approved. Individual agent allow lists not implemented in OpenClaw - bindings handle routing instead.

---

## Verification Commands

```bash
# Check bindings
openclaw agents bindings

# Check cron jobs
openclaw cron list

# Check pairing status
openclaw pairing list slack

# Restart gateway
pkill -f "openclaw gateway" && openclaw gateway &

# Check gateway health
curl -s http://127.0.0.1:18789/health
```

---

## Current Known Issues (2026-03-24 12:50 UTC)

1. **dev1 user not responding** - After gateway restarts, dev1 not processing messages
2. **<your-org> slow** - Getting responses but with delays
3. **Duplicates returning** - <your-org> getting duplicate responses again
4. **API rate limits** - Both Google and Fireworks hitting limits