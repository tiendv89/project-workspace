# Product Specification

## Feature
- Feature ID: `agent-rag-v3`
- Title: Agent RAG v3 — Hybrid Search (Dense + BM25 Sparse)

## Problem

v2 (agent-rag-v2) indexes source code, docs, and all existing content types using `BAAI/bge-base-en-v1.5` (768-dim dense vectors). Dense semantic search works well for prose questions ("how does this codebase handle retries?") but scores poorly for exact identifier lookup ("find `AuthService.validate_token`") — the query and the answer use the same tokens, but cosine similarity across a high-dimensional space may rank semantically unrelated chunks higher.

This is the gap Hermes Agent's FTS5 approach addresses: keyword-exact and BM25-ranked retrieval is fundamentally better for precise lookup. The v3 goal is to absorb that insight into the existing Qdrant stack rather than adding a second backend.

## Goals

1. **Hybrid search** — add a BM25 sparse vector field to the Qdrant collection alongside the existing dense field; at query time combine both via Reciprocal Rank Fusion (RRF) in a single `rag_query` call
2. **No agent-facing changes** — the `rag_query` MCP tool contract is unchanged; agents get better results without knowing anything changed
3. **Exact identifier recall** — an agent querying a specific function name, class, or variable gets it back in the top results even if the semantic similarity score would have buried it
4. **Measurable improvement** — validate that retrieval precision for exact code lookups improves over the v2 dense-only baseline before declaring v3 complete
5. **Event-driven indexer trigger** — instead of the indexer polling on a fixed interval, the agent runtime signals the indexer immediately after a task branch is pushed; agents starting shortly after a completed task get fresh RAG context rather than stale index up to 5 minutes old

## Memory gap context

The current indexer already captures design-time knowledge well: product specs, technical designs, task logs, CLAUDE.md, and source code are all indexed. What is missing is **delivery-time and conversational knowledge**:

- Agent sessions end with no summary of key decisions made — `log.jsonl` records actions but not reasoning ("chose X over Y because Z", "worked around bug W by doing V")
- Human conversations that drive architectural decisions (like the ones that shaped this spec) are never indexed — the only way they survive is if someone manually writes the outcome into a committed file
- Each agent starts completely cold; two agents working on related features back-to-back share no learned context

The v2 indexer does **not** have this gap because it never claimed to cover it — v2 was about source content types. This is a new category: **episodic/decision memory**.

Addressing this fully (automatic session summarization, conversation capture) is out of scope for v3. However, the groundwork laid here — event-driven indexing and fresher context — makes a v4 episodic memory layer more tractable. The near-term mitigation is discipline: key decisions should be written into `technical-design.md` or a `decisions.md` file per feature so the indexer picks them up.

## Non-goals

- Not adding a second MCP tool or splitting the backend
- Not changing the `workspace_id` isolation model
- Not indexing new content types (that was v2)
- Not implementing automatic session summarization or conversation capture (deferred to v4)

## Dependency

**agent-rag-v2 must be fully deployed** before v3 begins. v3 adds a sparse vector field to the collection, which requires dropping and recreating it — the same one-time migration pattern used in v2.

## Success criteria

- `rag_query("AuthService.validate_token", workspace_id=...)` returns the correct function chunk in position 1 or 2
- Semantic queries ("how does auth work?") return results of equal or better quality compared to v2
- No change to the `rag_query` tool signature or return shape
