# Deploy Silent git fetch Failure Investigation

**Date:** 2026-04-03
**Investigated by:** dev1 (research agent)
**Status:** Root cause identified, fix needed

## Summary

The GitHub Actions deploy workflow (run 23940130160, PR #150, commit 0ca2309) reported success at 2026-04-03T08:38:35Z, but `git fetch origin` silently failed due to a macOS Keychain credential error. Because of how `set -e` interacts with `&&` chains in bash, the script continued without updating the repo, deployed the stale commit 7d59255, and reported success.

## Root Cause

**Two bugs combine to create the failure:**

### Bug 1: Git HTTPS credential failure (macOS Keychain)

The deploy log shows these two lines immediately before the git pull section:

```
2026-04-03T08:38:42.5340420Z failed to get: -25308
2026-04-03T08:38:42.5346440Z fatal: could not read Username for 'https://github.com': Device not configured
```

- `failed to get: -25308` is a macOS Security framework error (Keychain item not found / access denied)
- `fatal: could not read Username for 'https://github.com': Device not configured` means git's credential helper (macOS osxkeychain) could not obtain HTTPS credentials
- The remote is configured as HTTPS: `https://github.com/<your-org>/openclaw-agents.git`
- This is a non-interactive environment (GitHub Actions runner as launchd service), so there is no TTY to prompt for credentials
- The Keychain item may have expired, been revoked, or the launchd service context lacks Keychain access

### Bug 2: `set -e` does NOT exit on `&&` chain failure (deploy.sh line 71)

The critical line in `deploy.sh` is:

```bash
git fetch origin && git reset --hard origin/main
```

With `set -e` (errexit), bash does NOT exit when a command fails as part of a `&&` or `||` chain. This is specified POSIX behavior. When `git fetch origin` fails:

1. `git fetch origin` returns non-zero (credential error)
2. Bash short-circuits the `&&` -- skips `git reset --hard origin/main`
3. The `&&` chain itself returns non-zero, BUT `set -e` does NOT trigger because the failure occurred in a compound command
4. Execution continues to the next line: `log "  OK -- now at $(git rev-parse --short HEAD)"`
5. `git rev-parse --short HEAD` returns the existing (stale) HEAD: `7d59255`
6. Script logs `OK -- now at 7d59255` and proceeds with the rest of the deploy

**Verified experimentally:**
```bash
bash -c 'set -euo pipefail; false && echo "after"; echo "continued"'
# Output: "continued"  (no exit, no error)
```

### Result

- The deploy ran against stale commit 7d59255 instead of target commit 0ca2309
- sync-agents, stow, apply-cron all ran successfully on the old code
- GitHub Actions marked the run as success (exit code 0)
- No Slack failure notification was sent (the step only runs on `failure()`)

## Evidence

### Deploy log (run 23940130160)
```
[deploy] === Pulling latest from origin/main ===
failed to get: -25308
fatal: could not read Username for 'https://github.com': Device not configured
[deploy]   OK -- now at 7d59255
[deploy] === Deploy sequence ===
```

### Git remote configuration
```
origin  https://github.com/<your-org>/openclaw-agents.git (fetch)
origin  https://github.com/<your-org>/openclaw-agents.git (push)
```

### Runner configuration
- Runner name: `openclaw-host`
- Machine: `Mini-von-Tech`
- Version: 2.333.1
- Status: online
- Labels: self-hosted, macOS, ARM64, openclaw-host
- Service: launchd PID 78209 (`actions.runner.<your-org>-openclaw-agents.openclaw-host`)

### Current HEAD (after manual git pull)
```
0ca2309 feat: proactive bootstrap with per-field state tracking (#150)
```

### Run history
- 10 recent deploy runs all reported success
- All completed in ~1m35s-1m57s
- Impossible to tell from run list which ones had the same silent failure

## Recommended Fixes

### Fix 1 (Critical): Make git fetch failure non-silent in deploy.sh

Replace the `&&` chain on line 71 with explicit error checking:

```bash
# Before (buggy):
git fetch origin && git reset --hard origin/main

# After (correct):
git fetch origin
git reset --hard origin/main
```

With `set -e`, separating the commands onto individual lines ensures each one independently triggers errexit on failure.

Alternatively, add explicit error checking:

```bash
if ! git fetch origin; then
  fail "git fetch origin failed -- check HTTPS credentials or switch to SSH"
fi
git reset --hard origin/main
```

### Fix 2 (Critical): Fix git credentials for the runner

Options (pick one):
1. **Switch remote to SSH**: `git remote set-url origin git@github.com:<your-org>/openclaw-agents.git` and ensure SSH key is available to the launchd service
2. **Use a GitHub PAT**: Configure `git credential.helper store` with a fine-grained PAT that does not depend on macOS Keychain
3. **Use `GITHUB_TOKEN`**: The workflow already has a `GITHUB_TOKEN` with `contents: read` -- pass it to git via environment variable in the workflow step

### Fix 3 (Recommended): Add post-pull commit verification

After the pull, verify the expected commit was fetched:

```bash
EXPECTED_SHA="${GITHUB_SHA:-}"
if [ -n "$EXPECTED_SHA" ]; then
  ACTUAL_SHA="$(git rev-parse HEAD)"
  if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    fail "HEAD ($ACTUAL_SHA) does not match expected commit ($EXPECTED_SHA)"
  fi
fi
```

This catches any future silent-pull-failure scenarios.

### Fix 4 (Recommended): Audit previous deploy runs

Since we cannot tell from the run list which previous deploys silently failed, audit recent runs to check if they logged the same `failed to get: -25308` error. Commands:

```bash
for run_id in 23934434551 23933499173 23933366607 23930150091 23930094432; do
  echo "=== Run $run_id ==="
  gh run view "$run_id" --log 2>&1 | grep -E "failed to get|fatal:|now at"
done
```

## Impact Assessment

- **Severity:** High -- deploys silently fail to update code, creating drift between GitHub and production
- **Blast radius:** All deploys since the credential broke are affected (unknown scope)
- **Detection gap:** No monitoring catches this -- the deploy reports success
- **Data loss:** None -- the stale code still functions, just misses updates
- **Recovery:** Manual `git pull origin main` on host (already done for this incident)
