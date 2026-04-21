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

## Non-goals

- Not adding a second MCP tool or splitting the backend
- Not changing the `workspace_id` isolation model
- Not indexing new content types (that was v2)

## Dependency

**agent-rag-v2 must be fully deployed** before v3 begins. v3 adds a sparse vector field to the collection, which requires dropping and recreating it — the same one-time migration pattern used in v2.

## Success criteria

- `rag_query("AuthService.validate_token", workspace_id=...)` returns the correct function chunk in position 1 or 2
- Semantic queries ("how does auth work?") return results of equal or better quality compared to v2
- No change to the `rag_query` tool signature or return shape
