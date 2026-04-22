# Product Specification

## Feature
- Feature ID: `agent-rag-v3`
- Title: Agent RAG v3 — Hybrid Search, Event-Driven Indexing, and Episodic Memory

## Problem

v2 (agent-rag-v2) indexes source code, docs, and all existing content types using `BAAI/bge-base-en-v1.5` (768-dim dense vectors). Dense semantic search works well for prose questions ("how does this codebase handle retries?") but scores poorly for exact identifier lookup ("find `AuthService.validate_token`") — the query and the answer use the same tokens, but cosine similarity across a high-dimensional space may rank semantically unrelated chunks higher.

This is the gap Hermes Agent's FTS5 approach addresses: keyword-exact and BM25-ranked retrieval is fundamentally better for precise lookup. The v3 goal is to absorb that insight into the existing Qdrant stack rather than adding a second backend.

## Goals

1. **Hybrid search** — add a BM25 sparse vector field to the Qdrant collection alongside the existing dense field; at query time combine both via Reciprocal Rank Fusion (RRF) in a single `rag_query` call
2. **No agent-facing changes** — the `rag_query` MCP tool contract is unchanged; agents get better results without knowing anything changed
3. **Exact identifier recall** — an agent querying a specific function name, class, or variable gets it back in the top results even if the semantic similarity score would have buried it
4. **Measurable improvement** — validate that retrieval precision for exact code lookups improves over the v2 dense-only baseline before declaring v3 complete
5. **Event-driven indexer trigger** — instead of the indexer polling on a fixed interval, the agent runtime signals the indexer immediately after a task branch is pushed; agents starting shortly after a completed task get fresh RAG context rather than stale index up to 5 minutes old
6. **Episodic memory** — agents append a decision summary to `agents/<id>/decisions.md` at task completion; the indexer picks it up automatically, giving future agents access to reasoning that would otherwise disappear when the session ends

## Memory gap context

> **Q: The current indexer already indexes technical docs — doesn't that cover our design decisions?**
>
> Yes, design-time knowledge is covered: product specs, technical designs, task logs, CLAUDE.md, and source code are all indexed. What is missing is delivery-time and conversational knowledge:
>
> - Agent sessions end with no summary of key decisions made — `log.jsonl` records actions but not reasoning ("chose X over Y because Z", "worked around bug W by doing V")
> - Human conversations that drive architectural decisions are never indexed — the only way they survive is if someone manually writes the outcome into a committed file
> - Each agent starts completely cold; two agents working on related features back-to-back share no learned context
>
> This is a new category not addressed by v2: **episodic/decision memory**.

> **Q: Why not defer episodic memory to v4 — isn't it out of scope?**
>
> The implementation is actually lightweight given what's already in place. The indexer already watches `agents/<id>/log.jsonl` — adding `agents/<id>/decisions.md` as an indexed path costs almost nothing on the indexer side. The main work is in the `start-implementation` and `pr-create` skills to write a summary at task completion. Hybrid search, event-driven triggering, and episodic memory touch different codebases and can be parallelized as separate workstreams within v3:
>
> - **Stream A**: hybrid search (rag-service: Qdrant schema, indexer, query logic)
> - **Stream B**: event-driven trigger (rag-service + agent runtime)
> - **Stream C**: episodic memory (agent skills write `decisions.md`; indexer watches it)

## Non-goals

- Not adding a second MCP tool or splitting the backend
- Not changing the `workspace_id` isolation model
- Not indexing PR review comments (low value given current PR review workflow)
- Not implementing automatic conversation capture (requires out-of-band tooling; discipline-based approach via `decisions.md` is sufficient)

## Dependency

**agent-rag-v2 must be fully deployed** before v3 begins. v3 adds a sparse vector field to the collection, which requires dropping and recreating it — the same one-time migration pattern used in v2.

## Success criteria

- `rag_query("AuthService.validate_token", workspace_id=...)` returns the correct function chunk in position 1 or 2
- Semantic queries ("how does auth work?") return results of equal or better quality compared to v2
- No change to the `rag_query` tool signature or return shape
- After an agent pushes a branch, the indexer re-indexes within seconds rather than waiting up to 5 minutes
- After an agent completes a task, `agents/<id>/decisions.md` exists in the management repo and is queryable via `rag_query`
