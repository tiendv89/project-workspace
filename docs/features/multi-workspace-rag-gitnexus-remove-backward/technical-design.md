# Technical Design

## Feature
- Feature ID: `multi-workspace-rag-gitnexus-remove-backward`
- Title: Remove backward-compatible single-workspace paths from RAG/GitNexus

## 1. Current State

`multi-workspace-rag-gitnexus` has been fully implemented and merged to `main` in all
four affected repos (`rag-service#17`, `git-nexus#6`, `hermes-agent#39`,
`workflow#280`), even though its tracked task YAMLs in this management repo were never
advanced past `ready`/`todo` — that tracking gap is out of scope here and is not
touched by this feature (see "Task file scope" / one-repo rules; fixing stale task
state is not a technical-design concern). The verification below is against the actual
merged code, not the parent design doc's plan, since implementation can (and did, per
task-tracking metadata) drift from the original task breakdown.

Multi-workspace support is real and working (`WORKSPACE_URLS`, `/ws/<workspace_id>/sse`,
per-workspace storage namespacing). But every producer and — this is the part the
approved product spec under-scoped — **two of the four consumers** still carry the
backward-compatible single-workspace path from goal G6 of the parent feature:

**`rag-service`**
- `services/indexer/main.py::main()` — `WORKSPACE_URLS` set → multi-workspace
  (`run_multi`); unset → legacy `else` branch reading `WORKSPACE_ID` +
  `WORKSPACE_URL`/`WORKSPACE_YAML_PATH` and calling `run()`. `run()`,
  `_load_workspace_repos()`, `_resolve_workspace_yaml_path()` (`main.py:242-378`) are
  called **only** from that legacy branch — `run_multi()` (`:468-591`) is a fully
  independent implementation that does not call `run()`.
- `services/indexer/workspace_resolver.py` — `bootstrap_workspace()`, `load_repo_paths()`,
  `_ensure_cloned()` are the legacy (non-namespaced) clone path, used only by the
  legacy branch above. `bootstrap_workspace_url_derived()`, `load_repo_paths_namespaced()`,
  `_ensure_cloned_at()` are the multi-workspace path and do not call the legacy
  functions — clean separation, safe to delete one side without touching the other.
- `services/rag_server/server.py::create_app()` registers `Route("/sse", handle_sse)` +
  `Mount("/messages/", _sse.handle_post_message)` (the default/legacy route) alongside
  `Mount("/ws", _workspace_sse_app)` (`:471-478`). `_resolve_workspace()` (`:96-123`)
  falls back to `DEFAULT_WORKSPACE_ID` when neither the connection path nor an explicit
  `rag_query` argument supplies a workspace.

**`git-nexus`**
- `services/gitnexus_indexer/index.js` — `WORKSPACE_URLS` takes precedence;
  `WORKSPACE_URL` (singular) is the fallback (`:15-32,86,135,142,187`), used only when
  `WORKSPACE_URLS` is unset.
- `services/gitnexus_server/server.py` carries more legacy surface than RAG: an
  **eagerly-started** `legacy_entry` subprocess (`create_app():273-301`) resolved from
  `DEFAULT_WORKSPACE_ID` or the original `HOME`-based single-workspace layout
  (`_LEGACY_HOME`, `_LEGACY_WORKSPACE_ID` sentinel, `:36-49`); a legacy `Route("/sse", ...)`
  + `Mount("/messages/", ...)` (`:362-363`); and legacy top-level keys
  (`registry`, `session`, `registry_path`, `default_workspace`) merged into the
  `/health` response "for backward compat with old single-workspace health checks"
  (`:342-356`). `REGISTRY_PATH`/module-level `_state` (`:47-49`) are also marked
  backward-compat exports for tests/external code.

**`workflow` (agent-workflow — the runtime executor)**
- `runtime/executors/claude/src/mcp-endpoint-binding.ts::buildMcpSseUrl()` —
  `workspaceId ? .../ws/${workspaceId}/sse : ${baseUrl}/sse` (falls back to the plain
  legacy route when `workspaceId` is falsy). The approved product spec assumed this was
  already unconditional; it is not — the fallback is deliberate G6 scaffolding and its
  own test file has a dedicated `"legacy fallback (WORKSPACE_ID absent)"` suite
  (`mcp-endpoint-binding.test.ts:30-49`).
- `runtime/orchestrator/templates/docker-compose.yml` and `docker-compose.local-docker.yml`
  already require `WORKSPACE_URLS` unconditionally for both indexers (no legacy indexer
  env remains there) — the only surviving legacy knob in deployment is
  `DEFAULT_WORKSPACE_ID`, wired to both the `rag-server` and `gitnexus-server` containers
  to keep their default `/sse` route alive.
- `claude/workflow_skills/init-agent/SKILL.md:166` documents `DEFAULT_WORKSPACE_ID` as
  the way to "enable the legacy `GET /sse` route for backward compat."

**`hermes-agent`** — also under-scoped by the approved product spec:
- `plugins/tools/gitnexus.py::handle()` (`:156-163`) always passes
  `workspace_id=workspace_id` to `call_mcp_tool()` — GitNexus calls **are** already
  connection-scoped via `/ws/<id>/sse`, matching what the product spec assumed. But
  `workspace_id` can still be an empty string when `get_workspace_id()` has no session
  context, and `handle()` does not guard against that (unlike `rag.py`, see next point) —
  an empty `workspace_id` falls through `_sse_endpoint()`'s legacy branch.
- `plugins/tools/rag.py::handle()` (`:79-90`) calls
  `call_mcp_tool(url, "rag_query", arguments)` **without** the `workspace_id=` keyword —
  it never binds the connection to a workspace at all. It relies entirely on the
  explicit `workspace_id` inside `arguments` (the retained, non-legacy Option A1 call
  shape) and therefore **always** connects via the plain `/sse` route. This is the one
  path in the whole system that still depends on the default `/sse` route as its
  *primary*, not fallback, transport.
- `plugins/mcp_client.py::_sse_endpoint()` (`:67-85`) has the same
  `workspace_id ? /ws/<id>/sse : /sse` fallback as the `workflow` executor.

## 2. Problem Framing

What must change: delete the single-workspace/default-route code path (indexer legacy
branches, default `/sse` routes, `DEFAULT_WORKSPACE_ID`, and the two consumer-side
fallbacks-to-plain-`/sse`) from all four repos, and update the `workflow` deployment
templates and `init-agent` docs to match.

What must remain stable: `WORKSPACE_URLS` config shape, `/ws/<workspace_id>/sse`
routing, per-workspace storage namespacing, the subprocess-pool model, `workspace_id`
uniqueness fail-fast, and RAG's explicit `workspace_id` argument on `rag_query` (kept
per the approved product spec's non-goals — it is a legitimate non-connection-scoped
call shape, not single-workspace legacy).

Assumption already fixed by the approved product spec: this is a removal of a
superseded path, not a removal of single-workspace *capability* — a one-element
`WORKSPACE_URLS` remains a fully supported way to run one workspace.

**Correction to the approved product spec's scope table.** The product spec listed
`workflow` as deployment-only and `hermes-agent` as "no expected change — already
connection-scoped … verify no residual reference." Grounding the design in the actual
merged code (§1) shows both have real, load-bearing legacy fallbacks:
`buildMcpSseUrl()` in `workflow`, and `rag.py` + `mcp_client.py` in `hermes-agent`. This
does not change any Goal or Non-goal from the product spec — G2 ("only `/ws/<id>/sse`
is accepted") cannot be achieved while a consumer still primarily or optionally
connects via plain `/sse`. It expands the *task list* under the same approved goals; it
does not require re-approving the product spec, and the two open questions the spec
raised for technical design are answered directly by this finding (see §5).

## 3. Options Considered

### Option A — Delete producer routes only, leave consumer fallbacks in place
- What it is: remove the legacy indexer branches and default `/sse` routes from
  `rag-service`/`git-nexus` only; leave `buildMcpSseUrl()` and `hermes-agent`'s
  fallbacks as dead code.
- Pros: smaller diff, touches only the two repos the product spec's Goals named first.
- Cons: `hermes-agent`'s `rag.py` **always** uses the plain `/sse` route today (not a
  fallback — its only path) — deleting the route without migrating this call site
  breaks RAG queries from hermes-agent outright. Also leaves genuinely dead/misleading
  "legacy fallback" code and tests in two repos, which is exactly the kind of cruft this
  feature exists to remove.
- Implementation impact: incomplete — fails G2 for the one real caller of the route.
- Dependency impact: none deferred, but ships a regression.

### Option B — Migrate consumers first, then delete producer routes (chosen)
- What it is: (1) switch `hermes-agent`'s RAG tool to connection-scoped
  `/ws/<workspace_id>/sse` and remove both consumer-side fallbacks-to-`/sse`
  (`workflow`, `hermes-agent`); (2) once no consumer depends on the plain `/sse` route,
  delete it — and `DEFAULT_WORKSPACE_ID` — from both servers; (3) update deployment
  templates/docs to match.
- Pros: no window where a real caller loses connectivity; fully achieves G1–G4;
  ordering makes the removal's safety self-evident (delete a route only after nothing
  calls it).
- Cons: more tasks (7 vs. an originally-assumed 4–5); requires care that step (1) lands
  and is verified before step (2) starts.
- Implementation impact: touches all four repos, as corrected in §2.
- Dependency impact: introduces a real cross-repo ordering constraint (§5, §6) —
  producer route deletion depends on consumer migration, the opposite direction from
  the parent feature's build-out (which shipped producers first, behind a default
  route, precisely so consumers could migrate without a hard cutover).

### Option C — Feature-flag the removal (env toggle to re-enable legacy route)
- What it is: ship the deletion behind a flag so an operator can temporarily
  re-enable the legacy route if an undiscovered caller breaks.
- Pros: safety net for an unknown caller.
- Cons: reintroduces the exact dual-code-path cost (G1–G4 exist specifically to retire)
  under a different name; the flag itself becomes new backward-compat surface to remove
  later. Contradicts the feature's own premise.
- Implementation impact: negative — adds code instead of removing it.
- Dependency impact: none, but rejected on principle.

**Chosen: Option B.** It is the only option that both fully satisfies G1–G4 and avoids
a regression for `hermes-agent`'s RAG path, which today has no other way to reach
`rag-service` than the route this feature deletes.

## 4. Chosen Design

Consumers migrate off the plain `/sse` route before producers delete it. Concretely:

1. **`hermes-agent`** (`plugins/tools/rag.py`) starts passing `workspace_id=wid` to
   `call_mcp_tool()`, so the RAG connection becomes workspace-scoped
   (`/ws/<workspace_id>/sse`) exactly like the existing GitNexus call in
   `plugins/tools/gitnexus.py`. `gitnexus.py::handle()` gains the same
   "`workspace_id` is required" guard `rag.py` already has, closing the empty-string
   fallthrough. `plugins/mcp_client.py::_sse_endpoint()` drops its `elif` branch —
   every call site now always supplies a non-empty `workspace_id`, so building the
   plain `/sse` path is dead code once the two call sites above are fixed.
2. **`workflow`** (`runtime/executors/claude/src/mcp-endpoint-binding.ts`) drops the
   ternary in `buildMcpSseUrl()`; `workspaceId` becomes a required, non-optional
   parameter. This is already how the executor calls it in practice (`WORKSPACE_ID` is
   injected into every executor's env by the dispatcher — see `CLAUDE.md`'s Runtime ABI
   references), so this removes an unreachable-in-production branch and its dedicated
   test suite.
3. **`rag-service`** (`services/rag_server/server.py`) removes `Route("/sse", ...)`,
   `Mount("/messages/", _sse.handle_post_message)`, `handle_sse()`, and the module-level
   `_sse` transport instance built for it; `_resolve_workspace()` drops the
   `DEFAULT_WORKSPACE_ID` branch — precedence becomes connection path → explicit
   `rag_query` argument → error. `rag_query`'s docstring drops the "callers using the
   default `/sse` route" sentence.
4. **`rag-service`** (`services/indexer/main.py`, `workspace_resolver.py`) deletes the
   legacy `else` branch in `main()`, `run()`, `_load_workspace_repos()`,
   `_resolve_workspace_yaml_path()`, `bootstrap_workspace()`, `load_repo_paths()`,
   `_ensure_cloned()`. `WORKSPACE_URLS` becomes required — `main()` raises a clear
   config error if it is unset, instead of falling through to the deleted branch.
   `WORKSPACE_YAML_PATH`/`WORKSPACE_CLONE_DIR` env vars are removed (verified: used only
   by the deleted functions, §1).
5. **`git-nexus`** (`services/gitnexus_server/server.py`) removes `legacy_entry` and its
   eager startup in `lifespan()`, `_LEGACY_HOME`, `_LEGACY_WORKSPACE_ID`, the legacy
   `Route("/sse", ...)`/`Mount("/messages/", ...)`, `handle_sse()`, and
   `DEFAULT_WORKSPACE_ID`. The `/health` response drops the backward-compat top-level
   `registry`/`session`/`registry_path`/`default_workspace` keys, keeping only the
   `workspaces` list (per-workspace health is already there). `REGISTRY_PATH`/`_state`
   are removed unless still needed as internal test fixtures (verify at
   implementation time — see §5).
6. **`git-nexus`** (`services/gitnexus_indexer/index.js`) deletes the `WORKSPACE_URL`
   (singular) fallback; `WORKSPACE_URLS` becomes required, same fail-fast treatment as
   (4).
7. **`workflow`** (`runtime/orchestrator/templates/docker-compose.yml`,
   `docker-compose.local-docker.yml`, `claude/workflow_skills/init-agent/SKILL.md`)
   removes the `DEFAULT_WORKSPACE_ID` env wiring from both the `rag-server` and
   `gitnexus-server` containers and its documentation, once (3) and (5) no longer honor
   it.

**Compatibility considerations.** This is the one place the design is intentionally
*not* additive — it is a deletion, by design (that is the feature). The mitigation for
that risk is ordering (§5, §6), not backward compatibility: every real caller is
migrated to the surviving path before the old path is deleted, so no external behavior
regresses for `WORKSPACE_URLS`/`/ws/<id>/sse` users. Operators who still set
`WORKSPACE_URL`/`WORKSPACE_ID`/`DEFAULT_WORKSPACE_ID` (singular, unmigrated deployment)
will need to switch to `WORKSPACE_URLS` — this is the explicit intent of the feature and
is called out in the release notes (§8), not a silent break.

**Operational implications.** No data migration, no schema change, no new
infrastructure. Pure code/config deletion plus one small behavior change in two
consumers (RAG connection becomes workspace-scoped in `hermes-agent`).

## 5. Dependency Analysis

**Internal (cross-repo) dependencies**
- Producer route deletion (`rag-service` §4.3, `git-nexus` §4.5) depends on consumer
  migration (`hermes-agent` §4.1, `workflow` §4.2) landing first — this is the central
  ordering constraint of this feature (see Option B, §3).
- Indexer legacy-path deletion (`rag-service` §4.4, `git-nexus` §4.6) has **no**
  dependency on the consumer/server work — indexers are not called by `hermes-agent` or
  the runtime executor; they only write to Qdrant / the GitNexus data root. Confirmed:
  `docker-compose.yml`/`docker-compose.local-docker.yml` already require `WORKSPACE_URLS`
  unconditionally for both indexer containers (§1) — deployment needs **no** change for
  the indexer-side deletions.
- Deployment template/docs cleanup (`workflow` §4.7) depends on both server deletions
  (§4.3, §4.5) — removing `DEFAULT_WORKSPACE_ID` from the template before the servers
  stop honoring it would silently strand any deployment still relying on the default
  route with no way to configure it, one full release ahead of the route itself being
  gone.

**External dependencies / unresolved items — must be verified at implementation time**
- **Undiscovered plain-`/sse` callers.** This design verified `hermes-agent` and the
  `workflow` executor (the two consumers named in `workspace.yaml`) directly against
  their source. It did **not** exhaustively grep every repo in `workspace.yaml`
  (e.g. `digital-factory-ui`, `workflow-bff`, ad hoc dev scripts) for a hardcoded
  `.../sse` URL. The `rag-service`/`git-nexus` server tasks (§4.3, §4.5) must re-run
  this grep across all repos immediately before deleting the route, as a final gate —
  not a one-time design-time check.
- **`git-nexus` legacy `/health` fields.** Grepped `agent-workflow/runtime` and
  `workflow-backend` for `registry_path`/`default_workspace` — no consumer found. Not
  exhaustive; the implementing task should re-verify no external dashboard/monitor
  parses those top-level keys before removing them.
- **`REGISTRY_PATH`/`_state` module exports in `git-nexus/server.py`.** Docstring calls
  these "backward-compat: tests and external code may import" them. Implementation must
  check `git-nexus`'s own test suite and any known external importer before deleting —
  if only internal tests use them, update the tests instead of preserving the export.

No unresolved *blocking* decision remains — every item above is a verification step
assigned to a specific task, not an open design question.

## 6. Parallelization / Blocking Analysis

```
T1: rag-service — indexer legacy WORKSPACE_URL/WORKSPACE_ID removal
  └── Can begin now — no blockers (independent of server/consumer work, §5)
  │
T3: git-nexus — indexer legacy WORKSPACE_URL removal
  └── Can begin now — no blockers
  └── T1 and T3 run in parallel
  │
T5: workflow — remove buildMcpSseUrl legacy fallback, require workspaceId
  └── Can begin now — no blockers (workspaceId is already always injected in practice)
  │
T6: hermes-agent — RAG tool → connection-scoped /ws/<id>/sse; require workspace_id in
    gitnexus.py; remove mcp_client.py legacy fallback
  └── Can begin now — no blockers
  └── T5 and T6 run in parallel with T1 and T3 (Wave 1, four independent repos)
  │
  T2: rag-service — RAG server: delete default /sse route + DEFAULT_WORKSPACE_ID
        └── BLOCKED on T5 (workflow executor must no longer construct plain /sse)
        └── BLOCKED on T6 (hermes-agent's rag.py must no longer be the route's only caller)
  T4: git-nexus — server: delete legacy /sse route, eager legacy subprocess,
      DEFAULT_WORKSPACE_ID, legacy health fields
        └── BLOCKED on T5 (same reason)
        └── BLOCKED on T6 (hermes-agent gitnexus.py's empty-workspace_id fallthrough
            must be closed first)
        └── T2 and T4 run in parallel (Wave 2, independent repos, same blockers)
        │
        T7: workflow — remove DEFAULT_WORKSPACE_ID from docker-compose.yml +
            docker-compose.local-docker.yml + init-agent SKILL.md
              └── BLOCKED on T2 (rag-server no longer honors DEFAULT_WORKSPACE_ID)
              └── BLOCKED on T4 (gitnexus-server no longer honors DEFAULT_WORKSPACE_ID)
```

**Waves**
- **Wave 1 (parallel, four repos, all unblocked):** T1, T3, T5, T6.
- **Wave 2 (parallel):** T2, T4 — both after T5 **and** T6.
- **Wave 3:** T7 — after T2 and T4.

Note the direction reversal from the parent feature: there, consumers (T5/T7) were
blocked on producers (T2/T4) because the new route had to exist before anything could
connect to it. Here producers (T2/T4) are blocked on consumers (T5/T6) because the old
route must have no remaining caller before it is safe to delete.

## 7. Repository Impact

Repo ids match `workspace.yaml -> repos[].id` (`rag-service`, `git-nexus`, `workflow`,
`hermes-agent`).

| Repo | Why affected | Representative touch points |
|---|---|---|
| `rag-service` | Legacy indexer branch and legacy server route both live here, in independent modules (T1, T2). | `services/indexer/main.py` (`main()` legacy branch, `run()`, `_load_workspace_repos()`, `_resolve_workspace_yaml_path()`); `services/indexer/workspace_resolver.py` (`bootstrap_workspace()`, `load_repo_paths()`, `_ensure_cloned()`); `services/rag_server/server.py` (`Route("/sse", ...)`, `handle_sse()`, `_resolve_workspace()`'s `DEFAULT_WORKSPACE_ID` branch). |
| `git-nexus` | Same split as rag-service, plus more legacy surface in the server (eager subprocess, health fields) (T3, T4). | `services/gitnexus_indexer/index.js` (`WORKSPACE_URL` fallback); `services/gitnexus_server/server.py` (`legacy_entry`, `_LEGACY_HOME`, `_LEGACY_WORKSPACE_ID`, legacy `Route`/`Mount`, `handle_sse()`, `DEFAULT_WORKSPACE_ID`, legacy `/health` keys). |
| `workflow` (runtime + deployment) | Executor has its own legacy-fallback URL builder (T5); deployment templates/docs are the last consumer of `DEFAULT_WORKSPACE_ID` and must be updated only after the servers stop reading it (T7). | `runtime/executors/claude/src/mcp-endpoint-binding.ts` (`buildMcpSseUrl()`), its test file; `runtime/orchestrator/templates/docker-compose.yml`, `docker-compose.local-docker.yml`; `claude/workflow_skills/init-agent/SKILL.md`. |
| `hermes-agent` | Only remaining *primary* (non-fallback) caller of the plain `/sse` route (RAG tool) plus its own fallback URL builder (T6). | `plugins/tools/rag.py` (`handle()` — add `workspace_id=` to `call_mcp_tool()`); `plugins/tools/gitnexus.py` (`handle()` — require non-empty `workspace_id`); `plugins/mcp_client.py` (`_sse_endpoint()` — drop the `elif` fallback). |

## 8. Validation and Release Impact

**Testing expectations**
- Every deleted function/branch has its dedicated legacy-path tests removed, not left
  disabled: `rag-service` (`tests/rag_server/test_workspace_resolution.py`,
  `tests/indexer/test_workspace_resolver.py`, `tests/shared/test_schema.py` — legacy
  cases only), `git-nexus` (`services/gitnexus_indexer/__tests__/index.test.js`,
  `.../workspace.test.js`, `services/gitnexus_server/tests/test_server.py` — legacy
  cases only), `workflow` (`mcp-endpoint-binding.test.ts`'s `"legacy fallback"` describe
  block).
- Add/extend: `hermes-agent` — a test asserting `rag.py`'s `handle()` now passes
  `workspace_id=` to `call_mcp_tool()` (connection-scoped, not just the explicit
  argument); a test asserting `gitnexus.py`'s `handle()` errors clearly when no
  workspace context is set (mirroring `rag.py`'s existing "workspace_id is required"
  test) instead of silently falling through.
- Regression: existing multi-workspace isolation/no-collision/fail-fast tests (G2/G3/§4a
  from the parent feature) must still pass unchanged — this feature does not touch that
  code path.
- Full test suite per repo (per this workspace's Pre-push checks / Test-before-PR
  rules) — no partial runs.

**Migration/config impact**
- Any deployment still setting `WORKSPACE_URL`/`WORKSPACE_ID` (singular, indexers) or
  `DEFAULT_WORKSPACE_ID` (servers) must switch to `WORKSPACE_URLS` (one-element list is
  the single-workspace equivalent) before upgrading past this feature's release. No
  Qdrant/GitNexus data migration — storage layout is unchanged by this feature.

**Rollout concerns**
- Ship in dependency order (§6): consumers (T5, T6) before producers (T2, T4) before
  deployment docs (T7). Because Wave 1 tasks are independent PRs across four repos, they
  can merge in any order relative to each other, but **no Wave 2 PR should merge before
  both Wave 1 consumer PRs (T5, T6) are merged** — this is a real release-sequencing
  constraint, not just a task-graph nicety, since Wave 2 deletes the route Wave 1
  migrates off of.
- No cold-start/re-index concern — this feature does not touch index cycles.

**Backward compatibility**
- Explicitly not preserved for the deleted paths — that is this feature's purpose. What
  is preserved: `WORKSPACE_URLS`, `/ws/<workspace_id>/sse`, RAG's explicit
  `workspace_id` `rag_query` argument, all MCP tool names/result shapes, and
  single-workspace *capability* via a one-element `WORKSPACE_URLS`.
