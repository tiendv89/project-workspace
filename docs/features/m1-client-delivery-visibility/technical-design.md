# Technical Design

## Feature
- Feature ID: `m1-client-delivery-visibility`
- Title: `Client Delivery Visibility (read-only)`

> Status: **draft.** Authored by tech-lead Phase 1 after product spec approval.

## Current State

- `workflow-backend` (Go / Gin / pgx) hosts two service binaries that share the
  Postgres schema described in `database/schema.dbml` (workspace-data-backend v001):
  - **api-service** — read-side; queries `workspaces`, `workspace_features`,
    `workspace_tasks`, `workspace_activity_events`, `workspace_feature_documents`.
  - **adapter-service** — write-side; syncs git YAML state into those tables via
    the GitHub adapter.
- The schema already carries the workspace-scoped state this feature needs:
  features (`feature_status`, `current_stage`, `next_action`), tasks (`status`,
  `depends_on`, `blocked_reason`, `pr`), activity events (`scope_type`,
  `action`, `actor`, `note`, `occurred_at`).
- `digital-factory-ui` (Next.js) is the existing internal-facing dashboard. It
  reads workflow state and exposes operator-only views (claim controls, PR
  links, agent logs, retry buttons). It is **not** safe to expose to a
  non-engineer client as-is.
- No identity, account, or membership model exists today. That spine is being
  built in the sibling feature `m1-identity-and-workspaces`. This feature
  **must consume** that spine — login (Google + GitHub federated), session
  cookie, `user` / `account` / `workspace` / `membership` tables, and per-
  workspace scoping.
- `workspace_id` is already a first-class discriminator on every relevant
  state table — multi-tenant scoping is a query-filter problem, not a schema
  problem.

## Problem framing

What must change:

1. There is no client-facing surface today. The client cannot see the
   workspace, features, tasks, or activity their engagement is producing.
2. The existing `digital-factory-ui` mixes read views with operator action
   controls and internal nomenclature (agent claim commits, branch names, PR
   URLs, retry counts, raw logs). A non-engineer client must not see those.
3. There is no enforced authorization layer on the read APIs. Whatever read
   path the client UI uses must reject requests for workspaces the caller is
   not a member of, even if the caller can guess the slug.

What must remain stable:

- The data layer (`workspaces`, `workspace_features`, `workspace_tasks`,
  `workspace_activity_events`) — no schema additions needed for M1
  visibility; this feature is purely a presentation + authorization layer
  over already-synced state.
- The adapter-service write path — read clients must never trigger writes.
- The internal `digital-factory-ui` operator surface — unchanged in M1.

Fixed assumptions:

- Federated login (Google + GitHub) and the identity/membership tables land
  in `m1-identity-and-workspaces` before this feature ships to a real client.
- `membership` rows scope a user to one or more `(account_id, workspace_id)`
  pairs with a role. M1 needs only one client-shaped role
  (`client_viewer`) — see Dependency Analysis.
- "Near-real-time" is satisfied by polling on a short interval and/or
  refresh. M1 does not require server-push.

## Options considered

### Option A — Client-scoped route segment inside `digital-factory-ui`

Add a `/c/[workspace_slug]` route group with its own middleware that enforces
client-viewer role, swaps in a client-presentation layout, and renders only
read components. Reuse shared data-fetching hooks and primitives.

- **Pros**
  - Fastest path: one Next.js app, one deploy, one auth integration.
  - Reuses existing feature/task list and detail components — just stripped
    of action controls.
  - Single read-API client; one place to enforce auth scoping middleware.
- **Cons**
  - Soft boundary: action controls live in the same codebase as the client
    layout. A regression that conditionally renders an action button in the
    wrong layout would leak write affordances to a client.
  - Existing internal nomenclature (PRs, branches, agent identifiers) is
    sprinkled across shared components; sanitizing them piece by piece is
    fragile.
  - Mobile/responsive posture is unclear in the internal app — clients are
    likely to view this on laptops *and* phones.
- **Implementation impact**
  - One repo touched (`digital-factory-ui`) plus authorization changes in
    `workflow-backend` (`api-service`).
- **Dependency impact**
  - Soft-couples client UI release to the internal dashboard's release
    cadence and refactors.

### Option B — Net-new client portal app (separate Next.js app)

Stand up a new Next.js app — physically a different codebase / deploy /
domain — purpose-built for the non-engineer client. Consumes the same
`api-service` reads. Hard wall between internal and client UIs.

- **Pros**
  - Hard guarantee that no action controls can exist in the client UI — the
    app literally cannot render them because they aren't in its component
    tree.
  - Designed for the actual audience (non-engineer, mobile-friendly,
    plain-language status). Avoids the "operator console crammed into
    client-friendly skin" failure mode.
  - Independent release cadence: ship client improvements without coupling
    to internal dashboard work.
  - Easier to demo / sell — its own URL, its own brand surface.
- **Cons**
  - Net-new repo, deploy pipeline, auth wiring, design system bootstrap.
    Higher one-time setup cost.
  - Read-API consumption is duplicated (light — a couple of typed clients).
  - Two repos to keep aligned with the read-API schema; coordination cost
    when the schema evolves.
- **Implementation impact**
  - One new repo, plus `api-service` authorization changes in
    `workflow-backend`.
- **Dependency impact**
  - Adds a new repo to `workspace.yaml`; deploy story for the new app must
    land in the same milestone.

### Option C — Read-only "client mode" toggle inside `digital-factory-ui`

A session-flag-driven mode that hides action controls and rewrites labels.
Toggle is forced on for `client_viewer` role and locked.

- **Pros**
  - Minimal code churn.
- **Cons**
  - Same soft boundary as Option A but worse — relies on a global flag
    correctly reaching every component. One missed call site leaks an
    action affordance. This is the classic "read-only toggle on an
    operator console" antipattern.
  - Doesn't help with audience-appropriate language, mobile posture, or
    information density.
- **Implementation impact / dependency impact:** as Option A but riskier.

## Chosen design

**Option B — net-new client portal app**, served from a new repo
`client-portal` (Next.js). M1 ships the portal as the client-facing
surface; `digital-factory-ui` is unchanged.

Why:

- M1's whole point is the **services → product** moment. Putting the client
  in front of a stripped-down operator console muddles that moment. A
  purpose-built portal is the product surface.
- The read-only constraint becomes a structural guarantee: the portal
  codebase has no action paths to leak.
- The downstream M2/M3 work ("The Thread") needs a client-facing surface
  that can grow chat, mentions, approval gates without contorting an
  internal console. M1 sets that stage by making the client portal a
  first-class app from day one.
- Schema and read APIs already cover what the portal needs — the new
  surface area is presentation + authorization, not data.

### Components

```
client (browser)
  ↓  HTTPS + session cookie (federated login from m1-identity-and-workspaces)
client-portal (Next.js, new repo)
  • App Router; route group /[workspace_slug]
  • Server Components fetch from api-service; RSC boundary holds the
    typed client and the auth header
  • No write paths exist in the codebase
  ↓  HTTP (server-to-server) with session-derived auth token
workflow-backend / api-service (Go / Gin / pgx)
  • New client-scoped endpoints (or `?client=true` projection on existing
    endpoints; decided at implementation time) that:
    – filter by membership: only return workspaces/features/tasks/events
      the caller is a member of
    – strip internal fields before serialization (see Sanitization rules)
    – map raw status to client-presentation status (see Status mapping)
  ↓  pgx
Postgres (existing workspace-data-backend schema)
```

### Authorization model

- The session cookie minted by `m1-identity-and-workspaces` resolves to a
  `user_id`.
- `api-service` resolves `(user_id) → memberships[]` on every request and
  scopes queries to `workspace_id IN (...memberships)`.
- Role check: M1 ships a single client-shaped role `client_viewer`
  (defined in `m1-identity-and-workspaces`). The portal's middleware
  rejects any user whose membership for the requested workspace is not
  `client_viewer` (or a superset role allowed for testing).
- All authorization decisions live in `api-service`, not the portal.
  The portal trusts what `api-service` returns; portal-side filtering
  is presentation only, never the security boundary.

### Sanitization rules (server-side, in api-service)

Strip from every payload returned to a client-portal caller:

- Branch names (`feature/<x>`, task branches)
- PR URLs and PR-related fields (`pr.url`, `pr.status`, internal review
  state)
- Agent / orchestrator identifiers in `actor` (`reviewer_started`,
  `claimed`, etc.)
- Retry counts, `review_incomplete` cycle counts
- Raw error messages, blocked details that mention paths, configs, or
  credentials
- `actor_type` distinctions (`agent` / `human`) — collapse to the team

Keep:

- Feature title, current stage, next action (rewritten to client-safe
  language — see below).
- Task title, mapped status, dependency list, blocked reason (sanitized
  to a single client-readable sentence).
- Activity entries whose `action` is in the client-allowlist (see
  Status mapping). Drop everything else.

### Status mapping (raw → client-presentation)

Feature lifecycle (`feature_status`):
- `in_design`, `in_tdd`, `ready_for_implementation` → **Planning**
- `in_implementation` → **In progress**
- `in_handoff` → **Wrapping up**
- `done` → **Delivered**
- `blocked` → **Paused**
- `cancelled` → **Cancelled**

Task status:
- `todo`, `ready` → **Not started**
- `in_progress` → **In progress**
- `blocked` → **Paused**
- `in_review`, `reviewing`, `review_passed`, `change_requested`,
  `review_incomplete` → **In review**
- `done` → **Done**
- `cancelled` → **Cancelled**

Activity event allowlist (everything else dropped at the API layer):
- `created`, `started`, `blocked`, `done`, `cancelled`, `ready`

The mapping table lives in `api-service` so the wire format the portal sees
already contains the client-presentation labels.

### Refresh model

- Portal pages are RSC with a short revalidation interval (proposed: 30s).
- A client-side "Refresh" affordance triggers a hard reload of the
  Server Component tree.
- No WebSockets, no SSE in M1. Polling is sufficient for "near-real-time
  or on refresh" per the spec; pushes are an M3+ concern.

### Affected repositories

| Repo | Why |
|---|---|
| `client-portal` (NEW) | New Next.js app; the client-facing portal itself. |
| `workflow-backend` | Add client-scoped endpoints / projections to `api-service`; add membership-based authorization filter; add sanitization + status mapping. |
| `management-repo` (this repo) | Register the new repo in `workspace.yaml`. No schema, docs, or workflow rule changes beyond that. |
| `digital-factory-ui` | **Unchanged in M1.** Internal operator console continues as-is. |

The schema does not change for M1. `database/schema.dbml` is unaffected.

### Compatibility considerations

- No write paths added; no schema migrations. Adapter-service is untouched.
- The `client_viewer` role is defined in `m1-identity-and-workspaces`;
  this feature only consumes it.
- Internal callers continue to use the existing (unscoped or differently
  scoped) `api-service` endpoints. Client-scoped endpoints are an
  additive surface, not a replacement.

### Operational / release implications

- New deploy target: `client-portal` (Next.js). Hosting choice is a sub-
  decision at task time; recommend matching whatever hosts
  `digital-factory-ui` to keep ops thin.
- New domain or subdomain for the portal — a marketing-visible URL.
  Decision needed (see Dependency Analysis D1).
- Session cookie scoping: the portal and `api-service` must share a
  session domain. Decided by `m1-identity-and-workspaces` cookie domain
  choice (see Dependency Analysis D2).

## Dependency analysis

**Internal dependencies (feature-to-feature):**

- **`m1-identity-and-workspaces` — hard blocker.** Required artifacts before
  this feature can ship: federated login (Google + GitHub), session
  cookie, `user` / `account` / `workspace` / `membership` tables, and the
  `client_viewer` role. Task work in this feature can start in parallel
  for portal scaffolding and `api-service` plumbing, but end-to-end
  integration testing and ship are blocked on identity landing.

**External / cross-cutting decisions to resolve before tasks `T3`/`T4`/`T5`:**

- **D1 — Portal domain / subdomain.** Need a final URL (e.g.
  `app.<brand>.com` vs `portal.<brand>.com`). Affects DNS, TLS,
  marketing copy. Owner: Pye. Unblock: pick a name; provision DNS.
- **D2 — Session cookie domain.** The portal and `api-service` must share
  a session cookie domain (or the portal must call `api-service` through
  a same-origin proxy). Owner: tech lead of `m1-identity-and-workspaces`.
  Unblock: confirm cookie domain choice and CORS posture in the identity
  feature's technical design.
- **D3 — Hosting target for `client-portal`.** Vercel-style managed
  Next.js vs self-hosted to match `digital-factory-ui`. Owner: Pye.
  Unblock: choose; this affects task `T1` (repo scaffold) only lightly
  but sets ops expectations.

**External dependencies (vendors / tooling):**

- None new. Federated IdPs (Google, GitHub) are introduced by
  `m1-identity-and-workspaces`, not this feature.

**Configuration dependencies:**

- `workspace.yaml` must register `client-portal` as a new repo entry.
- `api-service` configuration must accept a `CLIENT_PORTAL_ORIGIN`
  (CORS allowlist) once the portal origin is known (resolves with D1).

**Release dependencies:**

- This feature cannot ship to a real external client until
  `m1-identity-and-workspaces` is live. Internal demo / dogfood (the
  delivery team viewing their own workspace) is possible earlier with a
  stub session, but that is not the M1 deliverable.

**Unresolved at design-approval time:**

- D1, D2, D3 above.
- Final list of activity event types to expose to the client is
  intentionally an allowlist that can grow without schema change. The
  initial list above is the starting point.

## Parallelization / blocking analysis

This diagram is illustrative for the chosen design. The concrete task
breakdown lands in `tasks.md` during Phase 2.

```
D1: Portal domain / subdomain (Pye)              ──┐
D2: Session cookie domain (m1-identity tech lead)──┤  resolve before T3/T4/T5 ship-ready
D3: Hosting target for client-portal (Pye)       ──┘  low-effort; can land in parallel with T1/T2

T1: Scaffold client-portal Next.js repo
  └── Can begin now — no blockers (placeholder env values OK)
  │
T2: api-service — add membership-scoped client projection
  └── Can begin now — no blockers (schema and unscoped reads already exist)
  │
  T3: Portal — workspace overview page (features + tasks list)
        └── BLOCKED on T1 (portal scaffold exists)
        └── BLOCKED on T2 (client projection endpoint reachable)
        │
        T4: Portal — feature/task detail page
              └── BLOCKED on T3 (shared layout + data hooks from overview)
              │
              T5: Portal — activity feed
                    └── BLOCKED on T2 (activity event projection)
                    └── BLOCKED on T3 (workspace layout shell)
                    │
                    T6: End-to-end auth wiring with m1-identity-and-workspaces
                          └── BLOCKED on m1-identity-and-workspaces shipping session + memberships
                          └── BLOCKED on D1, D2 (domain + cookie scope locked)
                          │
                          T7: Internal review + ship-readiness sign-off
                                └── T8: Register client-portal in workspace.yaml,
                                        deploy, mark feature done
                                              └── BLOCKED on D3 (hosting target chosen)
```

Notes:

- **T1 and T2 run in parallel** — they touch different repos
  (`client-portal` scaffold vs `workflow-backend / api-service`).
- **T3, T4, T5 are sequential** because they share layout, data hooks,
  and component primitives. Splitting them into parallel branches in M1
  produces avoidable rebase churn for negligible time saved.
- **T6 is the integration gate** — nothing ships externally until
  identity is in and end-to-end auth works.
- **T7 → T8** keeps the management-repo write (workspace.yaml + done
  marker) as the last step, so the feature isn't declared done until the
  portal is reachable from a real domain with real auth.

## Repository impact

| Repo (matches `workspace.yaml -> repos[].id`) | Why |
|---|---|
| `client-portal` (NEW — to be added to `workspace.yaml`) | The new client-facing Next.js portal. |
| `workflow-backend` | Client-scoped projection + sanitization + status mapping + membership auth filter in `api-service`. |
| `management-repo` | Register the new repo in `workspace.yaml` (single-line addition); no other doc/config changes. |
| `digital-factory-ui` | **No change** in M1. |

Task-level `repo` values must match these IDs.

## Validation and release impact

**Testing expectations:**

- `api-service` — unit tests for the membership scoping filter (the
  security boundary). Integration tests asserting that a request without
  membership for `workspace_id` returns 403/404 (no information leak via
  status code; prefer 404).
- `api-service` — golden tests for the sanitization layer: assert no PR
  URLs, branch names, or agent identifiers appear in client-projected
  payloads.
- `client-portal` — component tests for status mapping; smoke E2E that
  loads workspace overview / feature detail / activity feed against a
  stubbed `api-service`.
- E2E test with real `m1-identity-and-workspaces`: log in as a
  `client_viewer`, confirm only their workspace is visible, confirm
  no write affordances render anywhere.

**Migration / config impact:**

- No DB migrations.
- New env values in `workflow-backend`: `CLIENT_PORTAL_ORIGIN` (CORS).
- New repo registration in `workspace.yaml`.

**Rollout concerns:**

- Until `m1-identity-and-workspaces` is live, the portal can run in a
  stubbed-auth mode for internal demos but must not be exposed to
  external clients.
- Treat the first client onboarding as a soft launch: one workspace,
  one client org, manually invited.

**Backward compatibility:**

- Additive. Existing `api-service` consumers (the internal
  `digital-factory-ui`) are unaffected — client-scoped projections are
  separate endpoints (or a separate projection parameter, decided at
  task time).

**Deployment / handoff implications:**

- A new deploy target (`client-portal`) joins the M1 ship list.
- Handoff doc must include: portal URL, how the `client_viewer` role is
  granted to a user, and the first-client onboarding runbook.
