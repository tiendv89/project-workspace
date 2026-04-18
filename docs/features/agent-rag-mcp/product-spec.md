# Product Specification

## Feature
- Feature ID: `agent-rag-mcp`
- Title: Agent Context — RAG + MCP Integration

## Problem

Agents currently start every task cold. When an agent claims a task, its only context is:
- The task YAML (status, description, dependencies)
- The relevant `SKILL.md` files
- The raw implementation repo on disk

This means the agent spends its first several iterations doing discovery work — reading files, tracing imports, reconstructing conventions, understanding prior decisions — before it can produce useful output. That discovery burns tokens and iterations, increases per-task cost, and produces lower-quality output because context is often incomplete or missed entirely.

There is no mechanism for an agent to quickly answer questions like:
- "How does this codebase handle error responses?"
- "What decisions were made in prior tasks that affect this one?"
- "What patterns does this project use for authentication / data access / logging?"
- "What does the product owner consider in-scope for this feature?"

## Goals

1. **Fast project context delivery** — at claim time, the agent receives a relevant context summary derived from indexed project knowledge, not a blank slate
2. **On-demand retrieval during task execution** — the agent can query for additional context mid-task using an MCP tool, rather than exploring the codebase manually
3. **Index task history** — completed task logs (the `.jsonl` files now landing in the management repo) become a searchable record of past decisions and implementation patterns
4. **Index technical skills** — `SKILL.md` files are already used but only for declared skills; RAG allows surfacing relevant skills the agent didn't explicitly request
5. **Index codebase conventions** — docs, ADRs, README files, and key source files are indexed so agents share a consistent understanding of the project

## Non-goals

- Not replacing the existing task YAML / claim protocol — RAG is additive context, not a workflow replacement
- Not building a general-purpose RAG system — this is scoped to the agent-runtime workflow
- Not real-time indexing — batch/incremental indexing on push is acceptable for v1
- Not multi-tenant — single workspace per RAG instance for now

## Key open questions (to resolve in technical design)

1. **What to index?** Candidates: technical skill `SKILL.md` files, task logs (`.jsonl`), product specs and technical designs, codebase README / docs / ADRs, key source files. What is too noisy to include?
2. **Vector store choice** — embedded (ChromaDB, LanceDB) vs hosted (Pinecone, Weaviate). Embedded keeps infrastructure simple; hosted scales better. What's the right tradeoff at current scale?
3. **MCP server architecture** — standalone process the agent connects to, or embedded in agent-runtime? How does the agent discover it (env var, config)?
4. **Context injection point** — does RAG context land in the initial `agentContext` prompt, as a pre-loaded MCP resource, or both? What is the right chunk size / token budget for upfront context?
5. **Indexing trigger** — on git push to management repo, on task completion, on a schedule? Who owns the indexer process?
6. **Staleness** — how quickly does indexed content need to reflect new commits? Is a lag of minutes acceptable?

## Success criteria

- An agent claiming a task receives a context summary that reduces its cold-discovery iterations by a measurable amount
- The agent can invoke an MCP tool to retrieve relevant project context mid-task without navigating the filesystem manually
- Task logs from prior runs are searchable and surfaced when relevant
- Adding new indexed content (a new skill, a completed task log) requires no manual intervention
