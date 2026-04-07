---
name: openclaw-add-secret
description: Add a credential — either a standalone JSON file or a config-referenced token via SecretRef
argument-hint: [credential-name]
disable-model-invocation: true
---

# Add Credential

Add a new credential for `$ARGUMENTS`. There are two patterns depending on what the credential is for.

## Pattern 1: Config-referenced tokens (Slack, Telegram, API keys used by gateway)

Tokens that `openclaw.json` references use the **SecretRef file provider**. They live in `~/.openclaw/credentials/tokens.json` and are referenced by JSON pointer.

### Current tokens.json layout

```json
{
  "SLACK_BOT_TOKEN": "xoxb-...",
  "SLACK_APP_TOKEN": "xapp-...",
  "TELEGRAM_BOT_TOKEN": "..."
}
```

### Steps

1. **Ask the user** for the token value. Do NOT echo it back.

2. **Add to tokens.json:**
```bash
# Read, add key, write back
jq --arg key "$ARGUMENTS" --arg val "<VALUE>" '. + {($key): $val}' \
  ~/.openclaw/credentials/tokens.json > /tmp/tokens-update.json \
  && mv /tmp/tokens-update.json ~/.openclaw/credentials/tokens.json \
  && chmod 600 ~/.openclaw/credentials/tokens.json
```

3. **Register the SecretRef in openclaw.json:**
```bash
openclaw config set <config.path.to.token> \
  --ref-provider tokens --ref-source file --ref-id "/$ARGUMENTS"
```
Replace `<config.path.to.token>` with where the token is referenced in config (e.g., `channels.slack.botToken`).

4. **Validate and restart:**
```bash
openclaw config validate
openclaw gateway restart
```

5. **Verify** the gateway can read the token:
```bash
openclaw gateway status
openclaw channels list
```

### SecretRef format in openclaw.json

After step 3, the config entry looks like:
```json
{
  "source": "file",
  "provider": "tokens",
  "id": "/$ARGUMENTS"
}
```

The `tokens` provider is registered at `secrets.providers.tokens` and points to `tokens.json`.

## Pattern 2: Standalone credentials (API keys, service accounts)

Credentials not referenced by `openclaw.json` — used by scripts or plugins directly.

### Current standalone credentials

```
~/.openclaw/credentials/
├── tokens.json                 (SecretRef provider — Pattern 1)
├── gemini-nano-banana.json     (Google API key for image gen)
├── slack-default-allowFrom.json
├── slack-pairing.json
└── telegram-pairing.json
```

### Steps

1. **Ask the user** for the credential value. Do NOT echo it back.

2. **Create the JSON file:**
```bash
cat > ~/.openclaw/credentials/$ARGUMENTS.json << 'EOF'
{
  "key": "<value>"
}
EOF
chmod 600 ~/.openclaw/credentials/$ARGUMENTS.json
```

3. **No config change needed** — scripts reference the file path directly.

4. **Verify:**
```bash
ls -la ~/.openclaw/credentials/$ARGUMENTS.json
```

## Important

- NEVER echo the credential value back to the user
- NEVER commit credentials to the repository
- All credential files must be mode 600: `chmod 600 ~/.openclaw/credentials/*.json`
- The LaunchAgent plist only sets `HOME` and `TMPDIR` — no secrets via environment variables
- Agent workspaces cannot traverse up to `~/.openclaw/credentials/` (OpenClaw boundary security)
