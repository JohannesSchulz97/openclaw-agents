---
name: openclaw-add-secret
description: Add a credential as a JSON file in ~/.openclaw/credentials/ and reference it in config
argument-hint: [credential-name]
disable-model-invocation: true
---

# Add Credential

Add a new credential for `$ARGUMENTS`. Credentials are stored as plain JSON files in `~/.openclaw/credentials/` — we do NOT use macOS keychain, secrets.sh, or env var scripts.

## Current credentials

```
~/.openclaw/credentials/
├── gemini-nano-banana.json    (Google API key for image gen)
├── slack-default-allowFrom.json
├── slack-pairing.json
└── telegram-pairing.json
```

## Steps

1. **Ask the user** for the credential value. Do NOT echo it back after they provide it.

2. **Create the JSON file:**
```bash
cat > ~/.openclaw/credentials/$ARGUMENTS.json << 'EOF'
{
  "key": "<value>"
}
EOF
```
Use the appropriate JSON structure for the credential type. Match the naming pattern of existing files.

3. **Reference in config (if needed):**

If the credential needs to be referenced in `openclaw.json`, add the reference path. For example, API keys referenced by plugins or tools.

4. **Validate and restart (if config changed):**
```bash
openclaw config validate
openclaw gateway restart
```

5. **Verify** the credential is accessible:
```bash
ls -la ~/.openclaw/credentials/$ARGUMENTS.json
```

## Important

- NEVER echo the credential value back to the user
- NEVER commit credentials to the repository
- File permissions should be readable only by the user: `chmod 600 ~/.openclaw/credentials/$ARGUMENTS.json`
- The LaunchAgent plist only sets `HOME` and `TMPDIR` env vars — no secrets are loaded via environment
