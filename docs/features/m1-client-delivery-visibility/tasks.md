# Tasks — m1-client-delivery-visibility

> Feature status: `in_tdd` (reference). Stage status: `tasks/draft` until human approval.
> Machine-mutable state for each task lives in `tasks/T<n>.yaml`. This file is narrative
> only — descriptions, required skills, and subtask checklists.

## Index

| ID | Wave | Title | Repo | Depends on |
|---|---|---|---|---|
| T1 | 1 | `workflow-backend` — activate workspace scoping in service layer | workflow-backend | — |
| T2 | 1 | `workflow-backend` — activity-feed allowlist + `audience=client` relabel | workflow-backend | — |
| T3 | 1 | `digital-factory-ui` — remove write affordances from client-reachable routes | digital-factory-ui | — |
| T4 | 1 | `digital-factory-ui` — move `/connect` to `/admin/connect` + admin layout guard | digital-factory-ui | — |
| T5 | 2 | `digital-factory-ui` — no-membership `EmptyState` + replace `/connect` redirects | digital-factory-ui | T4 |
| T6 | 1 | `digital-factory-ui` — client vocabulary mapping at status-render sites | digital-factory-ui | — |
| T7 | 2 | `digital-factory-ui` — 30s focus-aware polling + manual Refresh button | digital-factory-ui | T3 |
| T8 | 2 | `digital-factory-ui` — wire activity feed to `audience=client` | digital-factory-ui | T2 |

> **Note on parallelism.** T1 and T2 are both in `workflow-backend` and may run in parallel
> (they touch different files); each ships its own PR into `feature/m1-client-delivery-visibility`.
> T3, T4, T6 are independent frontend tasks and may run in parallel.
> T5 waits on T4 (the `platform_admin` empty-state variant links to `/admin/connect`).
> T7 waits on T3 (the Refresh button reuses the slot freed by removing the Sync control).
> T8 waits on T2 (backend must accept the `audience=client` parameter first).

---

## T1 — `workflow-backend` — activate workspace scoping in service layer

### Description

Activate the commented-out `authmw.FromContext` blocks in
`workflow-backend/internal/service/workspace.go` so every read endpoint filters by
`AccessibleWorkspaceIDs` and 404s on out-of-scope IDs. This is the single largest
blocker to letting a non-Kitelabs user log in safely (see §1.3 gap #1 in the technical
design). The contract is unchanged when `AuthCtx` is absent (development/unauthenticated
path) — current behaviour is preserved.

Endpoints in scope:

- `ListWorkspaces` — filter by `AccessibleWorkspaceIDs`; empty list when none.
- `GetWorkspace` — 404 when ID not in scope.
- `SearchFeatures`, `SearchTasks`, `GetTask` — 404 when workspace not in scope.
- `ListActivity` — 404 when workspace not in scope (separate from T2's `audience` work).

The 404 must use the existing `ErrDatabaseNotFound` so the frontend's existing
not-found UI renders. Do not introduce a new authorization error type.

Audit sibling service files (`internal/database/queries.go`, any other workspace-scoped
fetchers) for unscoped queries discovered during T1; activate them in the same task.

### Required skills

- backend-engineer
- go-best-practices

### Subtasks

- [ ] Audit `internal/service/workspace.go` for commented-out `authmw.FromContext` blocks
- [ ] Activate scoping in `ListWorkspaces`
- [ ] Activate scoping in `GetWorkspace`, `SearchFeatures`, `SearchTasks`, `GetTask`, `ListActivity`
- [ ] Confirm `AuthCtx` absent → preserve current pass-through behaviour
- [ ] Audit sibling service files (e.g. `ListGitHubSources`) for unscoped queries; activate
- [ ] Use existing `ErrDatabaseNotFound` for the 404 path
- [ ] Unit tests: list scoped to `AccessibleWorkspaceIDs`; empty list when none; 404 for out-of-scope ID; pass-through when `AuthCtx` absent
- [ ] Integration test: two-organization isolation case (sign in as `client_member` of org A; `/api/workspaces` returns only org A; org B 404s; `platform_admin` sees both)

---

## T2 — `workflow-backend` — activity-feed allowlist + `audience=client` relabel

### Description

Add an optional `audience` query parameter to
`GET /api/workspaces/:workspaceId/activity`. When `audience=client`, filter
`workspace_activity_events.action` to the M1 client allowlist and rewrite each row's
`action` field to the client-friendly label on the response DTO. Default audience
is `internal` — backwards-compatible (existing callers are unaffected).

Allowlist + label map (from §3 Option 4 in the technical design):

| Action | `audience=client`? | Client label |
|---|---|---|
| `created` | yes | Created |
| `ready` | yes | Ready |
| `started` | yes | Started |
| `work_phase_complete` | yes | Progress |
| `done` | yes | Completed |
| `blocked` | yes | Blocked |
| `reviewer_complete` | yes | Reviewed |
| `cancelled` | yes | Cancelled |
| `claimed`, `rag_pre_flight`, `reviewer_started`, `fix_started`, `review_blocked`, `retried` | no | (filtered out) |

The allowlist lives in `workflow-backend` (single source of truth). When new task-log
action names are added by the workflow, this allowlist must be revisited — a one-line
maintenance step per new action.

### Required skills

- backend-engineer
- go-best-practices

### Subtasks

- [ ] Add `audience` query parameter parsing to the `ListActivity` handler
- [ ] Implement allowlist filter and label rewrite for `audience=client`
- [ ] Default (parameter absent or `audience=internal`) preserves the existing unfiltered, unrenamed response
- [ ] Reject unknown `audience` values with HTTP 400
- [ ] Unit test: allowlist filters out non-allowlisted actions; labels rewritten for each allowlisted action
- [ ] Unit test: parameter absent returns the unfiltered list (no behaviour change)
- [ ] Integration test: `?audience=client` end-to-end against seeded activity rows

---

## T3 — `digital-factory-ui` — remove write affordances from client-reachable routes

### Description

Delete every write affordance from `/board`, `/feature/*`, and `/task/*`. After this
task, these routes contain no button, no drag handler, no inline form, no comment box,
and no onClick handler that issues a POST/PUT/DELETE — for any role. The product
spec is explicit: "no commenting, no approving, no `@mention`, no spec-drafting" on
the client surface. Operator-only screens move under `/admin/*` in T4; this task is
the deletion pass on the client-reachable routes themselves (see §3 Option 5B).

Note: this task creates the slot in `BoardHeader` that T7 fills with the manual
Refresh button.

### Required skills

- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks

- [ ] Remove `CreateTaskButton` import + render from `BoardHeader`
- [ ] Remove `CreateTaskButton` import + render from `KanbanBoard`
- [ ] Delete the unused `CreateTaskButton` component file once nothing imports it
- [ ] Remove the "Sync" action from `BoardHeader` (the slot is reused by T7)
- [ ] Audit `FeatureBoardView`, `TaskBoardView`, `FeatureDetailSheet`, `FeatureTabView`, `TaskTrackingPanel` for onClick handlers issuing POST/PUT/DELETE; delete them
- [ ] Remove any drag-to-reorder / status-transition handlers in `KanbanBoard` (the board renders columns from `status` but does not transition status)
- [ ] Component tests assert `BoardHeader` no longer renders `CreateTaskButton` or the old Sync control
- [ ] E2E test: a logged-in `client_member` sees no "Create task" / "Sync" / "Import" controls on `/board`, `/feature/*`, or `/task/*`

---

## T4 — `digital-factory-ui` — move `/connect` to `/admin/connect` + admin layout guard

### Description

Relocate the operator-only workspace import form to `/admin/connect` and gate the
entire `/admin/*` tree behind a single server-side `platform_admin` check at the
layout level. After this task, a `client_member` cannot reach the import form by
URL or by link. The route `/connect` is **deleted, not redirected** — it was
operator-internal; the small bookmark break is acceptable (see §8 Rollout in the
technical design).

The layout guard is the single point of authorization for operator screens; no
per-control role check is added inside `/admin/*` pages (Option 5B principle:
gate once, at the boundary).

### Required skills

- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks

- [ ] Create `src/app/admin/layout.tsx`; body returns `notFound()` when `session.user.memberships[*].role` does not include `platform_admin`
- [ ] Move `src/app/connect/page.tsx` to `src/app/admin/connect/page.tsx` (preserve all import-form behaviour)
- [ ] Delete the `src/app/connect/` directory after the move
- [ ] Audit and update any internal links / `router.push` calls that target `/connect`
- [ ] Manual verification: `/admin/connect` returns 404 for `client_member`; renders for `platform_admin`
- [ ] E2E test: `client_member` direct-navigating to `/admin/connect` receives 404

---

## T5 — `digital-factory-ui` — no-membership `EmptyState` + replace `/connect` redirects

### Description

Resolve the "signed-in user with zero memberships lands on `/connect`" gap (§1.3 gap
#3 in the technical design). Build a single `EmptyState` component with role-aware
variants and use it to replace the two existing redirect-to-`/connect` branches
(root page and `/board`). For `client_member` and any non-`platform_admin`, the
state is a friendly "contact your delivery lead" message with logout. For
`platform_admin`, it additionally renders an inline link to `/admin/connect`
(which exists after T4).

This task depends on T4 because the `platform_admin` variant's "Import workspace"
link points at the new `/admin/connect` route.

### Required skills

- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks

- [ ] Create `src/features/workspaces/components/EmptyState.tsx` with role-aware variants
- [ ] `client_member` variant copy: "Your workspace will appear here as soon as your engagement is set up. If you expected to see something, contact your Kitelabs delivery lead." + visible Logout button
- [ ] `platform_admin` variant: same copy + inline "Import workspace" link to `/admin/connect`
- [ ] In `src/app/page.tsx`: when `me.accessible_workspace_ids.length === 0`, render `EmptyState` instead of redirecting to `/connect`
- [ ] In `src/app/board/page.tsx`: replace the `summaries.length === 0` redirect-to-`/connect` branch with `EmptyState`
- [ ] Unit tests for both role variants of `EmptyState`
- [ ] E2E test: zero-membership login renders `EmptyState`, never the `/connect` import form

---

## T6 — `digital-factory-ui` — client vocabulary mapping at status-render sites

### Description

Add `clientStatusLabel(taskStatus)` and `clientFeatureStatusLabel(featureStatus)`
helpers in `src/features/board/lib/status.ts` (the existing status-definition
home) and replace every status-string render site with helper calls. The API
response is unchanged; the mapping lives entirely on the frontend (Option 2B).
Status pill colour mapping is unchanged.

Mapping tables are in §3 Option 2B of the technical design. Notable collapses:
`reviewing`, `review_passed`, `review_incomplete` all render as "In review" for
the client — the holding/audit distinctions are internal-only.

### Required skills

- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks

- [ ] Add `clientStatusLabel(taskStatus)` covering all 11 task statuses (`todo`, `ready`, `in_progress`, `in_review`, `reviewing`, `review_passed`, `change_requested`, `review_incomplete`, `blocked`, `done`, `cancelled`)
- [ ] Add `clientFeatureStatusLabel(featureStatus)` covering all 8 feature statuses (`in_design`, `in_tdd`, `ready_for_implementation`, `in_implementation`, `in_handoff`, `done`, `blocked`, `cancelled`)
- [ ] Audit status-render sites (`BoardHeader`, `KanbanBoard`, `FeatureBoardView`, `TaskBoardView`, `FeatureDetailSheet`, `FeatureTabView`, `TaskTrackingPanel`, any others) and replace direct status strings with helper calls
- [ ] Confirm status pill colour mapping remains correct after relabel (colour keys by API status, not by label)
- [ ] For `blocked` tasks, render `blocked_reason` verbatim under the "Blocked" label only when non-empty
- [ ] Unit tests covering all 11 task-status and 8 feature-status mappings

---

## T7 — `digital-factory-ui` — 30s focus-aware polling + manual Refresh button

### Description

Add a 30-second focus-aware background refresh of the active workspace in the
workspace context provider, plus a manual icon-only Refresh button in `BoardHeader`
(reusing the slot freed by T3's Sync removal). The product spec's "near-real-time
or on refresh" target is satisfied without building stream infrastructure (Option
3A in the technical design).

Refresh re-reads the workspace from the backend; it does **not** trigger a GitHub
re-sync (that is a separate operator action that no longer lives on this surface).

Depends on T3: the Refresh button occupies the `BoardHeader` slot that T3 frees
by removing the Sync control. Sequencing T7 after T3 avoids a merge collision in
`BoardHeader`.

### Required skills

- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks

- [ ] In `src/features/workspaces/context/WorkspaceContext.tsx`: schedule a re-fetch every 30s while `document.visibilityState === "visible"`
- [ ] Cancel the timer on visibility hide; restart on visibility show
- [ ] Re-fetch immediately on `visibilitychange` to `"visible"` (after the tab was hidden)
- [ ] Add manual icon-only `Refresh` button to `BoardHeader` in the slot freed by T3
- [ ] Refresh button invokes the same workspace re-fetch path
- [ ] Unit test: timer scheduled / cleared on visibility transitions
- [ ] Unit test: Refresh button triggers the re-fetch
- [ ] Manual verification: mutate a `workspace_tasks` row directly, observe the FE updating within ~30s without manual refresh

---

## T8 — `digital-factory-ui` — wire activity feed to `audience=client`

### Description

Pass `audience=client` to `GET /api/workspaces/:workspaceId/activity` from the
frontend's activity fetch and render the server's pre-relabeled `action` strings
as-is. With T2 in place, the backend returns only allowlisted, client-friendly
rows; the frontend stays presentation-only and gains no allowlist of its own.

Depends on T2: the backend must accept the `audience=client` parameter before the
FE can send it.

### Required skills

- frontend-engineer
- nextjs-best-practices
- typescript-best-practices

### Subtasks

- [ ] In `useActivity` (or equivalent) pass `audience=client` to the API request
- [ ] Render the returned `action` strings as-is (no FE-side label mapping)
- [ ] Render the activity feed in `TaskTrackingPanel`
- [ ] Render the activity feed at the bottom of the feature drill-down
- [ ] Unit / component test: request URL carries `audience=client`
- [ ] E2E test: client view shows only allowlisted actions with friendly labels (no `claimed`, `rag_pre_flight`, `reviewer_started`, `fix_started`, `review_blocked`, `retried` rows)
