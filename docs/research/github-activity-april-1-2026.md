# GitHub Activity Report: <your-org> org - April 1, 2026

**Date:** 2026-04-02
**Purpose:** Ground-truth audit of all org activity on April 1, to compare against tech-manager reports

---

## Summary Statistics

- **Total commits:** 97
- **Merged PRs:** 26
- **Active repos:** 9 (11labs-ag, aws-terraform, core, openclaw-agents, tob-cv-processing, tob-dagster, tob-llm-pipelines, tob-twenty, waha-alert-connected, wordpress-app)
- **Active developers:** 8

---

## Commits Per Developer

| Developer | GitHub Username | Commits | Repos |
|-----------|----------------|---------|-------|
| dev10 | <github-username> | ~57 | core, tob-dagster |
| <manager-agent> (dev1) | <manager-agent> | 7 | openclaw-agents |
| dev6 | <github-username> | 6 | 11labs-ag |
| dev5 | <github-username> | 7 | waha-alert-connected, aws-terraform, wordpress-app |
| dev10-Jean | <github-username> | 3 | tob-llm-pipelines |
| dev9 | <github-username> | 3 | core |
| dev10 | <github-username> | 1 | wordpress-app |
| dev7 | <github-username> | 0 commits shown, but 3 PRs merged | tob-twenty |
| Unknown (no GH account linked) | null | ~13 | openclaw-agents, tob-llm-pipelines, tob-cv-processing |

**Note:** "unknown" authors are commits where the committer email did not map to a GitHub account (common with co-authored/bot commits in openclaw-agents and tob-llm-pipelines).

---

## Activity By Repository

### 1. core (dev10 + dev9) -- HEAVIEST ACTIVITY

dev10 dominated this repo with a massive Expo Web SPA migration:

**Merged PRs:**
- #248 (<github-username>): "feat: Expo Web SPA Migration -- CORS, CSP, SPA-Routing & Responsive UI"
- #247 (<github-username>): "fix: Chat Profilbilder, Nutzersuche Fallback, Admin Drawer"

**Key work by dev10 (~50+ commits):**
- Complete legacy frontend removal from apps/core
- Expo Web build setup (Phase 1)
- Platform abstractions: SecureStore, Haptics, ImagePicker, Audio, Sentry, ElevenLabs, WebView, PagerView, DocumentPicker, ImageManipulator, FileSystem
- Auth0 Web implementation with @auth0/auth0-react SPA SDK
- Responsive design foundation (Home, Kalender, Programme, Profil, Neuigkeiten)
- Tauri v2 Desktop app project structure
- CI/CD workflows for desktop builds and web deployment
- Worker refactored to API-only + SPA catch-all
- Multiple bug fixes (CORS, CSP, onboarding loops, Alert.alert web patch)

**Key work by dev9 (3 commits):**
- Auth0 profile picture persistence on login
- Chat list profile picture fix
- Admin drawer cleanup

### 2. 11labs-ag (dev6) -- 6 commits, 6 PRs merged

Critical reviewer ownership bug fix chain:
- #169: feat: split counter into Reviews (conversations) and Turns
- #170: fix: prevent bulkUpsert from overwriting other users' reviewer_id
- #171: fix: relax reviewer_id update to allow localStorage-based self-repair
- #172: fix: bulletproof reviewer ownership - WHERE clause + admin repair endpoint
- #173: feat: admin repair button for one-click reviewer_id reset
- #174: fix: skip sync on initial load -- only sync actual user edits

### 3. openclaw-agents (dev1/<manager-agent>) -- 7 commits, 7 PRs merged

Agent infrastructure work:
- #85: feat: structured daily summaries for tech-manager reports
- #93: Tech-manager governance, IDENTITY.md fixes, cron model cleanup
- #94: fix: move tech-manager scripts to types/manager (survive sync)
- #95: fix: correct github-activity.sh docs to use --user flag
- #96: fix: apply-cron model clearing, agent verbosity guidance, bootstrap data, research docs
- #97: feat: activate cron jobs for dev10 and dev10-jean
- #98: feat: add session watchdog, dev7 identity, and research docs

### 4. tob-dagster (dev10) -- 4 PRs merged

- #181: Fix Schmerzfrei Fundament programId: use WP App ID 10907
- #182: Justus Truth V2: knowledge ontology with source quotes & 3-axis taxonomy
- #183: Subscription V2: 1:1 contract model + program-specific celebration calls
- #184: Fix PandaDoc subscription ID hash collisions

### 5. tob-llm-pipelines (dev10-Jean) -- 3 PRs merged

- #26: feat: add tob-sa-api service with annotation evaluation
- #38: feat: tob-sa-api + shared LLM retry with exponential backoff
- #39: feat: tob-sa-api service, LLM retry, save_results fix + backfill script

### 6. tob-twenty (dev7) -- 3 PRs merged

- #117: feat: switch user list from tobCustomer to tobAppUser
- #118: Feature/coaching
- #119: fix: parse responseData JSON array in Anamnesebogen tab

### 7. waha-alert-connected (dev5) -- 4+ commits

- Add WAHA Alert Connected Lambda
- Update README translation to English
- Remove VPC-related configurations
- Refactor Lambda build and deployment process

### 8. aws-terraform (dev5) -- 1 commit

- Add health check port configuration

### 9. wordpress-app (dev10 + dev5) -- 3 commits

- #73 (<github-username>): fix: recordings Load More stuck at March 25 -- cursor broken by SQL regex
- dev5: merge branch stage/dev

### 10. tob-cv-processing -- 1 commit

- fix: lower knee landmark confidence threshold from 0.50 to 0.35 (author unknown/unlinked)

---

## Foundry-Related Activity

**Zero foundry-related commits or PRs found on April 1, 2026.** The search for "foundry" across all org commits on this date returned 0 results.

---

## Developers With NO Activity on April 1

Based on the agent list (17 dev-pa agents), the following had zero commits/PRs:

- dev10 (<github-username>)
- dev3 (<github-username>)
- dev4 (<github-username>)
- dev10 (<github-username>)
- dev8 (<github-username>)
- dev10 (<github-username>)
- dev10 (<github-username>)
- dev10 (<github-username>)

That is 8 out of 17 developers with no visible GitHub activity.

---

## Key Observations for Tech-Manager Comparison

1. **dev10 was by far the most active developer** with ~57 commits across core and tob-dagster. The Expo Web SPA migration was a massive effort spanning platform abstractions, auth, responsive design, CI/CD, and legacy removal.

2. **dev6 had a focused but critical day** -- 6 PRs fixing a reviewer ownership bug chain in 11labs-ag. This was clearly a production issue requiring rapid iteration.

3. **dev5 worked across 3 repos** (waha-alert-connected, aws-terraform, wordpress-app) on infrastructure/DevOps tasks.

4. **dev10-Jean's tob-llm-pipelines work** added a new tob-sa-api service with LLM retry logic -- substantial feature work.

5. **dev7 merged 3 PRs in tob-twenty** -- coaching feature, user list migration, and a bug fix.

6. **dev10 fixed a specific bug** in wordpress-app (recordings pagination).

7. **dev9 contributed fixes** in core for chat profiles and admin drawer.

8. **8 developers had zero activity** -- this is worth checking against work schedules (some may have been off, some may be new/not yet bootstrapped).

9. **No foundry activity whatsoever** -- if the tech-manager mentioned foundry work, that would be a fabrication.

10. **Many "unknown" author commits** (13) -- these are from openclaw-agents and tob-llm-pipelines where the commit email does not map to a GitHub account. Most are co-authored bot commits.
