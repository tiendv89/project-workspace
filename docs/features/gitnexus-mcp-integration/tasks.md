# Task Breakdown — GitNexus Code-Graph MCP Integration

**Feature status:** `in_tdd` | **Tasks stage:** `draft` | Machine state lives in `tasks/T<n>.yaml`.

---

## Index

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | Remove source_code indexing from RAG | — |
| T2 | 1 | Build gitnexus-indexer service | — |
| T3 | 2 | Build gitnexus-server service | T2 |
| T4 | 3 | Wire GITNEXUS_MCP_URL into executor and docker-compose | T3 |
| T5 | 4 | Add gitnexus-mcp technical skill and shared usage rule | T4 |

---

## T1 — Remove source_code indexing from RAG

### Description
Remove the `source_code` file type from the RAG indexer so that `.py`, `.ts`, `.tsx`, `.js`, and `.go` files are no longer ingested into Qdrant. Code queries are handled by GitNexus going forward; keeping code chunks in RAG is dead weight that never surfaces in agent results.

Changes are confined to `rag-service`:
- `services/indexer/source_mapper.py` — remove the `source_code` pattern from `_PATTERNS` (one line)
- `services/indexer/chunker.py` — remove `_EXT_TO_LANGUAGE`, `_FUNCTION_NODE_TYPES`, `_CLASS_NODE_TYPES`, `_METHOD_NODE_TYPES`, and the Tree-sitter chunking branches that are now unreachable
- Tests — update `tests/indexer/test_source_mapper.py` and `tests/indexer/test_chunker.py` to remove source_code coverage; confirm no test references the removed code paths
- Verify existing Qdrant collection cleanup path: check whether `FORCE_REINDEX=1` or an equivalent env flag exists to wipe stale `source_code` vectors on next indexer restart; document the operational step in the PR description if a manual collection wipe is needed

### Required skills
- python-best-practices

### Subtasks
- [ ] Remove `(re.compile(r"\.(py|ts|tsx|js|go)$"), "source_code", None)` from `_PATTERNS` in `source_mapper.py`
- [ ] Remove `_EXT_TO_LANGUAGE`, `_FUNCTION_NODE_TYPES`, `_CLASS_NODE_TYPES`, `_METHOD_NODE_TYPES` constants from `chunker.py`
- [ ] Remove Tree-sitter AST chunking branches (`_infer_language`, `_chunk_by_ast`, related helpers) from `chunker.py`
- [ ] Update `test_source_mapper.py` — remove `source_code` test cases
- [ ] Update `test_chunker.py` — remove AST chunking test cases
- [ ] Check for `FORCE_REINDEX` flag or equivalent; document stale-vector cleanup in PR description
- [ ] Run full test suite — all tests pass

---

## T2 — Build gitnexus-indexer service

### Description
Create the `gitnexus-indexer` service in the new `git-nexus` repo. This is a Node.js process that reads `workspace.yaml` to discover repos, clones or pulls each one, runs `gitnexus analyze` on each, and repeats on a configurable poll interval. The index is written to `/gitnexus-data` (a named Docker volume shared with `gitnexus-server`).

Structure under `git-nexus/services/gitnexus_indexer/`:
- `index.js` (or TypeScript) — main loop: read workspace.yaml → clone/pull repos → `npx gitnexus@latest analyze <path>` → sleep → repeat
- `Dockerfile` — `node:lts` base; installs `gitnexus` globally or via npx; mounts `/gitnexus-data` as `HOME`
- `docker-compose.yml` (or addition to root compose) — service definition with `WORKSPACE_YAML_PATH`, `SSH_PRIVATE_KEY`, `GITNEXUS_POLL_INTERVAL_SECONDS`, volume mount `gitnexus-data:/gitnexus-data`
- `.env.example` — document required env vars

Key env vars:
- `WORKSPACE_YAML_PATH` — path to workspace.yaml inside the container
- `SSH_PRIVATE_KEY` — for cloning private repos
- `GITNEXUS_POLL_INTERVAL_SECONDS` — default 300

### Required skills
- backend-engineer

### Subtasks
- [ ] Scaffold `git-nexus` repo structure: `services/gitnexus_indexer/`, `README.md`
- [ ] Implement workspace.yaml reader — parse `repos[].github` and `repos[].id`
- [ ] Implement clone/pull loop with SSH key injection (same pattern as RAG indexer)
- [ ] Run `npx gitnexus@latest analyze <repo_path>` with `HOME=/gitnexus-data`
- [ ] Implement poll loop with `GITNEXUS_POLL_INTERVAL_SECONDS`
- [ ] Emit structured JSON log events: `gitnexus_analyze_start`, `gitnexus_analyze_done`, `gitnexus_analyze_failed`
- [ ] Write `Dockerfile` — `node:lts` base, install deps, set `HOME=/gitnexus-data`
- [ ] Write `docker-compose.yml` with `gitnexus-data` named volume
- [ ] Write `.env.example`
- [ ] Run locally and confirm index appears under `/gitnexus-data/.gitnexus/`

---

## T3 — Build gitnexus-server service

### Description
Create the `gitnexus-server` service in the `git-nexus` repo. This is a Python/FastMCP service that proxies `gitnexus mcp` (stdio) over SSE, using the same `mcp` package and `FastMCP.as_proxy` pattern as the existing `rag-server`.

Structure under `git-nexus/services/gitnexus_server/`:
- `server.py` — FastMCP proxy wrapping `npx gitnexus@latest mcp` as a stdio subprocess
- `main.py` — uvicorn entrypoint, same shape as `rag-server/main.py`
- `Dockerfile` — `node:lts` base + Python layer; installs `mcp`, `uvicorn`
- Addition to `docker-compose.yml` — service definition with port `:8002`, volume mount `gitnexus-data:/gitnexus-data`, `depends_on: gitnexus-indexer`
- Health-check: poll whether `~/.gitnexus/registry.json` exists before starting; retry with backoff if indexer hasn't finished

The `gitnexus-server` is stateless — it reads the pre-built index from the shared volume but owns no data.

### Required skills
- python-best-practices

### Subtasks
- [ ] Add `mcp>=1.0.0`, `uvicorn[standard]` to `requirements.txt`
- [ ] Implement `server.py` using `FastMCP.as_proxy(StdioServerParameters(command="npx", args=["-y", "gitnexus@latest", "mcp"]))` with `HOME=/gitnexus-data`
- [ ] Implement startup health-check: wait for `/gitnexus-data/.gitnexus/registry.json` with retries
- [ ] Implement `main.py` — uvicorn on `0.0.0.0:8002`
- [ ] Write `Dockerfile` — `node:lts` base, install Python + pip deps, set `HOME=/gitnexus-data`
- [ ] Add `gitnexus-server` service to `docker-compose.yml` with `depends_on: gitnexus-indexer`
- [ ] Expose `/sse` endpoint; verify Claude Code can connect via `--mcp-config`
- [ ] Manual smoke test: start both services, run `gitnexus query` via MCP and confirm results

---

## T4 — Wire GITNEXUS_MCP_URL into executor and docker-compose

### Description
Update the `workflow` repo to register `gitnexus-server` as a second MCP server in the executor's MCP config, and surface the new env var through the docker-compose template and `.env.example`.

Files to change:
- `runtime/executors/claude/src/index.ts` — read `GITNEXUS_MCP_URL`; if set, add `gitnexus` SSE entry to the MCP config; update the `if` condition guard and the header comment block
- `runtime/orchestrator/templates/docker-compose.yml` — add `GITNEXUS_MCP_URL: "${GITNEXUS_MCP_URL:-}"` to the base anchor (`x-agent`) and all three agent overrides (agent-1, agent-2, agent-3)
- `runtime/orchestrator/templates/.projects/.env.example` — add `# GITNEXUS_MCP_URL=http://gitnexus-server:8002` with a comment

No `GITNEXUS_ENABLED` flag — presence of `GITNEXUS_MCP_URL` enables it, absence disables it. Identical pattern to `MCP_RAG_URL`.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Read `GITNEXUS_MCP_URL` from `process.env` alongside `MCP_RAG_URL` in `index.ts`
- [ ] Add `gitnexus` SSE entry to MCP config when `gitnexusMcpUrl` is set: `{ type: "sse", url: \`${gitnexusMcpUrl}/sse\` }`
- [ ] Update `if (mcpRagUrl || figmaToken)` guard to include `|| gitnexusMcpUrl`
- [ ] Update header comment block in `index.ts` to document `GITNEXUS_MCP_URL`
- [ ] Add `GITNEXUS_MCP_URL` to base anchor and agent-1/2/3 environment blocks in `docker-compose.yml`
- [ ] Add commented `GITNEXUS_MCP_URL` entry to `.env.example` with description
- [ ] Run TypeScript type-check and existing tests

---

## T5 — Add gitnexus-mcp technical skill and shared usage rule

### Description
The gitnexus infrastructure (indexer + server + executor wiring) is fully deployed by T4, but agents receive no instruction to use the MCP tools it exposes. Without this task the feature delivers working infrastructure that has zero behavioural effect — agents will continue reading files and grepping instead of querying the code graph.

Two changes are required, both in the `workflow` repo:

**1. New technical skill: `technical_skills/gitnexus-mcp/SKILL.md`**

Document the 16 tools exposed by `mcp__gitnexus__*` and define when agents should reach for each:

| Tool | When to use |
|---|---|
| `query` | Finding where a symbol, function, or pattern is defined or used |
| `context` | Full 360° view of a symbol — callers, callees, type refs, process participation |
| `impact` | Blast-radius analysis before a refactor or deletion |
| `detect_changes` | Map a git diff to the symbols and processes it affects |
| `list_repos` | Discover which repos are indexed |
| `group_query` | Cross-repo execution flow tracing |

Lookup priority rule (mirrors the RAG-first pattern):
1. Use `mcp__gitnexus__query` or `mcp__gitnexus__context` first for structural code lookups
2. Fall back to `grep`/`Read` only when gitnexus returns no results or the MCP is unavailable
3. Never open an entire file just to find a symbol when gitnexus can answer it directly

**2. Common rule in `CLAUDE.shared.md`**

Add a "GitNexus-first code search rule" block alongside the existing RAG-first read rule:

- When `mcp__gitnexus__*` tools are available, use them for structural code lookups (find references, trace calls, get symbol definitions, compute blast radius) before opening files
- Exceptions: targeted line-range edits where the exact path is already known; config/lock/generated files; when the gitnexus MCP is unavailable for the run

After editing `CLAUDE.shared.md`, run `sync-workspace-rules` to propagate the change into `CLAUDE.md`.

### Required skills
- go-best-practices

### Subtasks
- [ ] Create `technical_skills/gitnexus-mcp/SKILL.md` with tool reference table and lookup priority rule
- [ ] Add "GitNexus-first code search rule" block to `CLAUDE.shared.md`
- [ ] Run `sync-workspace-rules` to propagate into `CLAUDE.md`
- [ ] Verify `CLAUDE.md` contains the new rule after sync
