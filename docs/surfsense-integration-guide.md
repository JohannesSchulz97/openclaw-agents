# SurfSense (TOB Oracle) Integration Guide

> How to integrate Oracle's knowledge base, search, and AI capabilities into external agents and pipelines.

---

## TL;DR

Yes, Oracle has a full REST API. There are **3 integration patterns** depending on what you need:

| Pattern | Use case | Endpoint | Auth |
|---------|----------|----------|------|
| **A. RAG Search** | Retrieve relevant documents from the KB | `POST /api/pipeline/retrieve` | CF headers + `PIPELINE_API_TOKEN` |
| **B. Document Ingest** | Push data into the KB | `POST /api/v1/documents/fileupload` | CF headers + JWT |
| **C. Full Chat** | Delegate a question to the Oracle agent (gets tools, KB search, Foundry, etc.) | `POST /api/v1/new_chat` | CF headers + JWT |

There's also an **LLM routing endpoint** (`POST /api/pipeline/llm/complete`) that lets you call whatever LLM is configured for a search space without managing API keys yourself.

---

## 1. Base URL & Authentication

### Base URL

```
https://oracle.tob.sh
```

For containers on the same Hetzner server (e.g. LangGraph Standalone Server), use the internal URL:
```
http://surfsense-backend-1:8000
```

### Auth: Two layers required for production

**Layer 1 — Cloudflare Access** (gateway). Every request needs:
```
CF-Access-Client-Id: <CF_ACCESS_CLIENT_ID>
CF-Access-Client-Secret: <CF_ACCESS_CLIENT_SECRET>
```
Without these, Cloudflare returns 403 before the request reaches the backend.

**Layer 2 — User auth** (one of two options):

| Option | Header | How to get | Best for |
|--------|--------|------------|----------|
| JWT token | `Authorization: Bearer <JWT_TOKEN>` | `POST /auth/jwt/login` with email/password | User-facing endpoints (`/api/v1/*`) |
| Pipeline token | `Authorization: Bearer <PIPELINE_API_TOKEN>` | Static env var, ask PJ | Machine-to-machine (`/api/pipeline/*`) |

**Getting a JWT programmatically:**
```python
import httpx

resp = httpx.post(
    "https://oracle.tob.sh/auth/jwt/login",
    headers={
        "CF-Access-Client-Id": CF_ACCESS_CLIENT_ID,
        "CF-Access-Client-Secret": CF_ACCESS_CLIENT_SECRET,
    },
    data={"username": EMAIL, "password": PASSWORD},
)
jwt_token = resp.json()["access_token"]
```

### Credential storage

Store in `.env.cloudflare` (never committed):
```bash
CF_ACCESS_CLIENT_ID=xxxxxxxxxxxx.access
CF_ACCESS_CLIENT_SECRET=yyyyyyyyyyyyyyyyyyyyyyyyyyyy
PIPELINE_API_TOKEN=your-pipeline-token
```

---

## 2. Pattern A — RAG Search Tool (recommended for most agents)

**Best for**: Adding Oracle KB context to any LangChain/LangGraph agent as a tool.

### Endpoint

```
POST /api/pipeline/retrieve
Auth: CF headers + Bearer <PIPELINE_API_TOKEN>
```

### Request body

```json
{
  "query": "back pain treatment protocols",
  "search_space_id": 8,
  "top_k": 10,
  "connectors_to_search": ["SLACK", "GOOGLE_DRIVE"],
  "start_date": "2026-01-01T00:00:00Z",
  "end_date": "2026-03-27T00:00:00Z"
}
```

Only `query` and `search_space_id` are required. The rest is optional.

### Response

```json
{
  "results": [
    {
      "title": "Treatment Protocol v3",
      "content": "...",
      "source": "GOOGLE_DRIVE",
      "score": 0.87
    }
  ],
  "count": 10
}
```

### Python snippet — LangChain tool

```python
"""Oracle KB search tool for any LangChain/LangGraph agent."""
import os
import httpx
from langchain_core.tools import tool

ORACLE_BASE = os.environ.get("ORACLE_API_BASE", "https://oracle.tob.sh")
PIPELINE_TOKEN = os.environ["PIPELINE_API_TOKEN"]
CF_CLIENT_ID = os.environ["CF_ACCESS_CLIENT_ID"]
CF_CLIENT_SECRET = os.environ["CF_ACCESS_CLIENT_SECRET"]
SEARCH_SPACE_ID = int(os.environ.get("ORACLE_SEARCH_SPACE_ID", "8"))

def _oracle_headers() -> dict[str, str]:
    return {
        "CF-Access-Client-Id": CF_CLIENT_ID,
        "CF-Access-Client-Secret": CF_CLIENT_SECRET,
        "Authorization": f"Bearer {PIPELINE_TOKEN}",
        "Content-Type": "application/json",
    }

@tool
async def search_oracle_kb(query: str, top_k: int = 10) -> str:
    """Search the Oracle knowledge base for relevant documents.

    Use this when you need internal company knowledge: policies,
    meeting notes, Slack threads, Google Drive docs, etc.

    Args:
        query: Natural language search query
        top_k: Number of results (default 10, max 100)
    """
    async with httpx.AsyncClient(timeout=30) as client:
        resp = await client.post(
            f"{ORACLE_BASE}/api/pipeline/retrieve",
            headers=_oracle_headers(),
            json={
                "query": query,
                "search_space_id": SEARCH_SPACE_ID,
                "top_k": top_k,
            },
        )
        resp.raise_for_status()
        data = resp.json()

    results = data.get("results", [])
    if not results:
        return "No relevant documents found in the knowledge base."

    # Format for LLM consumption
    parts = []
    for r in results:
        title = r.get("title", "Untitled")
        content = r.get("content", "")[:2000]
        source = r.get("source", "unknown")
        parts.append(f"### {title} ({source})\n{content}")

    return "\n\n---\n\n".join(parts)
```

### How HttpPipelineContext does it today

The `tob-llm-pipelines` repo already uses this pattern. `HttpPipelineContext` (in `context_http.py`) calls:
- `POST /api/pipeline/retrieve` — for KB search (with `PIPELINE_API_TOKEN`)
- `POST /api/pipeline/llm/complete` — for LLM calls routed through Oracle
- `GET /api/foundry/open-tickets` — for Foundry data (no auth, internal network only)

---

## 3. Pattern B — Document Ingest Tool

**Best for**: Agents that produce content and want to store it in Oracle.

### Endpoint

```
POST /api/v1/documents/fileupload
Auth: CF headers + Bearer <JWT_TOKEN>
```

### Python snippet

```python
"""Push a document into Oracle KB."""
import httpx

async def ingest_document(
    file_path: str,
    search_space_id: int,
    jwt_token: str,
) -> dict:
    """Upload a file to Oracle's knowledge base.

    Supported: PDF, DOCX, XLSX, PPTX, HTML, CSV, MD, TXT,
    MP3, MP4, WAV (audio → transcribed via STT).
    """
    headers = {
        "CF-Access-Client-Id": CF_CLIENT_ID,
        "CF-Access-Client-Secret": CF_CLIENT_SECRET,
        "Authorization": f"Bearer {jwt_token}",
    }

    async with httpx.AsyncClient(timeout=120) as client:
        with open(file_path, "rb") as f:
            resp = await client.post(
                f"{ORACLE_BASE}/api/v1/documents/fileupload",
                headers=headers,
                files={"files": (file_path.split("/")[-1], f)},  # field is "files" (plural!)
                data={"search_space_id": str(search_space_id)},
            )
        resp.raise_for_status()
        return resp.json()
```

You can also create text/URL documents via `POST /api/v1/documents` (JSON body).

---

## 4. Pattern C — Full Chat Delegation

**Best for**: When you want the full Oracle agent (KB search + Foundry tools + web scraping + report generation) to handle a complex question end-to-end.

### Endpoints (two-step)

```
1. POST /api/v1/threads     → create a thread (returns thread_id)
2. POST /api/v1/new_chat    → send message (returns SSE stream)
```

### Request body for `/api/v1/new_chat`

```json
{
  "chat_id": 42,
  "user_query": "Summarize all Slack threads about the pricing change",
  "search_space_id": 8,
  "mentioned_document_ids": [],
  "disabled_tools": []
}
```

Required: `chat_id`, `user_query`, `search_space_id`.

### Python snippet

```python
"""Delegate a question to the Oracle AI agent."""
import httpx
import json

async def ask_oracle_agent(
    question: str,
    search_space_id: int,
    jwt_token: str,
) -> str:
    """Send a question to the Oracle agent and collect the full response.

    Returns the agent's text response (parsed from SSE stream).
    """
    headers = {
        "CF-Access-Client-Id": CF_CLIENT_ID,
        "CF-Access-Client-Secret": CF_CLIENT_SECRET,
        "Authorization": f"Bearer {jwt_token}",
        "Content-Type": "application/json",
    }

    async with httpx.AsyncClient(timeout=180) as client:
        # Step 1: Create a thread
        thread_resp = await client.post(
            f"{ORACLE_BASE}/api/v1/threads",
            headers=headers,
            json={"title": question[:50], "search_space_id": search_space_id},
        )
        thread_resp.raise_for_status()
        thread_id = thread_resp.json()["id"]

        # Step 2: Send chat message (SSE streaming response)
        async with client.stream(
            "POST",
            f"{ORACLE_BASE}/api/v1/new_chat",
            headers=headers,
            json={
                "chat_id": thread_id,
                "user_query": question,
                "search_space_id": search_space_id,
            },
        ) as stream:
            text_parts = []
            async for line in stream.aiter_lines():
                # Vercel AI SDK Data Stream Protocol
                # Text tokens are prefixed with "0:"
                if line.startswith("0:"):
                    token = json.loads(line[2:])  # remove "0:" prefix, parse JSON string
                    text_parts.append(token)

    return "".join(text_parts)
```

**Important**: The response is SSE (`text/event-stream`), not JSON. Each line has a type prefix (`0:` = text token). Use an SSE library or parse line-by-line as shown above.

---

## 5. Bonus: LLM Routing via Oracle

If you want to use whatever LLM is configured in a search space without managing keys:

```
POST /api/pipeline/llm/complete
Auth: CF headers + Bearer <PIPELINE_API_TOKEN>
```

```python
resp = await client.post(
    f"{ORACLE_BASE}/api/pipeline/llm/complete",
    headers=_oracle_headers(),
    json={
        "messages": [
            {"role": "system", "content": "You are a helpful assistant."},
            {"role": "user", "content": "Summarize this: ..."},
        ],
        "search_space_id": 8,
        "role": "agent",  # or "document_summary"
    },
)
# Returns: {"content": "...", "role": "assistant", "model": "gemini-2.5-pro"}
```

The `role` field selects which LLM config to use: `"agent"` (main model) or `"document_summary"` (typically cheaper/faster).

---

## 6. Which Pattern for `ticket_analyse`?

The `ticket_analyse` pipeline in `tob-llm-pipelines` already integrates with Oracle via **Pattern A** (search) through `HttpPipelineContext`. It calls:

1. `GET /api/foundry/open-tickets` — fetches tickets from Foundry
2. `GET /api/foundry/structure-analyse?customer_email=...` — gets customer analysis
3. `POST /api/pipeline/llm/complete` — LLM calls for generating feedback

If you want to **add Oracle KB search** to `ticket_analyse` (e.g., to enrich tickets with KB context), add a call to `POST /api/pipeline/retrieve` in the relevant graph node. `HttpPipelineContext` already has an `oracle_retrieve()` method for this.

### Where to add a new tool file

If you want to expose Oracle search as a new **LangChain tool inside Oracle's own agent** (for other use cases):

```
surfsense_backend/app/agents/new_chat/tools/your_tool.py
```

Then register it in [registry.py](surfsense_backend/app/agents/new_chat/tools/registry.py) — see `ADDING_TOOLS_GUIDE.md` for the full walkthrough.

---

## 7. Gotchas

| Issue | Detail |
|-------|--------|
| **Double auth** | Production requires BOTH Cloudflare headers AND Bearer token. Forgetting CF headers → 403 (or HTML login page). |
| **`files` not `file`** | The upload field is plural: `files=@doc.pdf`. |
| **`user_query` not `message`** | Chat endpoint uses `user_query`, not `message`. |
| **`chat_id` required** | Must create a thread first (`POST /api/v1/threads`), then use its `id` as `chat_id`. |
| **SSE not JSON** | Chat response (`/api/v1/new_chat`) is Server-Sent Events. Parse line by line. |
| **Search space IDs** | Every operation is scoped to a `search_space_id`. List them: `GET /api/v1/searchspaces`. |
| **Pipeline token vs JWT** | `/api/pipeline/*` endpoints use `PIPELINE_API_TOKEN` (static). `/api/v1/*` endpoints use JWT (per-user, expires). |
| **Timeouts** | LLM-heavy endpoints (`/api/v1/new_chat`, `/api/pipeline/kb-article`) can take 30-120s. Set client timeout ≥ 180s. |
| **Internal network** | Foundry proxy endpoints (`/api/foundry/*`) have no auth — they're only accessible from the same server. Don't expose externally. |
| **No standalone RAG endpoint with JWT** | There's no `/api/v1/search` endpoint. For RAG search, use `/api/pipeline/retrieve` with `PIPELINE_API_TOKEN`. |

---

## 8. Quick Reference: All Integration Endpoints

| Endpoint | Method | Auth | Returns | Description |
|----------|--------|------|---------|-------------|
| `/api/pipeline/retrieve` | POST | CF + Pipeline token | JSON | Hybrid RAG search (semantic + full-text) |
| `/api/pipeline/llm/complete` | POST | CF + Pipeline token | JSON | LLM call via search space config |
| `/api/pipeline/kb-article` | POST | CF + Pipeline token | JSON | Run KB article pipeline in-process |
| `/api/v1/new_chat` | POST | CF + JWT | SSE stream | Full agent chat with tools |
| `/api/v1/threads` | POST | CF + JWT | JSON | Create chat thread |
| `/api/v1/documents/fileupload` | POST | CF + JWT | JSON | Upload document to KB |
| `/api/v1/documents` | POST | CF + JWT | JSON | Create text/URL document |
| `/api/v1/documents` | GET | CF + JWT | JSON | List documents |
| `/api/v1/documents/search` | GET | CF + JWT | JSON | Search documents by title |
| `/api/v1/searchspaces` | GET | CF + JWT | JSON | List search spaces |
| `/auth/jwt/login` | POST | CF only | JSON | Get JWT token |

---

## 9. Existing Documentation

- [API_DO<channel-id>.md](API_DO<channel-id>.md) — Full endpoint reference
- [API_USAGE_EXAMPLES.md](API_USAGE_EXAMPLES.md) — curl examples for common operations
- [EXTERNAL_API_README.md](EXTERNAL_API_README.md) — External integration guide (MCP + REST)
- [ADDING_TOOLS_GUIDE.md](ADDING_TOOLS_GUIDE.md) — How to add tools to the Oracle agent
- [CLOUDFLARE_SERVICE_TOKEN_SETUP.md](CLOUDFLARE_SERVICE_TOKEN_SETUP.md) — CF token setup (in French)
- Swagger UI: `https://oracle.tob.sh/docs` (requires CF headers + JWT)

---

## 10. Credentials

Ask PJ for:
- `CF_ACCESS_CLIENT_ID` / `CF_ACCESS_CLIENT_SECRET` — Cloudflare Access
- `PIPELINE_API_TOKEN` — Machine-to-machine pipeline auth
- Oracle account email/password — for JWT auth
- `LANGGRAPH_AUTH_TOKEN` — if using the MCP server at `langgraph.tob.sh`
