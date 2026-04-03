# Research: GitHub Actions Deploy Path Mismatch (PR #153)

**Date:** 2026-04-03
**Symptom:** Deploy workflow reported "Deploy complete" for PR #153 but ~/openclaw-agents on the host still showed old commit (0ca2309 from PR #150). Manual `git pull origin main` was needed to reach 3c64a1e.

---

## Finding: There Is No Path Mismatch

The suspected root cause — runner using its own checkout directory instead of ~/openclaw-agents — does NOT apply here. The workflow is correctly designed to avoid that trap.

### Evidence

**deploy.yml line 34:**
```
run: bash $HOME/openclaw-agents/scripts/deploy.sh --pull
```

The workflow uses `$HOME/openclaw-agents` explicitly. There is no `actions/checkout` step. The comment in the workflow file makes the intent explicit (lines 29-31):

> No actions/checkout needed — the self-hosted runner IS the OpenClaw host with a persistent repo clone at $HOME/openclaw-agents. deploy.sh --pull handles updating to latest main via `git fetch origin && git reset --hard origin/main`.

So the runner always operates on the live repo at `~/openclaw-agents`. The deploy script is invoked from that exact path.

---

## How deploy.sh --pull Actually Works

**deploy.sh lines 65-74:**
```bash
if [ "$PULL" = true ]; then
  cd "$REPO_ROOT"
  git fetch origin && git reset --hard origin/main
  log "  OK — now at $(git rev-parse --short HEAD)"
fi
```

`REPO_ROOT` is computed at line 8 as the parent of the script's own directory:
```bash
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
```

Since the script is invoked as `bash $HOME/openclaw-agents/scripts/deploy.sh --pull`, `REPO_ROOT` resolves to `$HOME/openclaw-agents`. The `cd "$REPO_ROOT"` before the fetch therefore operates on the correct directory.

The pull mechanism uses `git fetch origin && git reset --hard origin/main` — not `git pull`. This is intentional: it bypasses the pre-commit and post-checkout hooks (which block commits and branch switches respectively), and it avoids merge conflicts.

---

## The Actual Likely Cause

Given the design is correct, the "deploy complete but stale HEAD" symptom points to one of these scenarios:

### Scenario A: The deploy ran in a previous runner workdir (most likely)

Self-hosted runners maintain a `_work/` directory under their installation path (e.g. `~/actions-runner/_work/openclaw-agents/openclaw-agents/`). When a workflow uses `actions/checkout`, the runner clones the repo there. If a previous workflow run had an `actions/checkout` step and the step was later removed, the runner's `GITHUB_WORKSPACE` still points to `_work/`.

**The critical question:** What does `$HOME` resolve to in the runner's shell environment?

If the runner is installed as a service (per the workflow comment: `sudo ./svc.sh install`), it runs as a system service user. That user's `$HOME` may not be `/Users/<hostname>` or the expected user home. If `$HOME` resolves differently for the service user, `$HOME/openclaw-agents` would be a different (possibly nonexistent or freshly-created) path, and the deploy would silently succeed against an empty or stale clone.

**How to confirm:** Check the runner's service user and what `$HOME` it sees. In the Actions run logs, the step "Deploy config to OpenClaw host" should show the output of `log "OK — now at $(git rev-parse --short HEAD)"` — if the logged commit SHA after pull is NOT 3c64a1e, this confirms the script ran against a different directory.

### Scenario B: git fetch succeeded but git reset --hard failed silently

`deploy.sh` uses `set -euo pipefail` (line 6), so any command failure should abort the script. However, `git fetch origin && git reset --hard origin/main` is a compound command — if `git fetch` succeeds but `git reset` fails (e.g. due to a dirty working tree or a lock file), the `&&` short-circuits and the exit code of the compound expression is the git reset exit code, which would trigger `set -e` and abort.

But if the failure happened BEFORE the pull step (e.g. in `openclaw config validate`), the script would exit early and never reach the git commands, yet the job could still be marked as "failed" — not "successful". So if the job showed success, the commands ran to completion.

### Scenario C: The deploy ran successfully on a different clone

If at some point the runner was re-registered or re-configured with a different home directory, there could be TWO clones of openclaw-agents on the host: one at the runner's `$HOME/openclaw-agents` (which the deploy updates) and the live one at `/Users/<hostname>/openclaw-agents` (or wherever openclaw actually runs from). The deploy would update the runner's clone, complete successfully, but the live clone would be untouched.

### Scenario D: git reset --hard ran but stow failed

If stow or sync-agents failed after the git reset, the deploy script would exit non-zero (due to `set -euo pipefail`), and the GHA job would be marked FAILED, not successful. So this does not explain a "successful" deploy with stale HEAD — unless the failure was caught somewhere and swallowed.

---

## Git Hooks Analysis

The git hooks in `.git/hooks/` are:

**pre-commit** — blocks all commits with exit 1. This does NOT affect `git reset --hard` (resets bypass commit hooks entirely).

**post-checkout** — blocks branch switching away from main. This DOES fire on `git checkout` but NOT on `git reset --hard`. The deploy script uses `git reset --hard origin/main`, not `git checkout`, so this hook is irrelevant to the deploy flow.

**Conclusion:** Neither hook could have interfered with the deploy pull step. The post-checkout hook would only fire if someone manually ran `git checkout <branch>` on the host.

---

## Root Cause Assessment

The most likely explanation is **Scenario A**: the runner's `$HOME` environment variable does not point to the expected user home when running as a launchd/systemd service, causing `$HOME/openclaw-agents` to resolve to a different path than `~/openclaw-agents` as observed by the <hostname> user.

The deploy script ran successfully against that path (updating a different clone or creating a new one), logged "Deploy complete", and the GHA job exited 0 — while the live `/Users/<hostname>/openclaw-agents` remained untouched.

---

## Recommended Verification Steps

1. **Check runner logs for the actual post-pull SHA.** In the GHA run for PR #153, expand "Deploy config to OpenClaw host" and look for the line `[deploy] OK — now at <sha>`. If the SHA is not 3c64a1e, the script ran against a different clone.

2. **Check $HOME for the runner service.** On the host: `cat ~/actions-runner/.env` or `sudo launchctl print system/com.github.actions.runner | grep HOME` to see what HOME the service sees.

3. **Search for multiple openclaw-agents clones.** Run `find / -name "deploy.sh" -path "*/openclaw-agents/*" 2>/dev/null` to locate all clones on the host.

4. **Harden the workflow.** Replace `$HOME/openclaw-agents` with a hardcoded absolute path in deploy.yml to eliminate ambiguity:
   ```yaml
   run: bash /Users/<hostname>/openclaw-agents/scripts/deploy.sh --pull
   ```
   Or set `HOME` explicitly in the workflow env block.

---

## Files Examined

- `/Users/<hostname>/openclaw-agents/scripts/deploy.sh`
- `/Users/<hostname>/openclaw-agents/.github/workflows/deploy.yml`
- `/Users/<hostname>/openclaw-agents/.git/hooks/pre-commit`
- `/Users/<hostname>/openclaw-agents/.git/hooks/post-checkout`
