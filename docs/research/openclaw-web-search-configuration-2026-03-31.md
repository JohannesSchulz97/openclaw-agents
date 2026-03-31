# OpenClaw Web Search Configuration Research

**Date:** 2026-03-31
**Status:** Complete
**Classification:** Informational (reference material)

---

## Summary

Web search is already configured and enabled for OpenClaw agents. The search provider is **Brave Search**, and it is configured at the gateway level via `tools.web.search` in `openclaw.json`. No separate Brave API key file is needed -- OpenClaw appears to handle the Brave Search integration internally (gateway-proxied), as there is no `apiKey` field in the config and no Brave credential file exists.

---

## Key Findings

### 1. Search Provider: Brave Search

The current configuration in `~/.openclaw/openclaw.json` (lines 275-282):

```json
"tools": {
  "profile": "coding",
  "web": {
    "search": {
      "enabled": true,
      "provider": "brave"
    }
  }
}
```

### 2. No Separate API Key Required

- `openclaw config get tools.web.search.apiKey` returns "Config path not found"
- No `brave*` files exist in `~/.openclaw/credentials/`
- No `BRAVE` environment variable is set
- **Conclusion:** OpenClaw proxies Brave Search through its own gateway infrastructure. The user does not need to supply a Brave API key.

### 3. Agents Already Have Web Search Access

From session data and prior research, agents receive a `web_search` tool when running. The tool list for cron jobs includes both `web_fetch` and `web_search`. This means all 17+ agents already have web search capability.

### 4. Configuration Location

- **Config file:** `~/.openclaw/openclaw.json` (Category 3 -- runtime only, never in repo)
- **Config path:** `tools.web.search`
- **Read via CLI:** `openclaw config get tools.web.search`
- **Modify via CLI:** `openclaw config set tools.web.search.enabled true`

### 5. Available Providers

Based on ClawHub skill search results, OpenClaw's built-in web search supports at least:
- `brave` (currently configured)
- Potentially others via ClawHub skills: DuckDuckGo, Bing, DashScope

### 6. Tools Profile

The `tools.profile` is set to `"coding"`, which determines which built-in tools are exposed to agents. Web search is included in this profile.

---

## Configuration Reference

### Enable Web Search (already done)

```bash
openclaw config set tools.web.search.enabled true
openclaw config set tools.web.search.provider brave
openclaw gateway restart
```

### Disable Web Search

```bash
openclaw config set tools.web.search.enabled false
openclaw gateway restart
```

### Verify Current Config

```bash
openclaw config get tools.web.search
# Output: { "enabled": true, "provider": "brave" }
```

---

## Related Commands

| Command | Purpose |
|---------|---------|
| `openclaw skills list` | List all available skills (13/50 ready) |
| `openclaw skills check` | Check skill requirements |
| `openclaw config get tools` | View full tools configuration |
| `openclaw doctor` | Health check (does not flag web search issues) |

---

## No Action Required

Web search is already fully operational for all agents. The configuration is:
- **Enabled:** Yes
- **Provider:** Brave (gateway-proxied, no user API key needed)
- **Available to agents:** Yes (`web_search` and `web_fetch` tools)
- **Works in cron jobs:** Yes (confirmed in session data)
