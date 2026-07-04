# Tasks — Remove backward-compatible single-workspace paths from RAG/GitNexus

**Feature status:** `in_tdd` → awaiting task approval
**Stage:** task breakdown
**Machine state:** lives in `tasks/T<n>.yaml` — this file is narrative only.

## Index

| ID | Wave | Title | Repo | Depends on |
|----|------|-------|------|------------|
| T1 | 1 | rag-service — indexer: remove legacy WORKSPACE_URL/WORKSPACE_ID path | rag-service | — |
| T2 | 2 | rag-service — RAG server: remove default /sse route + DEFAULT_WORKSPACE_ID | rag-service | T5, T6 |
| T3 | 1 | git-nexus — indexer: remove legacy WORKSPACE_URL path | git-nexus | — |
| T4 | 2 | git-nexus — server: remove legacy /sse route, eager legacy subprocess, DEFAULT_WORKSPACE_ID, legacy health fields | git-nexus | T5, T6 |
| T5 | 1 | workflow — executor: remove buildMcpSseUrl legacy fallback | workflow | — |
| T6 | 1 | hermes-agent — connection-scope the RAG tool; close GitNexus fallback gap | hermes-agent | — |
| T7 | 3 | workflow — deployment: drop DEFAULT_WORKSPACE_ID from compose templates + init-agent docs | workflow | T2, T4 |

All tasks implement the **migrate-consumers-then-delete-producers** ordering frozen in
`technical-design.md` §4/§6. See `technical-design.md` §6 for the full per-task
dependency diagram and the reasoning behind the direction reversal from the parent
feature (there, consumers waited on producers; here, producers wait on consumers).

---

## T1 — rag-service — indexer: remove legacy WORKSPACE_URL/WORKSPACE_ID path

### Description
Delete the single-workspace legacy branch from the RAG indexer (product goal G1).
`services/indexer/main.py::main()` currently branches on whether `WORKSPACE_URLS` is
set: if unset, it falls into a legacy `else` branch reading `WORKSPACE_ID` +
`WORKSPACE_URL`/`WORKSPACE_YAML_PATH` and calling `run()`. That legacy branch and the
functions it alone calls — `run()`, `_load_workspace_repos()`,
`_resolve_workspace_yaml_path()` (`main.py:242-378`) — are deleted. `run_multi()`
(`:468-591`) is a fully independent implementation and needs no change. In
`workspace_resolver.py`, delete the matching legacy-only functions: `bootstrap_workspace()`,
`load_repo_paths()`, `_ensure_cloned()` — verified unused by the namespaced
(`bootstrap_workspace_url_derived()`, `load_repo_paths_namespaced()`, `_ensure_cloned_at()`)
path. `WORKSPACE_URLS` becomes required: `main()` must raise a clear config error if it
is unset, instead of falling through to the deleted branch. `WORKSPACE_YAML_PATH` and
`WORKSPACE_CLONE_DIR` env vars are removed — verified used only by the deleted functions.
This task has no dependency on any server or consumer work (§5 of the design):
indexers are never called by `hermes-agent` or the runtime executor.

Touch points: `services/indexer/main.py` (`main()`, `run()`, `_load_workspace_repos()`,
`_resolve_workspace_yaml_path()`), `services/indexer/workspace_resolver.py`
(`bootstrap_workspace()`, `load_repo_paths()`, `_ensure_cloned()`).

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Delete the legacy `else` branch in `main()`; raise a clear `ValueError` when
      `WORKSPACE_URLS` is unset instead of falling through
- [ ] Delete `run()`, `_load_workspace_repos()`, `_resolve_workspace_yaml_path()` from `main.py`
- [ ] Delete `bootstrap_workspace()`, `load_repo_paths()`, `_ensure_cloned()` from
      `workspace_resolver.py` — confirm no remaining caller first (grep for each name)
- [ ] Remove `WORKSPACE_YAML_PATH` and `WORKSPACE_CLONE_DIR` env var handling and docs
- [ ] Remove legacy-path test cases: `tests/indexer/test_workspace_resolver.py`,
      `tests/rag_server/test_workspace_resolution.py`, `tests/shared/test_schema.py`
      (legacy cases only — do not remove multi-workspace test cases)
- [ ] Run full test suite — all pass

---

## T2 — rag-service — RAG server: remove default /sse route + DEFAULT_WORKSPACE_ID

### Description
**Blocked on T5 and T6** — the runtime executor (`workflow`, T5) and `hermes-agent`'s
RAG tool (T6) must no longer construct or rely on the plain `/sse` route before it is
deleted. `hermes-agent`'s `rag.py` is today the plain `/sse` route's only caller (not a
fallback — its sole transport, per `technical-design.md` §1), so deleting this route
before T6 lands breaks RAG queries from hermes-agent outright.

Once unblocked: remove `Route("/sse", endpoint=handle_sse, methods=["GET"])`,
`Mount("/messages/", app=_sse.handle_post_message)`, `handle_sse()`, and the
module-level `_sse` transport instance from `services/rag_server/server.py::create_app()`.
`_resolve_workspace()` drops its `DEFAULT_WORKSPACE_ID` branch — precedence becomes
connection path → explicit `rag_query` argument → error (no default fallback).
Update `rag_query`'s docstring to drop the "callers using the default `/sse` route"
sentence. Before deleting, re-run a grep across all repos in `workspace.yaml` for any
hardcoded `.../sse` URL targeting rag-service that this design's grounding pass may
have missed (§5 "Undiscovered plain-`/sse` callers" — this is a final gate, not a
one-time design-time check).

Touch points: `services/rag_server/server.py` (`create_app()` route registration,
`handle_sse()`, `_sse` transport, `_resolve_workspace()`, `rag_query` docstring).

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Re-grep all `workspace.yaml` repos for hardcoded plain `/sse` URLs targeting
      rag-service; confirm none remain beyond what T5/T6 already migrated
- [ ] Remove `Route("/sse", ...)`, `Mount("/messages/", ...)`, `handle_sse()`, module-level `_sse`
- [ ] Remove the `DEFAULT_WORKSPACE_ID` branch from `_resolve_workspace()`; update its docstring
- [ ] Update `rag_query`'s docstring (drop the default-`/sse`-route sentence)
- [ ] Remove legacy-path test cases from `tests/rag_server/test_workspace_resolution.py`
      (default-route / `DEFAULT_WORKSPACE_ID` cases only)
- [ ] Verify `/ws/<workspace_id>/sse` behavior and explicit `rag_query` `workspace_id`
      argument are both unaffected
- [ ] Run full test suite — all pass

---

## T3 — git-nexus — indexer: remove legacy WORKSPACE_URL path

### Description
Delete the single `WORKSPACE_URL` fallback from the GitNexus indexer (Node.js).
`services/gitnexus_indexer/index.js` currently prefers `WORKSPACE_URLS`
(comma-separated) and falls back to singular `WORKSPACE_URL` when unset
(`:15-32,86,135,142,187`). Remove the fallback and the single-workspace clone path it
drives; `WORKSPACE_URLS` becomes required, with the same fail-fast-on-missing treatment
as T1. No dependency on server or consumer work — this only affects the indexer
process, which the runtime executor and hermes-agent never call directly.

Touch points: `services/gitnexus_indexer/index.js`.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Remove the `WORKSPACE_URL` (singular) fallback and its single-workspace clone
      branch; raise a clear error when `WORKSPACE_URLS` is unset
- [ ] Remove any config/docs comments describing the legacy fallback
- [ ] Remove legacy-path test cases from `services/gitnexus_indexer/__tests__/index.test.js`
      and `workspace.test.js` (legacy cases only)
- [ ] Run full test suite — all pass

---

## T4 — git-nexus — server: remove legacy /sse route, eager legacy subprocess, DEFAULT_WORKSPACE_ID, legacy health fields

### Description
**Blocked on T5 and T6** — same reasoning as T2. Even though `hermes-agent`'s GitNexus
tool already connects via `/ws/<id>/sse` today, `plugins/tools/gitnexus.py::handle()`
does not guard against an empty `workspace_id` (unlike `rag.py`), so an unset session
context silently falls through to the legacy route today — T6 closes that gap first.

Once unblocked, remove from `services/gitnexus_server/server.py::create_app()`: the
eagerly-started `legacy_entry` subprocess and its `lifespan()` startup, `_LEGACY_HOME`,
`_LEGACY_WORKSPACE_ID` sentinel, the legacy `Route("/sse", ...)` /
`Mount("/messages/", ...)`, `handle_sse()`, and `DEFAULT_WORKSPACE_ID`. The `/health`
response drops its backward-compat top-level `registry`/`session`/`registry_path`/
`default_workspace` keys, keeping only the `workspaces` list. Verify at implementation
time whether `REGISTRY_PATH`/module-level `_state` are still needed by this repo's own
tests before removing them (design §5 flags this as unresolved-pending-verification,
not settled). Also re-run the cross-repo `/sse` grep as in T2.

Touch points: `services/gitnexus_server/server.py` (`create_app()`, `legacy_entry`,
`_LEGACY_HOME`, `_LEGACY_WORKSPACE_ID`, `handle_sse()`, `health()`, `REGISTRY_PATH`, `_state`).

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Re-grep all `workspace.yaml` repos for hardcoded plain `/sse` URLs targeting
      git-nexus; confirm none remain beyond what T5/T6 already migrated
- [ ] Remove the eager `legacy_entry` subprocess and its `lifespan()` startup
- [ ] Remove `_LEGACY_HOME`, `_LEGACY_WORKSPACE_ID`, `DEFAULT_WORKSPACE_ID`
- [ ] Remove the legacy `Route("/sse", ...)`, `Mount("/messages/", ...)`, `handle_sse()`
- [ ] Drop the backward-compat top-level `registry`/`session`/`registry_path`/
      `default_workspace` keys from the `/health` response; keep the `workspaces` list
- [ ] Check whether `REGISTRY_PATH`/`_state` are still required by this repo's tests;
      remove them if only used for the legacy path, update tests otherwise
- [ ] Remove legacy-path test cases from `services/gitnexus_server/tests/test_server.py`
- [ ] Run full test suite — all pass

---

## T5 — workflow — executor: remove buildMcpSseUrl legacy fallback

### Description
Remove the legacy-fallback branch from
`runtime/executors/claude/src/mcp-endpoint-binding.ts::buildMcpSseUrl()`, which today
returns `${baseUrl}/sse` when `workspaceId` is falsy instead of
`${baseUrl}/ws/${workspaceId}/sse`. `WORKSPACE_ID` is already injected into every
executor's env unconditionally by the dispatcher, so this fallback is unreachable in
production — this task makes that a compile-time guarantee by making `workspaceId` a
required, non-optional parameter, rather than only an operational assumption. No
dependency on other tasks — `/ws/<workspace_id>/sse` already exists in both producers
today (parent feature, already merged).

Touch points: `runtime/executors/claude/src/mcp-endpoint-binding.ts`,
`runtime/executors/claude/src/mcp-endpoint-binding.test.ts`.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Change `buildMcpSseUrl(baseUrl: string, workspaceId: string)` to a required
      parameter; remove the ternary fallback to plain `/sse`
- [ ] Update call sites in `runtime/executors/claude/src/index.ts` if the type change
      surfaces any caller that doesn't already guarantee a non-empty `workspaceId`
- [ ] Remove the `"legacy fallback (WORKSPACE_ID absent)"` describe block from
      `mcp-endpoint-binding.test.ts`
- [ ] Run full test suite — all pass

---

## T6 — hermes-agent — connection-scope the RAG tool; close GitNexus fallback gap

### Description
No dependency on other tasks — `/ws/<workspace_id>/sse` already exists in both
producers today. This task is the critical path unblock for T2 and T4: it removes the
last real (non-fallback) caller of rag-service's plain `/sse` route and the last silent
fallthrough on the GitNexus side.

`plugins/tools/rag.py::handle()` currently calls
`call_mcp_tool(url, "rag_query", arguments)` **without** `workspace_id=`, so it always
connects via the plain `/sse` route and relies entirely on the explicit `workspace_id`
inside `arguments` (the retained, non-legacy Option A1 call shape — kept as-is per the
product spec's non-goals). Add `workspace_id=wid` to that call so the connection itself
becomes workspace-scoped (`/ws/<workspace_id>/sse`), matching
`plugins/tools/gitnexus.py::handle()`'s existing pattern — this does not change the
`rag_query` argument shape, only which endpoint the connection targets.

`plugins/tools/gitnexus.py::handle()` resolves `workspace_id = resolve_workspace_slug(get_workspace_id())`
but never checks it is non-empty before calling `call_mcp_tool()` — unlike `rag.py`,
which already errors clearly when no workspace context is set. Add the same
"`workspace_id` is required" guard to `gitnexus.py`, closing the empty-string
fallthrough to the legacy route.

Once both call sites always supply a non-empty `workspace_id`,
`plugins/mcp_client.py::_sse_endpoint()`'s `elif` branch (falls back to plain `/sse`
when `workspace_id` is empty) becomes dead code — remove it.

Touch points: `plugins/tools/rag.py` (`handle()`), `plugins/tools/gitnexus.py`
(`handle()`), `plugins/mcp_client.py` (`_sse_endpoint()`).

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Add `workspace_id=wid` to the `call_mcp_tool()` call in `plugins/tools/rag.py::handle()`
- [ ] Add a "`workspace_id` is required" guard to `plugins/tools/gitnexus.py::handle()`,
      mirroring `rag.py`'s existing check, returning a clear error instead of silently
      falling through
- [ ] Remove the `elif` legacy fallback branch from `plugins/mcp_client.py::_sse_endpoint()`
- [ ] Update `_sse_endpoint()`'s docstring to drop the backward-compatibility note
- [ ] Add a test asserting `rag.py::handle()` passes `workspace_id=` to `call_mcp_tool()`
      (connection-scoped, not just the explicit `rag_query` argument)
- [ ] Add a test asserting `gitnexus.py::handle()` errors clearly when no workspace
      context is set, instead of silently connecting to the legacy route
- [ ] Run full test suite — all pass

---

## T7 — workflow — deployment: drop DEFAULT_WORKSPACE_ID from compose templates + init-agent docs

### Description
**Blocked on T2 and T4** — removing `DEFAULT_WORKSPACE_ID` from the deployment
templates before the servers stop honoring it would silently strand any deployment
still relying on the default route with no way to configure it, one release ahead of
the route itself being gone.

Once unblocked: remove the `DEFAULT_WORKSPACE_ID` env wiring from both the `rag-server`
and `gitnexus-server` containers in `runtime/orchestrator/templates/docker-compose.yml`
and `docker-compose.local-docker.yml`, and remove the associated
"Single-workspace deployments: set DEFAULT_WORKSPACE_ID…" comments. Update
`claude/workflow_skills/init-agent/SKILL.md` to remove the `DEFAULT_WORKSPACE_ID`
documentation (including the line noting it "enables the legacy `GET /sse` route for
backward compat") and confirm the single-workspace guidance now describes a
one-element `WORKSPACE_URLS` as the only single-workspace path.

Touch points: `runtime/orchestrator/templates/docker-compose.yml`,
`runtime/orchestrator/templates/docker-compose.local-docker.yml`,
`claude/workflow_skills/init-agent/SKILL.md`.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Remove `DEFAULT_WORKSPACE_ID` env wiring from the `rag-server` service in
      `docker-compose.yml` and `docker-compose.local-docker.yml`
- [ ] Remove `DEFAULT_WORKSPACE_ID` env wiring from the `gitnexus-server` service in
      both compose files
- [ ] Remove the "Single-workspace deployments: set DEFAULT_WORKSPACE_ID…" comments
- [ ] Update `init-agent/SKILL.md` to remove `DEFAULT_WORKSPACE_ID` docs and the legacy
      `/sse` backward-compat note; confirm single-workspace guidance describes a
      one-element `WORKSPACE_URLS` only
- [ ] Verify a fresh single-workspace `init-agent` run (one-element `WORKSPACE_URLS`,
      no `DEFAULT_WORKSPACE_ID`) still produces a working stack
- [ ] Run full test suite — all pass
