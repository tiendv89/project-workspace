# Product Specification

## Feature
- Feature ID: `multi-workspace-rag-gitnexus`
- Title: Multi-workspace support for RAG and GitNexus

## Problem

The two code-intelligence services that back the agent runtime — the **RAG service**
(`rag-service`) and **GitNexus** (`git-nexus`) — are each operationally bound to a
single workspace.

- **GitNexus** is pinned by a single `WORKSPACE_URL` environment variable read once at
  process startup. It clones every repo into a flat `repos/<repo_id>/` path with no
  workspace prefix, writes one global `registry.json` with no workspace partitioning,
  and exposes MCP tools (`query`, `context`, `impact`, `list_repos`, `group_query`)
  that have **no workspace parameter** — every call hits the one global index.
- **RAG** is already workspace-aware on the *query* path (`rag_query` takes a
  `workspace_id`, Qdrant collections are keyed by workspace, points are filtered by
  workspace), but its **indexer** reads a single `WORKSPACE_ID` env var at startup, so
  one indexer process can only ever populate one workspace.

Today, serving a second workspace means standing up a **second, fully duplicated stack**
(indexer + server + storage) per workspace. That is operationally heavy, wastes compute
and memory (each stack reloads embedding models, holds its own volumes), multiplies the
number of MCP endpoints agents must be routed to, and makes onboarding a new workspace a
deploy event rather than a config change.

As the number of workspaces grows (each team / project / client gets its own workspace),
this one-stack-per-workspace model does not scale.

This is not only a producer-side change. The two **consumers** of these services — the
`agent-workflow` agent runtime (orchestrator + executors) and `hermes-agent` — already
multiplex many workspaces through a single instance, but they do not consistently scope
their RAG/GitNexus calls to the active workspace. RAG queries from hermes-agent already
carry a `workspace_id`; GitNexus calls from both consumers carry none, and in-agent RAG
calls during a runtime task rely on the model remembering to pass the right workspace.
Closing the multi-workspace gap therefore spans four repositories, not two.

## Goals

- **G1 — One stack, many workspaces.** A single deployed RAG stack and a single deployed
  GitNexus stack can index and serve **multiple workspaces concurrently**, configured
  declaratively (add a workspace to config; no new containers, no redeploy of the others).
- **G2 — Strict isolation between workspaces.** A query scoped to workspace A must never
  return results, symbols, or repos belonging to workspace B. No cross-workspace leakage
  in either service.
- **G3 — No identifier collisions.** The same repo (or the same file/symbol within it)
  indexed under two different workspaces must not collide in storage — distinct
  point IDs / registry entries / on-disk paths per workspace.
- **G4 — Workspace-scoped query surface.** Every MCP/HTTP query entry point can be scoped
  to a specific workspace. GitNexus tools gain a workspace selector; RAG's existing
  `workspace_id` parameter is preserved.
- **G5 — Independent indexing lifecycle.** Adding, removing, or re-indexing one workspace
  does not interrupt or corrupt indexing for the others. A failure indexing one workspace
  is isolated and does not halt the whole indexer.
- **G6 — Backward compatibility.** A single-workspace deployment continues to work with
  no behavior change for existing callers; the multi-workspace config is additive.

## Non-goals

- **Authn/authz between workspaces.** This feature provides *logical* isolation (correct
  scoping), not a security/permission boundary or per-tenant access control. Callers are
  trusted to request the right workspace.
- **Dynamic per-request workspace onboarding.** Workspaces are added via configuration and
  picked up on the next index cycle — not created on the fly from an MCP call.
- **Cross-workspace federated queries.** Answering a single query across multiple
  workspaces at once is out of scope; each query targets exactly one workspace.
  (GitNexus's existing `group_query` across repos *within* a workspace is preserved.)
- **Resource quotas / fairness scheduling between workspaces.** Throttling or prioritizing
  one workspace's indexing over another is out of scope for this iteration.
- **Migration of historical indexes.** Re-indexing from source is acceptable; we do not
  commit to in-place migration of existing single-workspace volumes.
- **Changing the embedding model, graph schema, or query semantics.** This feature is
  about *tenancy*, not retrieval quality.

## Scope — affected repositories

| Repo | Role | What changes |
|---|---|---|
| `rag-service` | producer | Indexer must drive N workspaces from config; point IDs namespaced by workspace. Query path already workspace-aware. |
| `git-nexus` | producer | Workspace-keyed config, per-workspace registry + clone paths, and a workspace selector on the MCP tools. |
| `agent-workflow` (runtime) | consumer | Scope in-agent RAG/GitNexus calls to the task's workspace; multi-workspace deployment templates (`docker-compose`, `init-agent`). RAG pre-flight already passes `workspace_id`. |
| `hermes-agent` | consumer | Add workspace scoping to GitNexus calls (RAG already scoped via session context). |

The mechanism by which a workspace-bound caller scopes its queries — without relying on
the model to pass the right `workspace_id` on every call — is the central design question
and is deferred to the technical design (e.g. connection-scoped endpoint vs. explicit
argument). See Open Questions.

## Success Criteria

- A single RAG stack, configured with two workspaces, indexes both and answers
  `rag_query` correctly for each with zero cross-workspace results.
- A single GitNexus stack, configured with two workspaces, indexes both; `list_repos`
  scoped to workspace A returns only A's repos; `query`/`context`/`impact` scoped to A
  never surface B's symbols.
- Adding a third workspace is a config edit picked up on the next index cycle — no new
  containers and no redeploy of the existing services.
- An existing single-workspace deployment upgraded to the new version continues to work
  with its current configuration unchanged.

## Open Questions (for technical design)

- Where does the per-workspace config live and what is its shape (one combined config
  listing N workspaces, vs. a directory of per-workspace files)?
- For GitNexus: per-workspace registry files + workspace-prefixed clone paths, vs. a
  single registry with a workspace column — and how the MCP server routes a scoped call.
- How a caller/agent selects the target workspace per MCP tool call (explicit argument vs.
  session/connection context), and the default when only one workspace is configured. This
  must cover both consumers: the runtime executor's in-agent calls and hermes-agent's
  session-scoped calls. Connection-scoped binding (endpoint path / header / token set by
  the runtime at spawn time) is the leading candidate because it removes the model's
  ability to query the wrong workspace.
- Indexer concurrency model: index workspaces sequentially within one loop vs. in parallel
  worker pools, and how failure isolation (G5) is enforced.
