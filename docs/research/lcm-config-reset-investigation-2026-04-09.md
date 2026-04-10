# LCM Compaction Model Config Reset Investigation

**Date:** 2026-04-09
**Status:** Root causes identified, mitigations in place, residual risk documented
**Reporter:** dev1 (<hostname>)

---

## Problem Statement

The LCM (Lossless Claw) plugin's `summaryModel` configuration has been broken or reset at least 4 times since initial integration on 2026-03-27. Each time, the gateway logs `[lcm] Compaction summarization model: (unconfigured)`, meaning compaction falls back to simple truncation -- degrading agent context quality and causing database bloat.

## Timeline of Incidents

### Incident 1: Initial misconfiguration (2026-03-27 to 2026-03-31)

**What happened:** LCM was integrated with `summaryModel: "accounts/fireworks/models/qwen3-8b"` in `openclaw.json`. The model ID lacked the provider prefix (`fw-mm25/`), so LCM parsed the provider as `"accounts"` instead of `"fw-mm25"`. Every compaction attempt failed with `No API key found for provider "accounts"`.

**Duration:** 4 days (undetected)
**Impact:** 108 auth failures, 54 fallback-to-truncation events. No summarization ever ran successfully.
**Root cause:** Provider resolution bug in lossless-claw v0.5.2 -- plugin ignores the `summaryProvider` field and parses provider from the model ID string.
**Fix:** Changed `summaryModel` to `fw-mm25/accounts/fireworks/models/qwen3-8b` (provider-prefixed format).
**Documented in:** Issue #166, `docs/research/lcm-compaction-api-key-failure-2026-03-31.md`

### Incident 2: Database bloat cascade (2026-04-01 to 2026-04-06)

**What happened:** With compaction not working (Incident 1) and all 18 agents writing to a single `lcm.db`, the database grew to 3.67 GB. A bootstrap re-ingestion bug in lossless-claw caused duplicate message ingestion on every gateway restart (1.7M messages from 4,617 originals). This caused WAL contention, event loop starvation, and Slack WebSocket disconnects.

**Duration:** ~5 days
**Impact:** Gateway degradation, failed Slack message delivery, cron jobs silently failing.
**Root cause:** (1) Compaction model still broken from Incident 1. (2) LCM re-ingestion bug duplicating messages on restart. (3) No cron session exclusion.
**Fix:** Deduplication (3.4 GB to 44 MB), fixed compaction model, added `ignoreSessionPatterns`, enabled `pruneHeartbeatOk`.
**Documented in:** Issues #166, #183, #185

### Incident 3: OpenClaw downgrade broke config parsing (2026-04-06 to 2026-04-07)

**What happened:** Downgrading OpenClaw from 2026.4.5 to 2026.4.2 (to fix a voice message parsing regression) caused the `plugins.entries.lossless-claw.config` section of `openclaw.json` to become unreadable. Version 4.2 could not parse the plugin config format written by 4.5. The gateway logged `(unconfigured)` from 2026-04-06 ~09:40 through 2026-04-07 ~06:59.

**Duration:** ~21 hours
**Impact:** Without compaction, the `agent:dev1:main` heartbeat session entered a tool loop and overflowed to 217K tokens. OpenClaw restarted the session 6 times in ~3 hours, each time accumulating more uncompactable data.
**Root cause:** OpenClaw version mismatch -- config format not backward-compatible between 4.5 and 4.2.
**Fix:** Added LCM env vars to the launchd plist (`ai.openclaw.gateway.plist`), bypassing `openclaw.json` entirely. Env vars take precedence over config file.
**Documented in:** Issue #183 (second comment)

### Incident 4: `openclaw plugins install --force` + `doctor --fix` (2026-04-06, multiple restarts)

**What happened:** During the stabilization work on 2026-04-06, multiple operations that touch `openclaw.json` were run: `openclaw plugins install --force @martian-engineering/lossless-claw`, `openclaw doctor --fix`, and manual config edits. The log shows that after `plugins install` ran at ~14:45 (visible from reload message: "config change requires gateway restart (plugins.installs.lossless-claw.spec, ...)"), the compaction model reverted to `(unconfigured)`. The `plugins install` command writes its own metadata to `openclaw.json`, and the resulting config restart caused the plugin to reload without the env vars (because it reloaded in-process, not via launchd).

**Duration:** Brief (resolved on next full gateway restart via launchd)
**Impact:** Temporary loss of compaction during hot-reload restarts.
**Root cause:** In-process gateway reload does not inherit launchd environment variables. Only a full `launchctl` restart picks up the plist env vars.

## Identified Reset Vectors

### Vector 1: `openclaw doctor --fix` overwrites the plist

**Risk level:** HIGH
**Mechanism:** `openclaw doctor --fix` regenerates the `ai.openclaw.gateway.plist` file. This overwrites any custom env vars added to the plist, including all `LCM_*` variables.
**Current mitigation:** `update-openclaw.sh` has a Step 4b workaround that re-injects `NODE_OPTIONS` after `doctor --fix`. However, it only checks for `NODE_OPTIONS` -- it does NOT re-inject the `LCM_*` env vars.
**Evidence:** Issue #211, PR #212 (only covers NODE_OPTIONS), upstream bug openclaw/openclaw#62342.
**CRITICAL GAP:** The `update-openclaw.sh` script will silently wipe all LCM env vars on the next OpenClaw update that triggers `doctor --fix`.

### Vector 2: `openclaw plugins install --force` modifies openclaw.json

**Risk level:** MEDIUM
**Mechanism:** Running `openclaw plugins install --force @martian-engineering/lossless-claw` writes plugin metadata to `openclaw.json`. This can trigger an in-process config reload, during which the plugin re-initializes without launchd env vars (since the process was started before the plist was updated).
**Current mitigation:** After `plugins install`, a full `gateway restart` is needed (which `update-openclaw.sh` does).
**Residual risk:** If someone manually runs `openclaw plugins install` without restarting, compaction runs unconfigured until next full restart.

### Vector 3: OpenClaw version mismatch in config format

**Risk level:** MEDIUM  
**Mechanism:** Upgrading OpenClaw may change how `plugins.entries.*.config` is serialized. Downgrading to an older version cannot parse the newer format, causing `openclaw.json` plugin config to be silently ignored.
**Current mitigation:** Env vars bypass `openclaw.json` entirely.
**Residual risk:** If env vars are lost (Vector 1), this becomes the only config source and is fragile across versions.

### Vector 4: Config file in `openclaw.json` is ignored by LCM

**Risk level:** LOW (with env vars), HIGH (without env vars)
**Mechanism:** The original bug from Incident 1 -- lossless-claw v0.5.2+ ignores the `summaryProvider` field and derives provider from model ID string. The `openclaw.json` config section has `summaryModel: "fw-mm25/accounts/fireworks/models/glm-5"` which would work with provider-prefix parsing, but the `summaryProvider: "fw-mm25"` field is decorative only.
**Current mitigation:** Env vars (`LCM_SUMMARY_MODEL`, `LCM_SUMMARY_PROVIDER`) take precedence.

### Vector 5: In-process reload vs launchd restart

**Risk level:** LOW
**Mechanism:** When OpenClaw detects config changes, it can do an in-process reload instead of a full launchd restart. The reloaded process inherits the parent process's environment, which may or may not have the LCM env vars depending on how the gateway was started. Only a full `launchctl unload/load` picks up plist env vars.
**Current mitigation:** Most operations that matter (deploy, update) end with `openclaw gateway restart` which does a full launchd cycle.

## Current State (2026-04-09)

The gateway is currently working correctly:
- Plist has all `LCM_*` env vars set
- Gateway logs show `Compaction summarization model: fw-mm25/accounts/fireworks/models/glm-5 (override)`
- Compaction is running successfully (summaries being generated)

The `openclaw.json` config section is a **dead config** that LCM ignores in favor of env vars:
```json
"lossless-claw": {
  "enabled": true,
  "config": {
    "summaryModel": "fw-mm25/accounts/fireworks/models/glm-5",
    "summaryProvider": "fw-mm25",
    "expansionModel": "fw-mm25/accounts/fireworks/models/glm-5",
    "expansionProvider": "fw-mm25"
  }
}
```

## Critical Gap: update-openclaw.sh will break LCM on next update

The most urgent finding is that `update-openclaw.sh` will wipe LCM env vars on the next OpenClaw update:

1. Step 3: `npm i -g openclaw` -- installs new version
2. Step 4: `openclaw doctor --fix` -- **regenerates plist, wiping all LCM_* env vars**
3. Step 4b: Re-injects only `NODE_OPTIONS` -- **does NOT re-inject LCM_* vars**
4. Step 5: `openclaw plugins install --force @martian-engineering/lossless-claw` -- may further modify config
5. Step 8: `openclaw gateway restart` -- **starts with plist missing LCM env vars**
6. Result: `(unconfigured)` again

## Recommendations

### Immediate (prevent next occurrence)

1. **Update `update-openclaw.sh` Step 4b to re-inject ALL custom env vars**, not just `NODE_OPTIONS`. The script already has the pattern (`sed -i` on the plist after `doctor --fix`). Extend it to cover `LCM_SUMMARY_MODEL`, `LCM_SUMMARY_PROVIDER`, `LCM_CONTEXT_THRESHOLD`, `LCM_FRESH_TAIL_COUNT`, `LCM_INCREMENTAL_MAX_DEPTH`, `LCM_IGNORE_SESSION_PATTERNS`.

2. **Add a validation check in `update-openclaw.sh`** after Step 8 (gateway restart): grep the gateway log for `(unconfigured)` and alert if found.

### Medium-term

3. **Create a `plist-env-vars.conf` file** that lists all custom env vars. Have `update-openclaw.sh` read from this file when re-injecting after `doctor --fix`. This prevents the problem of forgetting to update the script when new env vars are added.

4. **Add an invariant check** to `validate-invariants.sh` that verifies the gateway plist contains all required `LCM_*` env vars.

### Long-term

5. **Report upstream** to OpenClaw: `openclaw doctor --fix` should preserve custom env vars in the plist (openclaw/openclaw#62342 already open).

6. **Report upstream** to lossless-claw: The `summaryProvider` config field should be respected, not ignored in favor of parsing the model ID string.

## Scripts and Operations That Touch openclaw.json

| Script/Operation | What it does | Risk to LCM |
|---|---|---|
| `openclaw doctor --fix` | Regenerates plist, fixes config | **HIGH** -- wipes plist env vars |
| `openclaw plugins install --force` | Writes plugin metadata to openclaw.json | **MEDIUM** -- in-process reload without env vars |
| `openclaw config set` | Modifies openclaw.json | **LOW** -- may trigger reload |
| `update-openclaw.sh --apply` | Runs doctor --fix + plugins install | **HIGH** -- combines Vector 1 + 2 |
| `deploy.sh` | Runs apply-cron.sh (config validate only) | **LOW** -- does not modify config |
| `create-agent.sh` | Adds agent to openclaw.json | **LOW** -- does not touch plugin config |
| `remove-agent.sh` | Removes agent from openclaw.json | **LOW** -- does not touch plugin config |
| `patch-openclaw.sh` | Fixes streaming config format | **NONE** -- does not touch plugin config |
| Manual `openclaw gateway restart` | Full launchd restart | **NONE** -- picks up plist env vars correctly |

## References

- Issue #20: Original LCM integration
- Issue #166: LCM database bloat (3.67 GB)
- Issue #183: LCM Phase 0 stabilization
- Issue #185: Verify compaction produces summaries
- Issue #198: Configure dedicated compaction model
- Issue #211: Re-inject NODE_OPTIONS after doctor --fix
- PR #212: Fix for NODE_OPTIONS re-injection
- `docs/research/lcm-compaction-api-key-failure-2026-03-31.md`
- `docs/research/lossless-claw-research-2026-03-27.md`
- Upstream: openclaw/openclaw#62342 (doctor --fix overwrites plist)
