# Technical Design

## Feature
- Feature ID: `m1-client-delivery-visibility`
- Title: `Client Delivery Visibility (read-only)`

## 1. Current state

### Identity and scoping (delivered by `m1-identity-and-workspaces`)
- `user-service` issues OAuth-backed sessions, exposes `/api/me` (UI) and
  `/internal/sessions/validate` (service-to-service).
- `workflow-backend` validates session cookies via `authmw.RequireAuth`, which attaches an
  `AuthCtx{UserID, OrganizationID, AccessibleWorkspaceIDs}` to the request context.
- All read queries in `workflow-backend/internal/database/queries.go` filter by
  `ScopedWorkspaceIDs(ctx)` when an `AuthCtx` is present; unauthenticated requests
  remain unscoped (legacy/service path).
- `digital-factory-ui` has `SessionProvider` (loads `/api/me` on mount, redirects to
  `/login` on failure), `OrgWorkspaceSwitcher`, and a session-aware root layout.
- `user-service` seeds the Kitelabs organization and auto-grants `platform_admin`
  role on Kitelabs membership for users matching `PLATFORM_ADMIN_EMAILS`.

### Read surfaces already in place
- `workflow-backend` exposes a read-only API surface for delivery state:
  - `GET /api/workspaces`, `GET /api/workspaces/:id`
  - `GET /api/workspaces/:id/features`, `GET /api/workspaces/:id/features/:fid`
  - `GET /api/workspaces/:id/tasks`, `GET /api/workspaces/:id/tasks/:tid`
  - `GET /api/workspaces/:id/features/:fid/tasks[/:tid]`
  - `GET /api/workspaces/:id/activity` — `ActivityEvent` model already defined in
    `internal/domain/dto.go`
- The only two non-GET endpoints today are `POST /api/workspaces/import` and
  `POST /api/workspaces/:id/sync` — both are operator/admin actions.
- `digital-factory-ui` renders the delivery state today at `/board`, drill-downs at
  `/feature/[sessionId]` and `/task/[sessionId]`. The board surface
  (`src/features/board/components/*`) already shows features, tasks, kanban columns,
  task tracking panel, feature detail sheet, and feature drill-down with
  documents/tasks/logs.

### Current write/action surfaces in the UI (must be hidden for clients)
- `CreateTaskButton/CreateTaskButton.tsx` — create-task control on the board.
- `KanbanBoard/KanbanBoard.tsx` — drag-to-move-status interaction.
- `FeatureDetailSheet/FeatureDetailSheet.tsx` and `FeatureTabView/*` — edit controls
  inside feature drill-down.
- `BoardHeader/BoardHeader.tsx` — sync workspace action.
- Other components in `src/features/board/components/*` contain `onClick` handlers
  that write workflow state (search produced 17 files with mutation paths).

### Repo / system boundaries
- Three repos in scope: `user-service`, `workflow-backend`, `digital-factory-ui`.
- No new service, no new database, no new contract surface beyond extending two
  existing JSON payloads (`/internal/sessions/validate` and `/api/me`) with a single
  derived boolean.

## 2. Problem framing

### What needs to change
- The board and drill-downs must render the same delivery state without write
  affordances for client users.
- "Client user" needs a stable, server-authoritative definition usable by both the
  UI (to gate controls) and the backend (to refuse writes as defence-in-depth).
- Vocabulary in the product spec ("client org", "workspace") must align with the
  identity model now in place (`organizations`, `workspaces`, membership roles).
- The activity feed (already in the API DTOs) needs a client-legible presentation.

### What must remain stable
- The existing read API contract on `workflow-backend` (URL shape, response schema,
  scoping behaviour) — clients consume the same endpoints as staff.
- The identity contract on `user-service` (`/api/me`, `/internal/sessions/validate`)
  — extensions only, no removals or renames.
- Staff workflow on `/board` — adding a client-mode branch must not regress the
  internal experience.

### Assumptions already fixed
- Identity, sessions, organizations, workspaces, and workspace scoping are shipped
  and live (`m1-identity-and-workspaces` is `done`).
- Membership role is a free-form string today (`MeMembership.role: string`); T6 in
  the identity feature populates `platform_admin` for the Kitelabs org via
  `PLATFORM_ADMIN_EMAILS`. This is the only role currently emitted by the seed; any
  non-platform-admin membership is treated as a client membership.
- The product team accepts the "single surface, role-gated" rule below; the
  alternative (separate `/client/*` tree) is rejected in §3.

## 3. Options considered

### Option A — Same `/board` surface; client mode derived from membership role

- **What it is**: keep `/board`, `/feature/[id]`, `/task/[id]` as the only delivery
  surface. Derive `isPlatformStaff` from the session (`memberships[].role ===
  "platform_admin"` on the Kitelabs org). Hide write controls when
  `!isPlatformStaff`. Backend rejects writes from non-staff with 403.
- **Pros**:
  - One UI codebase; consistent mental model between client and staff.
  - When **M3 (The Thread)** introduces participation, the path is "expose hidden
    control" — no second UI to retrofit.
  - Existing component tree, routing, and data-fetching are reused; no duplication
    of feature/task rendering.
  - Backend changes are additive (one new boolean in two payloads, one new
    authorization branch on two write endpoints).
- **Cons**:
  - Every new write-capable component must remember the client-mode check; risk of
    accidental leakage if a developer forgets.
  - Branding / aesthetic for clients is constrained to the staff shell. Acceptable
    for M1 ("crack the black box open") — not for a long-term polished offering.
- **Implementation impact**: 7 tasks across 3 repos. ~half a sprint of UI work
  centered on hiding controls; small backend deltas.
- **Dependency impact**: relies on `memberships[].role` populated correctly by the
  identity feature (already the case for Kitelabs platform admins). No new
  service-to-service surface.

### Option B — Separate `/client/*` route tree with read-only components

- **What it is**: build a parallel set of routes (`/client/board`,
  `/client/feature/:id`, `/client/task/:id`) and a separate set of components that
  render the same data shapes but contain no mutation paths.
- **Pros**:
  - Strong physical isolation — no chance of accidental write leakage from a forgotten
    flag check.
  - Independent UX evolution for clients without affecting staff.
- **Cons**:
  - Significant duplication of feature/task/board/drill-down components. Estimated
    ~60% of `src/features/board/components/*` would need a parallel implementation.
  - Two surfaces to keep in sync as the workflow state model evolves; cost grows
    every milestone.
  - When **M3** adds participate, the parallel client tree has to absorb the same
    components again. The duplication keeps compounding.
  - Routing model becomes load-bearing for tenancy, on top of the existing
    workspace scoping. More invariants to enforce.
- **Implementation impact**: roughly double the UI task count; full re-implementation
  of board UI under a new route.
- **Dependency impact**: same identity surface; no service changes — but a much
  larger UI surface area.

### Option C — Single surface with backend write-block only (no UI gating)

- **What it is**: hide nothing in the UI; rely on backend returning 403 to fail
  mutations. Client users see action controls that don't work.
- **Pros**: trivial UI change (none); fully server-enforced.
- **Cons**:
  - Failed actions in the UI surface as error toasts; the product spec is explicit
    that clients "never see an action control". This violates that goal.
  - Bad UX for the audience the feature is designed for (non-engineers).
- **Rejected** — fails the product spec.

### Chosen: Option A
- One surface, role-gated mode, with backend write authorization as defence in
  depth. This is detailed in §4.

## 4. Chosen design

### 4.1 Role surface (user-service)
- Extend `/api/me` (UI) and `/internal/sessions/validate` (service-to-service) to
  include a derived boolean field:
  - Wire name: `is_platform_staff` (snake_case on the wire).
  - Definition: `true` iff the user has any membership with `role === "platform_admin"`
    on the platform-admin organization (Kitelabs, identified by configurable
    `PLATFORM_ADMIN_ORG_SLUG`, default `"kitelabs"`).
  - Backwards-compatible: existing clients ignore the new field.

### 4.2 Backend write authorization (workflow-backend)
- Extend `authmw.AuthCtx` with `IsPlatformStaff bool`; populate from
  `SessionInfo.IsPlatformStaff` returned by the `user-service` client.
- Add a `RequirePlatformStaff` middleware (or inline check) that rejects with HTTP
  403 when `!ac.IsPlatformStaff`. Apply to:
  - `POST /api/workspaces/import`
  - `POST /api/workspaces/:workspaceId/sync`
- Read endpoints remain unchanged — the existing `ScopedWorkspaceIDs` filter already
  limits clients to their accessible workspaces.

### 4.3 UI client mode (digital-factory-ui)
- Extend `MeResponse` in `src/services/user-service/types.ts` to include
  `is_platform_staff: boolean`.
- `SessionContext` exposes `isPlatformStaff` as a top-level derived value alongside
  `session`.
- `useSession()` consumers branch on `isPlatformStaff`:
  - `BoardHeader` — hide sync button when client.
  - `CreateTaskButton` — render `null` when client.
  - `KanbanBoard` — disable drag handlers when client (cursor stays default; cards
    are still clickable to open drill-downs).
  - `FeatureDetailSheet` / `FeatureTabView/*` — hide edit affordances; keep
    document/log/task panels read-only.
- A single helper (e.g. `useClientMode()` in `src/features/auth`) exposes the
  derived flag so every component imports the same source of truth.

### 4.4 Client-legible presentation
- Status labels on the kanban columns and task cards translate the internal
  workflow vocabulary (`in_progress`, `in_review`, `review_passed`, etc.) into a
  non-engineer reading: "Being built", "Being reviewed", "Done", "Blocked",
  "Waiting on something". A single mapping module in
  `src/features/board/lib/clientStatusLabels.ts` is applied only when in client
  mode; staff continue to see the raw status.
- The activity feed (already exposed via `GET /api/workspaces/:id/activity`) is
  presented to clients as a chronological "what the team did" stream; internal-only
  events (e.g. `rag_pre_flight`, `reviewer_started`) are filtered out client-side
  for M1. The same filter list lives in `clientActivityFilter.ts`.

### 4.5 Vocabulary alignment (carried forward from product-spec open question)
- "Client organization" in the product spec ⇔ a row in the `organizations` table.
- "Client workspace" ⇔ a row in `workspaces` with `organization_id` matching the
  client's organization, where the user's `accessible_workspace_ids` includes the
  workspace's ID.
- "Client user" ⇔ any authenticated user where `is_platform_staff === false`.

### 4.6 Affected repositories
- `user-service` — add `is_platform_staff` to two response payloads; one
  database-level derivation (one join already available via existing schema). T0
  below.
- `workflow-backend` — propagate flag into `AuthCtx`; add write authorization on
  two endpoints; carry-over isolation test from the identity feature. T1/T2/T3
  below.
- `digital-factory-ui` — type extension, session-context flag, control hiding,
  client-legible labels, activity-feed presentation, drill-down polish.
  T4/T5/T6/T7 below.

### 4.7 Compatibility and release implications
- All payload changes are additive; existing consumers are unaffected.
- The 403 behaviour on the two `POST` endpoints is a tightening — but the only
  current callers (the workspace seed and operator tooling) are platform staff, so
  no client-side regression is expected.
- No database migrations are required for this feature; all state needed is already
  in `users`, `memberships`, `organizations`, and `workspaces` from the identity
  feature.

## 5. Dependency analysis

### Internal (resolved)
- `m1-identity-and-workspaces` is `done`. Login, organizations, workspaces,
  memberships, `accessible_workspace_ids`, `RequireAuth`, and scoped queries are
  live.

### Internal (carry-over follow-ups from `m1-identity-and-workspaces`)
- **D1 — cross-tenant isolation test in `workflow-backend`** — T3 of the identity
  feature flagged a missing test: handler tests do not inject `AuthCtx`, so no test
  proves that a user with `accessible_workspace_ids=[ws-A]` gets HTTP 404 when
  accessing `ws-B`. Implementation is correct; test is absent. This feature owns
  closing that gap because client visibility hinges on the test holding.
- **D2 — platform-admin null semantics in the user-service client** — the
  `workflow-backend` user-service client (`internal/serviceclient/user_service/client.go:209`)
  normalises `accessible_workspace_ids: null` (platform admin = unrestricted) into
  `[]` (empty list = zero workspaces). The current `ListWorkspaces` query then
  returns an empty list for platform admins. This affects staff, not clients —
  staff would see no workspaces today — so it's not a client-feature blocker, but
  T1 below fixes it as a side effect of widening the flag-passing path.

### External
- None. No third-party APIs, no design vendor, no infra change.

### Configuration
- `user-service` requires a `PLATFORM_ADMIN_ORG_SLUG` (default `"kitelabs"`) to
  resolve which organization confers platform-admin status. Already implicit in T6
  of the identity feature (uses `PLATFORM_ADMIN_EMAILS` to grant the role on a
  fixed-name org); promoting this to a named constant in user-service is a small
  delta inside T0.

### Vendor / tooling
- None.

### Unresolved
- None blocking. The Figma question does not apply — `product-spec.md` has no
  Figma link, and the existing `digital-factory-ui` styling system is reused.

## 6. Parallelization / blocking analysis

```
T0: user-service — add is_platform_staff to /api/me + /internal/sessions/validate
  └── Can begin now — no blockers
  │
  T1: workflow-backend — propagate IsPlatformStaff into AuthCtx + fix null → unrestricted
      └── BLOCKED on T0 (validate-session payload must carry is_platform_staff)
      │
      T2: workflow-backend — write-path authorization (403 on POST when !staff)
          └── BLOCKED on T1 (AuthCtx must carry IsPlatformStaff)
  │
T3: workflow-backend — cross-tenant isolation test (m1-identity T3 follow-up)
  └── Can begin now — no blockers (test-only; touches handler tests)
  │
  T4: digital-factory-ui — SessionContext exposes isPlatformStaff
      └── BLOCKED on T0 (/api/me must include is_platform_staff)
      │
      T5: digital-factory-ui — hide write controls in board when !isPlatformStaff
      T6: digital-factory-ui — client-legible status labels + activity feed
      T7: digital-factory-ui — read-only polish on feature + task drill-downs
          └── T5, T6, T7 run in parallel
          └── BLOCKED on T4 respectively (each component imports the shared flag from SessionContext)
```

- T0 is the single upstream blocker. It is short (one derived field in two payloads)
  and should land first.
- T3 is fully independent of the rest and can start immediately — it closes the
  identity-feature follow-up and tightens the test surface this feature depends on.
- T1 and T2 are sequential (both in `workflow-backend`); T2 cannot exist without T1.
- T4 is the UI fan-in point — once it lands, T5/T6/T7 run in parallel because each
  touches a disjoint slice of the board UI:
  - T5: write-control components (`CreateTaskButton`, `KanbanBoard`, header sync,
    edit controls in detail sheet).
  - T6: status/label mapping module + activity feed presentation.
  - T7: feature drill-down (`src/app/feature/[sessionId]`) and task drill-down
    (`src/app/task/[sessionId]`) — separate route tree.

## 7. Repository impact

| Task | Repo (`workspace.yaml -> repos[].id`) | Why |
|---|---|---|
| T0 | `user-service` | Identity service owns role and session payloads |
| T1 | `workflow-backend` | Auth middleware + service client live here |
| T2 | `workflow-backend` | Write authorization belongs at the API surface |
| T3 | `workflow-backend` | Carry-over test gap from identity T3 |
| T4 | `digital-factory-ui` | Session-context-level type + value extension |
| T5 | `digital-factory-ui` | Board write controls are in this UI |
| T6 | `digital-factory-ui` | Board labels + activity feed are in this UI |
| T7 | `digital-factory-ui` | Drill-down pages are in this UI |

Every task changes exactly one repository (per the one-repo-per-task workflow
rule).

## 8. Validation and release impact

### Testing expectations
- `user-service`:
  - Unit test on the derivation: a user with platform-admin role on the configured
    org returns `is_platform_staff: true`; all other configurations return `false`.
  - Contract test on `/api/me` and `/internal/sessions/validate` responses including
    the new field.
- `workflow-backend`:
  - Unit test: `AuthCtx.IsPlatformStaff` is populated from the validate response.
  - Integration test: `POST /api/workspaces/import` and `POST /api/workspaces/:id/sync`
    return 403 when the caller is not platform staff.
  - Cross-tenant isolation test (T3): a user whose `accessible_workspace_ids=[ws-A]`
    receives HTTP 404 (not 200, not 403) when accessing endpoints under `ws-B`.
- `digital-factory-ui`:
  - Component tests: when `isPlatformStaff` is `false`, `CreateTaskButton`,
    `BoardHeader` sync, and `KanbanBoard` drag affordances are not rendered or are
    disabled.
  - Integration test: a session response with `is_platform_staff: false` results in
    a board view with zero write controls.
  - Snapshot/story tests for the client-legible status labels and activity feed
    presentation.

### Migration / config impact
- No database migrations.
- One new config value: `PLATFORM_ADMIN_ORG_SLUG` in `user-service`
  (`.env.template`). Default `"kitelabs"` keeps current behaviour.

### Rollout concerns
- The 403 on the two write endpoints is the only behaviour change for existing
  staff. Validate via an integration test using a staff session before rollout.
- Internal/service-to-service callers of the workflow-backend (e.g. the seed) that
  use the unauthenticated path remain unaffected — `RequireAuth` is not enforced on
  that path today and this feature does not change that.

### Backward compatibility
- All API contract changes are additive booleans defaulting to `false`. A stale
  client that ignores `is_platform_staff` simply renders the client (read-only)
  view — the safer default.

### Deployment / handoff
- Roll order: `user-service` (T0) → `workflow-backend` (T1, T2; T3 independent) →
  `digital-factory-ui` (T4, then T5/T6/T7). Each repo's PR is independent and can
  merge in this order.
- The handoff document records each PR per task as in `m1-identity-and-workspaces`.
- No infra changes; no environment variable other than the optional
  `PLATFORM_ADMIN_ORG_SLUG`.

## Figma
_None — the product spec has no Figma links. The existing `digital-factory-ui`
visual system is reused; status-label and activity-feed presentation choices are
made in code review._
