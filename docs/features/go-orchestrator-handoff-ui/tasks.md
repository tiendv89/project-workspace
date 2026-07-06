
# Tasks — go-orchestrator-handoff-ui

## Dependency Diagram

```
T1 (workflow-backend: queries + endpoint)
   │
   ▼
T2 (workflow-bff: routing entry)
   │
   ▼
T3 (digital-factory-ui: service + HandoffSection UI)
   │
   ▼
T4 (end-to-end verification)
```

## Index

| ID | Title | Repo | Depends On | Actor |
|---|---|---|---|---|
| T1 | Handoff read queries + `GET .../handoff` endpoint | workflow-backend | | agent |
| T2 | workflow-bff routing entry for handoff endpoint | workflow-bff | T1 | agent |
| T3 | Handoff section UI (service call + table/empty state) | digital-factory-ui | T2 | agent |
| T4 | End-to-end verification against a real go feature handoff | workflow-backend | T3 | agent |

---

## T1 — Handoff read queries + `GET .../handoff` endpoint

### Description
In `workflow-backend`, add read-only access to the `handoffs` / `handoff_prs` tables (same Postgres DB shared with `workflow-orchestrator` — confirmed no migration needed) and expose it via a new REST endpoint:

```
GET /api/workspaces/{workspaceId}/features/{featureId}/handoff
```

- Add `GetHandoffForFeature(featureID)` — returns the handoff row (`id`, `feature_id`, `created_at`) or "not found".
- Add `ListHandoffPRsForHandoff(handoffID)` — returns one row per PR (`repo`, `pr_url`, `status`, `conflict_state`), ordered by `repo`.
- Normalize each PR's display status in the handler: `conflict_state` set → `conflicted`; else `status == "merged"` → `merged`; else → `open`.
- Response (200, handoff exists):
  ```json
  { "created_at": "2026-07-03T14:22:00Z", "prs": [ { "repo": "...", "pr_url": "...", "status": "merged" } ] }
  ```
- Response (404): no handoff row exists for the feature, OR the feature is not `owner: go` (ts-flow features never have DB-backed handoffs) — follow the existing error-response conventions in `internal/app/api/response/http_response.go`.
- Do not modify `workflow-orchestrator` at all — this task only adds new, additive, read-only code to `workflow-backend`.
- Add unit/integration tests: handoff exists (single PR, multiple PRs), handoff not found, non-go-owned feature, and each status-normalization branch (open/merged/conflicted).

### Required skills
- go-best-practices

### Subtasks
- [ ] Confirm exact column names/types for `handoffs` and `handoff_prs` against `db/schema/schema.sql` (or equivalent shared schema reference) before writing queries.
- [ ] Add `GetHandoffForFeature` and `ListHandoffPRsForHandoff` read queries.
- [ ] Add new handler (e.g. `internal/handler/handoff.go`) implementing `GET /api/workspaces/{workspaceId}/features/{featureId}/handoff`, wired into the router alongside existing handlers.
- [ ] Implement status normalization (open/merged/conflicted) in the handler layer.
- [ ] Implement 404 behavior for "no handoff" and "non-go-owned feature".
- [ ] Add unit + integration tests covering all response branches.
- [ ] Run full test suite + lint; open PR.

---

## T2 — workflow-bff routing entry for handoff endpoint

### Description
Add a single new entry to `workflow-bff`'s `RoutingTable` (`internal/app/api/handler/proxy/routing.go`) mapping:

```
GET /api/workspaces/:workspaceId/features/:featureId/handoff  →  workflow-backend
```

Follow the exact existing pattern used for task-create / feature-name-filter / unblock routes (see `routing_test.go: TestTaskCreateAndFeatureNameRoutesResolveToWorkflowBackend`). Do not modify `ProxyHandler.Proxy` or add any BFF-side business logic — this is a pure routing-table addition, pass-through only.

### Required skills
- go-best-practices

### Subtasks
- [ ] Add the new route pattern to `RoutingTable` resolving to the `workflow-backend` target host.
- [ ] Add a routing test mirroring `TestTaskCreateAndFeatureNameRoutesResolveToWorkflowBackend` for the new route.
- [ ] Verify no changes to `ProxyHandler.Proxy` itself; run full test suite + lint; open PR.

---

## T3 — Handoff section UI (service call + table/empty state)

### Description
In `digital-factory-ui`, add a `HandoffSection` for the feature detail view, shown only for `owner: go` features:

- Add a new service function (alongside `src/services/workflow-backend/documents.ts`, e.g. a sibling `handoff.ts`) that calls the new endpoint **through the `workflow-bff` URL** (never the raw `workflow-backend` host) — consistent with `documents.ts:getDocumentContent`.
- Add a `HandoffSection` component (near `feature-document-panel.tsx` / `feature-ide-docs-panel.tsx`):
  - On mount/feature-change, call the service function.
  - `404` → render "No handoff yet." empty state (treated as expected, non-error UI state — not a generic error).
  - `200` → render `Created: <created_at>` once, followed by a table with columns **Repo / PR (link) / Status**, one row per `prs[]` entry. Status renders as a colored badge (🟢 Merged / 🟡 Open / 🔴 Conflicted), reusing `src/components/board/status-glyph.tsx` conventions where feasible.
  - Any other error (network, 5xx, etc.) → render a generic error state, distinct from the 404 empty state.
- Mount `HandoffSection` only for `owner: go` features; ts-flow features keep using the existing `handoffs/handoff.md`-based path unchanged.
- Add component tests for: no-handoff (404) state, populated table state (multiple PRs, mixed statuses), and generic-error state.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Add service function calling the BFF URL for the new handoff endpoint.
- [ ] Add `HandoffSection` component with empty/table/error states per mockup in the product spec.
- [ ] Wire `HandoffSection` into the feature detail view, gated on `owner: go`.
- [ ] Add component tests for all three states.
- [ ] Run full test suite + lint; open PR.

---

## T4 — End-to-end verification against a real go feature handoff

### Description
Verify the full path works end-to-end against a real `owner: go` feature that has a completed or in-progress handoff:
- Confirm `workflow-backend`'s endpoint returns correct data directly.
- Confirm `workflow-bff`'s route correctly proxies to it.
- Confirm `digital-factory-ui` renders the table (and empty state, tested against a go feature with no handoff yet) as expected.
- Confirm ts-flow features are entirely unaffected (their `handoffs/handoff.md` panel still renders as before).

This task does not add new product code; it is a verification pass and may include small fixes if integration issues are found (fixes should be scoped back to the relevant repo's task if substantial).

### Required skills
- go-best-practices

### Subtasks
- [ ] Verify `workflow-backend` endpoint response for a go feature with a handoff (multiple PRs, mixed statuses).
- [ ] Verify `workflow-backend` endpoint 404 for a go feature without a handoff.
- [ ] Verify `workflow-bff` proxies the route correctly end-to-end.
- [ ] Verify `digital-factory-ui` renders both states correctly in a running environment.
- [ ] Verify a ts-flow feature's handoff display is unchanged.
- [ ] Record verification results in the PR/task log.
