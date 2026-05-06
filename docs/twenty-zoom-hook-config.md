# Twenty Zoom Hook Config

This feature depends on a host-only `hooks.mappings` entry in `~/.openclaw/openclaw.json`.

For the current Phase 1 rollout, Twenty can post directly to:

`https://<host-url>/hooks/twenty/zoom`

The optional Cloudflare Worker is deferred until Phase 2 hardening.

The OpenClaw side should route that path to the deterministic transform in:

`~/.openclaw/hooks/transforms/twenty-zoom.js`

## Required host config

```json5
{
  channels: {
    slack: {
      replyToModeByChatType: {
        direct: "all"
      }
    }
  },
  hooks: {
    enabled: true,
    path: "/hooks",
    token: "<dedicated-hooks-token>",
    mappings: [
      {
        id: "twenty-zoom",
        name: "Twenty Zoom transcript delivery",
        match: { path: "twenty/zoom" },
        action: "agent",
        messageTemplate: "handled by transform",
        transform: {
          module: "twenty-zoom.js"
        }
      }
    ]
  }
}
```

## Notes

- The transform handles delivery itself and returns `null`, so no agent session is created even though `action: "agent"` is required by the hook mapping schema.
- `hooks.transformsDir` should resolve to `~/.openclaw/hooks/transforms`.
- Keep using a dedicated `hooks.token`, not the gateway auth token.
- Slack DM threading requires `channels.slack.replyToModeByChatType.direct = "all"`.
- Transcript attachments are sent as `.txt`.
- The transform uploads the transcript file directly through Slack's file upload API because `openclaw message send --media` rejects host-local `text/plain` files.
- If the Worker is introduced later, it should inject `OPENCLAW_TOKEN` and add HMAC verification against `TWENTY_SECRET`.
- Opt-in registry path: `~/.openclaw/twenty-zoom-optin.json`
- Registry entries can include `summary_lang: "en" | "de" | "both"`. The host transform reads that field and only sends the matching summary variants.

## Enrollment

Enroll a developer with the real script name and an explicit language preference:

```bash
bash scripts/enable-twenty-zoom-transcripts.sh --agent <name> --email <zoom-email> --slack-id <SLACK_ID> --lang <en|de|both>
```

If `--lang` is omitted, the script defaults to `both` and prints a warning.

## Validation

After updating `openclaw.json` on the host:

```bash
openclaw config validate
openclaw gateway restart
```
