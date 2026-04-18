# Technical Design: Agent Context — RAG + MCP Integration

## Feature
- Feature ID: `agent-rag-mcp`
- Status: **draft** — awaiting human approval

---

## 1. Current State

The agent runtime (in the `workflow` repo) today provides agents with:
- The claimed task YAML (status, description, dependencies)
- The feature's `product-spec.md` and `technical-design.md`
- Explicitly declared `SKILL.md` files (via `role_skill_overrides`)
- The raw implementation repo on disk

**Current limitations:**
- No cross-task memory — completed tasks' patterns and decisions are not available to future agents
- No convention recall — common patterns (error handling, auth, logging) must be re-discovered each task via manual file traversal
- No skill discovery — only explicitly declared skills load; relevant undeclared skills are missed
- Discovery work (reads, greps, import tracing) consumes tokens and iterations before useful output begins
- Context is assembled statically at claim time; there is no mid-task retrieval mechanism

---

## 2. Problem Framing

**Must change:**
- Agents need a searchable project knowledge index populated before they claim tasks
- Context delivery at claim time must not require full repo traversal
- Agents must be able to query for additional context mid-task via an MCP tool

**Must remain stable:**
- Task YAML / git-based claim protocol — RAG is additive context, not a workflow replacement
- Existing skill loading (declared skills still load explicitly)
- Human governance: review gates, approval protocol, task status rules
- Agent execution contract from `distributed-agent-team` spec

**Fixed assumptions:**
- Claude Code is the agent runtime — MCP tools are first-class
- Agents run as Docker containers (from `distributed-agent-team`)
- A lag of minutes for indexed content is acceptable (stated in product spec)
- **Every document stored and every query issued must carry `workspace_id`** — this is a hard platform requirement. v1 already serves two workspaces (`faro` and `workspace`); authentication is deferred but isolation is enforced by `workspace_id` from day one.

---

## 3. Options Considered

### 3a. Vector store

**Option A — ChromaDB (HTTP server mode)**
- Self-hostable Python-native vector DB, HTTP server mode
- Pros: zero infra cost, simple setup
- Cons: Python-only client; weaker K8s story; less production-mature than Qdrant
- Implementation impact: new `chromadb` container in `docker-compose.yml`

**Option B — LanceDB (embedded)**
- Rust-based embedded DB, very fast
- Pros: fast, embedded, no network hop per agent
- Cons: embedded means each agent holds its own index — divergent, expensive, no shared knowledge
- Dependency impact: per-agent index means no shared workspace knowledge

**Option C — Qdrant (self-hosted)**
- Rust-based vector DB, self-hostable via `qdrant/qdrant` Docker image
- REST + gRPC API, official Python client (`qdrant-client`), official Helm chart for K8s
- Collections keyed by `workspace_id`; payload filtering enforces tenant isolation
- Runs identically as a separate service in Docker Compose (local) or a dedicated VM on the K8s network (production)
- Pros: production-ready, Rust performance, K8s-native, REST API accessible from any language, no API key
- Cons: one more service to manage

**Option D — Fully managed cloud (Pinecone / Weaviate Cloud)**
- Pros: zero ops
- Cons: external API key, cost, vendor lock-in; overkill for current scale

**Chosen: Qdrant self-hosted (Option C).** Works identically across local Docker Compose and a dedicated VM on a K8s network — agents just point `QDRANT_URL` at the right host. Rust performance, production-ready, REST API, and a clear K8s upgrade path via the official Helm chart.

---

### 3b. Embedding model

**Option A — `sentence-transformers/all-MiniLM-L6-v2` (local)**
- 384-dim, runs in-container, no API key, ~90MB download
- Good quality for mixed code + prose retrieval
- Pros: zero cost, no external dependency, deterministic, self-contained
- Cons: lower quality ceiling than API-based models

**Option B — OpenAI `text-embedding-3-small`**
- 1536-dim, higher retrieval accuracy
- Pros: better quality
- Cons: API key dependency, cost per chunk at index time, external call

**Chosen: `sentence-transformers/all-MiniLM-L6-v2` for v1.** Keeps the system fully self-contained. Swapping the embedding model is an isolated change (re-index required but no schema change).

---

### 3c. MCP server architecture

**Option A — Shared companion service (separate container / separate deployment)**
- Docker Compose: `rag-server` is its own service entry; all agent containers on the host connect to it
- K8s: `rag-server` is its own `Deployment` + `ClusterIP Service`; all agent pods connect to it as a shared service
- Pros: one shared index across all agents, consistent knowledge, no divergence
- Cons: one more service to manage; agents need `MCP_RAG_URL` configured

**Option B — Embedded in agent container**
- Each agent container runs its own MCP server + local Qdrant index
- Pros: simpler per-agent setup
- Cons: every agent has its own index — divergent, expensive, stale

**Chosen: Shared companion service (Option A).** Each agent pod/container is a client; the RAG service is shared. This is the only model that gives all agents consistent project knowledge.

---

### 3d. Indexing trigger

**Option A — Git push webhook**
- Webhook fires on push to management/workspace repos
- Pros: near-realtime
- Cons: requires webhook infrastructure (hosted endpoint or ngrok for local)

**Option B — Scheduled polling**
- Indexer polls repos for changes on a fixed interval (default 5 min)
- Uses `git pull` + changed-file detection to index only modified documents
- Pros: simple, self-contained, no external webhook setup
- Cons: up to 5-min lag (acceptable per product spec)

**Option C — Event-driven (agent signals indexer on task completion)**
- Pros: timely updates
- Cons: tight coupling between agent and indexer

**Chosen: Scheduled polling.** Simplest, fully decoupled, lag acceptable.

---

### 3e. Context injection point

**Option A — Upfront summary only**
- RAG query at claim time → top-k chunks injected into `agentContext` prompt
- Pros: zero tool calls needed for common patterns
- Cons: token budget consumed upfront regardless of need

**Option B — MCP tool only (on-demand)**
- Agent calls `rag_query` explicitly during execution
- Pros: agent decides when it needs context; zero upfront cost
- Cons: agent may not know when to ask; relies on judgment

**Option C — Both (chosen)**
- Brief summary (~500 tokens) injected at claim time via one upfront RAG query
- `rag_query` MCP tool available for on-demand mid-task retrieval
- Pros: covers common case upfront; tool handles deeper dives
- Cons: slightly higher initial token cost (~500 tokens per task)

**Chosen: Both.** The upfront summary is cheap (one query) and guarantees the agent enters with baseline context even if it never calls the tool.

---

## 4. Chosen Design

### System architecture

```
Local (Docker Compose)              Production (K8s)
──────────────────────              ────────────────────────────────
agent container                     agent pod
rag-server container          ───►  rag-server pod
qdrant container (compose service)  qdrant VM (QDRANT_URL=http://<vm>:6333)
indexer container                   indexer pod

┌──────────────────────────────────────────────────┐
│  agent container                                 │
│  - Claude Code + workflow skills                 │
│  - MCP client configured with MCP_RAG_URL        │
│  - calls rag_query tool during task execution    │
│  - receives upfront RAG summary at claim time    │
└──────────────┬───────────────────────────────────┘
               │ MCP HTTP/SSE
┌──────────────▼───────────────────────────────────┐
│  rag-server container                            │
│  - Python FastAPI + MCP protocol (HTTP/SSE)      │
│  - tool: rag_query(query, workspace_id, top_k)   │
│  - embeds query via sentence-transformers        │
│  - queries Qdrant, returns ranked chunks         │
└──────────────┬───────────────────────────────────┘
               │ qdrant-client REST (QDRANT_URL)
┌──────────────▼───────────────────────────────────┐
│  qdrant (container or VM)                        │
│  - qdrant/qdrant Docker image, port 6333         │
│  - one collection per workspace_id               │
│  - stores: vectors + payload per chunk           │
└──────────────▲───────────────────────────────────┘
               │ qdrant-client REST (QDRANT_URL)
┌──────────────┴───────────────────────────────────┐
│  indexer container                               │
│  - polls management repo + workspace repos       │
│  - detects changed files via git                 │
│  - chunks + embeds documents                     │
│  - upserts to Qdrant with workspace_id payload   │
└──────────────────────────────────────────────────┘
```

`QDRANT_URL` is the single env var that switches between local (`http://qdrant:6333`) and production (`http://<vm-ip>:6333`). No code change required between environments.

### Document schema (Qdrant payload)

Every point stored in Qdrant carries this payload:

```json
{
  "workspace_id": "string",       // REQUIRED — tenant partition key
  "source_type": "string",        // skill | task_log | product_spec | technical_design | readme | claude_md
  "source_path": "string",        // relative path from repo root
  "feature_id": "string | null",  // for feature-scoped documents
  "chunk_index": 0,               // position within source document
  "indexed_at": "ISO 8601"
}
```

`workspace_id` is enforced on every query via a Qdrant `must` filter:
```json
{ "must": [{ "key": "workspace_id", "match": { "value": "<id>" } }] }
```
Queries without this filter are rejected at the query layer.

### What gets indexed

| Source | `source_type` | Chunking |
|---|---|---|
| `workflow/workflow_skills/*/SKILL.md` | `skill` | Whole file (short) |
| `workflow/technical_skills/*/SKILL.md` | `skill` | Whole file |
| `docs/features/*/product-spec.md` | `product_spec` | 512 tokens / 50 overlap |
| `docs/features/*/technical-design.md` | `technical_design` | 512 tokens / 50 overlap |
| `agents/<id>/log.jsonl` | `task_log` | One chunk per log entry |
| `CLAUDE.md`, `CLAUDE.shared.md` | `claude_md` | Whole file |
| Top-level `README.md` per repo | `readme` | 512 tokens / 50 overlap |

**Not indexed:** raw source code, `node_modules`, `vendor/`, binary files, `.env` files, any file containing secrets.

### MCP tool contract

```python
rag_query(
    query: str,                          # natural language question
    workspace_id: str,                   # required — enforced tenant filter
    top_k: int = 5,                      # number of chunks to return
    source_types: list[str] | None = None  # optional filter by source_type
) -> list[{
    content: str,
    source_path: str,
    source_type: str,
    feature_id: str | None,
    score: float
}]
```

### Claim-time context injection

In `start-implementation` (and `agent-activate` when it exists), after step 2 (context gathering), before step 3 (LLM implementation):

1. Check `MCP_RAG_URL` — if absent, skip silently (graceful degradation)
2. Query: `rag_query(query=task_title + " " + feature_id, workspace_id=..., top_k=5)`
3. Format results as a `## Relevant project context` section, capped at ~500 tokens
4. Append to `agentContext` before passing to Claude Code
5. Log: `rag_context_injected: true/false` in the task log entry (for later analysis of token impact)

### Token usage logging

Per the product spec success criterion, every task log entry produced during an agent work phase must record:

```yaml
log:
  - action: work_phase_complete
    by: backend-bot-01
    at: 2026-04-18T10:00:00+1000
    tokens:
      input: 12400
      output: 3200
      total: 15600
      cost_usd: 0.047
    rag_context_injected: true
```

### `workspace_id` in v1

`workspace_id` is read from `workspace.yaml -> workspace_id` and passed by each agent at index and query time. **v1 already operates with two known workspaces: `faro` and `workspace`.** Each has its own collection in Qdrant, fully isolated by `workspace_id` payload filter.

What is deferred is **authentication** — in v1, any agent that knows a `workspace_id` can query that workspace's index. Access control (verifying the caller is authorised for that `workspace_id`) is a v2 concern. This is an acceptable risk for two internal, trusted workspaces. Before onboarding external paying tenants, auth middleware must be added.

---

## 5. Dependency Analysis

**Internal dependencies:**
- `distributed-agent-team` and `agent-runtime-polling-loop` — the claim-time injection lives in the `agent-activate` / `start-implementation` skill; RAG is additive but the injection point depends on those features' agent execution contract being stable
- Qdrant must be running before `rag-server` and `indexer` start (Docker Compose `depends_on` handles this locally; on K8s, Qdrant VM must be reachable before pods start)
- Indexer must run at least once before agents query — cold start returns empty results; agents degrade gracefully

**External dependencies:**
- `qdrant-client` Python package (PyPI, Apache 2.0)
- `qdrant/qdrant` Docker image (Apache 2.0) — ports 6333 (REST) and 6334 (gRPC)
- `sentence-transformers` Python package (PyPI, Apache 2.0); model download ~90MB on first start
- `fastapi` + `uvicorn` for MCP server HTTP layer
- Docker + docker-compose (already required by `distributed-agent-team`)

**Blocking decisions:**
- **MCP transport: HTTP/SSE chosen** (vs stdio). The RAG server is a shared service potentially serving multiple agent containers; stdio requires a single process parent. HTTP/SSE is the correct choice. This is resolved.
- **Chunk size / overlap:** 512 tokens / 50 overlap proposed. Adjustable post-deploy with re-index; no schema change required.
- **Embedding model:** `all-MiniLM-L6-v2` chosen. Swappable with full re-index.

**Configuration dependencies:**
- `MCP_RAG_URL` — new optional env var in agent `.env`; must be added to `.env.template` and `agent.yaml.example`
- `QDRANT_URL` — new env var for `rag-server` and `indexer`; `http://qdrant:6333` locally, `http://<vm-ip>:6333` in production
- `WORKSPACE_ID` — already in `workspace.yaml`; surfaced to containers via compose env

**Release dependencies:**
- Independent of `workflow-db` — RAG reads from files/git, not the DB
- Enhances `distributed-agent-team` but does not require it — agents without `MCP_RAG_URL` degrade gracefully to cold start

---

## 6. Parallelization / Blocking Analysis

```
D1: Register rag-service repo in workspace.yaml ── human action; unblocks T1

T1: Qdrant schema + collection init — rag-service repo
  └── BLOCKED on D1 (repo must exist in workspace.yaml before implementation can begin)
  │
  T2: Indexer service — rag-service repo
  T3: RAG MCP server — rag-service repo
    └── T2 and T3 run in parallel
    └── BLOCKED on T1 (payload schema and collection structure must be frozen before
        indexer writes points or server builds queries against it)
    │
    T4: Agent claim-time context injection — workflow repo
      └── BLOCKED on T3 (MCP server must expose rag_query before agent can call it at claim time)
    │
    T5: Docker Compose + init-agent integration — workflow repo
      └── BLOCKED on T2 (indexer service must exist to wire into compose)
      └── BLOCKED on T3 (RAG server must exist to wire into compose)
      └── T4 and T5 run in parallel once their respective deps are met
          (T4 needs only T3; T5 needs T2 + T3 — T4 may start before T5)
    │
        T6: Documentation + operator guide — workflow repo
          └── BLOCKED on T4 (claim-time injection flow must be stable to document agent UX)
          └── BLOCKED on T5 (compose changes must be stable to document setup steps)
```

---

## 7. Repository Impact

All tasks target the **`workflow`** repo (`management-repo` is read by the indexer but not modified).

| Path | Change |
|---|---|
| `services/rag-server/` | New Python service — FastAPI + MCP + `qdrant-client` |
| `services/indexer/` | New Python service — polling indexer |
| `docker-compose.yml` | Add `qdrant`, `rag-server`, `indexer` services |
| `workflow_skills/start-implementation/SKILL.md` | Add RAG context injection step (step 2b) |
| `agent.yaml.example` | Document `MCP_RAG_URL` field |
| `.env.template` | Add `MCP_RAG_URL`, note it is optional (graceful degradation) |
| `README.md` / operator docs | Setup guide for new services |

---

## 8. Validation and Release Impact

**Testing expectations:**
- Unit: chunking logic, `workspace_id` filter enforcement (queries without it must be rejected), payload schema validation
- Integration: indexer → Qdrant → rag-server returns expected chunks for a known document
- Agent integration: claim-time injection produces non-empty context when indexed docs exist
- Graceful degradation: agent activates and completes a task when `rag-server` is unreachable — no crash, just cold start

**Migration / config impact:**
- `MCP_RAG_URL` is new and optional — existing agents without it continue to function identically
- Existing agent workspaces require: updated `docker-compose.yml` (new services) + `MCP_RAG_URL` in `.env`
- `init-agent` skill update ensures new agent workspaces get the full stack automatically

**Rollout concerns:**
- Qdrant cold start: index is empty until the indexer runs at least once; agents degrade gracefully
- Embedding model download (~90MB) on first `rag-server` container start — consider pre-baking into Docker image to avoid slow first-start
- Production: Qdrant VM must be provisioned and reachable before deploying rag-server and indexer pods; `QDRANT_URL` is the only config change between local and production
- Polling interval (5 min default) means newly committed docs appear in the index within 5 min

**Backward compatibility:**
- RAG is purely additive — no changes to task YAML schema, claim protocol, or human governance
- Agents without `MCP_RAG_URL` behave exactly as before

**Deployment / handoff:**
- New containers (`qdrant`, `rag-server`, `indexer`) must be documented in operator guide
- `init-agent` skill is the canonical setup path — it must provision the new services automatically
- Existing agents need a documented one-time migration (add new services to their `docker-compose.yml`)
