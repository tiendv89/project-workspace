
# Technical Design

## Feature
- Feature ID: `go-orchestrator-handoff-ui`
- Title: Display Go Orchestrator Handoff PR Info

## Current State

**Data model (source of truth: `workflow-orchestrator` repo, Postgres schema in `db/schema/schema.sql`):**
- The Go orchestrator (`workflow-orchestrator`) owns two tables, written via sqlc-generated queries:
  - `handoffs` — one row per feature handoff. Written by `Queries.InsertHandoff` (`internal/database/queries/handoffs.sql.go:115-130`) when `CheckAndFinalizeHandoffs` / the handoff-trigger flow fires. Read back via `Queries.GetHandoffFeatureInfo` (`handoffs.sql.go:74-79`), which returns `FeatureID`, `FeatureName` (and, per schema, a `CreatedAt` column — confirmed indirectly via the `handoff_prs.CreatedAt` sibling column and `GetHandoffFeatureInfo`'s row shape; exact column list will be verified against `db/schema/schema.sql` at implementation time).
  - `handoff_prs` — one row per PR belonging to a handoff (a handoff can fan out to multiple repos/PRs). Model: `internal/database/queries/models.go:HandoffPr` with fields `ID`, `HandoffID`, `Repo`, `PrURL`, `Status`, `ConflictState`, `ConflictResolutionAttempts`, `DispatchHandle`, `DispatchNonce`, `DispatchedAt`, `ReenqueueAttempts`, `CreatedAt`, `UpdatedAt`. Written via `Queries.InsertHandoffPR` (`handoff_prs.sql.go:85-109`), read via `Queries.ListHandoffPRsByHandoff` (`handoff_prs.sql.go:119-151`), and mutated via `Queries.SetHandoffPRConflicted` — confirming `Status`/`ConflictState` together encode the open/merged/conflicted states we need.
  - These queries are consumed internally by `internal/orchestrator/feature_lifecycle.go` (`CheckAndFinalizeHandoffs`, `maybeFinalize`, `reconcileHandoffPRs`) and `internal/orchestrator/handoff_pr.go` (`getHandoffPRDispatchInfo`, `DispatchHandoffPRConflictResolution`).
- `workflow-orchestrator` exposes **no general REST API** — it only starts a `healthz` server (`cmd/orchestrator/main.go:startHealthzServer`). It is a headless background daemon; it does not serve reads for the frontend today.
- `workflow-backend` already writes into the same domain for go features (e.g. `internal/database/queries.go:insertGoTask`, `internal/service/task_create.go:WorkspaceService.CreateTasks`), confirming `workflow-backend` and `workflow-orchestrator` share the same Postgres database/schema and communicate via DB rows, not via a service-to-service HTTP API. This is the established integration pattern this feature will follow.
- `workflow-backend`'s `internal/handler/document.go` already has a `resolvePRState` helper and a `RegisterDocumentRoutes` handler that serves ts-flow's `handoffs/handoff.md` (git-file-based) content, including PR-state resolution for the ts case. This is the closest existing analog but is git/file-based (ts-flow only) and not applicable to reading go-flow's DB-native handoff rows.
- `workflow-bff` has a generic pass-through: `internal/app/api/handler/proxy/proxy_handler.go:ProxyHandler.Proxy` + `internal/app/api/handler/proxy/routing.go:RoutingTable.Resolve`/`TargetHosts`, which forwards FE requests to `workflow-backend` by route pattern (see `routing_test.go`: task-create, feature-name-filter, unblock routes are already wired this way). No aggregation/business logic lives in the BFF for these routes — it is pure routing.
- `digital-factory-ui` renders the feature detail view including a docs/handoff area (`FeatureIDEDocsPanel` / `feature-document-panel.tsx`), currently driven by `src/services/workflow-backend/documents.ts` (`getDocumentContent`, `apiErrorMessage`) which calls through the BFF.

## Constraints
- `workflow-orchestrator` must not be modified — no new HTTP API, no schema changes, no changes to handoff creation/finalization/conflict-resolution logic (per product spec non-goals).
- `workflow-bff` proxy/routing internals must not change — only a new routing-table entry may be added, using the existing pass-through mechanism (per product spec non-goals).
- Read-only surface: no write/mutate endpoints for handoff PRs.
- Must not affect ts-flow's existing `handoffs/handoff.md` file-based display path.
- `workflow-backend` and `workflow-orchestrator` are separate Go modules/binaries; `workflow-backend` cannot import `workflow-orchestrator`'s internal sqlc package directly (unexported `internal/` path across modules) — the read queries must be re-declared inside `workflow-backend` against the same shared schema.

## Options Considered
### Option A — `workflow-backend` reads `handoffs`/`handoff_prs` tables directly (shared DB)
- Pros:
  - Matches the existing integration pattern: `workflow-backend` already writes go-task rows (`insertGoTask`) into the same shared Postgres instance that `workflow-orchestrator` reads/writes — this is how the two services already talk today.
  - No new service dependency, no new network hop, no changes to `workflow-orchestrator` (satisfies the "do not modify orchestrator" constraint trivially).
  - Simple to implement: two new read-only SQL queries + one new handler + one new BFF route.
- Cons:
  - `workflow-backend` needs its own copy of the read queries (duplicated SQL, same shared schema) since it cannot import `workflow-orchestrator`'s internal Go package — a small amount of schema-shape duplication to keep in sync if `workflow-orchestrator`'s schema evolves.

### Option B — `workflow-orchestrator` exposes a new internal HTTP endpoint, `workflow-backend` calls it as a service client
- Pros:
  - Clean service boundary — `workflow-backend` never talks to `workflow-orchestrator`'s tables directly, no query duplication.
- Cons:
  - Requires adding a new HTTP handler/route to `workflow-orchestrator`, which today only exposes `healthz` — this is new server surface, arguably not a "change to handoff creation/finalization/conflict-resolution logic" but is still new API surface the spec's non-goals lean against ("read/display only... this is read/display only" refers to *this feature's* scope, but does not explicitly forbid adding a read API to the orchestrator). Given the ambiguity and the extra moving parts (new server, new service client akin to `workflow-bff`'s `serviceclient/workflowbackend/client.go`), this is more invasive than necessary.
  - Adds a runtime dependency: `workflow-backend` now needs orchestrator to be up and reachable just to answer a read for the UI; Option A only needs the DB, which `workflow-backend` already depends on.

## Chosen Design
**Option A** — `workflow-backend` reads the `handoffs` / `handoff_prs` tables directly via new sqlc-style read queries, colocated with `workflow-backend`'s existing database layer, and serves them through a new REST endpoint. `digital-factory-ui` calls this endpoint through the existing `workflow-bff` proxy (new routing-table entry only, no BFF logic changes).

### 1. `workflow-backend` — data layer
Add two new read queries (query names indicative; final SQL/sqlc annotations decided at implementation time against `db/schema/schema.sql`, which is either vendored/shared or replicated as a read model in `workflow-backend`'s own migrations directory — this must be confirmed against how `workflow-backend` currently reads go-owned tables, e.g. `insertGoTask`'s connection setup):
- `GetHandoffForFeature(featureID) (*Handoff, error)` — returns `{ id, feature_id, created_at }`, or `sql.ErrNoRows` when no handoff exists yet.
- `ListHandoffPRsForHandoff(handoffID) ([]HandoffPR, error)` — returns one row per PR: `{ repo, pr_url, status, conflict_state }`, ordered by `repo` (or `created_at`) for stable rendering.

Status normalization: derive a single display status per PR from `Status` + `ConflictState`:
- `conflict_state != "" / true` → `Conflicted`
- else `Status == "merged"` → `Merged`
- else → `Open`

(Exact enum values will be confirmed against `handoff_prs`'s column definitions in `db/schema/schema.sql` during implementation; the handler is the single place this mapping lives, so the mapping is testable independent of DB specifics.)

### 2. `workflow-backend` — API
New handler in `internal/handler/` (new file, e.g. `handoff.go`, alongside the existing `document.go`/`workspace.go` handlers), following the same handler/service pattern as `WorkspaceHandler`:

```
GET /api/workspaces/{workspaceId}/features/{featureId}/handoff
```

Response shape (handoff exists — HTTP 200):
```json
{
  "created_at": "2026-07-03T14:22:00Z",
  "prs": [
    { "repo": "workflow-orchestrator", "pr_url": "https://github.com/.../pull/741", "status": "merged" },
    { "repo": "digital-factory-ui",    "pr_url": "https://github.com/.../pull/318", "status": "open" }
  ]
}
```
When no handoff row exists: HTTP `404 Not Found` (empty body, or a minimal `{"error": "handoff not found"}` following this codebase's existing error-response conventions in `internal/app/api/response/http_response.go`) — per REST convention, absence of the handoff sub-resource for this feature is represented as a 404, distinct from a 404 caused by an unknown `workspaceId`/`featureId` (which is validated and rejected earlier in the handler chain, before the handoff lookup, so the two 404 cases are not conflated at the point they're raised).

This endpoint only makes sense for `owner: go` features; for ts-flow features it returns `404` (or the handler may short-circuit based on the feature's `owner` field, mirroring existing owner-based branching such as `TestCreateTasks_400_NonGoFeature`) — no behavior change to the ts-flow `handoffs/handoff.md` path.

### 3. `workflow-bff` — routing only
Add one entry to `RoutingTable` (`internal/app/api/handler/proxy/routing.go`) mapping the new route pattern `GET /api/workspaces/:workspaceId/features/:featureId/handoff` to the `workflow-backend` target host, following the exact pattern already used for task-create / feature-name-filter / unblock (see `routing_test.go: TestTaskCreateAndFeatureNameRoutesResolveToWorkflowBackend`). No changes to `ProxyHandler.Proxy` itself, no new BFF business logic — pure pass-through, per the product spec's non-goal.

### 4. `digital-factory-ui` — frontend
- Add a new service function alongside `src/services/workflow-backend/documents.ts` (or a sibling `handoff.ts` in the same `services/workflow-backend/` directory) that calls the **`workflow-bff` URL** for the new route (never the raw `workflow-backend` host) — consistent with how `documents.ts:getDocumentContent` already routes through the BFF.
- Add a `HandoffSection` component (new file near `feature-document-panel.tsx` / `feature-ide-docs-panel.tsx`) rendered on the feature detail view for `owner: go` features:
  - Calls the new endpoint on mount/feature-change.
  - `404` response → renders the "No handoff yet." empty state (per product-spec mockup) — the FE treats this specific 404 as an expected, non-error UI state (distinct from network/auth/other errors, which render a generic error state instead).
  - `200` response → renders `Created: <created_at>` once above a table with columns **Repo / PR (link) / Status**, one row per entry in `prs[]`. Status renders as a colored badge (🟢 Merged / 🟡 Open / 🔴 Conflicted), reusing the existing status-glyph conventions in `src/components/board/status-glyph.tsx` where feasible for visual consistency with the rest of the board.
- ts-flow features continue to use the existing `handoffs/handoff.md`-based path unchanged; the new `HandoffSection` is only mounted for `owner: go` features (mirrors the existing owner-based branching already present in the codebase, e.g. `TestNullOwnerFeatureAndTasks_SurfaceWithoutOwnerField`, `TestCreateTasks_400_NonGoFeature`).

## Dependency Analysis
- **New `workflow-backend` read queries** depend only on the shared Postgres schema (`handoffs`, `handoff_prs` tables) already populated by `workflow-orchestrator`. Confirmed: `workflow-orchestrator` and `workflow-backend` share the same Postgres database (`workflow_backend` DB) — no new infra, no schema migration, and no cross-service schema-sharing step needed. `workflow-backend` can query the `handoffs`/`handoff_prs` tables directly with a plain read-only SQL query against its existing DB connection, the same way it already writes go-owned rows (e.g. `insertGoTask`).
- **New `workflow-backend` handler/endpoint** depends on the new queries (must land first).
- **`workflow-bff` routing entry** depends on the new `workflow-backend` endpoint existing (path/method must match) but is otherwise independent code — can be authored in parallel and merged either order, verified together in an integration/e2e pass.
- **`digital-factory-ui` service + component** depends on the new BFF route being live (frontend must call the BFF URL, not `workflow-backend` directly, per product spec) — must land last, or be feature-flagged/dark-launched if merged ahead of the BFF route.

## Parallelization / Blocking Analysis
- **Track 1 (workflow-backend):** new queries → new handler/endpoint. Sequential within this track; independent of the other repos until endpoint contract (path + response shape) is fixed.
- **Track 2 (workflow-bff):** routing-table entry. Can be scaffolded in parallel once the endpoint's path/method is agreed, but functionally blocked on Track 1 being deployed to be end-to-end testable.
- **Track 3 (digital-factory-ui):** service function + `HandoffSection` component. Can be built against a mocked response shape in parallel with Tracks 1–2, but end-to-end verification is blocked on both landing.
- Recommended task order: T1 (workflow-backend queries + endpoint) → T2 (workflow-bff routing entry, depends on T1's contract) → T3 (digital-factory-ui integration, depends on T2) → T4 (end-to-end verification against a real go feature with a handoff).
