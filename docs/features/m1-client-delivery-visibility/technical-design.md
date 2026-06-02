# Technical Design

## Feature
- Feature ID: `m1-client-delivery-visibility`
- Title: `Client Delivery Visibility (read-only)`
- Milestone: **M1 — Open the Black Box**

## 1. Current state

This feature does not start from a blank slate. Its sibling
`m1-identity-and-workspaces` is `done` and merged across three repos
(`user-service` PR #4, `workflow-backend` PR #15, `digital-factory-ui` PR #84),
which means the read-only client surface mostly already *exists* — it just
isn't safe to expose to a non-Kitelabs user yet.

### Identity + scoping delivered by `m1-identity-and-workspaces`
- `user-service` issues OAuth-backed sessions (Google + GitHub) and exposes
  `/api/me` (browser) and `/internal/sessions/validate` (service-to-service).
- `workflow-backend/internal/authmw/RequireAuth` validates the session cookie
  via `user-service` and attaches
  `AuthCtx{UserID, OrganizationID, AccessibleWorkspaceIDs}` to the request
  context (`workflow-backend/internal/authmw/auth.go`).
- The auth-context payload includes the per-user list of workspace IDs the
  caller may see. `MeResponse` in
  `digital-factory-ui/src/services/user-service/types.ts` already carries it
  (`accessible_workspace_ids: string[]`).
- Roles in `user-service` are `platform_admin` (Kitelabs internal team, granted
  via `PLATFORM_ADMIN_EMAILS`) and `client_member` (read-only at the
  application layer).

### Read API on `workflow-backend`
`internal/handler/workspace.go` already registers the read surface this feature
needs, all under `/api`:

| Method | Path | Returns |
|---|---|---|
| GET | `/api/workspaces` | List of workspace summaries |
| GET | `/api/workspaces/:workspaceId` | Workspace detail with features+tasks |
| GET | `/api/workspaces/:workspaceId/features` | Paginated/filtered features |
| GET | `/api/workspaces/:workspaceId/features/:featureId` | One feature |
| GET | `/api/workspaces/:workspaceId/features/:featureId/tasks` | Tasks in a feature |
| GET | `/api/workspaces/:workspaceId/features/:featureId/tasks/:taskId` | One task |
| GET | `/api/workspaces/:workspaceId/tasks` | All tasks in the workspace |
| GET | `/api/workspaces/:workspaceId/tasks/:taskId` | One task (top-level) |
| GET | `/api/workspaces/:workspaceId/activity` | Activity feed (scoped) |

The DB schema under `database/workspace/schema.dbml` already models all of
this: `workspaces`, `workspace_features` (status + stage + next_action),
`workspace_tasks` (status + depends_on + blocked_reason + pr), and
`workspace_activity_events` (scope_type + action + actor + occurred_at + note).
No schema change is required.

### Frontend surface in `digital-factory-ui`
The screens this feature needs already exist:

- `/login` (m1-identity)
- `/board` — workspace board with `BoardHeader`, `KanbanBoard`, `FeatureBoardView`,
  `TaskBoardView`, `TaskTrackingPanel`, `FeatureDetailSheet`
- `/feature/[sessionId]` — feature drill-down (tasks + documents + log)
- `/task/[sessionId]` — task drill-down (detail + log)
- `/connect` — workspace import form

`SessionGate` (`src/features/auth/components/SessionGate.tsx`) already gates
every route except `/login` behind a valid session.

### Three concrete gaps this feature must close

1. **Workspace scoping is wired but not enforced.**
   `RequireAuth` attaches `AccessibleWorkspaceIDs`, but the actual filter at
   the service layer is commented out in `workflow-backend/internal/service/workspace.go`
   (lines 145–149, 203–214 in the current main). Today any authenticated user
   — including a hypothetical `client_member` — would receive the full
   workspace list from `GET /api/workspaces` and could fetch any workspace by
   ID. This is the single biggest blocker to letting a client log in safely.

2. **Write affordances are mixed into the read views.** The current `/board`
   surface contains a `CreateTaskButton`, a `SyncWorkspace` action in
   `BoardHeader`, and a workspace-import form at `/connect`. These are
   Kitelabs-operator controls and must not be visible to a client.

3. **A signed-in user with zero memberships lands on `/connect`.**
   `src/app/page.tsx` redirects to `/board` if `localStorage` knows a
   workspace and to `/connect` otherwise; `src/app/board/page.tsx:38-46`
   redirects to `/connect` when `summaries.length === 0`. `/connect` is the
   operator-facing workspace-import form — it is not an acceptable destination
   for a freshly authenticated client whose invitation hasn't been seeded yet.

### Repo boundaries
- `workflow-backend` (Go) — enforces scoping and exposes activity feed details.
- `digital-factory-ui` (Next.js) — adapts the existing screens for a read-only
  client audience and resolves the no-membership landing.
- `user-service` — **no change.** The identity contract is sufficient.
- `management-repo` — small documentation additions to `docs/overview.md` and
  this feature's tasks; no schema migration (no `database/workspace/v003/`).

## 2. Problem framing

### What must change
1. Activate the commented-out workspace scoping in `workflow-backend` so that
   every read endpoint filters by `AccessibleWorkspaceIDs` (and 404s on
   out-of-scope IDs).
2. Remove every write control from the routes a client can reach
   (`/board`, `/feature/*`, `/task/*`).
3. Replace the "no workspaces → `/connect`" branch with a client-appropriate
   empty state.
4. Resolve the two open product questions surfaced in the product-spec
   approval comment:
   - **Surface choice** — same `digital-factory-ui` in read-only mode vs. a
     separate client app. See Option 1.
   - **Vocabulary alignment** — internal lifecycle vocabulary
     (`in_progress`, `review_passed`, `change_requested`, …) vs. what a
     non-engineer client sees. See Option 2.
5. Decide the live-update mechanism (poll vs. websockets). See Option 3.
6. Decide the activity-feed shape for the client (firehose vs. allowlist).
   See Option 4.

### What must stay stable
- The `/api/workspaces*` URL shape, response schema, and authentication
  contract. The same endpoints serve Kitelabs ops and clients.
- The `user-service` HTTP and DB contracts.
- The workflow CLI / agent toolchain — that is the canonical write path for
  delivery state. The UI is not the write surface for tasks.
- The GitHub adapter (`workspace-github-adapter`).

### Fixed assumptions
- **No write affordances of any kind** in the client-reachable UI. The product
  spec is explicit: "no commenting, no approving, no `@mention`, no
  spec-drafting." We will enforce this by route, not by per-component role
  gating (see Option 5).
- **Multi-tenant scoping is non-optional.** A client never sees a workspace
  they aren't a member of. Cross-workspace leakage is a P0 bug.
- **Refresh-based liveness.** "Near-real-time or on refresh" in the product
  spec means polling, not websockets, for M1 (see Option 3).
- **Kitelabs ops keeps its admin tooling, but on a different route.** The
  `/connect` import form and any other operator action moves under `/admin/*`
  (or stays at `/connect` but is gated to `platform_admin`). Either way it
  must be unreachable from client navigation.
- **No new DB tables, no schema migration.** Everything needed is already in
  `database/workspace/schema.dbml`.

## 3. Options considered

### Option 1 — Client surface: shared vs. separate

**1A: Reuse `digital-factory-ui`. Same routes (`/board`, `/feature/*`, `/task/*`)
for both Kitelabs ops and clients. Operator-only actions move under
`/admin/*` (or are simply removed because the agent toolchain owns writes).**

- Pros:
  - Zero new repo, zero new deploy target.
  - The read views are already built and tested.
  - One auth surface, one cookie, one session — no cross-app SSO to design.
  - Bug fixes to "what the board shows" benefit both audiences.
  - Avoids inventing a second design language.
- Cons:
  - Requires careful removal of write controls; one stale button leaks
    capability.
  - Branding stays "Digital Factory" rather than a client-skinned product.

**1B: New `client-portal` Next.js app, read-only by construction.**

- Pros:
  - Hard isolation — a client app cannot accidentally render a write control
    that doesn't exist in the bundle.
  - Different visual identity if Kitelabs ever wants one.
- Cons:
  - Doubles the FE deploy + CI surface.
  - Duplicates session bootstrap, organization/workspace switcher, data
    fetching, and board rendering.
  - Forces a cookie-domain story that covers three subdomains
    (`app`, `client`, `users`).
  - High likelihood of drift between the two surfaces as the data model
    evolves (M2/M3 will add columns and views).

**Selected: 1A.** The cost-of-entry for a client-watching MVP does not justify
a new app. Write affordances are not just "hidden" — they are physically
removed from client-reachable routes (Option 5). Operator-only screens move
under `/admin/*` and are gated by `role === "platform_admin"`. The /board,
/feature, and /task routes contain no write affordance at all, for any role.

### Option 2 — Vocabulary alignment for the client view

**2A: Preserve the workflow vocabulary as-is.** Show `in_progress`,
`review_passed`, `change_requested`, etc. directly.

- Pros: no mapping table to maintain; matches what an internal viewer sees.
- Cons: many of these states encode internal review machinery (`review_passed`,
  `review_incomplete`, `reviewing`) that a non-engineer client has no model
  for. The product spec calls out exactly this risk: "present delivery state
  legibly to a non-engineer client."

**2B: Map workflow states to a small client-facing vocabulary on the
frontend.** The API response is unchanged; the FE renders the human-readable
label.

- Pros: API stability preserved; mapping lives in one place
  (`src/features/board/lib/status.ts` already centralises status definitions);
  easy to evolve.
- Cons: two vocabularies to keep in sync.

**Selected: 2B.** The proposed mapping table:

| API `status` (task) | Client label | Notes |
|---|---|---|
| `todo` | Not started | |
| `ready` | Ready to start | |
| `in_progress` | In progress | |
| `in_review` | In review | |
| `reviewing` | In review | Collapse `reviewing`/`in_review` for clients |
| `review_passed` | In review | Same — client doesn't need the holding state |
| `change_requested` | Revisions in progress | |
| `review_incomplete` | In review | |
| `blocked` | Blocked | Show `blocked_reason` verbatim only if present and non-empty |
| `done` | Done | |
| `cancelled` | Cancelled | |

| API `feature_status` | Client label |
|---|---|
| `in_design` | Design |
| `in_tdd` | Technical design |
| `ready_for_implementation` | Ready to build |
| `in_implementation` | Building |
| `in_handoff` | Handoff |
| `done` | Done |
| `blocked` | Blocked |
| `cancelled` | Cancelled |

"workspace", "feature", "task", "organization" remain unchanged — they map
1:1 to the product-spec language the client already encountered in the sales
conversation. (This resolves the second half of the product-spec approval
question: vocabulary aligns with `organizations`/`workspaces` tables in
`user-service` and `workspaces`/`workspace_features`/`workspace_tasks` in
`workflow-backend`. No rename.)

### Option 3 — Live-update mechanism

**3A: Manual refresh button + poll on focus.** Fetch on page mount; poll
every ~30s while the tab is foregrounded; re-fetch on `visibilitychange`.

- Pros: trivial; matches the product spec ("near-real-time or on refresh");
  no new infrastructure.
- Cons: not instant; small request load (one workspace summary every 30s per
  open tab).

**3B: SSE/Websocket-based push.** `workflow-backend` opens a stream and
broadcasts events as they land in `workspace_activity_events`.

- Pros: instant updates.
- Cons: significant infrastructure investment (event bus, fanout, reconnect
  logic, cross-pod broadcasting, scaling); duplicates capability M2/M3 will
  need for the conversation surface anyway, but does *not* shorten that work.

**Selected: 3A.** The product spec language ("near-real-time or on refresh")
allows polling. Instant push is a real-time-collaboration concern that
belongs in M3 (The Thread), not in a watch-only M1 surface. We absorb the
~30s freshness cost in exchange for not building stream infrastructure now.

### Option 4 — Activity feed shape for the client

**4A: Show the firehose.** Every row in `workspace_activity_events` for the
scoped workspace, ordered by `occurred_at`.

- Pros: zero filtering logic; whatever exists in the DB is what the client
  sees.
- Cons: the activity log includes engineer-only actions
  (`rag_pre_flight`, `claimed`, `reviewer_started`, `fix_started`, `retried`,
  `review_blocked` — see `CLAUDE.md` "Valid task log action names"). A
  non-engineer client looking at "claimed", "rag_pre_flight", and
  "reviewer_started" interleaved gets a confusing technical log instead of a
  story.

**4B: Server-side allowlist of client-visible action types.** Add a query
param `audience=client` to `GET /api/workspaces/:workspaceId/activity` that
filters down to the actions a client should see, and (optionally) renames a
small number of internal action labels.

- Pros: hides agent-runtime noise; produces a readable timeline.
- Cons: the allowlist is a contract that drifts as new action names are added
  by the workflow (`CLAUDE.md` already enumerates 14 actions).

**Selected: 4B.** Allowlist for M1:

| Action | Show to client? | Client label |
|---|---|---|
| `created` | yes | Created |
| `ready` | yes | Ready |
| `started` | yes | Started |
| `work_phase_complete` | yes | Progress |
| `done` | yes | Completed |
| `blocked` | yes | Blocked |
| `reviewer_complete` | yes | Reviewed |
| `claimed` | no | (agent-runtime audit) |
| `rag_pre_flight` | no | (agent-runtime audit) |
| `reviewer_started` | no | (agent-runtime audit) |
| `fix_started` | no | (agent-runtime audit) |
| `review_blocked` | no | (agent-runtime audit) |
| `retried` | no | (agent-runtime audit) |
| `cancelled` | yes | Cancelled |

The filter and labels live in `workflow-backend`. The frontend renders the
labels as received. When a new action is added to the workflow, the allowlist
must be updated explicitly — a known low-cost maintenance cost.

### Option 5 — Removing write controls

**5A: Hide write controls behind a `role === "platform_admin"` check in each
component.** Same routes for both audiences; per-control role gates.

- Pros: minimal route changes.
- Cons: fragile — one missed conditional leaks a write control to a client.
  Every new write affordance needs the same conditional, in every place. The
  rewrite-and-revert history in this feature's git log shows the team has
  already flinched on role gating once.

**5B: Move every write control out of client-reachable routes.** Operator-only
screens (`/connect`, future admin pages) live under `/admin/*` and are gated
once, at the layout level. Client-reachable routes (`/board`, `/feature/*`,
`/task/*`) physically contain no write affordance — for any role.

- Pros: one place to gate; the client surface cannot leak a control that
  isn't in its bundle / route tree.
- Cons: an `platform_admin` viewing `/board` doesn't get a "Sync now" button
  on that screen. They use `/admin/connect` (or the workflow CLI, which is the
  canonical write path anyway).

**Selected: 5B.** Concretely:
- Remove `CreateTaskButton` from `BoardHeader` and from `KanbanBoard`.
- Remove the "Sync" action from `BoardHeader` (it was operator-only). Move it
  behind `/admin/sync` if it is still desired in the UI at all; the agent
  workflow already syncs via webhook, so the manual control is a rarely-used
  fallback.
- Move `/connect` to `/admin/connect`. Keep the operator's ability to import
  workspaces, but only from there. The route is wrapped in a server-side
  guard that 404s for non-`platform_admin` callers.
- `KanbanBoard` drag-to-move handlers — if any exist that POST to a write
  endpoint — are deleted. The board renders columns from `status` but does
  not transition status. (Status transitions are a workflow concept; the UI
  doesn't own them.)

### Option 6 — No-membership landing

**6A: Keep the current redirect to `/connect`.** Unacceptable: `/connect` is
operator-facing and presents an import form. A logged-in client whose
invitation hasn't been seeded sees a workspace import form. This is the
exact problem flagged in the product-spec approval comment via the reverted
"address no-membership landing" rewrite.

**6B: Render an empty-state component at the root and on `/board` when
`memberships.length === 0` and `accessible_workspace_ids.length === 0`.**

- The empty state for a `client_member` (or any non-`platform_admin`):
  > "Your workspace will appear here as soon as your engagement is set up.
  > If you expected to see something, contact your Kitelabs delivery lead."
  Logout button visible.
- The empty state for a `platform_admin` (rare — admin signed in before any
  membership is created): same friendly message plus an "Import workspace"
  link to `/admin/connect`. The `platform_admin` role grants visibility to
  every workspace via `accessible_workspace_ids` automatically; the
  zero-memberships case is essentially the first-deploy bootstrap.

**Selected: 6B.** No new route — the empty state lives inside `/board`
(replacing the current "redirect to /connect" branch). `src/app/page.tsx`'s
root redirect logic also gets the same treatment: if signed in but no
accessible workspaces, render the empty state instead of pushing to
`/connect`.

## 4. Chosen design

### One picture

```
┌────────────────────────────────────────────────────────────────────┐
│ digital-factory-ui  (existing repo, Next.js)                       │
│                                                                    │
│  /login                  ← m1-identity                             │
│  /board                  ← read-only board (no write affordances)  │
│  /feature/[id]           ← read-only feature drill-down            │
│  /task/[id]              ← read-only task drill-down               │
│  /admin/connect          ← platform_admin only (was /connect)      │
│                                                                    │
│  Empty state: signed in, accessible_workspace_ids = []             │
│    → "Your workspace will appear here…" (no /connect redirect)     │
│                                                                    │
│  Workflow-data fetcher polls /api/workspaces/:id every 30s         │
│    when the tab is focused.                                        │
└──────────────────────────────┬─────────────────────────────────────┘
                               │ cookie-authenticated calls
                               ▼
┌────────────────────────────────────────────────────────────────────┐
│ workflow-backend  (existing repo, Go + Gin + pgx)                  │
│                                                                    │
│  RequireAuth (already shipped)                                     │
│    → AuthCtx{UserID, OrganizationID, AccessibleWorkspaceIDs}       │
│                                                                    │
│  THIS FEATURE ACTIVATES:                                           │
│    ListWorkspaces      filter by AccessibleWorkspaceIDs            │
│    GetWorkspace        404 if id ∉ AccessibleWorkspaceIDs          │
│    SearchFeatures      404 if workspace ∉ AccessibleWorkspaceIDs   │
│    SearchTasks         404 if workspace ∉ AccessibleWorkspaceIDs   │
│    GetTask             404 if workspace ∉ AccessibleWorkspaceIDs   │
│    ListActivity        404 if workspace ∉ AccessibleWorkspaceIDs;  │
│                        accept ?audience=client → allowlist filter  │
│                                                                    │
│  No change to write endpoints (POST /import, POST /sync, …) —      │
│    they remain authenticated; the client UI does not call them.    │
└──────────────────────────────┬─────────────────────────────────────┘
                               │
                               ▼
                  workflow_db  (existing — no schema change)
```

### Backend changes (`workflow-backend`)

**Activate workspace scoping** in `internal/service/workspace.go`. The
commented-out `authmw.FromContext` blocks become live. The contract:

- If `AuthCtx` is absent (development/unauthenticated): preserve current
  behaviour (return all). Tests cover this case.
- If `AuthCtx` is present and `AccessibleWorkspaceIDs` is empty: return an
  empty list (for `ListWorkspaces`) or 404 (for any `/workspaces/:id/*`).
- Otherwise, filter `ListWorkspaces` and 404 any workspace ID not in the
  set. The filter is applied at the service boundary, never at the handler
  — the handler does not touch IDs except to pass them through.

**Activity allowlist.** `ListActivity` gains an optional `audience` query
parameter. When `audience=client`, filter `workspace_activity_events.action`
to the allowlist in Option 4 and rewrite the `action` field on the response
DTO to the client-friendly label. The default audience is `internal` —
backwards-compatible.

**Workspace-scoping cache.** `RequireAuth`'s session payload already caches
`AccessibleWorkspaceIDs` in-process (per m1-identity tech design). No new
cache work in this feature.

**No new endpoints. No new DB columns. No migration.**

### Frontend changes (`digital-factory-ui`)

**Remove write affordances from client-reachable routes:**
- Delete `CreateTaskButton` from `BoardHeader` and from `KanbanBoard` (and
  delete the unused component file once nothing imports it).
- Delete the "Sync now" control in `BoardHeader`. The sync action is
  operator-only and is exercised either by the webhook adapter or, manually,
  from `/admin/sync` (out of M1 scope to build the page; the endpoint stays).
- Audit `FeatureBoardView`, `TaskBoardView`, `FeatureDetailSheet`, and
  `FeatureTabView` for any onClick that issues a POST/PUT/DELETE; delete it.
  No drag-to-reorder, no status transition control, no comment box.

**Move `/connect` to `/admin/connect`:**
- Create `src/app/admin/layout.tsx` whose body returns `notFound()` if
  `session.user.memberships[*].role` does not include `platform_admin`.
- Move the existing `src/app/connect/page.tsx` to
  `src/app/admin/connect/page.tsx`.
- Remove the route `/connect` entirely (deleted, not redirected — the URL
  was operator-internal).

**Handle the no-membership landing:**
- In `src/app/page.tsx`, when the session is loaded and
  `me.accessible_workspace_ids.length === 0`, render an `EmptyState`
  component (new) instead of redirecting to `/connect`.
- In `src/app/board/page.tsx`, replace the `summaries.length === 0`
  redirect-to-`/connect` branch with the same `EmptyState`.
- The empty state is one component (`EmptyState` under
  `src/features/workspaces/components/`). Copy is in Option 6B above.
- For `platform_admin` users with zero accessible workspaces, the empty
  state additionally renders an inline link to `/admin/connect`.

**Vocabulary mapping:**
- Add `clientStatusLabel(taskStatus)` and `clientFeatureStatusLabel(featureStatus)`
  helpers in `src/features/board/lib/status.ts`. Use them everywhere a
  status label is rendered in `/board`, `/feature/*`, `/task/*`.
- Existing colour mapping for status pills stays.

**Activity feed presentation:**
- In `useActivity` (or equivalent) pass `audience=client` to the API. The
  server returns already-relabeled `action` strings; the FE renders them
  as-is.
- Render the activity feed in the existing `TaskTrackingPanel` and at the
  bottom of the feature drill-down.

**Polling refresh:**
- In the workspace context provider
  (`src/features/workspaces/context/WorkspaceContext.tsx`), schedule a
  background re-fetch of the active workspace every 30s while
  `document.visibilityState === "visible"`. Cancel on hide.
- Add a manual "Refresh" button to `BoardHeader` (icon-only, distinct from
  the deleted "Sync" control — refresh re-reads cached state from the
  backend; it does not trigger GitHub re-sync).

**No new pages, no new top-level routes for the client surface.** The
client uses the same `/board → /feature → /task` tree that exists today.

### Role visibility summary

| Role | `/login` | `/board` | `/feature/*` | `/task/*` | `/admin/*` |
|---|---|---|---|---|---|
| anonymous | yes | redirect to `/login` | redirect to `/login` | redirect to `/login` | redirect to `/login` |
| `client_member` | yes | yes (scoped) | yes (scoped) | yes (scoped) | 404 |
| `platform_admin` | yes | yes (all workspaces) | yes | yes | yes |

No per-control role gating inside `/board /feature /task` — the read view is
identical for all signed-in roles. Visibility differs purely by what their
`accessible_workspace_ids` contains.

### Why this lands the product-spec approval questions

> *"same digital-factory-ui surface in read-only mode vs. separate client-facing surface"*

Same surface, read-only, with operator-only routes moved under `/admin/*`.
Justified in Option 1.

> *"confirm vocabulary alignment with organizations/workspaces tables"*

No rename; `organizations` / `workspaces` / `features` / `tasks` are the
client-facing words too. Internal lifecycle states (`review_passed`,
`change_requested`, …) are mapped to a small, stable client vocabulary on
the FE. Documented in Option 2.

## 5. Dependency analysis

**Internal — prerequisites that are already satisfied:**
- `m1-identity-and-workspaces` is `done`. `user-service` is deployed and
  exposes `/api/me` and `/internal/sessions/validate`.
- `workflow-backend` already has `RequireAuth` middleware in place — the
  client-visibility feature does *not* need to add the middleware; it needs
  to activate the workspace filter that the middleware was designed to feed.
- `digital-factory-ui` already has `SessionGate`, `SessionContext`, and
  `MeResponse` typing with `accessible_workspace_ids`.

**Internal — to do in this feature:**
- Workspace-scoping logic in `workflow-backend/internal/service/workspace.go`
  (and any sibling files that issue queries without the filter — to be
  audited during T1).
- Activity allowlist in `workflow-backend`.
- Route + control removal + empty state in `digital-factory-ui`.
- Vocabulary mapping in `digital-factory-ui`.

**External:**
- None new. The OAuth apps, DNS, and admin email list were provisioned by
  m1-identity-and-workspaces (P1–P4 in that feature's design).

**Vendor / tooling:**
- No new dependencies. Existing Go + Gin + pgx + Next.js stack.

**Configuration:**
- No new environment variables. The `audience=client` query parameter is a
  request-level toggle, not a deploy-level one.

**Blocking decisions: none.** The two product-spec open questions are
resolved in Options 1, 2, 5, and 6 of this document. No external decision is
pending.

**External provisioning: none.**

## 6. Parallelization / blocking analysis

External decisions: **all resolved** in §3 (Options 1–6).
External provisioning: **none required** for this feature.

Task graph (proposed — final IDs and YAML files are produced in Phase 2,
**after** the human approves this design):

```
T1: workflow-backend — activate workspace scoping in service layer
       (ListWorkspaces, GetWorkspace, fetchWorkspace, SearchFeatures,
        SearchTasks, GetTask, ListActivity)
    └── Can begin now — no blockers
    │
    T2: workflow-backend — activity-feed allowlist + audience=client
        relabel
          └── Can begin now — no blockers (independent of T1's filter, but
              same repo)
          └── T1 and T2 run in parallel within workflow-backend, but they
              ship in the same PR to avoid two backend redeploys for the
              feature.

T3: digital-factory-ui — remove write affordances from client-reachable
    routes (CreateTaskButton + BoardHeader sync control + any
    onClick-write handlers in board components)
    └── Can begin now — no blockers (pure deletion + audit)
    │
    T4: digital-factory-ui — move /connect to /admin/connect + add
        /admin layout role guard
          └── Can begin now — no blockers; can run in parallel with T3
          │
          T5: digital-factory-ui — no-membership EmptyState component +
              replace /board and root-redirect "no workspaces" branches
                └── BLOCKED on T4 (need /admin/connect to exist so the
                    platform_admin variant of the empty state can link to
                    it correctly)

T6: digital-factory-ui — vocabulary mapping for status labels
    (clientStatusLabel, clientFeatureStatusLabel) and call sites in
    /board, /feature/*, /task/*
    └── Can begin now — no blockers; can run in parallel with T3/T4/T5

T7: digital-factory-ui — 30s focus-aware polling refresh in
    WorkspaceContext + manual Refresh button in BoardHeader
    └── BLOCKED on T3 (Refresh button replaces the Sync control slot
        removed in T3)

T8: digital-factory-ui — wire activity feed to ?audience=client
    └── BLOCKED on T2 (backend must accept the parameter)
```

Parallelism summary:
- **T1 and T2** are both in `workflow-backend` — both can begin now; ship as
  one PR.
- **T3, T4, T6** are independent `digital-factory-ui` edits and run in
  parallel.
- **T5** waits for T4.
- **T7** waits for T3.
- **T8** waits for T2.
- The two backend tasks are independent of the six frontend tasks. They can
  run fully in parallel.

Diagram (parallel-tracks view):

```
workflow-backend track:
   T1: activate scoping ──┐
   T2: activity allowlist ┘── one PR

digital-factory-ui track:
   T3: remove write controls    ─┐
   T4: move /connect to /admin   ┴── T5: empty state
   T6: vocabulary mapping       ──   T7: polling + refresh button
                                     T8: client activity wiring (waits on T2)
```

No task here writes to a second repo, so the workflow's one-repo-per-task
rule is naturally satisfied. The two backend tasks share a repo and are
candidates for merging into a single task in Phase 2; the design splits them
because they touch different files and have different review surface areas,
which keeps the diff readable. Phase 2 may merge them if the team prefers.

## 7. Repository impact

| Repo (`workspace.yaml -> repos[].id`) | Change |
|---|---|
| `workflow-backend` | Activate workspace scoping in `internal/service/workspace.go` and any sibling service files that fetch workspace-scoped data (audit during T1). Add `audience=client` handling to `ListActivity` plus the allowlist + label-rewrite logic. No new endpoints. No DB migration. New env vars: none. |
| `digital-factory-ui` | Remove write affordances from `/board`, `/feature/*`, `/task/*`. Move `/connect` → `/admin/connect` with a `platform_admin`-only layout guard. Add an `EmptyState` component for the no-membership landing. Add `clientStatusLabel` / `clientFeatureStatusLabel` helpers and use them at all status-render sites. Add a 30s focus-aware poll in `WorkspaceContext` and a manual "Refresh" button in `BoardHeader`. Wire the activity feed to `audience=client`. |
| `user-service` | **No change.** |
| `management-repo` | Tasks under `docs/features/m1-client-delivery-visibility/tasks/` once Phase 2 runs. Optional small `docs/overview.md` note documenting the activity-allowlist contract. **No `database/workspace/v003/`** — no schema migration. |
| `workspace-github-adapter` | **No change.** |
| `rag-service`, `git-nexus`, `workflow`, `management-repo` (otherwise) | **No change.** |

## 8. Validation and release impact

### Testing expectations

**workflow-backend unit:**
- `ListWorkspaces` with `AuthCtx{AccessibleWorkspaceIDs: [...]}` returns only
  those IDs; with an empty list returns `[]`; without `AuthCtx` returns all
  (preserving the unauthenticated/dev path).
- `GetWorkspace` returns 404 for an ID not in `AccessibleWorkspaceIDs`,
  including the same path that produced "not found" before scoping was
  active. The error code is `ErrDatabaseNotFound` (existing), not a new
  authorization error — so the FE renders the existing "not found" UI.
- `ListActivity` with `audience=client` filters to the allowlist and applies
  the relabel; without the parameter returns the unfiltered list.

**workflow-backend integration:**
- Seed two organizations + two workspaces. Sign in as a `client_member` of
  org A and confirm `GET /api/workspaces` returns only org A's workspaces;
  `GET /api/workspaces/<org B id>` returns 404; `GET /api/workspaces/<org B id>/activity`
  returns 404; `GET /api/workspaces/<org A id>/activity?audience=client`
  filters to allowed actions and applies labels.
- Sign in as `platform_admin` and confirm both orgs are visible.

**digital-factory-ui unit:**
- `clientStatusLabel("review_passed")` → "In review" (and the full table).
- `EmptyState` renders the right CTA for `platform_admin` vs.
  `client_member`.
- `BoardHeader` no longer renders `CreateTaskButton` or the old Sync
  control; a `Refresh` button is present.

**digital-factory-ui E2E (playwright):**
- A logged-in `client_member` lands on `/board`, sees their workspace name,
  sees no "Create task" / "Sync" / "Import" buttons anywhere, drills into a
  feature, drills into a task, returns to board. All states show the
  client-vocabulary labels.
- A `client_member` navigating to `/admin/connect` directly receives 404.
- A logged-in user with zero memberships sees the EmptyState and not the
  `/connect` import form.
- Polling: with the workspace open, mutate `workspace_tasks` directly in the
  DB and verify the FE picks up the change within ~30s without a manual
  refresh.

### Migration / config

- **No DB migration.** `database/workspace/schema.dbml` is unchanged; no
  `v003/` snapshot.
- **No new env vars.** The activity `audience` is a query parameter, not a
  deploy-level setting.
- **Activating scoping is a behaviour change for existing API consumers.**
  Today (in dev) the same code path returns every workspace because the
  filter is commented out. After this feature ships, an authenticated
  caller with zero `accessible_workspace_ids` sees zero workspaces. This is
  intended; the Kitelabs delivery team is in `PLATFORM_ADMIN_EMAILS`, which
  auto-grants membership on first login.

### Rollout

- Dev first. Verify the two-organization isolation case end-to-end on
  docker-compose.
- No staging exists (`workspace.yaml -> staging.enabled: false`). Production
  rollout follows dev verification.
- Backward compatibility:
  - The `/api/workspaces*` URL shape and response schema do not change.
  - The activity endpoint adds an optional `audience` parameter; absent =
    pre-existing behaviour. Existing internal callers (the FE today is the
    only one) are not broken.
  - The `/connect` route is **deleted, not redirected.** This is a known
    operator-side break: anyone who bookmarked `/connect` must update to
    `/admin/connect`. The current `/connect` traffic is one-digit
    internal-bookmark traffic — acceptable risk.

### Handoff implications

- M2 (Hermes / The Teammate) and M3 (The Thread) consume the same scoped
  read API and will add write affordances on top — under different routes,
  not by un-removing controls from these routes. The client surface stays
  read-only by construction.
- The vocabulary mapping table is the seed of a client-facing copy deck. M3
  will likely extend it; the central helper makes that easy.
- The activity allowlist is a contract documented in `docs/overview.md` (to
  be added in T2's PR). When new task-log action names appear in future
  workflow updates (per `CLAUDE.md` "Valid task log action names"), the
  allowlist must be revisited — a one-line maintenance step per new action.
