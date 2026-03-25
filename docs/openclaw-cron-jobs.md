# OpenClaw Cron Jobs - Notes

## SessionTarget Options

| Value | Behavior |
|-------|----------|
| `"main"` | Runs on next heartbeat with main session (systemEvent only) |
| `"isolated"` | Fresh session `cron:<jobId>` each run - no memory |
| `"current"` | Binds to session where cron was created |
| `"session:custom-id"` | **Persistent** named session - maintains context across runs |

**Note**: The CLI (`openclaw cron edit --session`) only accepts `main` or `isolated`. Custom sessions must be set directly in the JSON file.

## Payload Types

- `systemEvent` - simple text, runs via heartbeat, only works with `sessionTarget: "main"`
- `agentTurn` - full agent turn, can use isolated or custom sessions

## Delivery Modes

- `"announce"` - delivers to target + posts brief summary to main session (default for isolated)
- `"webhook"` - POSTs to URL
- `"none"` - internal only, no delivery

## Known Issues (2026.3.13)

1. **sessionTarget reverts**: Gateway overwrites `sessionTarget` to "isolated" when using `openclaw cron enable`. Must edit JSON file directly for custom sessions.

2. **CLI doesn't expose custom sessions**: `--session` flag only accepts main/isolated, not `session:custom-id`.

3. **Message formatting**: Agent includes system instructions in output. Need simpler prompts.

## Best Practices

- Use custom session for workflows that need context memory across runs
- Use announce mode for isolated jobs to avoid spamming main chat
- Keep prompts simple - agent tends to include system text in response
- Test with `openclaw cron run <id>` before relying on schedule