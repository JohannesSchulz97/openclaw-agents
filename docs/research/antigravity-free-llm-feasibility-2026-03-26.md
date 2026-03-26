# Antigravity: Free LLM Access Feasibility for OpenClaw Agents

**Date:** 2026-03-26
**Classification:** Informational (with actionable findings)
**Status:** Complete

---

## 1. What Is Antigravity?

**Google Antigravity** is an AI-powered IDE launched November 18, 2025 as a heavily modified fork of VS Code. It was built by the former Windsurf team (acquired by Google via a $2.4B licensing deal in July 2025). It is NOT an independent startup -- it is a Google product.

- **Platform:** Desktop IDE (macOS, Windows, Linux)
- **Core feature:** Agent-first development with parallel autonomous agents
- **Models included:** Gemini 3.1 Pro, Gemini 3 Flash, Claude Sonnet 4.6, Claude Opus 4.6, GPT-OSS-120B
- **Current status:** Public Preview (free for individuals, no paid tiers yet)
- **Official site:** antigravity.google

## 2. Free Tier Details

| Aspect | Detail |
|---|---|
| **Price** | $0 (Public Preview) |
| **Models** | Gemini 3 Pro (high/low), Claude Sonnet 4.6, Claude Opus 4.6 Thinking, GPT-OSS-120B |
| **Rate limits** | Reset every ~5 hours; based on agent work rather than prompt count |
| **Parallel agents** | Up to 5 simultaneous |
| **Tab completions** | Unlimited |
| **Command requests** | Unlimited (within rate limits) |
| **Seats** | Individual only (Team/Enterprise "coming soon") |

**Caveats:**
- Some users report exhausting credits in ~20 minutes during heavy use
- Reports of Pro subscribers hitting 7-day lockouts instead of 5-hour refresh
- Free Claude Opus access is unlikely to be Google's permanent model -- API costs are ~$15/$75 per 1M input/output tokens
- Google has signaled this is preview-phase pricing, not final

## 3. API Access: Can Tokens Be Used Outside the IDE?

### Official Position: NO

Google does NOT expose a public API for Antigravity's free LLM access. The service is designed as an IDE-bound experience. For headless/programmatic use cases, Google officially recommends **Gemini CLI** (which has its own separate rate limits and authentication).

### Reverse-Engineered Access: YES (with major caveats)

Community projects have reverse-engineered Antigravity's internal API:

**Endpoints (undocumented, internal):**
- Production: `https://cloudcode-pa.googleapis.com`
- Sandbox: `https://daily-cloudcode-pa.sandbox.googleapis.com`

**Authentication:** OAuth 2.0 via Google Cloud (Bearer tokens, Google account login)

**Key projects:**
- `opencode-antigravity-auth` -- enables CLI tools to authenticate against Antigravity's OAuth and use its rate limits
- `antigravity-proxy` -- intercepts Antigravity API calls for external use
- Both support headless/copy-paste auth flows

**Critical warning from the community:**
> "There are reports of Google blocking accounts using this plugin. The current Antigravity ToS (as of 2026-02-18) states that their service can't be used with third-party products."

### API Format

Requests must use **Gemini-style format** (`contents` array with `role: "user"/"model"`). Anthropic-style message arrays are NOT supported. This means any integration would need a translation layer.

## 4. Practical Feasibility for OpenClaw Agents

### Could OpenClaw route requests through Antigravity?

**Technically possible but practically infeasible.** Here is the assessment:

| Factor | Assessment |
|---|---|
| **API exists?** | Undocumented internal API, reverse-engineered by community |
| **Auth mechanism** | OAuth 2.0 with Google account -- requires interactive login flow |
| **Headless support** | Partial (copy-paste token flow), not designed for automation |
| **Request format** | Gemini-style only -- needs translation layer for OpenAI-compatible clients |
| **Rate limits** | Resets every 5 hours, reportedly exhaustible in 20 minutes of heavy use |
| **Account risk** | Reports of Google blocking accounts using third-party access |
| **Stability** | Internal API with no stability guarantees; can change without notice |
| **Multi-agent scaling** | Each Google account = one set of rate limits; scaling requires multiple accounts |

### What would be required:

1. **OAuth proxy service** that maintains authenticated sessions with Google
2. **Request translator** converting OpenAI-compatible format to Gemini-style
3. **Multiple Google accounts** to handle agent concurrency (5+ agents running simultaneously)
4. **Token refresh automation** to handle OAuth token expiry
5. **Rate limit management** across accounts to avoid exhaustion
6. **Fallback routing** when Antigravity limits are hit

### Comparison: effort vs. alternatives

| Approach | Monthly cost (5 agents) | Reliability | Effort | Risk |
|---|---|---|---|---|
| **Antigravity hack** | $0 | Very low | Very high | Account bans, API changes |
| **OpenRouter** | ~$50-200 | High | Low | None |
| **Gemini API direct** | ~$20-100 | High | Low | None |
| **Google AI Studio free** | $0 | Medium | Medium | Rate limits |

## 5. Terms of Service Analysis

### What the ToS says:

- Prohibits "automated systems (bots, scrapers) to access the Services without permission"
- Prohibits "reverse engineering or decompiling any aspect of the Services"
- Community reports state ToS explicitly says "service can't be used with third-party products"
- Service provided "as is" with right to suspend/terminate for violations
- Google uses interaction data for research and product improvement

### Would using Antigravity tokens for autonomous agents violate ToS?

**Almost certainly YES.** Multiple violations would apply:

1. **Automated access:** OpenClaw agents are bots accessing the service programmatically
2. **Third-party product restriction:** OpenClaw is a third-party product
3. **Reverse engineering:** Using undocumented internal APIs qualifies
4. **Spirit of the service:** Antigravity is designed as an interactive IDE, not an API provider

### Enforcement risk:

- Google has already been blocking accounts that use third-party auth plugins
- Account-level bans would disrupt all services tied to the Google account
- No appeals process documented for preview-phase products

## 6. Verdict

### Can Antigravity tokens realistically reduce costs for OpenClaw agents?

**No. This is not a viable path.** The reasons:

1. **No official API** -- only reverse-engineered internal endpoints
2. **ToS explicitly prohibits** automated/third-party access
3. **Google is actively enforcing** against unauthorized API usage
4. **Rate limits are too restrictive** for agent workloads (exhaustible in 20 min)
5. **Authentication is OAuth-interactive** -- not designed for headless automation
6. **Preview pricing will change** -- free tier is temporary
7. **Account ban risk** -- could affect other Google services on the same account
8. **Engineering effort** far exceeds cost savings vs. legitimate API providers

### Recommended alternatives for cost reduction:

- **Gemini API directly** ($0.30-2.00/1M input tokens) -- legitimate, stable, supports all use cases
- **OpenRouter** -- unified API with model fallback, pay-per-use
- **Google AI Studio free tier** -- 15 RPM free for Gemini models with legitimate API access
- **Gemini CLI** -- Google's official headless tool, with its own (separate) free quota

---

## Sources

- [DEV Community: Why I Switched to Antigravity](https://dev.to/fedtti/why-i-switched-from-vs-code-to-antigravity-and-im-not-going-back-2ml2)
- [VS Code Copilot vs Google Antigravity](https://addshore.com/2026/01/vs-code-copilot-agent-vs-google-antigravity-planning/)
- [Visual Studio Magazine: VS Code Forks Compared](https://visualstudiomagazine.com/articles/2026/01/26/what-a-difference-a-vs-code-fork-makes-antigravity-cursor-and-windsurf-compared.aspx)
- [Skywork: Antigravity Pricing & Limits](https://skywork.ai/blog/antigravity-pricing/)
- [DataStudios: Is Antigravity Free?](https://www.datastudios.org/post/is-google-antigravity-free-to-use-pricing-limits-and-what-developers-should-expect)
- [Google Developers Blog: Antigravity Announcement](https://developers.googleblog.com/build-with-google-antigravity-our-new-agentic-development-platform/)
- [opencode-antigravity-auth (GitHub)](https://github.com/NoeFabris/opencode-antigravity-auth)
- [antigravity-proxy (GitHub)](https://github.com/elad12390/antigravity-proxy)
- [Antigravity API Spec (reverse-engineered)](https://github.com/NoeFabris/opencode-antigravity-auth/blob/main/docs/ANTIGRAVITY_API_SPEC.md)
- [Google Cloud Blog: Choosing Antigravity or Gemini CLI](https://cloud.google.com/blog/topics/developers-practitioners/choosing-antigravity-or-gemini-cli)
- [Antigravity ToS Analysis (jorgep.com)](https://jorgep.com/blog/google-antigravity-additional-terms-of-service/)
- [Antigravity Official Terms](https://antigravity.google/terms)
- [DEVCLASS: Antigravity Review](https://devclass.com/2025/11/19/googles-antigravity-arrives-agentic-ai-development-but-frustrating-for-early-adopters/)
- [DataCamp: Claude Code vs Antigravity](https://www.datacamp.com/blog/claude-code-vs-antigravity)
