# Research: CI Deployment Automation Feasibility
# openclaw-agents deployment pipeline via GitHub Actions

Date: 2026-04-01
Status: Informational — no changes made

---

## Context

The deployment pipeline for openclaw-agents consists of three sequential steps that must run on the host machine (a Mac running OpenClaw gateway):

```
bash scripts/sync-agents.sh
&& cd ~/openclaw-agents/.openclaw && stow --adopt --no-folding -t ~/.openclaw .
&& stow --no-folding -t ~/.openclaw .
&& bash scripts/apply-cron.sh
```

Optionally followed by `openclaw gateway restart` when changes affect openclaw.json or in-memory cron state.

Key constraints identified from reading the scripts:

- `sync-agents.sh` operates on `~/openclaw-agents/.openclaw/agents/*/` using `rsync --delete` and `cp -f`. It must run on the host where that path exists.
- `apply-cron.sh` invokes `openclaw cron list --json`, `openclaw cron add`, `openclaw cron edit`, `openclaw cron rm`, and directly patches `~/.openclaw/cron/jobs.json`. The `openclaw` binary and its running gateway must be present on the host.
- `stow` must run with `--adopt` before `stow` to prevent overwriting per-agent runtime files (IDENTITY.md, USER.md, memory/). This is a race-condition-sensitive sequential operation.
- `openclaw.json` is Category 3 (runtime-only, never in repo) — the CI runner cannot touch it.
- Per-agent `memory/` state must never be overwritten by CI.
- `apply-cron.sh` uses a lockfile at `/tmp/apply-cron.lock` to prevent concurrent runs. A CI job could conflict with a cron job that also runs apply-cron.sh, though none currently do.

---

## Options Compared

### Option 1: GitHub Actions Self-Hosted Runner on the Mac

**How it works:**
Install the GitHub Actions runner agent (`actions/runner`) on the Mac host as a LaunchAgent or LaunchDaemon. It polls GitHub for workflow jobs. On push to main, GitHub Actions dispatches a job to the self-hosted runner, which executes the deployment script locally on the Mac.

**Setup:**
1. Download and configure runner: `./config.sh --url https://github.com/<org>/openclaw-agents --token <TOKEN>`
2. Install as LaunchAgent: `./svc.sh install && ./svc.sh start`
3. Write a workflow (`.github/workflows/deploy.yml`) that triggers on push to main and runs the deployment steps.

**Pros:**
- Runs directly on the host — no SSH, no network exposure, no port forwarding needed.
- Full access to `openclaw`, `stow`, `rsync`, and all local paths.
- Workflow logs visible in GitHub UI (easy to audit).
- Supports branch protection: can require the deploy job to pass before merging.
- Runner token auth is handled by GitHub; no SSH keys to manage.
- Idiomatic GitHub Actions approach — same tooling as any other CI.
- Can be scoped to a specific label (e.g., `runs-on: [self-hosted, mac]`) so it only runs on your machine.

**Cons:**
- Requires the runner process to stay running on the Mac. If the Mac is rebooted and LaunchAgent fails to start, deploys silently stop working.
- Runner authenticates to GitHub — the registration token (and the resulting `.credentials` files) must be stored on disk. These give write access to the repo's Actions API. Not a secret file, but worth noting.
- GitHub requires the runner process to have a registration token refreshed periodically (auto-renews via the runner agent itself — not a manual concern in practice).
- The runner runs as whatever user installs it. If that user is your login user, the runner has full access to the Mac, including `openclaw.json`. A compromised workflow could be destructive.
- Concurrent workflow runs could conflict with `apply-cron.sh`'s lockfile. The lockfile handles this gracefully (exits with error), but the deploy would fail and need a retry.
- No isolation from the live system — a broken deploy script runs directly against production.

**Security considerations:**
- Self-hosted runners on public repos are a known security risk (malicious PRs can execute code on your machine). This repo appears to be private, which eliminates that attack vector.
- For a private repo with a single trusted maintainer (you), the risk is low.
- Runner should run as a non-root user. The current deployment scripts don't require root.
- Do not store secrets in the workflow file itself — use GitHub Actions secrets for any tokens or credentials.

**Complexity:** Low to Medium (runner setup is ~15 minutes; workflow file is ~20 lines).

---

### Option 2: SSH from GitHub Actions (GitHub-Hosted Runner)

**How it works:**
Use a GitHub-hosted runner (e.g., `ubuntu-latest`). The workflow SSHes into the Mac host and runs the deployment commands remotely.

**Setup:**
1. Generate a dedicated SSH key pair.
2. Add the public key to `~/.ssh/authorized_keys` on the Mac.
3. Store the private key as a GitHub Actions secret.
4. Expose SSH port (22) or use a tunnel (ngrok, Tailscale, Cloudflare Tunnel) if the Mac is behind NAT.
5. Write a workflow that SSHes in and runs the deployment.

**Pros:**
- No persistent process required on the Mac (beyond sshd, which is always running).
- GitHub-hosted runner handles the CI side — no runner maintenance on the Mac.
- Clean separation: the CI side runs on GitHub's infrastructure; only deployment commands touch the Mac.

**Cons:**
- The Mac must be reachable over SSH from GitHub Actions IP ranges. GitHub publishes these IPs, but they are broad (~30 CIDR blocks). If the Mac is behind a residential NAT or corporate firewall, you need a tunnel solution.
- Tunnel options (Tailscale, Cloudflare Tunnel, ngrok) add operational complexity and another service to keep running.
- SSH private key stored as a GitHub Actions secret is a long-lived credential with shell access to your Mac. If the secret is leaked (e.g., via a compromised GitHub account), an attacker gets a shell.
- SSH keys don't expire by default — requires manual rotation discipline.
- The stow race condition is still a risk: if a deploy runs while an agent is writing to `~/.openclaw/agents/*/memory/`, stow --adopt could pull in partial state.

**Security considerations:**
- Long-lived SSH key with shell access to the host is a meaningful attack surface.
- Key rotation must be manual and deliberate.
- Should be combined with key restrictions in `authorized_keys` (e.g., `command=` restriction to only allow the deploy script, `no-pty`, `no-agent-forwarding`).
- Firewall rules to restrict SSH access to GitHub Actions IP ranges help but the IP list is large and changes.

**Complexity:** Medium to High (SSH setup + tunnel if behind NAT; key management ongoing).

---

### Option 3: Webhook Listener + Deploy Script on the Host

**How it works:**
Run a small HTTP server on the Mac (e.g., using `webhook` tool, a tiny Python/Node server, or `smee.io` proxy). GitHub sends a webhook on push to main; the listener verifies the HMAC signature and runs the deployment script.

**Setup:**
1. Install a webhook receiver (e.g., `brew install webhook`, or a small Python script).
2. Configure it as a LaunchAgent so it runs on boot.
3. Set a shared secret in both GitHub (webhook settings) and the listener config.
4. Add a GitHub webhook pointing to the listener's URL (requires external reachability, same NAT problem as SSH, or use smee.io as a proxy).
5. Optionally add `smee.io` as a relay to avoid exposing a port.

**Pros:**
- Very lightweight — just a small HTTP server + script.
- No GitHub Actions runner to maintain.
- Webhook secret provides authentication (HMAC-SHA256).
- Can be fully self-contained with no GitHub infrastructure dependency beyond the webhook push.

**Cons:**
- Same NAT/reachability problem as SSH unless using a relay.
- `smee.io` is a third-party service — adds a dependency and potential downtime.
- No built-in audit trail or logs in GitHub UI. You'd need to set up your own logging.
- Security of the webhook secret: it lives in a config file on disk (similar risk profile to the SSH key, but more narrowly scoped — only allows triggering the deploy script, not arbitrary shell access).
- More custom code to maintain than a GitHub Actions workflow.
- No built-in concurrency protection (though `apply-cron.sh`'s lockfile handles the cron collision case).

**Complexity:** Medium (setup is straightforward; relay adds complexity; no GitHub UI integration).

---

### Option 4: Manual Deployment (Current State, Improved)

**How it works:**
Keep manual deployment as-is, but add a Makefile target or a single `deploy.sh` wrapper script that encodes the full command sequence, reducing the chance of forgetting a step.

**Pros:**
- No infrastructure changes.
- Zero security surface area added.
- The operator (you) is always in the loop, which is appropriate given how sensitive the stow operation is (known data loss risk on dev10/dev10 IDENTITY.md, 2026-03-30).
- No risk of a CI bug deploying bad config to production agents.

**Cons:**
- No automation — deploys don't happen unless you remember.
- Drift can accumulate if merges to main aren't followed by manual deploys.
- Human error risk: running stow without --adopt, or forgetting apply-cron.sh.

---

## Security Considerations Summary

| Approach | Network Exposure | Credential Type | Blast Radius if Compromised |
|----------|-----------------|-----------------|----------------------------|
| Self-hosted runner | None (outbound only) | Runner registration token | Full shell on the runner user account |
| SSH | Inbound SSH (or via tunnel) | Long-lived SSH private key | Full shell on the Mac |
| Webhook | Inbound HTTP (or via relay) | HMAC webhook secret | Can only trigger the deploy script |
| Manual | None | None | N/A |

**Critical note for all automated approaches:** The deployment modifies `~/.openclaw/` which contains live agent state. A misconfigured or malicious deploy could silently overwrite agent memory (IDENTITY.md, USER.md) or misconfigure cron jobs. The stow --adopt safeguard only helps if it runs correctly. CI removes the human review step.

---

## Recommendation

**Self-hosted GitHub Actions runner** is the best fit for this setup, with one caveat: only implement it once the stow safety issues are properly handled (the known issue of stow overwriting per-agent files needs a GH issue and a safeguard before automating).

**Rationale:**

1. No network exposure (outbound polling only). For a single-Mac setup, this is the cleanest security posture of the automated options.
2. No SSH keys or tunnels required.
3. Full auditability via GitHub Actions logs.
4. Standard tooling — easy to reason about and hand off.
5. The runner runs on the same user account that currently runs deployments manually, so no permission changes needed.
6. For a private repo with a single trusted maintainer, the security risk is low.

**Suggested workflow structure:**

```yaml
# .github/workflows/deploy.yml
name: Deploy to host

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: [self-hosted, mac]
    concurrency:
      group: deploy
      cancel-in-progress: false   # queue, don't cancel, to avoid partial deploys
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Sync agents
        run: bash scripts/sync-agents.sh

      - name: Stow (adopt then apply)
        run: |
          cd ~/.openclaw
          stow --adopt --no-folding -t ~/.openclaw ~/openclaw-agents/.openclaw
          stow --no-folding -t ~/.openclaw ~/openclaw-agents/.openclaw

      - name: Apply cron
        run: bash scripts/apply-cron.sh

      # Only restart if needed (detect openclaw.json changes separately)
      # - name: Restart gateway
      #   run: openclaw gateway restart
```

**Before implementing, these issues must be resolved:**

1. **Stow per-agent file safety**: The known risk that `stow --adopt` followed by `stow` can overwrite IDENTITY.md and USER.md with repo templates needs to be addressed. Options: (a) verify `.stow-local-ignore` correctly excludes all per-agent files before automating, or (b) add a pre-deploy check that diffs per-agent files against templates and aborts if they diverge unexpectedly.

2. **Gateway restart policy**: `apply-cron.sh` patches `jobs.json` directly (Phase 2b: clear model), but notes that a gateway restart is required for in-memory state to reflect the change. The workflow should either always restart, or detect whether a restart is needed (e.g., by checking if any Phase 2b patches were applied).

3. **Lockfile conflict**: If a cron job or manual run of `apply-cron.sh` happens concurrently with a CI deploy, the CI run will fail with the lockfile error. This is safe (fail-fast is correct behavior), but the CI job will need a retry mechanism or a human to re-run it.

4. **openclaw.json excluded from automation**: The workflow must never touch `openclaw.json`. The current setup already handles this (it's not in the repo), but the workflow should not run `openclaw gateway restart` unconditionally — only when agent configs change (not cron changes, which don't require a restart).

**Alternative if stow safety isn't resolved yet**: Use the webhook approach as a lighter-weight intermediate step. It adds less infrastructure than a runner, and the blast radius if the HMAC secret leaks is limited to triggering the deploy script (not arbitrary shell access).

---

## Files Referenced

- `/Users/<hostname>/openclaw-agents/scripts/sync-agents.sh` — copies shared type files into each agent dir; uses `rsync --delete` and `cp -f`
- `/Users/<hostname>/openclaw-agents/scripts/apply-cron.sh` — reconciles gateway cron jobs with `jobs-config.json`; invokes `openclaw` binary; patches `~/.openclaw/cron/jobs.json` directly
- `/Users/<hostname>/openclaw-agents/.openclaw/cron/jobs-config.json` — 23 cron jobs for tech-manager + 5 agents (dev1, dev10, dev10, dev10, dev7, dev10, dev10-jean); all have `sessionKey` fields
- `/Users/<hostname>/openclaw-agents/CLAUDE.md` — repo conventions, category definitions, sync/stow workflow, known issues
