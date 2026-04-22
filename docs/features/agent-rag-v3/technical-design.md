# Technical Design

## Feature
- Feature ID: `agent-rag-v3`
- Title: Agent RAG v3 — Hybrid Search (Dense + BM25 Sparse)

## Current State

The v2 RAG stack consists of:
- **Qdrant** — vector store with a single dense field per chunk (`BAAI/bge-base-en-v1.5`, 768-dim)
- **rag-server** — FastMCP service exposing `rag_query` over HTTP/SSE; queries Qdrant with cosine similarity
- **indexer** — polls repos from `workspace.yaml` on a fixed interval (default 300s), embeds changed files, upserts into Qdrant

Limitations being addressed in v3:
1. Dense-only search misses exact identifier lookups
2. Pull-based indexer introduces up to 5-minute lag between a task push and available RAG context

---

## Change 1 — Hybrid Search (Dense + BM25 Sparse)

### Design

Add a second sparse vector field to the Qdrant collection using BM25 (via `qdrant-client`'s `SparseVector` support). At index time, compute both a dense embedding and a BM25 sparse vector for each chunk. At query time, issue a hybrid query combining both via Reciprocal Rank Fusion (RRF).

**Index changes (`indexer`):**
- Compute sparse BM25 vector alongside the existing dense embedding for every chunk
- Upsert both vectors in the same Qdrant point

**Query changes (`rag_server`):**
- Replace the current `query_points` dense-only call with a hybrid query using `qdrant_client.query_points` with `prefetch` on both vectors and RRF fusion

**Collection migration:**
- The sparse field must be declared at collection creation time — a one-time drop-and-recreate is required (same pattern as v2)
- Migration script: drop existing collection, recreate with `sparse_vectors_config`, re-index all content

**No changes to:**
- `rag_query` tool signature or return shape
- `workspace_id` isolation model
- Agent-side code

---

## Change 2 — Event-Driven Indexer Trigger

### Problem

The indexer currently wakes on a fixed poll interval. When an agent finishes a task and pushes a branch at minute 1, the next agent claiming a task may start at minute 2 — but won't get that fresh context until the indexer's next poll at minute 5+.

### Design

Add a lightweight HTTP trigger endpoint to the indexer (`POST /trigger`). After a successful `git push` in `pr-create` or `start-implementation`, the agent runtime calls this endpoint to wake the indexer immediately for the affected workspace.

**Indexer changes:**
- Add a `POST /trigger?workspace_id=<id>` endpoint (FastAPI, runs alongside the existing poll loop)
- On trigger: run one index cycle for the specified workspace immediately, outside the normal poll schedule
- The poll loop continues unchanged as a fallback — the trigger is additive, not a replacement

**Agent runtime changes (`pr-create` skill):**
- After `git push origin <branch>`, check for `INDEXER_TRIGGER_URL` env var
- If set, `POST ${INDEXER_TRIGGER_URL}/trigger?workspace_id=<workspace_id>`
- Fire-and-forget — if the call fails, log and continue; never block the PR flow

**Docker Compose changes:**
- Expose the indexer trigger port (e.g. `8001`)
- Add `INDEXER_TRIGGER_URL=http://indexer:8001` to agent environment

### Graceful degradation

If `INDEXER_TRIGGER_URL` is unset or the call fails, behavior is identical to v2 — the poll loop picks up changes on the next cycle. The trigger is purely an optimization.

---

## Dependency Analysis

- Change 1 (hybrid search) depends on `agent-rag-v2` being fully deployed (collection must exist before migration)
- Change 2 (event-driven trigger) is independent of Change 1 and can be implemented in parallel

## Parallelization / Blocking Analysis

| Task | Depends on | Can parallelize with |
|---|---|---|
| Add sparse vector indexing | v2 deployed | Trigger endpoint |
| Add hybrid query to rag_server | v2 deployed | Trigger endpoint |
| Collection migration script | Sparse indexing + hybrid query complete | — |
| Indexer trigger endpoint | Nothing | Hybrid search work |
| pr-create trigger call | Trigger endpoint | Hybrid search work |
