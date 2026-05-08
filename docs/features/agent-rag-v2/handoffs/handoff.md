# Handoff — agent-rag-v2

**Feature:** Agent RAG v2 — Source Code + Docs Indexing + Runtime Pre-injection
**Completed:** 2026-04-22
**All tasks:** T1–T5 done (5/5)

---

## What was built

Extended the RAG stack to index source code and docs, upgraded the embedding model for better code+prose retrieval, and fixed the core injection gap that meant agents never actually received RAG context during task execution.

### Problem summary

| Gap | Before | After |
|---|---|---|
| Source code | Not indexed — agents re-discovered patterns via grep on every task | All `.py`, `.ts`, `.tsx`, `.js`, `.go` files indexed with AST-aware chunking |
| Docs folder | Only `product-spec.md` and `technical-design.md` indexed | All `docs/**/*.md` indexed as `source_type: doc` |
| Embedding model | `all-MiniLM-L6-v2` (384-dim, prose-only) | `BAAI/bge-base-en-v1.5` (768-dim, strong on code + prose) |
| RAG injection | Tool registered in MCP but never called (0 invocations across all sessions) | Context pre-injected by runtime before Claude is spawned — model behaviour irrelevant |

### New and changed components

| Component | Repo | Change |
|---|---|---|
| `services/shared/schema.py` | `rag-service` | Added `"doc"` and `"source_code"` to `VALID_SOURCE_TYPES`; `VECTOR_DIM` → 768 |
| `services/indexer/embedder.py` | `rag-service` | Model swapped to `BAAI/bge-base-en-v1.5` |
| `services/rag_server/embedder.py` | `rag-service` | Same model swap (index and query must use identical model) |
| `services/indexer/source_mapper.py` | `rag-service` | Added `doc` and `source_code` inclusion patterns; extended exclusion list |
| `services/indexer/chunker.py` | `rag-service` | Added `doc` strategy (sliding window 512/50) and `source_code` strategy (tree-sitter AST, fallback to sliding window) |
| `services/rag_server/server.py` | `rag-service` | New `POST /query` REST endpoint; bound server to `0.0.0.0`; migrated `client.search()` → `client.query_points()` |
| `agent-runtime/src/bootstrap/fetch-rag-context.ts` | `workflow` | New helper — POSTs to `POST /query`, returns formatted `## RAG Context` block; returns `""` on any failure, never throws |
| `agent-runtime/src/main.ts` | `workflow` | Pre-injects RAG context between `generateAgentContext()` and `runClaude()` using `MCP_RAG_URL` as the switch |
| `requirements.txt` | `rag-service` | Added `tree-sitter>=0.23.0`, `tree-sitter-python`, `tree-sitter-typescript`, `tree-sitter-go` |

### Source code chunking strategy

AST-aware via tree-sitter: each top-level function, class, and method becomes its own chunk, prefixed with `# file: <path>` and `# class: <ClassName>` for context. Falls back to sliding window (512/50) for unsupported languages or parse failures. Very large nodes (>6000 chars) are split within the node body, each sub-chunk prefixed with the function signature.

### Runtime pre-injection flow

```
generateAgentContext(task, featureId, ...) → baseAgentContext (string)
  ↓
fetchRagContext(MCP_RAG_URL, "${task.title} ${featureId}", workspaceId)
  → POST ${MCP_RAG_URL}/query
  → on success: "## RAG Context\n\n<chunk>\n---\n..." block
  → on any failure: "" (log warning, never throw)
  ↓
agentContext = baseAgentContext + "\n\n" + ragBlock
  ↓
runClaude({ agentContext, ... })
```

`MCP_RAG_URL` is the single switch. If unset, behaviour is identical to pre-v2. The MCP tool registration is unchanged — agents can still call `rag_query` mid-task for follow-up queries.

---

## Operational notes

### One-time migration required (already applied)

The model upgrade from 384-dim to 768-dim requires dropping and recreating the Qdrant collection. Procedure:
1. Stop indexer
2. `DELETE /collections/{workspace_id}` on Qdrant REST API
3. Deploy new indexer image
4. Indexer recreates collection at 768-dim and re-indexes all content on first run

This was performed as part of T1 deployment.

### Deployment order

1. Deploy `rag-service` (T1→T2→T3→T4 are merged; rebuild containers)
2. Run collection migration if not already done
3. Deploy `workflow` agent-runtime (T5 merged; rebuild agent container)
4. Verify `MCP_RAG_URL` is set in agent environment — pre-injection is a no-op without it

### First indexer run after deployment

Cold start: the indexer performs a full re-index on first run (no prior `_last_commit`). Content is available within one poll cycle (~5 min). Brief window between collection recreation and re-index completion returns empty results — graceful degradation applies.

---

## Key design decisions

**D1 — Runtime pre-injection over skill enforcement:**
The original design relied on `start-implementation` instructing the model to call `rag_query`. Telemetry showed 0 calls across all sessions — graceful-degradation language gave the model cover to skip it. Pre-injection from the runtime removes model agency from the equation entirely.

**D2 — `MCP_RAG_URL` as the only switch:**
No new env var required. If RAG is configured (MCP_RAG_URL set), pre-injection is active. If not set, behaviour is unchanged. This keeps the deployment diff minimal.

**D3 — `POST /query` REST endpoint alongside MCP/SSE:**
The rag-server already exposes retrieval via FastMCP/SSE. The REST endpoint is a thin wrapper around the same internal function — no duplicate retrieval logic. This decouples the runtime fetch from the MCP protocol, which requires an active SSE session.

**D4 — AST chunking, not sliding window for source code:**
Sliding window arbitrarily splits functions mid-body, producing chunks with no signature context. AST chunking produces semantically complete units. The fallback to sliding window on parse failure ensures robustness.

**D5 — `BAAI/bge-base-en-v1.5` over `all-MiniLM-L6-v2`:**
The original model was trained on prose. Adding source code to the index with a prose-only model would produce poor retrieval for code queries. `bge-base-en-v1.5` handles both. The 768-dim dimension change required a one-time collection migration.

---

## What is NOT done (out of scope)

- **Hybrid search (dense + BM25 sparse):** Qdrant 1.9+ supports sparse vectors for exact identifier lookup. Currently dense-only. Planned for agent-rag-v3.
- **Event-driven indexer trigger:** Indexer still polls on a fixed interval (~5 min). A `POST /trigger` endpoint is designed but not implemented. Fresh context after a task push has up to 5-min lag. Planned for agent-rag-v3.
- **Episodic / decision memory:** Agent task logs are indexed as `task_log` chunks but there is no structured episodic memory layer. Cross-session recall of decisions and outcomes is not yet supported.
- **Integration tests requiring live Qdrant:** 9 integration tests are skipped in CI (require a running Qdrant instance). Unit coverage is complete; integration tests require a live stack.
- **`pr-create` skill registration in agent container:** The agent stalled on T5 because the `pr-create` skill was not available via the `Skill` tool inside the container. The SKILL.md file exists at `/agent/workflow/workflow_skills/pr-create/SKILL.md` but is not wired into the container's Claude settings. Needs a separate fix.

---

## PRs delivered

| Task | Repo | PR |
|---|---|---|
| T1 — Schema + model upgrade | rag-service | [#7](https://github.com/tiendv89/rag-service/pull/7) |
| T2 — Docs folder indexing | rag-service | [#8](https://github.com/tiendv89/rag-service/pull/8) |
| T3 — Source code indexing (AST) | rag-service | [#9](https://github.com/tiendv89/rag-service/pull/9) |
| T4 — REST query endpoint | rag-service | [#10](https://github.com/tiendv89/rag-service/pull/10) |
| T5 — Runtime pre-injection | workflow | [#49](https://github.com/tiendv89/agent-workflow/pull/49) |
