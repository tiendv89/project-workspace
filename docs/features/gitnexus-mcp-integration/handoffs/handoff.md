# Handoff — GitNexus Code-Graph MCP Integration

**Feature:** `gitnexus-mcp-integration`
**Date:** 2026-05-07
**Author:** matthew@swellnetwork.io

---

## What was built

Agents now have structural code intelligence via GitNexus, a persistent code-graph sidecar that runs alongside the existing RAG stack. Agents can look up symbol definitions, trace call graphs, and compute blast radius of changes without full-file reads or expensive grep scans.

As part of this feature, source code was also removed from the RAG index — it was never surfacing in retrieval results and was adding indexing noise.

### Task summary

| Task | Title | Repo | PR | Status |
|---|---|---|---|---|
| T1 | Remove source_code indexing from RAG | rag-service | [#12](https://github.com/tiendv89/rag-service/pull/12) | merged |
| T2 | Build gitnexus-indexer service | git-nexus | [#1](https://github.com/tiendv89/git-nexus/pull/1) | merged |
| T3 | Build gitnexus-server service | git-nexus | [#2](https://github.com/tiendv89/git-nexus/pull/2) | merged |
| T4 | Wire GITNEXUS_MCP_URL into executor and docker-compose | workflow | [#83](https://github.com/tiendv89/agent-workflow/pull/83) | merged |
| T5 | Add gitnexus-mcp skill, shared usage rule, and query audit | workflow | [#84](https://github.com/tiendv89/agent-workflow/pull/84) | merged |

---

## Architecture

Two new long-lived Docker services were added to `docker-compose.yml`, following the same sidecar pattern as the RAG stack:

```
gitnexus-indexer   — clones/pulls all workspace repos on startup and on a
                     polling interval, runs gitnexus analyze, writes the
                     code-graph index to a named volume: gitnexus-data

gitnexus-server    — wraps gitnexus mcp (stdio) in an HTTP/SSE transport,
                     reads the pre-built index from gitnexus-data,
                     exposes MCP tools over SSE at :8002
```

Agents connect via `GITNEXUS_MCP_URL` — same pattern as `MCP_RAG_URL`.

---

## New MCP tools available to agents

| Tool | Purpose |
|---|---|
| `mcp__gitnexus__query` | Locate symbol definitions, classes, functions across the indexed repos |
| `mcp__gitnexus__context` | Get callers, callees, and type relationships for a symbol |
| `mcp__gitnexus__impact` | Compute blast radius before a refactor or deletion |
| `mcp__gitnexus__detect_changes` | Map a git diff or changed file list to affected symbols |
| `mcp__gitnexus__list_repos` | Discover which repos are indexed |
| `mcp__gitnexus__group_query` | Trace execution flows across multiple indexed repos |

---

## New skill and usage rule

The `gitnexus-mcp` skill (`technical_skills/gitnexus-mcp/SKILL.md`) was added to the workflow repo. It provides agents with lookup-order instructions: use GitNexus first for structural questions, fall back to grep/Read only when GitNexus returns no results or the MCP is unavailable.

The **GitNexus lookup priority rule** was added to `CLAUDE.shared.md` and propagated to `CLAUDE.md` via `sync-workspace-rules`. This rule applies in both interactive sessions and agent runtime.

---

## Query audit

A `gitnexus-audit.ts` module (mirroring `rag-audit.ts`) was added to the executor. It emits `gitnexus_query` events to the orchestrator for observability. These events record query text, result count, and latency — the same schema as `rag_query` events.

---

## Operator setup

### Required env var

Add to each agent's environment (`.env` or `docker-compose.yml`):

```
GITNEXUS_MCP_URL=http://gitnexus-server:8002/sse
```

The executor will only mount the GitNexus MCP server when this variable is set. If unset, the executor runs without GitNexus — no error, just no code-graph tools.

### RAG cleanup (one-time)

Stale `source_code` chunks remain in Qdrant from before T1 was merged. Clear them by restarting the indexer with `FORCE_REINDEX=1`:

```bash
docker compose stop indexer
FORCE_REINDEX=1 docker compose up indexer
```

Or drop and recreate the Qdrant collection directly if `FORCE_REINDEX` is not supported by the current indexer version.

---

## What's not included

- **Incremental indexing for GitNexus**: GitNexus has no incremental mode — a full re-analyze runs on every poll. This is acceptable at current repo sizes but will become a concern if repos grow significantly.
- **GitNexus for non-TS/Python repos**: coverage for Go, Rust, etc. is not verified. Agents should fall back to grep for those languages until confirmed.

---

## Cost

| Task | Input tokens | Output tokens | Cost (USD) |
|---|---|---|---|
| T3 | 384 | 54,725 | $0.82 |
| T4 | 412 | 50,009 | $0.75 |
| T5 | 310 | 35,529 | $0.53 |
| **Total** | **1,106** | **140,263** | **$2.10** |

T1 and T2 costs not recorded in task logs.
