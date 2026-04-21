# Product Specification

## Feature
- Feature ID: `agent-rag-v2`
- Title: Agent RAG v2 — Source Code + Docs Indexing

## Problem

v1 (agent-rag-mcp) built the RAG infrastructure and indexed skills, product specs, technical designs, task logs, CLAUDE.md, and top-level READMEs. Two important content categories were deliberately excluded as a conservative v1 scoping call:

1. **The `docs/` folder** — repositories often contain architecture docs, ADRs, guides, and reference material under `docs/`. These are not indexed, so agents cannot retrieve them and must navigate the filesystem manually to find them.

2. **Source code** — agents still start each task by re-discovering implementation patterns through grep and file reads. Without source code in the index, questions like "how does this codebase handle retries?", "what is the pagination interface?", or "is there an existing helper for X?" cannot be answered by RAG — the agent must spend iterations doing cold discovery before producing useful output.

The core hypothesis is: **an agent that cannot retrieve from the codebase it is editing cannot meaningfully improve its output quality over time.** Skills and specs describe intent; source code describes reality. The gap between them is where agent errors originate.

## Goals

1. **Index `docs/` folder content** — all Markdown files under `docs/` in every registered repo are indexed with `source_type: doc`, making architecture docs, ADRs, guides, and reference material queryable at task claim time and mid-task
2. **Index source code** — implementation files (`.py`, `.ts`, `.go`, `.tsx`, etc.) are chunked and indexed so agents can retrieve concrete patterns, function signatures, interfaces, and conventions without traversing the filesystem
3. **Noise control** — source code indexing must not degrade retrieval quality for existing source types; chunk strategy and file filtering must keep signal-to-noise ratio acceptable
4. **No re-architecture** — extend the existing v1 stack (Qdrant, indexer, rag-server, `workspace_id` isolation) rather than replacing it; v2 is additive

## Non-goals

- Not replacing grep/file reads — RAG supplements direct lookup, it does not replace it
- Not indexing generated code, vendored dependencies (`node_modules/`, `vendor/`), or build artifacts
- Not changing the Qdrant schema, MCP tool contract, or claim-time injection flow from v1
- Not re-indexing the entire history on every cycle — incremental indexing from v1 must continue to work

## Success criteria

- An agent querying "how does this codebase handle auth?" receives source code chunks, not just spec text
- An agent querying "what is in docs/architecture/" receives indexed doc content
- Retrieval quality for existing source types (skills, specs, task logs) is not degraded
- The indexer handles repos with large codebases without timing out or producing memory issues
- `.env` files, secrets, `node_modules/`, `vendor/`, and binary files are never indexed
