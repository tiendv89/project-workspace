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
The indexer currently reads a static `REPO_PATHS` environment variable (comma-separated container-internal paths). This hardcodes the workspace topology and prevents scaling to additional workspaces without redeployment. It also breaks in cloud (k8s) environments where repos are not pre-mounted on the filesystem.

Replace with workspace.yaml-driven resolution using a **clone-or-pull** strategy:
1. The indexer reads `workspace.yaml → repos[]` via `WORKSPACE_YAML_PATH` at startup
2. For each repo: if `local_path` exists on the container filesystem (Docker Compose volume mount), use it directly with `git pull` each cycle
3. If `local_path` is absent or does not exist (k8s / no volume mount), clone from `repos[].ssh_url` into `/tmp/indexer-repos/<repo_id>/` at startup and `git pull` each cycle
4. SSH key is available via `SSH_KEY_PATH` / `SSH_PRIVATE_KEY` env vars (same pattern as agent containers)

`REPO_PATHS` is removed entirely. The indexer container passes only `WORKSPACE_YAML_PATH`; all repo topology comes from `workspace.yaml`.

> **Note:** PR #5 (merged) introduced `WORKSPACE_YAML_PATH` and `workspace_resolver.py` but implemented local-path-only resolution. This rework adds the ssh_url clone fallback for k8s compatibility. Read the merged branch for prior art before implementing.

### Required skills
- python-best-practices
- python-data

### Subtasks
- [ ] Implement in `workspace_resolver.py`: if `local_path` exists on filesystem, `git pull --ff-only origin <base_branch>`; otherwise `git clone --branch <base_branch> <ssh_url>` at startup then pull each cycle
- [ ] Ensure SSH key env vars (`SSH_KEY_PATH` / `SSH_PRIVATE_KEY`) are wired into the git clone/pull commands
- [ ] Remove any remaining `REPO_PATHS` references in indexer code
- [ ] Update `docker-compose.yml`: remove `REPO_PATHS`, add `WORKSPACE_YAML_PATH`, mount `workspace.yaml` into indexer container — no hardcoded path env vars
- [ ] Update `.env.template` and `init-agent/SKILL.md` to remove `REPO_PATHS`, document `WORKSPACE_YAML_PATH`
- [ ] Update/add unit tests for clone-or-pull path — both local-mount path and ssh_url fallback
- [ ] Update integration test to verify indexer starts and indexes without `REPO_PATHS`

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
