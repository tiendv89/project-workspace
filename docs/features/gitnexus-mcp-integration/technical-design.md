# Technical Design

## Feature
- Feature ID: `gitnexus-mcp-integration`
- Title: GitNexus Code-Graph MCP Integration

---

## Current State

### RAG stack
The RAG stack has three services that run as long-lived Docker containers:
- `qdrant` — vector database, persistent named volume
- `rag-server` — MCP server over SSE, agents connect via `MCP_RAG_URL`
- `indexer` — reads `workspace.yaml`, clones all repos, watches for changes, upserts chunks into Qdrant

The indexer classifies files via `services/indexer/source_mapper.py`. It currently indexes source code under the `source_code` type (`.py`, `.ts`, `.tsx`, `.js`, `.go`) using Tree-sitter to chunk by function/class boundaries.

### Executor MCP config
`runtime/executors/claude/src/index.ts` builds an MCP config and passes it to `claude --mcp-config`. Currently supports:
- `rag-server` — SSE transport, `MCP_RAG_URL` env var
- `figma` — stdio transport, `FIGMA_PERSONAL_ACCESS_TOKEN` env var

### Gap
Agents have no structural code intelligence. RAG chunks code by syntax node but retrieval is semantic — it cannot answer "what calls X", trace an execution path, or compute blast radius of a change. In practice, code chunks score poorly against natural-language task queries and almost never surface in results.

---

## Part 1 — Remove Source Code from RAG

### Change
Single line removal in `rag-service/services/indexer/source_mapper.py`:

```python
# Remove this line from _PATTERNS:
(re.compile(r"\.(py|ts|tsx|js|go)$"), "source_code", None),
```

The `_EXT_TO_LANGUAGE` table and Tree-sitter chunking logic in `chunker.py` become unreachable — they can be removed in the same PR as dead code cleanup, but are not required for correctness.

### Effect
- The indexer stops ingesting source code on the next poll cycle.
- Existing `source_code` chunks in Qdrant are **not automatically deleted** — a one-time re-index or Qdrant collection wipe is needed to clean stale vectors. This can be done by restarting the indexer with `FORCE_REINDEX=1` if that flag exists, or by dropping and recreating the Qdrant collection.
- No changes to `rag-server`, `qdrant`, or the executor.

### Risk
Low. If code was never surfacing in RAG results it was never influencing agent behaviour. The only risk is the cleanup of stale vectors, which is operational not functional.

---

## Part 2 — GitNexus as a Persistent Sidecar

### The problem with per-task execution
Running `gitnexus analyze <repo>` inside the executor on every task start would cost 30–120s of full re-analysis on every task regardless of how much changed. GitNexus has no incremental indexing, so even a one-line commit triggers a full re-parse. This is the same mistake the RAG stack would make if it re-indexed everything on every task rather than watching for changes.

### Architecture: two new services in `docker-compose.yml`

Following the same pattern as `qdrant` + `rag-server` + `indexer`:

```
gitnexus-indexer   — clones/pulls all workspace repos, runs gitnexus analyze
                     on startup and on a polling interval, writes index to a
                     named volume: gitnexus-data

gitnexus-server    — wraps `gitnexus mcp` (stdio) in an HTTP/SSE transport,
                     reads the pre-built index from the same named volume,
                     exposes MCP tools over SSE at :8002
```

Agents connect via a new env var `GITNEXUS_MCP_URL` — same pattern as `MCP_RAG_URL`.

### Why HTTP/SSE wrapper rather than mounting the volume into executors

The executor could mount `gitnexus-data` and run `gitnexus mcp` as a local stdio process. This would work, but:
- Every executor container needs the volume mounted — docker-compose change and complexity on every new executor config.
- Multiple concurrent agents each spawn their own stdio process against the same volume — no coordination.
- Inconsistent with how `rag-server` works; agents would need different MCP config logic for "SSE servers" vs "stdio servers with pre-mounted volumes".

An HTTP/SSE wrapper keeps the pattern uniform: all MCP servers are SSE endpoints, all agents connect the same way, the executor needs no volume mounts.

### `gitnexus-indexer` design

Reads `workspace.yaml` to discover repos (same as the RAG indexer). For each repo:
1. Clone or pull to a local working directory (e.g. `/gitnexus-index/repos/<repo_id>`)
2. Run `npx gitnexus@latest analyze /gitnexus-index/repos/<repo_id>`
3. Repeat on a configurable poll interval (default: same as `INDEXER_POLL_INTERVAL_SECONDS`)

The `gitnexus analyze` command writes its index to `~/.gitnexus/` by default. We set `HOME=/gitnexus-data` in the container so the index lands on the named volume instead of the container's ephemeral filesystem.

### `gitnexus-server` design

A new Python service inside `rag-service` (`services/gitnexus_server/`), using the same stack as `rag-server`: `FastMCP` from the official `mcp` package, served over SSE via Starlette/uvicorn.

`FastMCP` supports proxying an existing MCP stdio server directly — it connects to the subprocess and re-exposes its tools over SSE with no manual JSON-RPC wiring:

```python
from mcp.server.fastmcp import FastMCP
from mcp.client.stdio import StdioServerParameters

mcp_server = FastMCP.as_proxy(
    StdioServerParameters(command="npx", args=["-y", "gitnexus@latest", "mcp"])
)
```

On each tool call, FastMCP spawns `gitnexus mcp` (with `HOME=/gitnexus-data` so it reads the shared index volume), forwards the call, and returns the result. The service is stateless — it owns no index data.

Same Dockerfile base image, same `requirements.txt`, same docker-compose service shape as `rag-server`. Exposes on `:8002`.

### Startup ordering
```
gitnexus-indexer  (runs analyze on all repos, writes to gitnexus-data volume)
       ↓
gitnexus-server   (starts once index exists, depends_on: gitnexus-indexer)
       ↓
agents            (connect via GITNEXUS_MCP_URL=http://gitnexus-server:8002)
```

`gitnexus-server` should health-check whether the index exists before starting, and retry with backoff if `gitnexus-indexer` hasn't finished yet.

### Executor changes
Add `GITNEXUS_MCP_URL` alongside `MCP_RAG_URL` in `index.ts`:

```typescript
const gitnexusMcpUrl = process.env.GITNEXUS_MCP_URL;
// ...
if (gitnexusMcpUrl) {
  mcpConfig.mcpServers["gitnexus"] = { type: "sse", url: `${gitnexusMcpUrl}/sse` };
}
```

No per-task indexing. No `GITNEXUS_ENABLED` flag needed — presence of `GITNEXUS_MCP_URL` enables it, absence disables it. Same pattern as `MCP_RAG_URL`.

---

## Affected Repos

| Repo | Change |
|---|---|
| `rag-service` | Remove `source_code` from `source_mapper._PATTERNS` + dead code cleanup in `chunker.py`; add `gitnexus-indexer` and `gitnexus-server` services under `services/` |
| `workflow` | Add `GITNEXUS_MCP_URL` to executor `index.ts` MCP config; add env var and new services to docker-compose template and `.env.example` |

## Dependency Analysis
- Part 1 (RAG cleanup) has no dependencies. Can ship independently.
- Part 2 (GitNexus services) depends on Part 1 being complete only for clean separation; technically independent.
- The `gitnexus-server` bridge depends on `@modelcontextprotocol/sdk` being available in the new service.

## Parallelization / Blocking Analysis
- Part 1 (rag-service change): single task, one PR.
- Part 2 (gitnexus-indexer + gitnexus-server): can be one task (same service repo) or split if the services are developed independently.
- Executor change (workflow repo): unblocked, can run in parallel with Part 2.
