# Technical Design

## Feature
- Feature ID: `m1-client-delivery-visibility`
- Title: `Client Delivery Visibility (read-only)`

## 1. Current state

### Identity and scoping (delivered by `m1-identity-and-workspaces`)
- `user-service` issues OAuth-backed sessions; exposes `/api/me` (UI) and
  `/internal/sessions/validate` (service-to-service).
- `workflow-backend.authmw.RequireAuth` validates session cookies and attaches an
  `AuthCtx{UserID, OrganizationID, AccessibleWorkspaceIDs}` to the request
  context.
- `workflow-backend/internal/database/queries.go` filters all read queries via
  `ScopedWorkspaceIDs(ctx)` when an `AuthCtx` is present.
- `digital-factory-ui` has `SessionProvider` (loads `/api/me` on mount;
  redirects to `/login` on failure), `OrgWorkspaceSwitcher`, session-aware root
  layout, and logout.
- The data model: `users` × `memberships` × `organizations` × `workspaces`. A
  user sees a workspace iff they have a membership on that workspace's
  organization and that workspace ID is included in their session's
  `accessible_workspace_ids`.

### Read surfaces already in place
- `workflow-backend` exposes a GET API surface for workspaces, features, tasks,
  drill-downs, and `ListActivity` (events are already modelled in
  `internal/domain/dto.go`).
- `digital-factory-ui` renders delivery state today at `/board`, with
  drill-downs at `/feature/[sessionId]` and `/task/[sessionId]`. The board
  surface (`src/features/board/components/*`) shows features, tasks, kanban
  columns, task tracking panel, feature detail sheet, and feature drill-down
  with documents / tasks / logs.

### Current write surfaces in the UI (must be removed for M1)
- `CreateTaskButton/CreateTaskButton.tsx` — create-task control.
- `KanbanBoard/KanbanBoard.tsx` — drag-to-move-status interaction.
- `FeatureDetailSheet/FeatureDetailSheet.tsx` and `FeatureTabView/*` — edit
  affordances inside feature drill-down.
- `BoardHeader/BoardHeader.tsx` — sync workspace action.
- `ConnectForm.tsx` (`/connect` page) — workspace-import form. Operator-only;
  see §4.5.
- `grep` produces 17 files under `src/features/board/components/*` that contain
  mutation-related handlers — all in scope for control removal.

### Gap in current model: a user with zero memberships
- `m1-identity-and-workspaces` made `workspaces.organization_id NOT NULL` (T1b).
- A new authenticated user has no `memberships` until Kitelabs ops invites them.
  `/api/me` returns `memberships: []` and `accessible_workspace_ids: []`.
- `/board` currently redirects to `/connect` in that case
  (`src/app/board/page.tsx:38-46`). `/connect` is a workspace-import form — not
  a meaningful destination for a client without an invitation. The M1 design
  must replace that branch with a client-appropriate empty state.

### Repo / system boundaries
- Two repos in scope for the UI / API delta: `workflow-backend`,
  `digital-factory-ui`.
- No `user-service` change (the identity model is sufficient as-is).
- No new database, no new contract surface.

## 2. Problem framing

### What needs to change
- The board and drill-downs must render delivery state without any write
  affordances.
- A signed-in user with zero memberships must land on a useful state, not on
  the operator-facing `/connect` form.
- Activity (already in the API DTOs) needs a non-engineer-legible presentation.
- Status vocabulary (`in_progress`, `review_passed`, etc.) needs a
  non-engineer-legible mapping on the client surface.

### What must remain stable
- The existing read API contract on `workflow-backend` (URL shape, response
  schema, scoping). All users — Kitelabs ops included — consume the same
  endpoints.
- The identity contract on `user-service`. No payload changes.
- The existing workflow CLI / agent toolchain — that is the way delivery state
  is mutated, not the UI.

### Assumptions already fixed
- All users in the platform have the same identity model. There is no
  "platform_staff" privilege flag and the design does not introduce one.
- Delivery state is driven by the workflow CLI and agents (init-feature,
  tech-lead, start-implementation, orchestrator). The UI is observational. The
  write controls that exist on the board today are operator artefacts that
  predate the M1 product framing and are being retired for M1.
- Org and workspace creation for clients is an **ops process** (Kitelabs sets up
  the org, creates workspaces, invites the client). Self-serve org creation is
  out of scope for M1 and is captured as a follow-up (§5 D2).

## 3. Options considered

### Option A — Strip write controls from `/board`; treat the surface as observational for everyone
- **What it is**: remove `CreateTaskButton`, drag-to-move-status,
  `FeatureDetailSheet` edit affordances, and the sync button from the board UI
  for **all users**. The workflow CLI and agents continue to drive delivery
  state outside the UI. Backend GET endpoints unchanged. Backend POST endpoints
  unchanged (still callable by internal tooling and operators using their
  session cookie — but no longer surfaced in the UI for anyone).
- **Pros**:
  - One UI for everyone — no per-user privilege model to maintain.
  - Matches the M1 product framing ("crack the black box open"): the platform's
    UI becomes the observation surface; the orchestration surface remains the
    CLI / agents.
  - Smallest backend change (none — only a UI delta).
  - When M3 (The Thread) adds participation, controls return as **first-class
    product** affordances, not as resurrected operator artefacts.
- **Cons**:
  - Kitelabs ops can no longer use the board UI to manually drag a card or hit
    sync. They lose a convenience affordance. Mitigation: those workflows are
    available via the existing CLI/agents and via direct API calls.
  - The `/connect` page (workspace import) becomes the only legacy write
    surface in the UI. Kept for now (operator use); not part of the client
    flow. See §4.5.

### Option B — Same surface, role-gated client mode (rejected by Pye)
- A `is_platform_staff` boolean would gate write controls.
- Rejected because it conflicts with the "all users are the same identity
  model" rule. Not pursued.

### Option C — Separate `/client/*` route tree
- Parallel routes with read-only components.
- Rejected: ~60% of `src/features/board/components/*` would need duplicate
  implementations; two surfaces to maintain; the M3 participation work would
  have to merge them back together anyway.

### Chosen: Option A.

## 4. Chosen design

### 4.1 Write-control removal in the board UI (digital-factory-ui)
- Remove (not hide — remove) the following from the M1 board surface:
  - `CreateTaskButton` — delete the component or stop rendering it from
    `BoardHeader`.
  - Drag handlers in `KanbanBoard/KanbanBoard.tsx` — make cards click-to-open
    only.
  - Sync workspace control in `BoardHeader/BoardHeader.tsx`.
  - Edit affordances in `FeatureDetailSheet` and `FeatureTabView/*` — keep
    document / task / log panels visible and read-only.
- The mutation-related onClick handlers identified by the audit (17 files
  under `src/features/board/components/*`) are reviewed individually; only
  those that perform state mutations are removed. Navigation / drill-down /
  filter / pagination handlers stay.
- No role check is performed anywhere in the UI. Every user gets the same
  read-only board.

### 4.2 No-memberships landing state (digital-factory-ui)
- When `/api/me` resolves with `memberships: []` and
  `accessible_workspace_ids: []`, route the user to a dedicated landing page
  (e.g. `/`, or a new `/welcome` — placement decided in implementation review)
  showing a friendly empty state: "You're signed in but not connected to a
  workspace yet. Contact your Kitelabs delivery lead to be invited."
- Replace the current `/board` → `/connect` redirect for this case. `/connect`
  remains accessible as an operator path (§4.5) but is no longer the default
  landing for a memberships-less user.
- The empty state is server-truth driven: the same condition
  (`memberships.length === 0`) is checked once in a layout / guard and routed
  accordingly.

### 4.3 Client-legible presentation (digital-factory-ui)
- A mapping module in `src/features/board/lib/clientStatusLabels.ts` translates
  the internal workflow vocabulary into non-engineer language:
  `in_progress` → "Being built", `in_review` → "Being reviewed",
  `review_passed` → "Approved, almost done", `done` → "Done",
  `blocked` → "Blocked", `change_requested` → "Revising", etc.
- The mapping is applied to kanban columns, task cards, and the feature/task
  drill-downs.
- Since this is M1 and everyone gets the same surface, the friendly labels
  apply to all users (the internal vocabulary is not surfaced on `/board`).
  Internal-only diagnostic views can keep the raw labels if/when they are
  introduced; out of scope for M1.

### 4.4 Activity feed presentation (digital-factory-ui)
- `GET /api/workspaces/:id/activity` is already available. The activity feed is
  surfaced on the board as a "what the team did" chronological stream.
- A client-side filter module
  (`src/features/board/lib/clientActivityFilter.ts`) suppresses internal-only
  event types for M1 (`rag_pre_flight`, `reviewer_started`, `fix_started`,
  `run_completed` — they're agent-runtime audit entries that don't mean
  anything to a non-engineer). The filter is applied to all users for M1; the
  underlying API still returns the full stream.

### 4.5 Operator path: `/connect` (digital-factory-ui)
- The existing `/connect` page (workspace-import form) remains accessible by
  URL. It is not linked from the read-only board.
- It is **not** the no-membership landing destination. The no-membership
  redirect (§4.2) replaces that role.
- Kitelabs ops can still hit `/connect` directly during dev / setup. Long-term
  this should move to a dedicated operator console; out of scope for M1.

### 4.6 Cross-tenant isolation test (workflow-backend)
- T3 of the identity feature flagged that handler tests do not inject
  `AuthCtx`, so no test currently proves that a user with
  `accessible_workspace_ids=[ws-A]` gets HTTP 404 when accessing `ws-B`.
- This feature's safety story depends on that test. Adding it is in scope.

### 4.7 Vocabulary alignment
| Product-spec term | Identity model term |
|---|---|
| "Client" | A user (a row in `users`) — same identity as any other user |
| "Client organization" | An `organizations` row — the org the client was invited into |
| "Client workspace" | A `workspaces` row where `organization_id` matches the client's org and the workspace ID is in the user's `accessible_workspace_ids` |
| "Delivery state" | Feature + task records read from the workflow management repo via `workflow-backend` |
| "Activity" | `ActivityEvent` rows from `GET /api/workspaces/:id/activity` |

There is **no privilege role** in this vocabulary. "Client" is a product-spec
audience label, not an identity-model role.

### 4.8 Affected repositories
- `digital-factory-ui` — write-control removal, no-membership landing,
  client-legible labels, activity filtering, read-only drill-down polish.
- `workflow-backend` — cross-tenant isolation test (carry-over).

### 4.9 Compatibility and release implications
- The UI no longer renders the operator write controls on `/board`. The
  corresponding backend POST endpoints remain functional; Kitelabs ops who
  relied on the UI controls will need to use the CLI / agents (which is what
  they predominantly use already).
- No database migrations.
- No service contract changes.

## 5. Dependency analysis

### Internal (resolved)
- `m1-identity-and-workspaces` is `done`. Login, organizations, workspaces,
  memberships, `accessible_workspace_ids`, `RequireAuth`, and scoped queries
  are live.

### Internal (carry-over follow-ups)
- **D1 — cross-tenant isolation test in `workflow-backend`** (m1-identity T3
  reviewer note). Handler tests do not inject `AuthCtx`. This feature owns
  closing the gap because the read-only safety story rests on the scoping
  filter being correctly tested. Captured as T1 below.

### Internal (out of scope — flagged for future work)
- **D2 — Self-serve organization creation and client invitation UI.** Today,
  Kitelabs ops set up the client's org and invite them out-of-band (DB / CLI).
  For M1 this is acceptable because the M1 audience is **invited clients**, so
  the typical M1 user already has a membership at sign-in. A new user without
  an invitation lands on the empty state (§4.2). Self-serve org / invitation
  UI is a separate future feature and is not gated by this one.

### External
- None.

### Configuration
- None new.

### Vendor / tooling
- None.

### Unresolved
- None blocking.

## 6. Parallelization / blocking analysis

```
T1: workflow-backend — cross-tenant isolation test (m1-identity T3 follow-up)
  └── Can begin now — no blockers
  │
T2: digital-factory-ui — remove write controls from board (CreateTaskButton, drag handlers, sync button, edit affordances)
  └── Can begin now — no blockers
  │
T3: digital-factory-ui — no-memberships landing state (replace /board → /connect redirect for clients)
  └── Can begin now — no blockers
  │
T4: digital-factory-ui — client-legible status labels mapping (clientStatusLabels.ts) + apply on board, drill-downs
  └── Can begin now — no blockers
  │
T5: digital-factory-ui — activity feed presentation (clientActivityFilter.ts) + render on board
  └── Can begin now — no blockers
  │
T6: digital-factory-ui — read-only polish on feature drill-down (/feature/[sessionId]) and task drill-down (/task/[sessionId])
  └── BLOCKED on T2 (drill-down components share the write-removed FeatureDetailSheet / FeatureTabView from T2)
  └── BLOCKED on T4 (drill-downs render status labels via the mapping module)
  └── T2 and T4 are not mutually blocking — they touch disjoint components — so T6 can begin once both are merged
```

- T1 is independent (touches `workflow-backend` only) and runs in parallel with
  all UI tasks.
- T2, T3, T4, T5 all touch `digital-factory-ui` but in disjoint files and can
  run in parallel. The board surface is large enough that parallel work in
  different components is safe; conflicts, if any, are at the index/export
  level and easy to resolve.
- T6 is the only dependent task — it consolidates the drill-down read-only
  experience and uses pieces from T2 (write-removal) and T4 (status labels).

## 7. Repository impact

| Task | Repo (`workspace.yaml -> repos[].id`) | Why |
|---|---|---|
| T1 | `workflow-backend` | Auth + scoping enforcement lives here; closes the m1-identity T3 follow-up |
| T2 | `digital-factory-ui` | Write controls live in this UI |
| T3 | `digital-factory-ui` | Routing + session-aware landing flow lives here |
| T4 | `digital-factory-ui` | Status labels are presentation-layer mapping |
| T5 | `digital-factory-ui` | Activity feed component + filter live here |
| T6 | `digital-factory-ui` | Drill-down pages live here |

Every task changes exactly one repository.

## 8. Validation and release impact

### Testing expectations
- `workflow-backend` (T1):
  - Integration test: a user whose `accessible_workspace_ids=[ws-A]` receives
    HTTP 404 (not 200, not 403) when accessing endpoints under `ws-B`. Covers
    `GET /workspaces/:id`, `GET /workspaces/:id/features`,
    `GET /workspaces/:id/features/:fid`, `GET /workspaces/:id/tasks`,
    `GET /workspaces/:id/tasks/:tid`, `GET /workspaces/:id/activity`.
- `digital-factory-ui` (T2):
  - Component tests verify no write controls render anywhere on `/board` —
    `CreateTaskButton`, drag handlers, sync button, edit menus are absent.
  - Snapshot of board with sample state to lock the read-only shape.
- `digital-factory-ui` (T3):
  - Integration test: `/api/me` returns `memberships: []` → user is routed to
    the empty-state landing (not `/connect`).
- `digital-factory-ui` (T4, T5):
  - Unit tests on the label and activity-filter mapping modules covering every
    documented status value and every filtered activity type.
- `digital-factory-ui` (T6):
  - Integration test: feature drill-down and task drill-down render with no
    edit affordances; status labels are client-legible; activity log items
    apply the filter.

### Migration / config impact
- No migrations. No config changes.

### Rollout concerns
- The removal of write controls is the only behaviour change visible to
  existing users. Kitelabs ops should be notified before rollout that the
  board's write affordances move to CLI/agents.
- No breaking change for clients (none exist on the platform yet).

### Backward compatibility
- API contracts unchanged. The UI removal is forward-only; no need to keep the
  write controls behind a flag.

### Deployment / handoff
- Roll order: `workflow-backend` (T1) and `digital-factory-ui` (T2–T6) are
  independent and can merge in any order; the UI changes do not depend on T1
  beyond the safety story it codifies.
- Handoff document records each PR per task as in `m1-identity-and-workspaces`.

## Figma
_None — the product spec has no Figma links. The existing `digital-factory-ui`
visual system is reused; status-label and activity-feed presentation choices
are made in code review._
