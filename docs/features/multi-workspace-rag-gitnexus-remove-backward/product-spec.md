# Product Specification

## Feature
- Feature ID: `multi-workspace-rag-gitnexus-remove-backward`
- Title: Remove backward-compatible single-workspace paths from RAG/GitNexus

## Problem

`multi-workspace-rag-gitnexus` added multi-workspace support to the RAG service
(`rag-service`) and GitNexus (`git-nexus`), and made **backward compatibility with the
old single-workspace deployment a hard goal (G6)** of that feature — a single-workspace
deployment had to keep working unchanged while the multi-workspace path was built and
proven out. That meant every producer shipped **two parallel code paths** side by side:

- **Indexers** (RAG and GitNexus) accept the new `WORKSPACE_URLS` (comma-separated) config
  *and* still parse the old singular `WORKSPACE_URL` (+ optional `WORKSPACE_ID`) env vars,
  treating a one-element `WORKSPACE_URLS` as equivalent to the legacy shape.
- **Servers** (RAG server and GitNexus server) expose the new workspace-scoped
  `GET /ws/<workspace_id>/sse` route *and* keep the old default `/sse` route alive,
  resolving it to a single "default workspace" via `DEFAULT_WORKSPACE_ID` or the sole
  configured workspace.
- **Deployment** (`docker-compose.yml`, `docker-compose.local-docker.yml`, the
  `init-agent` skill) still documents and defaults to the single-workspace
  `WORKSPACE_ID`/`WORKSPACE_URL` shape as the simplest path, with `WORKSPACE_URLS` as the
  opt-in multi-workspace variant.
- **Test suites** in both producer repos carry dedicated cases asserting the legacy
  single-workspace path still works, alongside the new multi-workspace cases.

Now that RAG and GitNexus both work well on the multi-workspace config
(`WORKSPACE_URLS` / `/ws/<workspace_id>/sse`), carrying the old single-workspace path
forward indefinitely is unnecessary cost: two config surfaces to document and reason
about (`WORKSPACE_URL` vs `WORKSPACE_URLS`, default `/sse` vs `/ws/<id>/sse`), two code
paths to keep passing tests on every change, and a lingering "one deployment = one
workspace" assumption baked into the default deployment templates and onboarding docs.
This feature removes that superseded path so `WORKSPACE_URLS` and `/ws/<workspace_id>/sse`
become the *only* supported shape, for every deployment regardless of workspace count.

## Goals

- **G1 — Single config shape.** Indexers (RAG and GitNexus) accept only `WORKSPACE_URLS`
  (comma-separated); the singular `WORKSPACE_URL`/`WORKSPACE_ID` parsing path is deleted,
  including the "one-element list behaves like the legacy shape" special-casing.
- **G2 — Single routing shape.** RAG and GitNexus servers accept only the workspace-scoped
  `GET /ws/<workspace_id>/sse` (+ paired POST message route). The default `/sse` route and
  its `DEFAULT_WORKSPACE_ID`/sole-workspace fallback resolution are deleted.
- **G3 — Deployment reflects the single shape.** `docker-compose.yml`,
  `docker-compose.local-docker.yml`, and the `init-agent` skill configure every
  deployment — including a single-workspace one — via `WORKSPACE_URLS` and
  `/ws/<workspace_id>/sse`, with no remaining reference to the retired env vars or route.
- **G4 — Clean test suite.** Tests that exist solely to pin the legacy single-workspace
  behavior are removed; multi-workspace test coverage (isolation, no-collision,
  fail-fast on duplicate `workspace_id`) is otherwise unaffected.
- **G5 — No functional regression for real callers.** Every existing deployment is
  migrated to `WORKSPACE_URLS`/`/ws/<workspace_id>/sse` as part of this change — this is a
  removal of a redundant path, not a removal of single-workspace *capability* (a
  single-workspace deployment is just `WORKSPACE_URLS` with one entry).

## Non-goals

- **RAG's explicit `workspace_id` argument on `rag_query`.** That is a distinct,
  still-supported call shape for callers that aren't connection-scoped — it is not
  single-workspace legacy and is out of scope for removal here.
- **Any change to the multi-workspace design itself.** Connection-scoped routing,
  per-workspace storage namespacing (Qdrant collection/point IDs, GitNexus per-workspace
  `HOME`), the subprocess-pool model, and `workspace_id` uniqueness/fail-fast validation
  all stay exactly as `multi-workspace-rag-gitnexus` built them.
- **MCP tool names or result shapes.** No consumer-visible tool contract changes.
- **Consumer (runtime executor / hermes-agent) endpoint construction.** Both already build
  workspace-scoped `/ws/<id>/sse` URLs unconditionally (T5, T7) — there is no legacy
  fallback on the consumer side to remove.
- **New workspace-management or onboarding features.** This is a cleanup of superseded
  code paths, not new product surface.

## Scope — affected repositories

| Repo | Role | What changes |
|---|---|---|
| `rag-service` | producer | Delete the legacy `WORKSPACE_URL`/`WORKSPACE_ID` indexer parsing path; delete the default `/sse` route and `DEFAULT_WORKSPACE_ID` fallback on the RAG server; drop legacy-path tests. |
| `git-nexus` | producer | Delete the legacy single `WORKSPACE_URL` indexer parsing path; delete the default `/sse` route and default-workspace fallback on the GitNexus server; drop legacy-path tests. |
| `agent-workflow` (runtime) | deployment | Update `docker-compose.yml`, `docker-compose.local-docker.yml`, and the `init-agent` skill so every deployment (including single-workspace) is documented and configured via `WORKSPACE_URLS`/`/ws/<workspace_id>/sse`, with the retired env vars and route removed from templates and docs. |
| `hermes-agent` | consumer | No expected change — already connection-scoped via `/ws/<workspace_id>/sse` from `multi-workspace-rag-gitnexus` (T7); verify no residual reference to the default `/sse` route. |

## Success Criteria

- Neither the RAG indexer nor the GitNexus indexer parses `WORKSPACE_URL`/`WORKSPACE_ID`
  — `WORKSPACE_URLS` is the only accepted config, and a single-workspace deployment is
  simply a one-element list.
- Neither the RAG server nor the GitNexus server serves a default `/sse` route —
  every MCP connection resolves via `/ws/<workspace_id>/sse`.
- `docker-compose.yml`, `docker-compose.local-docker.yml`, and the `init-agent` skill
  contain no reference to `WORKSPACE_URL` (singular), `WORKSPACE_ID` as a standalone
  server/indexer config, `DEFAULT_WORKSPACE_ID`, or the default `/sse` route.
- A fresh single-workspace deployment, built entirely from the post-removal templates and
  skill, still works end-to-end (index + query) using a one-element `WORKSPACE_URLS`.
- The full test suites of `rag-service` and `git-nexus` pass with the legacy-path test
  cases removed and no remaining reference to the retired config/route in either suite.

## Open Questions (for technical design)

- Is there any deployed environment still relying on the legacy `WORKSPACE_URL`/default
  `/sse` route today that must be migrated *before* the code path is deleted, or can the
  removal ship together with the migration in one change?
- Does `hermes-agent`'s MCP client or config retain any dormant reference to the old
  default `/sse` route (e.g. as a fallback) that should be cleaned up alongside the
  producer-side removal, even though its primary path is already connection-scoped?
