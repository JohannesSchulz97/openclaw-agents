# QMD Integration Status Report

**Date:** 2026-03-27
**Researcher:** Research Agent (Claude Opus 4.6)

## Version Summary

| Component | Installed | Latest Available | Gap |
|-----------|-----------|-----------------|-----|
| OpenClaw  | 2026.3.13 (61d171a) | 2026.3.24 | **11 days behind** |
| QMD       | Not installed | v2.0.1 (2026-03-11) | N/A |

## Issue #11308: Status and Applicability

- **Title:** QMD Memory Backend: Systemic Issues Requiring Comprehensive Fix
- **State:** CLOSED (stateReason: COMPLETED)
- **Created:** 2026-02-07
- **Closed:** 2026-02-14
- **Last Updated:** 2026-03-04
- **Author:** jon9314
- **Labels:** bug
- **Closing PRs:** None linked (closed without direct PR reference)
- **Repository:** openclaw/openclaw

### What the Issue Covered

The issue was a meta-bug cataloging 20+ systemic QMD problems:
1. Timeout and performance issues (CPU-only systems)
2. Search returning empty results (collection name mismatches, `memory_search` not calling `qmd search`)
3. Configuration confusion (overlapping config keys)
4. Permanent fallback after timeout (never recovers)
5. Boot embed timeout not configurable

### Resolution Status

The issue was marked COMPLETED on 2026-02-14. Since then, the OpenClaw CHANGELOG shows **extensive QMD fixes** across multiple releases, addressing nearly every category from the original issue:

**Fixes that landed (post-issue, in CHANGELOG):**
- Default `searchMode` changed to `search` for faster CPU-only recall
- Boot refresh runs in background by default
- Configurable QMD maintenance timeouts
- Retry QMD after fallback failures
- Scoped queries to managed collections only (#9690, #9705, #10042 -- directly cited in issue)
- Collection name conflict recovery
- Per-agent collection scoping
- Search result decoding fixes
- Multi-collection query ranking fixes
- CJK query normalization
- Windows spawn hardening
- Index isolation per agent
- Duplicate document recovery
- Output buffering caps
- And many more (40+ QMD-related CHANGELOG entries)

## Applicability to Current Installed Version (2026.3.13)

**The installed version (2026.3.13) was released on 2026-03-14, which is AFTER the issue was closed (2026-02-14) and AFTER many of the fixes landed.** Most of the systemic fixes cataloged in #11308 should be present in 2026.3.13.

However, the CHANGELOG shows QMD fixes continuing through the latest release (2026.3.24), meaning:
- Additional QMD improvements exist in newer versions
- Some edge cases (Windows spawn, collection conflict recovery, search result decoding) were fixed in releases after 2026.3.13

## Applicability to Latest Version (2026.3.24)

The latest version (2026.3.24) contains ALL QMD fixes through 2026-03-25, which comprehensively addresses every category from #11308 plus additional hardening.

## QMD Itself: Latest Version

QMD (tobi/qmd) latest release is **v2.0.1** (2026-03-11). This is a major version bump from the v0.7.x referenced in issue #11308 testing notes.

## Key Findings

1. **Issue #11308 is OUTDATED for current versions.** It was filed 2026-02-07 and closed 2026-02-14. Both the installed (2026.3.13) and latest (2026.3.24) OpenClaw versions post-date it.

2. **The CLAUDE.md warning about QMD is partially outdated.** The reference to "known issues with QMD (GitHub issue #11308)" was accurate when written but the issue has since been closed as COMPLETED. However, QMD integration remains complex and the `memory.backend: "local"` fallback suggestion remains prudent for simplicity.

3. **The installed version is behind.** 2026.3.13 vs 2026.3.24 means 11 days of additional fixes are available, including some QMD-specific improvements.

4. **QMD is not installed on this system.** The `qmd` binary is not in PATH, making the QMD backend configuration moot for this deployment.

5. **QMD v2.0.1 is a major upgrade** from v0.7.x referenced in the issue. Many upstream QMD bugs may also be resolved.

## Recommendations

1. **Update OpenClaw** to latest (2026.3.24):
   ```bash
   pnpm add -g openclaw
   openclaw gateway restart
   ```

2. **Update CLAUDE.md** to reflect that #11308 is closed/resolved, while keeping the `local` backend recommendation for simplicity (QMD adds complexity).

3. **If QMD is desired:** Install QMD v2.0.1 (`bun install -g https://github.com/tobi/qmd`) and update OpenClaw to latest first.

4. **Current `local` backend is fine.** For this deployment's use case (dev-pa agents), the local memory backend is simpler and avoids QMD complexity entirely.
