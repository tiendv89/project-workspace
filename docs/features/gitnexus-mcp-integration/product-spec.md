# Product Specification

## Feature
- Feature ID: `gitnexus-mcp-integration`
- Title: GitNexus Code-Graph MCP Integration

## Problem
The current RAG stack (Qdrant + rag-server) provides good context retrieval for prose documents, workspace YAML, and markdown — but gives agents weak cross-file code intelligence. Agents cannot reliably answer "what calls X", "what breaks if I change this interface", or "trace the execution path from this entry point." This forces agents to do expensive full-file reads and often miss inter-file relationships entirely, leading to incomplete implementations and unnecessary blocked states.

## Goals
- Wire [GitNexus](https://github.com/abhigyanpatwari/GitNexus) as a second MCP server alongside the existing `rag-server`, scoped to implementation repos only.
- Give agents access to code-graph tools: symbol lookup, call graph traversal, impact analysis, and change detection.
- Remove source code file indexing from the RAG stack — code queries are handled by GitNexus; RAG is scoped to prose, YAML, and documentation only.
- Make the integration opt-in per deployment (env flag) so existing stacks are unaffected.

## Non-goals
- Replacing the existing Qdrant/RAG stack — this is additive; RAG continues to serve non-code content.
- Incremental/live reindexing during a task run (GitNexus does not support this today).
- Supporting all 14 GitNexus languages — TypeScript and Python are the priority.
- Commercial GitNexus features (auto-reindex, multi-repo graphs, PR review).
