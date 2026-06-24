# Technical Design

## Feature
- Feature ID: `multi-workspace-rag-gitnexus`
- Title: Multi-workspace support for RAG and GitNexus

---

## 1. Current State

Two code-intelligence services back the agent runtime, and two consumers call them.

### Producers

**`rag-service`** — `indexer` + `rag_server` + Qdrant.
- The **query path is already workspace-aware**: `rag_query(query, workspace_id, top_k, source_types)` (`services/rag_server/server.py:122`); Qdrant collection name = `workspace_id` (`services/shared/qdrant_init.py:26`, `collection_name_for`); every point carries `workspace_id` and queries filter on it (`services/shared/schema.py`, `build_workspace_filter`).
- The **indexer is single-workspace**: it reads one `WORKSPACE_ID` env var once at startup (`services/indexer/main.py:310`) and indexes the `repos[]` of one mounted `workspace.yaml` into that one workspace.
- **Point IDs are not workspace-scoped**: `_point_id(repo_path, rel_path, chunk_index)` (`services/indexer/main.py:97`) hashes only the path triple — the same repo indexed under two workspaces produces colliding IDs.
- PR-index state file (`services/indexer/pr_indexer.py`) is a single un-namespaced `pr_index_state.json`.

**`git-nexus`** — `gitnexus_indexer` (Node) + `gitnexus_server` (Python) sharing a `gitnexus-data` volume.
- Single-workspace **throughout**. One `WORKSPACE_URL` env var read once (`services/gitnexus_indexer/index.js:9`). Repos cloned flat to `repos/<repo_id>/` with **no workspace prefix** (`src/git.js:99`). The workspace management repo is cloned to a fixed `_workspace` dir (`src/workspace.js:37`).
- One **global** registry at `$HOME/.gitnexus/registry.json` (`services/gitnexus_server/server.py:33`), with no workspace partitioning.
- The server wraps a **single** `gitnexus mcp` stdio subprocess (`server.py:69`, `command="gitnexus", args=["mcp"]`) keyed entirely off `HOME` (`env={"HOME": GITNEXUS_DATA}`). The CLI (`gitnexus@1.x`, an opaque npm package) reads everything from `$HOME/.gitnexus/`.
- The MCP tools (`query`, `context`, `impact`, `list_repos`, `group_query`, `detect_changes`) have **no workspace parameter** — every call hits the one global registry.

### Consumers

**`workflow`** (the agent-workflow runtime, orchestrator + executors).
- Already knows the workspace: orchestrator reads `workspace_id` from `workspace.yaml` and threads it onto every `DispatchJob` (`runtime/executor/queue-dispatch.ts:122`, ABI `runtime/abi/src/types.ts:69`); the dispatcher injects `WORKSPACE_ID` into the executor env (`runtime/dispatcher/src/spawner.ts:256`).
- **RAG pre-flight already passes `workspace_id`** (`runtime/orchestrator/src/bootstrap/fetch-rag-context.ts:61`) — no change needed there.
- **In-agent MCP calls are not workspace-bound**: the claude executor registers the MCP servers as plain SSE URLs (`runtime/executors/claude/src/index.ts:411-417`, `url: ${mcpRagUrl}/sse`, `url: ${gitnexusMcpUrl}/sse`). When the agent calls `rag_query`/`gitnexus.*` mid-task, RAG relies on the model passing the right `workspace_id`, and GitNexus cannot pass one at all.
- **Deployment templates hardcode one workspace**: `runtime/orchestrator/templates/docker-compose.yml` pins a single `WORKSPACE_ID` (rag-server + indexer, ~lines 164/193), a single `WORKSPACE_URL` (gitnexus-indexer, ~line 240), and mounts one `workspace.yaml`. The `init-agent` skill (`claude/workflow_skills/init-agent/SKILL.md`, step 4) sets up the stack with one `WORKSPACE_ID`.

**`hermes-agent`** (a long-lived agent service that already multiplexes many sessions/workspaces).
- **RAG: already scoped.** `plugins/tools/rag.py:77` resolves `workspace_id` from the tool arg or thread-local session context (`plugins/context.py`, set per session at `src/api/agent_dispatch.py:260`) and forwards it.
- **GitNexus: not scoped.** `plugins/tools/gitnexus.py` `_build_arguments()` produces `{query|name|target, repo, direction}` with **no workspace_id**; `list_indexed_repos()` (called at context-injection time, `plugins/hooks.py:176`) is likewise unscoped.
- The MCP client (`plugins/mcp_client.py`) opens a fresh SSE connection per call and auto-appends `/sse` to the base URL (`RAG_MCP_URL`, `GITNEXUS_MCP_URL` in `.env`).

### Current limitations

- Serving N workspaces requires N fully duplicated stacks (indexer + server + storage). Onboarding a workspace is a deploy event, not a config change.
- GitNexus has no logical isolation between workspaces at all; RAG has it on the read path but cannot populate more than one workspace per indexer process.

---

## 2. Problem Framing

### What must change
1. **RAG indexer** must populate **N workspaces** from configuration in one process, with **workspace-namespaced point IDs** (no cross-workspace collisions — product goal G3).
2. **GitNexus** must isolate workspaces end-to-end: per-workspace clone paths, per-workspace registry, and a **workspace selector** on the MCP surface (G2, G3, G4).
3. **Both consumers** must scope their RAG/GitNexus calls to the active workspace **without trusting the model** to pass the right id on every call.
4. **Deployment** (compose templates + `init-agent`) must configure one stack serving N workspaces; adding a workspace is a config edit picked up on the next index cycle (G1, G5).

### What must remain stable
- RAG's existing `rag_query` argument shape and Qdrant collection-per-workspace model (additive only — G6).
- The GitNexus MCP **tool names and result shapes** — consumers and `CLAUDE.md` lookup rules depend on them.
- A single-workspace deployment must keep working unchanged (G6).

### Fixed assumptions (from product spec)
- Single multi-tenant instance (not multi-instance).
- Logical isolation only — **no** per-tenant authz, federated cross-workspace queries, quotas, or in-place index migration. **Re-index from source is the accepted migration path.**

---

## 3. Options Considered

### Decision A — How a workspace-bound caller scopes its queries

**Option A1 — Explicit per-call argument (status quo for RAG).**
Every tool takes a `workspace_id`; the calling agent must supply it on every call.
- Pros: smallest server change; RAG already does this; trivially backward-compatible.
- Cons: **fragile** — relies on the model remembering the id on every call; GitNexus tools would all need a new required arg the model must populate; a wrong/blank id silently queries the wrong (or no) workspace. Fails the "without trusting the model" requirement.
- Implementation impact: consumer-side only; producers mostly unchanged.
- Dependency impact: none new.

**Option A2 — Connection-scoped endpoint (chosen).**
The workspace is bound to the **MCP connection**, not the call: the SSE endpoint carries the workspace (URL path `…/ws/<workspace_id>/sse`). The runtime/hermes set the endpoint from the workspace they already know, at spawn/session time. The server resolves the workspace from the connection; the model cannot get it wrong because it never names a workspace.
- Pros: removes model trust entirely; one mechanism for **all** tools (RAG and every GitNexus tool) with **no per-tool schema churn**; matches reality that each executor/session has exactly one workspace; backward-compatible via a default route.
- Cons: servers must parse the workspace from the connection and route; SSE mount must be parameterised.
- Implementation impact: producer servers gain a routing layer; consumers change only the endpoint URL they construct.
- Dependency impact: consumers depend on the server-side route existing.

**Option A3 — Per-workspace endpoint URL (separate base URL per workspace).**
- Pros: no server routing logic.
- Cons: drifts back toward multi-instance (the rejected direction); needs external routing/DNS per workspace; explosion of env vars (`MCP_RAG_URL_<ws>`).
- Implementation impact: rejected — contradicts the single-instance decision.
- Dependency impact: external routing infra.

**Chosen: A2 (connection-scoped), with A1 retained as a backward-compatible fallback** — RAG keeps accepting an explicit `workspace_id` argument; when a connection is workspace-scoped, the connection wins. Single-workspace deployments use a default route and behave exactly as today.

### Decision B — GitNexus multi-workspace storage & subprocess model

**Option B1 — Per-workspace `HOME` (chosen).**
Give each workspace its own data root: `HOME=/gitnexus-data/<workspace_id>`, so its registry is `/gitnexus-data/<workspace_id>/.gitnexus/registry.json` and its repos live under `/gitnexus-data/<workspace_id>/repos/<repo_id>/`. The indexer builds per-workspace HOMEs; the server runs **one `gitnexus mcp` subprocess per workspace**, each launched with that workspace's `HOME`, and routes a connection-scoped request to the matching subprocess.
- Pros: **zero changes to the opaque `gitnexus` CLI** — isolation falls out of `HOME`; full data isolation; matches the connection-scoped routing of Decision A.
- Cons: one subprocess per active workspace (modest memory); server must manage a pool of subprocess sessions keyed by workspace.
- Implementation impact: `git-nexus` indexer + server; no CLI dependency change.
- Dependency impact: server (T4) depends on indexer layout (T3).

**Option B2 — Single registry with a `workspace` column + per-call filter.**
- Pros: one subprocess.
- Cons: the `gitnexus` CLI is a third-party black box — we cannot add a workspace column or a per-call filter to its registry/tools without forking it. Not viable without owning the CLI.
- Implementation impact: rejected — requires CLI changes we don't control.
- Dependency impact: would couple us to a CLI fork.

**Chosen: B1 (per-workspace HOME).** It reuses the CLI unmodified and gives the strongest isolation. Subprocesses are spawned lazily on first request for a workspace (or eagerly from the configured list) and cached.

### Decision C — Multi-workspace configuration shape (indexers)

Both indexers **clone**: each reads a workspace management repo from a git URL, then clones the
code repos listed in that repo's `workspace.yaml` (RAG: `services/indexer/main.py:22-24`, falling
back to a `local_path` mount when present; GitNexus: `src/git.js`). Today each is pinned to **one**
management-repo URL (`WORKSPACE_URL`). Multi-workspace therefore needs a **list of management-repo
URLs** — because the different workspaces live on different GitHub URLs/orgs (e.g.
`tiendv89/project-workspace`, `SwellNetwork/faro-workspace`) and the system itself must acquire them.

**No new config file is introduced.** The `workspace_id` and `repos[]` already live **inside** each
management repo's existing `workspace.yaml`. So the *only* new input is the list of URLs; everything
else is read from each clone.

**Option C1 — `WORKSPACE_URLS` env var, comma-separated (chosen).** Generalise the existing
`WORKSPACE_URL` scalar into a comma-separated list, mirroring the `GITHUB_TOKEN=a,b` convention from
`workspace-github-adapter-multi-github-token`. For each URL the indexer clones the management repo,
reads `workspace_id` + `repos[]` from its `workspace.yaml`, and indexes accordingly.
- Pros: **no new file**; one env var, consistent with existing conventions; `workspace_id` comes
  from the repo itself (no external mapping to keep in sync); adding a workspace = append a URL.
- Cons: a long list lives in an env var (acceptable; same as the token list).
- Implementation impact: split `WORKSPACE_URLS` on `,`, loop the existing single-`WORKSPACE_URL`
  clone/read path per entry.
- Dependency impact: deployment (T6) sets the env var; no mounted file.

**Option C2 — A new `workspaces.yaml` file listing `{id, repo_url}`.** (Previously chosen; rejected
per direction.)
- Pros: structured, room for per-workspace metadata.
- Cons: a new file to author, mount, and keep in sync; duplicates the `workspace_id` already present
  inside each management repo. Heavier than the problem needs.

**Chosen: C1 (`WORKSPACE_URLS` env var).** No new files. `workspace_id` is derived from each cloned
`workspace.yaml`. The indexer iterates the URL list, indexing each into its own workspace_id (RAG) /
its own HOME (GitNexus), and **isolates failures per workspace** (G5) so one bad workspace does not
halt the loop. The legacy single `WORKSPACE_URL` (+ optional `WORKSPACE_ID`) path is retained for
single-workspace mode — a one-element `WORKSPACE_URLS` behaves identically.

**`workspace_id` is the global partition key — the repo URL is only its source.** This has two
consequences that the implementation must enforce:

- **Clone path is URL-derived, not id-derived (chicken-and-egg).** `workspace_id` is unknown until
  *after* the management repo is cloned, so the clone cache is keyed by the URL's owner/repo:
  `<WORKSPACES_DIR>/<owner>/<repo>/`. Only the **logical** partition (RAG collection, GitNexus
  `HOME`, `/ws/<id>/sse` routing) is keyed by the `workspace_id` read from the clone.
- **`workspace_id` must be unique across `WORKSPACE_URLS` (fail-fast).** Two different management
  repos — e.g. `tiendv89/faro-workspace` and `SwellNetwork/faro-workspace` — that both declare
  `workspace_id: faro-workspace` are a genuine identity collision: they would share one Qdrant
  collection / one GitNexus `HOME` / one `/ws/faro-workspace/sse` route, and the **consumers**
  (orchestrator, hermes-agent) — which also identify a workspace by `workspace_id` — could not tell
  them apart either. The indexer must detect duplicate `workspace_id` after the clone-and-read step
  and **refuse to start**, naming the conflicting URLs (clear config error, mirroring
  `workspace-github-adapter-multi-github-token`). The fix is operator-side: give each workspace a
  distinct `workspace_id` in its `workspace.yaml` (the repo name is irrelevant to identity).

Config shape — one env var, no file:

```bash
# Multi-workspace: comma-separated management-repo URLs. workspace_id + repos[]
# are read from each repo's own workspace.yaml after cloning.
WORKSPACE_URLS=git@github.com:tiendv89/project-workspace.git,git@github.com:SwellNetwork/faro-workspace.git

# Legacy single-workspace (still supported):
# WORKSPACE_URL=git@github.com:tiendv89/project-workspace.git
```

### Decision D — Cross-org credentials

The workspaces above span different GitHub orgs. The general solution is to **route credentials by
repo owner** — the proven model from feature `workspace-github-adapter-multi-github-token`
(comma-separated token list, probe-and-cache, retry-on-401, matched on the repo's `owner`). Both
RAG and GitNexus indexers already parse the repo owner (RAG: `_parse_github_full_name`,
`services/indexer/main.py:91-95`).

**Decision (v1): a single shared SSH key.** For this iteration we use **one `SSH_PRIVATE_KEY`** that
has read access to every configured workspace's repos across orgs — exactly the existing credential
mechanism, unchanged. The multi-workspace work is purely "clone/index multiple repos". This keeps
v1 small and avoids new credential-routing code.

- **Assumption (must hold):** the single SSH key (a machine user added to each org/repo) can read
  *all* repos in *all* configured workspaces. If a repo is unreachable, that workspace's index
  fails in isolation (G5) and is logged — it does not block the others.
- **Deferred (future enhancement, explicitly out of scope here):** per-owner credential routing
  (multiple SSH keys or comma-separated `GITHUB_TOKEN`s selected by repo owner). When a single key
  can no longer cover all orgs, adopt the `workspace-github-adapter-multi-github-token` pattern.
  Decision A/B/C do not change when that lands — only the credential-resolution step does.

---

## 4. Chosen Design

A single RAG stack and a single GitNexus stack each serve N workspaces, driven by a directory of per-workspace `workspace.yaml` files, with the active workspace bound to each MCP **connection** via a `…/ws/<workspace_id>/sse` endpoint.

### The Multi-Workspace Contract (frozen here)

This is the cross-cutting agreement every task builds against:

1. **Endpoint convention.** RAG and GitNexus SSE servers expose `GET /ws/<workspace_id>/sse` (and the paired POST message route). The legacy `/sse` route remains and resolves to a **default workspace** (the sole configured workspace, or one named by `DEFAULT_WORKSPACE_ID`) — this is the backward-compat path (G6).
2. **Workspace resolution precedence (server side).** connection path `ws/<id>` → explicit `workspace_id` argument (RAG only) → default workspace → else error.
3. **Storage namespacing.**
   - RAG: Qdrant collection stays `= workspace_id`; point IDs become `hash(workspace_id | repo_path | rel_path | chunk_index)`.
   - GitNexus: data root per workspace = `/gitnexus-data/<workspace_id>/` (registry + repos underneath).
4. **Config.** Indexers read `WORKSPACE_URLS` (comma-separated management-repo URLs — no new file), clone each into a URL-derived cache path `<WORKSPACES_DIR>/<owner>/<repo>/`, and read `workspace_id` + `repos[]` from each clone's own `workspace.yaml`. The legacy single `WORKSPACE_URL` env remains supported (single-workspace mode).
4a. **`workspace_id` uniqueness.** `workspace_id` is the global partition key (collection / GitNexus `HOME` / `/ws/<id>/sse` route / consumer identity). It must be unique across `WORKSPACE_URLS`; the indexer detects duplicates after clone-and-read and **fails fast**, naming the conflicting URLs. The repo name/org is not part of identity.
5. **Credentials (v1).** A single shared `SSH_PRIVATE_KEY` with read access to all configured workspaces' repos across orgs. Per-owner credential routing is a deferred enhancement (Decision D).
6. **Tool surface is unchanged.** No new required tool arguments; GitNexus tool names and result shapes are untouched. Scoping is entirely connection-driven.
7. **Failure isolation.** Indexing iterates workspaces independently; a failure in one is logged and skipped, never aborting the cycle (G5).

### Affected repositories

| Repo (`workspace.yaml` id) | Role | Change |
|---|---|---|
| `rag-service` | producer | Indexer clones N management repos from `WORKSPACE_URLS` (single shared SSH key) into `WORKSPACES_DIR`; reads `workspace_id` + `repos[]` from each clone; indexes each into collection `= workspace_id` with point IDs namespaced by `workspace_id`; PR-index state namespaced. RAG server adds connection-path workspace resolution (param retained as fallback). |
| `git-nexus` | producer | Indexer clones N management repos from `WORKSPACE_URLS` (single shared SSH key) and builds a per-workspace `HOME` (registry + clone paths under `/gitnexus-data/<ws>/`). Server runs one `gitnexus mcp` subprocess per workspace and routes connection-scoped requests to it. |
| `workflow` | consumer | Claude executor builds workspace-scoped MCP endpoint URLs (`…/ws/${WORKSPACE_ID}/sse`) from the env it already has. Deployment compose templates + `init-agent` skill updated for the N-workspace stack. |
| `hermes-agent` | consumer | MCP client targets `…/ws/<workspace_id>/sse` per session context; GitNexus tool path + `list_indexed_repos()` become workspace-scoped (reusing the existing context resolver RAG already uses). |

### Compatibility considerations
- All changes are **additive**. Single-workspace deployments keep working via the default `/sse` route, `WORKSPACE_ID` env, and a single mounted `workspace.yaml`.
- RAG's `rag_query` argument shape is unchanged; the new behaviour is "connection path wins if present".
- GitNexus tool names/results are unchanged — no consumer that only reads results needs to change beyond the endpoint URL.

### Operational / release implications
- **Re-index at rollout (expected, automatic).** GitNexus's per-workspace `HOME`/clone-path change means existing flat-layout data does not match; the indexer rebuilds from source on its first cycle. RAG's point-ID namespacing similarly orphans old points; the affected collection is effectively re-indexed. Both are derived data — safe to rebuild, one-time cost per workspace, no manual migration (consistent with the product non-goal).
- **Cold-start window.** After deploy, a workspace returns partial/empty results until its first index cycle completes. Rollout should index the primary workspace first and tolerate degraded results during warm-up.

---

## 5. Dependency Analysis

**Internal**
- The **Multi-Workspace Contract** (§4) is the single frozen decision all tasks depend on. It is fixed in this document — no open external decision gates the work.
- GitNexus server (T4) depends on the GitNexus indexer (T3) for the on-disk `HOME`/registry layout it must read.
- Both consumers (T5 workflow executor, T7 hermes-agent) depend on the **server-side** endpoint convention existing — RAG server (T2) and GitNexus server (T4).
- Deployment/init-agent (T6) depends on the **indexer** config shapes (T1 RAG indexer, T3 GitNexus indexer) it must wire up.

**External / tooling**
- `gitnexus` CLI is third-party and **not modified** — the per-workspace `HOME` design is specifically chosen to avoid any CLI dependency. No version bump required.
- Qdrant: no version change; collection-per-workspace model is already in place.

**Credentials (v1 assumption — must hold)**
- A single shared `SSH_PRIVATE_KEY` (machine user) must have read access to **every** repo in **every** configured workspace, across all orgs (e.g. both `tiendv89/*` and `SwellNetwork/*`). This is a hard precondition for v1 (Decision D). A repo the key cannot read fails that workspace's index in isolation (G5) — surfaced in logs, not blocking others.
- Per-owner credential routing is **deferred** to a future feature (reuse `workspace-github-adapter-multi-github-token`). Not a blocker for v1, but the boundary where this assumption breaks.

**Configuration**
- New env: `WORKSPACE_URLS` (comma-separated management-repo URLs — no new file) + `WORKSPACES_DIR` clone cache (indexers), `DEFAULT_WORKSPACE_ID` (servers, optional). Existing `WORKSPACE_URL`/`WORKSPACE_ID` retained for single-workspace mode.

**Unresolved**
- Whether the GitNexus server spawns subprocesses **eagerly** (from the configured list) or **lazily** (on first request) is an implementation choice inside T4 — both satisfy the contract; lazy is preferred to bound memory to active workspaces.

---

## 6. Parallelization / Blocking Analysis

External decisions: **none** — the Multi-Workspace Contract (§4) is frozen in this design.

```
T1: rag-service — indexer multi-workspace + namespaced point IDs        [repo: rag-service]
  └── Can begin now — no blockers
  │
T2: rag-service — RAG server connection-scoped workspace resolution     [repo: rag-service]
  └── Can begin now — no blockers (orthogonal to T1; both touch rag-service)
  │
T3: git-nexus — indexer per-workspace HOME/clone/registry + config      [repo: git-nexus]
  └── Can begin now — no blockers
  │
  T1, T2, T3 run in parallel (Wave 1)
  │
  T4: git-nexus — server per-workspace subprocess routing + /ws/<id>/sse [repo: git-nexus]
  │     └── BLOCKED on T3 (per-workspace HOME/registry layout must be produced and frozen)
  │
  T6: workflow — multi-workspace compose templates + init-agent skill    [repo: workflow]
        └── BLOCKED on T1 (RAG indexer config shape — WORKSPACES_DIR — must be final)
        └── BLOCKED on T3 (GitNexus indexer HOME/config shape must be final)
        └── T4 and T6 run in parallel (Wave 2)
        │
        T5: workflow — executor connection-scoped MCP endpoint binding   [repo: workflow]
        T7: hermes-agent — connection-scoped endpoints + GitNexus scoping [repo: hermes-agent]
              └── BLOCKED on T2 (RAG server must accept /ws/<id>/sse)
              └── BLOCKED on T4 (GitNexus server must accept /ws/<id>/sse + routing)
              └── T5 and T7 run in parallel (Wave 3)
```

**Waves**
- **Wave 1 (parallel):** T1, T2, T3 — all unblocked.
- **Wave 2 (parallel):** T4 (after T3), T6 (after T1 + T3).
- **Wave 3 (parallel):** T5, T7 — both after the server endpoints exist (T2 + T4).

---

## 7. Repository Impact

| Repo | Why affected | Representative touch points |
|---|---|---|
| `rag-service` | Indexer must serve N workspaces; clone paths AND point IDs must be collision-free; server must resolve workspace from connection. | `services/indexer/main.py`: `main()` loops `WORKSPACE_URLS` and reads `workspace_id` **per-clone from `workspace.yaml`** (replacing the single `WORKSPACE_ID` env at `main.py:348`); `_point_id` namespaced by `workspace_id`; `run`/`index_repo` invoked per workspace. `services/indexer/workspace_resolver.py`: **namespace both clone dests** — mgmt repo `dest = base/"_workspace"` (`:164`) and code repo `dest = _CLONE_BASE/repo_id` (`:189`) are currently un-namespaced; key them per workspace (URL-derived for the mgmt repo, `<workspace_id>/<repo_id>` for code repos) so two workspaces never clone to the same dir. `services/shared/qdrant_init.py`: `collection_name_for` already `= workspace_id`. `services/indexer/pr_indexer.py` (state-file namespacing). `services/rag_server/server.py` (SSE route + resolution precedence). |
| `git-nexus` | Single-workspace throughout; needs per-workspace HOME + connection routing. | `services/gitnexus_indexer/index.js`, `src/workspace.js`, `src/git.js`, `src/analyzer.js` (per-workspace HOME/clone/registry, config loop); `services/gitnexus_server/server.py` (per-workspace subprocess pool, `/ws/<id>/sse` mount, routing). |
| `workflow` | Consumer must bind workspace to MCP connection; deployment must configure N-workspace stack. | `runtime/executors/claude/src/index.ts:411-417` (workspace-scoped URLs); `runtime/orchestrator/templates/docker-compose.yml` (+ `docker-compose.local-docker.yml`); `claude/workflow_skills/init-agent/SKILL.md`. RAG pre-flight (`fetch-rag-context.ts`) already correct. |
| `hermes-agent` | Consumer must scope GitNexus + target per-workspace endpoint. | `plugins/mcp_client.py` (endpoint construction), `plugins/tools/gitnexus.py` (`_build_arguments`, `handle`, `list_indexed_repos`), `plugins/hooks.py` (injection-time scoping). RAG (`plugins/tools/rag.py`) already resolves workspace context. |

Repo ids match `workspace.yaml -> repos[].id` (`rag-service`, `git-nexus`, `workflow`, `hermes-agent`).

---

## 8. Validation and Release Impact

**Testing expectations**
- **Isolation (G2):** with two workspaces configured, a query/connection scoped to A returns zero results/symbols/repos from B — assert for RAG (`rag_query`) and every GitNexus tool (`query`, `context`, `impact`, `list_repos`, `group_query`).
- **No collisions (G3):** index the *same* repo (and, for RAG, two workspaces that each list a repo with the *same* `repo_id`) into two distinct workspaces; assert distinct RAG **clone dirs** and **point IDs**, and distinct GitNexus registry entries / clone paths; no overwrite. (Guards the `_CLONE_BASE/repo_id` collision in `workspace_resolver.py:189`.)
- **Duplicate `workspace_id` fail-fast (§4a):** two `WORKSPACE_URLS` whose `workspace.yaml` both declare the same `workspace_id` (e.g. `tiendv89/faro-workspace` + `SwellNetwork/faro-workspace` both `→ faro-workspace`) → indexer exits with a clear error naming both URLs; it must **not** silently merge them into one collection / HOME.
- **Backward compat (G6):** single-workspace config (legacy `/sse`, `WORKSPACE_ID`, single `workspace.yaml`) behaves exactly as before — regression-test existing suites in all four repos.
- **Failure isolation (G5):** a malformed/unreachable repo in workspace A does not stop workspace B from indexing.
- **Consumer wiring:** runtime executor and hermes-agent build the `…/ws/<id>/sse` endpoint from their known workspace; integration test that an agent turn for workspace A only ever reaches A's data.

**Migration / config impact**
- New: `WORKSPACES_DIR` (indexers), optional `DEFAULT_WORKSPACE_ID` (servers). Compose templates mount a directory of `workspace.yaml` files instead of one file.
- One-time re-index at rollout (GitNexus per-workspace HOME; RAG point-ID change). No manual data migration — rebuild from source.

**Rollout concerns**
- Cold-start window per workspace until first index cycle; index the primary workspace first.
- Roll producers (T1–T4) before flipping consumers (T5, T7) to the `/ws/<id>/sse` endpoints; the default `/sse` route keeps consumers working during the transition.

**Backward compatibility**
- All changes additive; legacy single-workspace deployments unaffected. Tool names and result shapes unchanged.

**Deployment / handoff implications**
- `init-agent` gains a multi-workspace setup path (directory of management-repo clones / `workspace.yaml` files). Single-workspace setup remains the default for simple installs.

---

---

## Appendix A — Config & clone-cache layout

**Input** — one env var, no file. `workspace_id` + `repos[]` are read from each cloned repo's own
`workspace.yaml`:

```bash
# Multi-workspace: comma-separated management-repo URLs
WORKSPACE_URLS=git@github.com:tiendv89/project-workspace.git,git@github.com:SwellNetwork/faro-workspace.git

WORKSPACES_DIR=/gitnexus-data                 # clone cache root (GitNexus also = HOME root)
SSH_PRIVATE_KEY=...                           # one key, read access to all orgs (v1)

# Legacy single-workspace mode (still supported):
# WORKSPACE_URL=git@github.com:tiendv89/project-workspace.git
# WORKSPACE_ID=project-workspace
```

**Resulting layout.** Management repos clone to a **URL-derived** path (unique before `workspace_id`
is known); the **logical** index storage is keyed by the `workspace_id` read from each clone:

```
/gitnexus-data/                              ← WORKSPACES_DIR
├── tiendv89/project-workspace/   ← mgmt-repo clone (URL-derived); workspace.yaml read here
│                                    declares workspace_id: project-workspace
├── SwellNetwork/faro-workspace/  ← mgmt-repo clone (URL-derived)
│                                    declares workspace_id: faro-workspace
│
├── project-workspace/            ← logical store, keyed by workspace_id
│   ├── repos/<repo_id>/          ← cloned code repos for this workspace
│   └── .gitnexus/registry.json   ← GitNexus: HOME=/gitnexus-data/project-workspace
└── faro-workspace/
    ├── repos/<repo_id>/
    └── .gitnexus/registry.json   ← GitNexus: HOME=/gitnexus-data/faro-workspace
```

RAG indexes each workspace's repos into Qdrant collection `= workspace_id` (point IDs namespaced by
`workspace_id`); GitNexus runs one `gitnexus mcp` subprocess per workspace with that workspace's
`HOME`. **If two URLs resolve to the same `workspace_id`, the indexer fails fast** (see §4a).
Onboarding a workspace = append a URL to `WORKSPACE_URLS`; the next index cycle clones and indexes
it — no new container, no redeploy.

---

> **Phase 1 (Design) complete.** Task breakdown (`tasks.md` + `tasks/T<n>.yaml`) is produced in Phase 2, after this design is approved.
