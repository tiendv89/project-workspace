# Task Breakdown: Agent Context — RAG + MCP Integration

Feature status: `in_tdd` — technical design approved. Machine state lives in `tasks/T<n>.yaml`.

## Repo split

| Repo | Tasks | Notes |
|---|---|---|
| `rag-service` | T1, T2, T3, T7, T8 | New Python repo — RAG services (schema, indexer, MCP server) |
| `workflow` | T4, T5, T6 | Existing agent runtime repo — skill updates, Compose wiring, docs |

> **D1 blocker:** `rag-service` must be created and registered in `workspace.yaml -> repos[]` before T1 can begin. Human unblocks T1 after registration.

## Task index

| ID | Wave | Title | Repo | Depends on |
|---|---|---|---|---|
| T1 | 1 | Qdrant schema + collection init | `rag-service` | D1 |
| T2 | 2 | Indexer service | `rag-service` | T1 |
| T3 | 2 | RAG MCP server | `rag-service` | T1 |
| T4 | 3 | Agent claim-time context injection | `workflow` | T3 |
| T5 | 3 | Docker Compose + init-agent integration | `workflow` | T2, T3 |
| T7 | 4 | Move Dockerfile.rag to rag-service repo | `rag-service` | T5 |
| T8 | 4 | Replace REPO_PATHS with workspace.yaml-driven path resolution | `rag-service` | T2 |
| T6 | 5 | Documentation + operator guide | `workflow` | T4, T5, T7, T8 |

---

## T1 — Qdrant schema + collection init

### Description
Define the canonical payload schema for all documents indexed in Qdrant and write the collection initialisation code. This is the foundation every other task builds on — the indexer writes points to this schema; the MCP server queries against it. The schema must be frozen before T2 or T3 begin.

Deliverables:
- `services/shared/schema.py` (or equivalent) — payload dataclass with all required fields
- `services/shared/qdrant_init.py` — creates collections keyed by `workspace_id` if they don't exist; idempotent
- Unit tests: schema validation, `workspace_id` field presence enforcement, `must` filter correctness

Schema fields (from technical design):
```
workspace_id, source_type, source_path, feature_id, chunk_index, indexed_at
```

### Required skills
- python-best-practices

### Subtasks
- [ ] Define payload dataclass with all required fields
- [ ] Write `qdrant_init.py` — idempotent collection creation per workspace_id
- [ ] Enforce `workspace_id` presence on every upsert (raise if missing)
- [ ] Enforce `workspace_id` filter on every query (raise if missing)
- [ ] Unit tests for schema validation and filter enforcement

---

## T2 — Indexer service

### Description
A Python polling service that watches the management repo and workspace repos for changes, chunks documents, embeds them via `sentence-transformers/all-MiniLM-L6-v2`, and upserts points to Qdrant.

Polling interval is configurable (default 5 min). Uses `git pull` + changed-file detection to index only modified documents, not a full re-index on every cycle.

Sources to index (from technical design):
- `workflow/workflow_skills/*/SKILL.md` and `workflow/technical_skills/*/SKILL.md` → `source_type: skill`
- `docs/features/*/product-spec.md` → `source_type: product_spec`
- `docs/features/*/technical-design.md` → `source_type: technical_design`
- `agents/<id>/log.jsonl` → `source_type: task_log` (one chunk per log entry)
- `CLAUDE.md`, `CLAUDE.shared.md` → `source_type: claude_md`
- Top-level `README.md` per repo → `source_type: readme`

Not indexed: source code, `node_modules`, `vendor/`, binaries, `.env` files.

### Required skills
- python-best-practices
- python-data

### Subtasks
- [ ] Implement polling loop with configurable `INDEXER_POLL_INTERVAL_SECONDS` (default 300)
- [ ] Implement per-source-type chunking: whole-file for skills/claude_md; 512-token/50-overlap for specs/READMEs; per-entry for task logs
- [ ] Load `sentence-transformers/all-MiniLM-L6-v2` for embedding
- [ ] Upsert points to Qdrant using T1 schema — always include `workspace_id`
- [ ] Changed-file detection via `git diff --name-only` to avoid full re-index on each cycle
- [ ] Integration test: index a known document → verify point retrievable in Qdrant

---

## T3 — RAG MCP server

### Description
A Python FastAPI service implementing the MCP protocol over HTTP/SSE. Exposes one tool: `rag_query`. Agents connect to it via `MCP_RAG_URL`.

The server embeds the incoming query with `sentence-transformers/all-MiniLM-L6-v2`, issues a Qdrant search filtered by `workspace_id`, and returns ranked chunks. Queries without `workspace_id` are rejected (enforced by T1 schema layer).

MCP tool contract:
```python
rag_query(
    query: str,
    workspace_id: str,
    top_k: int = 5,
    source_types: list[str] | None = None
) -> list[{content, source_path, source_type, feature_id, score}]
```

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Set up FastAPI app with MCP HTTP/SSE endpoint
- [ ] Implement `rag_query` tool: embed query → Qdrant search with `workspace_id` must-filter → return top-k
- [ ] Reject queries missing `workspace_id` with a clear error
- [ ] Graceful startup: if Qdrant is unreachable, log warning and retry — do not crash
- [ ] Integration test: index a doc via T2 indexer → query via rag_query → verify chunk returned
- [ ] Smoke test: call `rag_query` with no `workspace_id` → confirm rejection

---

## T4 — Agent claim-time context injection

### Description
Update `workflow_skills/start-implementation/SKILL.md` to add a RAG context injection step between step 2 (context gathering) and step 3 (LLM implementation).

The agent checks for `MCP_RAG_URL` in its env. If present, it calls `rag_query` with the task title + feature_id as the query, formats the top-5 results as a `## Relevant project context` section (~500 token cap), and appends it to `agentContext`. If `MCP_RAG_URL` is absent, it skips silently.

Also update the task log entry format to include `tokens` and `rag_context_injected` fields (as defined in the technical design).

### Required skills

### Subtasks
- [ ] Add step 2b to `start-implementation/SKILL.md`: check `MCP_RAG_URL` → call `rag_query` → format + append to agentContext
- [ ] Define the 500-token cap behaviour: truncate at chunk boundary, never mid-sentence
- [ ] Add `rag_context_injected: true/false` to the task log entry spec in the skill
- [ ] Add `tokens: {input, output, total, cost_usd}` to task log entry spec
- [ ] Verify graceful degradation: agent runs normally when `MCP_RAG_URL` is unset

---

## T5 — Docker Compose + init-agent integration

### Description
Wire the three new services (`qdrant`, `rag-server`, `indexer`) into `docker-compose.yml`. Update `init-agent` skill to provision them for new agent workspaces. Update `agent.yaml.example` and `.env.template` with new required/optional vars.

New env vars:
- `QDRANT_URL` — for `rag-server` and `indexer` (local: `http://qdrant:6333`; production: `http://<vm-ip>:6333`)
- `MCP_RAG_URL` — for agent containers (local: `http://rag-server:8000`)

### Required skills
- python-best-practices

### Subtasks
- [ ] Add `qdrant` service to `docker-compose.yml` using `qdrant/qdrant` image, persist data on named volume
- [ ] Add `rag-server` service: `depends_on: qdrant`, expose port, pass `QDRANT_URL` + `WORKSPACE_ID`
- [ ] Add `indexer` service: `depends_on: qdrant`, pass `QDRANT_URL` + `WORKSPACE_ID` + `INDEXER_POLL_INTERVAL_SECONDS`
- [ ] Update agent service in compose to pass `MCP_RAG_URL`
- [ ] Update `init-agent/SKILL.md` to provision the new services and prompt for `WORKSPACE_ID`
- [ ] Update `agent.yaml.example` with `MCP_RAG_URL` documented
- [ ] Update `.env.template` with `QDRANT_URL` and `MCP_RAG_URL` (both optional, noted for graceful degradation)

---

## T7 — Move Dockerfile.rag to rag-service repo

### Description
`Dockerfile.rag` was placed in the `workflow` repo by T5 but belongs in `rag-service` alongside the service code it builds. Move the file, update all references in `docker-compose.yml` and `init-agent` skill, and confirm the compose stack still builds.

### Required skills
- python-best-practices

### Subtasks
- [ ] Move `Dockerfile.rag` (and any related build context) from `workflow` repo into `rag-service` repo root
- [ ] Update `docker-compose.yml` build context references to point to the `rag-service` repo path
- [ ] Update `init-agent/SKILL.md` if it references the old Dockerfile location
- [ ] Verify `docker compose build` succeeds with the new paths

---

## T8 — Replace REPO_PATHS with workspace.yaml-driven path resolution

### Description
The indexer currently reads a static `REPO_PATHS` environment variable (comma-separated container-internal paths). This hardcodes the workspace topology and prevents scaling to additional workspaces without redeployment.

Replace this with workspace.yaml-driven resolution: the indexer reads `workspace.yaml → repos[]` at startup and resolves container-internal mount paths from there. Each indexer instance is scoped to exactly one workspace (one-indexer-per-workspace model). `REPO_PATHS` is removed entirely.

This aligns with the future direction where workspace topology is authoritative in `workspace.yaml` (and eventually a workspace DB), not in environment variables.

### Required skills
- python-best-practices
- python-data

### Subtasks
- [ ] Update indexer to accept `WORKSPACE_YAML_PATH` env var pointing to the mounted `workspace.yaml`
- [ ] Parse `repos[]` from `workspace.yaml` at startup to determine which paths to watch
- [ ] Remove `REPO_PATHS` from indexer code, `docker-compose.yml`, `.env.template`, and `agent.yaml.example`
- [ ] Update `docker-compose.yml` to mount `workspace.yaml` into the indexer container and set `WORKSPACE_YAML_PATH`
- [ ] Update `init-agent/SKILL.md` to reflect the new env var
- [ ] Update unit/integration tests that used `REPO_PATHS`

---

## T6 — Documentation + operator guide

### Description
Update the operator-facing documentation to cover the final RAG stack (including T7 and T8 changes). All new setup steps, env vars, and service lifecycle changes must be documented before this task is complete. Documentation gaps are treated as incomplete work (per workflow rules).

> **Note:** This task replaces the PR opened in an earlier attempt (agent-workflow PR #40), which was invalidated when T7 and T8 were added. The agent must close PR #40 and open a new one covering the complete final state.

### Required skills

### Subtasks
- [ ] Update `README.md`: add RAG stack to architecture overview, list new services
- [ ] Update operator guide / Quickstart: add setup steps for `qdrant`, `rag-server`, `indexer`
- [ ] Document `QDRANT_URL`, `MCP_RAG_URL`, and `WORKSPACE_YAML_PATH` env vars with examples for local and production
- [ ] Document production deployment: Qdrant on dedicated VM, `QDRANT_URL` override
- [ ] Document graceful degradation: what happens when `MCP_RAG_URL` is unset
- [ ] Document `workspace_id` isolation: how collections stay separate per workspace
- [ ] Document one-indexer-per-workspace model and how repos are resolved from workspace.yaml
- [ ] Document migration path for existing agent workspaces (add new services to their compose file)
- [ ] Close PR #40 (superseded) and open a new PR for the complete documentation
