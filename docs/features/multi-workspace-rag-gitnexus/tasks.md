# Tasks — Multi-workspace support for RAG and GitNexus

**Feature status:** `in_tdd` → awaiting task approval
**Stage:** task breakdown
**Machine state:** lives in `tasks/T<n>.yaml` — this file is narrative only.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | rag-service — indexer multi-workspace + namespaced point IDs | — |
| T2 | 1 | rag-service — RAG server connection-scoped workspace resolution | — |
| T3 | 1 | git-nexus — indexer per-workspace HOME/clone/registry + config | — |
| T4 | 2 | git-nexus — server per-workspace subprocess routing + `/ws/<id>/sse` | T3 |
| T5 | 3 | workflow — executor connection-scoped MCP endpoint binding | T2, T4 |
| T6 | 2 | workflow — multi-workspace compose templates + init-agent skill | T1, T3 |
| T7 | 3 | hermes-agent — connection-scoped endpoints + GitNexus scoping | T2, T4 |

All tasks implement the frozen **Multi-Workspace Contract** in `technical-design.md` §4. See `technical-design.md` §6 for the full per-task dependency diagram.

---

## T1 — rag-service — indexer multi-workspace + namespaced point IDs

### Description
Generalize the RAG indexer to drive **N workspaces** from one process (product goal G1). Parse `WORKSPACE_URLS` (comma-separated management-repo git URLs) in place of the single `WORKSPACE_ID`/`WORKSPACE_URL` read today (`services/indexer/main.py:310`). For each URL, clone the management repo to a **URL-derived** path (`<WORKSPACES_DIR>/<owner>/<repo>/` — required because `workspace_id` is unknown until after the clone), then read `workspace_id` + `repos[]` from that clone's own `workspace.yaml`. Index each workspace into its Qdrant collection (`= workspace_id`, already correct in `services/shared/qdrant_init.py`) and namespace point IDs by `workspace_id` (`_point_id`, `services/indexer/main.py:97`) so the same repo indexed under two workspaces never collides (G3). Namespace the PR-index state file (`services/indexer/pr_indexer.py`) the same way. A failure indexing one workspace must be logged and skipped, never aborting the cycle (G5). Two `WORKSPACE_URLS` entries that resolve to the same `workspace_id` must fail the indexer fast, naming both conflicting URLs (§4a). The legacy single `WORKSPACE_URL` (+ optional `WORKSPACE_ID`) path must keep working unchanged — a one-element `WORKSPACE_URLS` behaves identically (G6).

Touch points: `services/indexer/main.py` (`main()` loop, `_point_id`), `services/indexer/workspace_resolver.py` (mgmt-repo clone dest at `:164`, code-repo clone dest at `:189` — both currently un-namespaced), `services/indexer/pr_indexer.py`, `services/shared/qdrant_init.py` (verify only, `collection_name_for` is already `= workspace_id`).

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Parse `WORKSPACE_URLS` (comma-separated) in `services/indexer/main.py`; retain the legacy single `WORKSPACE_URL`/`WORKSPACE_ID` path as the one-element case
- [ ] Clone each management repo to `<WORKSPACES_DIR>/<owner>/<repo>/` (URL-derived) via `workspace_resolver.py`; read `workspace_id` + `repos[]` from that clone's `workspace.yaml`
- [ ] Namespace the mgmt-repo clone dest (`workspace_resolver.py:164`) and per-repo code clone dest (`:189`) so two workspaces never collide — key code repo clones by `<workspace_id>/<repo_id>`
- [ ] Update `_point_id()` to `hash(workspace_id | repo_path | rel_path | chunk_index)`
- [ ] Namespace `pr_indexer.py`'s `pr_index_state.json` per `workspace_id`
- [ ] Detect duplicate `workspace_id` across `WORKSPACE_URLS` after clone-and-read; fail fast with a clear error naming both conflicting URLs
- [ ] Isolate per-workspace indexing failures — log and skip, never abort the whole cycle (G5)
- [ ] Add/extend tests: two workspaces indexing the same `repo_id` produce distinct clone dirs and point IDs; duplicate `workspace_id` triggers fail-fast; legacy single-workspace config still indexes correctly
- [ ] Run full test suite — all pass

---

## T2 — rag-service — RAG server connection-scoped workspace resolution

### Description
Add a workspace-scoped SSE route `GET /ws/<workspace_id>/sse` (+ paired POST message route) to `services/rag_server/server.py`, alongside the existing default `/sse` route (which resolves to the sole configured workspace or `DEFAULT_WORKSPACE_ID`). Implements the chosen connection-scoped design (Decision A2): workspace resolution precedence is **connection path → explicit `workspace_id` argument on `rag_query` → default workspace → error**. This is purely additive — `rag_query`'s argument shape and the existing default-route behavior are unchanged (G6). Orthogonal to T1 (both touch `rag-service`, no shared blocker).

Touch points: `services/rag_server/server.py` (route registration, connection-to-workspace resolver, `DEFAULT_WORKSPACE_ID` env).

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Add `GET /ws/<workspace_id>/sse` and the matching POST message route to `services/rag_server/server.py`
- [ ] Implement resolution precedence: connection path → explicit `rag_query` `workspace_id` arg → `DEFAULT_WORKSPACE_ID`/default → error
- [ ] Keep the legacy `/sse` route resolving to the default workspace, unchanged
- [ ] Add `DEFAULT_WORKSPACE_ID` env var support (optional; falls back to the sole configured workspace when unset and only one exists)
- [ ] Add tests: a query via `/ws/A/sse` only returns workspace A results (isolation, G2); default `/sse` route behavior unchanged; explicit `workspace_id` arg still works as a fallback
- [ ] Run full test suite — all pass

---

## T3 — git-nexus — indexer per-workspace HOME/clone/registry + config

### Description
Generalize the GitNexus indexer (Node.js) to loop over `WORKSPACE_URLS`, cloning each management repo to a URL-derived path, reading `workspace_id` + `repos[]` from its `workspace.yaml`, and building a **per-workspace data root** `HOME=/gitnexus-data/<workspace_id>/` (registry at `.gitnexus/registry.json`, code repos under `repos/<repo_id>/`) — replacing today's single `WORKSPACE_URL`, flat `repos/<repo_id>/` layout with no workspace prefix, and fixed `_workspace` mgmt-repo clone dir. This on-disk layout must be produced and frozen here because **T4 (server) depends on it**. Duplicate `workspace_id` across `WORKSPACE_URLS` must fail the indexer fast, naming the conflicting URLs (§4a); per-workspace failures are isolated (G5). Legacy single `WORKSPACE_URL` path must keep working unchanged (G6).

Touch points: `services/gitnexus_indexer/index.js` (config loop, currently single `WORKSPACE_URL` at `:9`), `src/workspace.js` (mgmt-repo clone, currently fixed `_workspace` dir at `:37`), `src/git.js` (code repo clone, currently flat `repos/<repo_id>/` with no workspace prefix at `:99`), `src/analyzer.js`.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Parse `WORKSPACE_URLS` (comma-separated) in `services/gitnexus_indexer/index.js`; retain the legacy single `WORKSPACE_URL` path
- [ ] Clone each management repo to a URL-derived cache path under `WORKSPACES_DIR` in `src/workspace.js` (replacing the fixed `_workspace` dir)
- [ ] Read `workspace_id` + `repos[]` from each clone's `workspace.yaml`
- [ ] Build per-workspace `HOME=/gitnexus-data/<workspace_id>/` and clone code repos to `<HOME>/repos/<repo_id>/` in `src/git.js` (replacing the flat, unprefixed layout)
- [ ] Point the registry write path at `<HOME>/.gitnexus/registry.json` per workspace
- [ ] Detect duplicate `workspace_id` across `WORKSPACE_URLS` after clone-and-read; fail fast naming both conflicting URLs
- [ ] Isolate per-workspace indexing failures — log and skip, never abort the whole cycle (G5)
- [ ] Add/extend tests: two workspaces produce distinct `HOME` dirs/registries for the same `repo_id`; duplicate `workspace_id` fails fast; legacy single-workspace config unaffected
- [ ] Run full test suite — all pass

---

## T4 — git-nexus — server per-workspace subprocess routing + `/ws/<id>/sse`

### Description
**Blocked on T3** — requires the per-workspace `HOME`/registry layout to exist and be frozen. `services/gitnexus_server/server.py` currently wraps a single `gitnexus mcp` stdio subprocess keyed off one global `HOME`. Change it to manage a **pool of subprocess sessions, one per active workspace**, each launched with `env={"HOME": "/gitnexus-data/<workspace_id>"}` (Decision B1 — zero changes to the opaque third-party `gitnexus` CLI). Add `GET /ws/<workspace_id>/sse` (+ POST message route) that routes a connection to its workspace's subprocess; spawn lazily on first request per workspace (preferred, per the design's noted implementation choice, to bound memory to active workspaces) and cache the session. The legacy `/sse` route continues to resolve to a default workspace. **No change to MCP tool names or result shapes** — `query`, `context`, `impact`, `list_repos`, `group_query`, `detect_changes` stay exactly as they are; only the routing layer is new.

Touch points: `services/gitnexus_server/server.py` (subprocess pool keyed by `workspace_id`, `/ws/<id>/sse` route + resolver, `DEFAULT_WORKSPACE_ID` env).

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Read the per-workspace `HOME` layout produced by T3 (`/gitnexus-data/<workspace_id>/`)
- [ ] Replace the single global `gitnexus mcp` subprocess with a pool keyed by `workspace_id`, each spawned with `env={"HOME": "/gitnexus-data/<workspace_id>"}`
- [ ] Spawn subprocesses lazily on first request per workspace; cache the session
- [ ] Add `GET /ws/<workspace_id>/sse` + POST message route; resolve the connection's `workspace_id` and route to the matching subprocess session
- [ ] Keep the legacy `/sse` route resolving to a default workspace (`DEFAULT_WORKSPACE_ID` or the sole configured workspace)
- [ ] Verify no MCP tool name or result-shape changes — `query`/`context`/`impact`/`list_repos`/`group_query`/`detect_changes` unchanged
- [ ] Add tests: a connection scoped to workspace A never surfaces workspace B's symbols/repos for any tool (G2); legacy `/sse` route behavior unchanged
- [ ] Run full test suite — all pass

---

## T5 — workflow — executor connection-scoped MCP endpoint binding

### Description
**Blocked on T2 and T4** — requires the RAG and GitNexus servers to accept `/ws/<id>/sse`. The claude executor currently registers both MCP servers as plain SSE URLs (`${mcpRagUrl}/sse`, `${gitnexusMcpUrl}/sse`, `runtime/executors/claude/src/index.ts:411-417`) — RAG scoping today relies on the model passing the right `workspace_id` on every call, and GitNexus cannot pass one at all. Change the executor to build **workspace-scoped** endpoint URLs (`…/ws/${WORKSPACE_ID}/sse`) from the `WORKSPACE_ID` already injected into its env by the dispatcher (`runtime/dispatcher/src/spawner.ts:256`) — no new plumbing to learn the workspace, only to use it in URL construction. This removes the model's ability to query the wrong workspace entirely (Decision A2). RAG pre-flight (`fetch-rag-context.ts:61`) already passes `workspace_id` explicitly and needs no change.

Touch points: `runtime/executors/claude/src/index.ts:411-417` (MCP server URL construction for both RAG and GitNexus).

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Build the RAG MCP SSE URL as `${mcpRagUrl}/ws/${WORKSPACE_ID}/sse` instead of `${mcpRagUrl}/sse`
- [ ] Build the GitNexus MCP SSE URL as `${gitnexusMcpUrl}/ws/${WORKSPACE_ID}/sse` instead of `${gitnexusMcpUrl}/sse`
- [ ] Confirm `WORKSPACE_ID` is present in the executor env before constructing the URLs (already injected by `runtime/dispatcher/src/spawner.ts:256`)
- [ ] Verify RAG pre-flight (`fetch-rag-context.ts`) is unaffected — it already passes `workspace_id` explicitly
- [ ] Add/extend an integration test: an agent turn for workspace A only ever reaches A's RAG/GitNexus data
- [ ] Run full test suite — all pass

---

## T6 — workflow — multi-workspace compose templates + init-agent skill

### Description
**Blocked on T1 and T3** — requires the RAG and GitNexus indexer config shapes (`WORKSPACES_DIR`, per-workspace `HOME`) to be final. Update `runtime/orchestrator/templates/docker-compose.yml` (+ `docker-compose.local-docker.yml`) so the RAG and GitNexus stacks are configured with `WORKSPACE_URLS` (comma-separated management-repo URLs) instead of a single `WORKSPACE_ID`/`WORKSPACE_URL` (currently pinned at ~lines 164/193/240), and mount a `WORKSPACES_DIR` clone-cache volume instead of one mounted `workspace.yaml`. Update the `init-agent` skill (`claude/workflow_skills/init-agent/SKILL.md`, step 4) to set up the stack for one-or-more workspaces via `WORKSPACE_URLS`. Single-workspace setups remain the default/simplest path (G6) — a one-element `WORKSPACE_URLS` is equivalent to the legacy config. Runs in parallel with T4 (both are Wave 2, independent repos).

Touch points: `runtime/orchestrator/templates/docker-compose.yml`, `runtime/orchestrator/templates/docker-compose.local-docker.yml`, `claude/workflow_skills/init-agent/SKILL.md`.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Update `docker-compose.yml`: rag-server + indexer take `WORKSPACE_URLS` (comma-separated) instead of a single `WORKSPACE_ID`; gitnexus-indexer takes `WORKSPACE_URLS` instead of a single `WORKSPACE_URL`
- [ ] Add a `WORKSPACES_DIR` volume mount for the indexer clone cache
- [ ] Mirror the same changes in `docker-compose.local-docker.yml`
- [ ] Update `claude/workflow_skills/init-agent/SKILL.md` step 4 to document/guide multi-workspace setup (`WORKSPACE_URLS`) while keeping single-workspace as the default simple path
- [ ] Add `DEFAULT_WORKSPACE_ID` as an optional env for the server-side default route, documented in compose + init-agent
- [ ] Verify a fresh single-workspace `init-agent` run still produces a working stack unchanged (G6 regression check)
- [ ] Run full test suite — all pass

---

## T7 — hermes-agent — connection-scoped endpoints + GitNexus scoping

### Description
**Blocked on T2 and T4** — requires the RAG and GitNexus servers to accept `/ws/<id>/sse`. hermes-agent's MCP client (`plugins/mcp_client.py`) opens a fresh SSE connection per call, auto-appending `/sse` to `RAG_MCP_URL`/`GITNEXUS_MCP_URL`. RAG is already workspace-scoped via the session's thread-local context (`plugins/tools/rag.py:77`, `plugins/context.py`, set per session at `src/api/agent_dispatch.py:260`); GitNexus is not — `plugins/tools/gitnexus.py`'s `_build_arguments()` and `list_indexed_repos()` carry no `workspace_id`, and `plugins/hooks.py:176`'s context-injection call is likewise unscoped. Change the MCP client to build `…/ws/<workspace_id>/sse` from the same session context RAG already resolves, and thread that same context into the GitNexus tool path and context-injection hook — no new model-facing argument required.

Touch points: `plugins/mcp_client.py` (endpoint construction), `plugins/tools/gitnexus.py` (`_build_arguments`, `handle`, `list_indexed_repos`), `plugins/hooks.py` (injection-time scoping).

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Change `plugins/mcp_client.py` to construct `…/ws/<workspace_id>/sse` (instead of plain `/sse`) for both `RAG_MCP_URL` and `GITNEXUS_MCP_URL`, using the existing session context resolver
- [ ] Wire the same workspace context resolution used by `plugins/tools/rag.py` into `plugins/tools/gitnexus.py`'s `_build_arguments()`/`handle()` — no new model-facing argument
- [ ] Scope `plugins/hooks.py`'s context-injection call to `list_indexed_repos()` to the session's workspace
- [ ] Add tests: a session bound to workspace A never surfaces workspace B's GitNexus repos/symbols (G2); RAG scoping behavior unchanged
- [ ] Run full test suite — all pass
