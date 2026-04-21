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

1. **Index `docs/` folder content** — all Markdown files under `docs/` in every registered repo are queryable at task claim time and mid-task
2. **Index source code** — implementation files are indexed so agents can retrieve concrete patterns, function signatures, interfaces, and conventions without traversing the filesystem
3. **Agents stop re-discovering** — an agent claiming a task should be able to answer "how does this codebase handle X?" from the index, not from grep iterations
4. **Best possible retrieval quality** — the technical design should choose whatever stack, architecture, and retrieval strategy produces the best agent outcomes; v1 choices are a reference point, not a constraint

## Non-goals

- Not indexing generated code, vendored dependencies (`node_modules/`, `vendor/`), build artifacts, `.env` files, secrets, or binaries

## Success criteria

- An agent querying "how does this codebase handle auth?" receives source code chunks, not just spec text
- An agent querying about docs content receives indexed doc content
- Agents measurably spend fewer iterations on discovery work before producing useful output
- The system handles large codebases without timing out or memory issues
