# Tasks — m1-identity-and-workspaces

> Feature status: `in_tdd` (reference). Stage status: `tasks/draft` until human approval.
> Machine-mutable state for each task lives in `tasks/T<n>.yaml`. This file is narrative
> only — descriptions, required skills, and subtask checklists.

## Index

| ID | Wave | Title | Repo | Depends on |
|---|---|---|---|---|
| T0 | 1 | Register `user-service` in `workspace.yaml` | management-repo | — |
| T1a | 1 | user-service DB schema v001 (identity + tenancy + sessions) | management-repo | — |
| T1b | 1 | workspace DB schema v002 — add `workspaces.organization_id` | management-repo | — |
| T2a | 2 | `user-service` repo scaffold (Go + Gin + pgx + Dockerfile + goose) | user-service | T0 |
| T2b | 3 | `user-service` — OAuth + sessions + identity + invitations + `/api/me` + `/internal/sessions/validate` | user-service | T1a, T2a |
| T3 | 4 | `workflow-backend` — service client + `RequireAuth` + `workspaces.organization_id` + scoped queries | workflow-backend | T1b, T2b |
| T4 | 1 | `digital-factory-ui` — `/login` page + session-aware root layout + logout | digital-factory-ui | — |
| T5 | 2 | `digital-factory-ui` — organization / workspace switcher driven by `/api/me` | digital-factory-ui | T4 |
| T6 | 5 | `user-service` seed — Kitelabs organization + workspaces backfill + `PLATFORM_ADMIN_EMAILS` auto-grant | user-service | T2b, T3 |

> **Note on bundled setup work:** T1a (user-service v001 schema) and T1b (workspace v002
> schema), along with the `database/` folder restructure they require, were authored
> together with this technical design and are already present on the feature-init branch.
> When this PR merges, mark T1a and T1b `done` directly. T0 is also a small change
> against the management repo; it may be batched into this PR or split as a follow-up.

## T0 — Register `user-service` in `workspace.yaml`

### Description

Add a new entry to `workspace.yaml -> repos[]` so the workflow harness recognises
`user-service` as a first-class repo in this workspace. Required before T2a, since
agents claiming work in `user-service` must be able to resolve its local path and
GitHub URL from the workspace config.

The entry is fully specified in the technical design (§Dependency Analysis):

```yaml
- id: user-service
  github: git@github.com:tiendv89/user-service.git
  local_path: env:USER_SERVICE_LOCAL_PATH
  base_branch: main
  owner_role: tech_lead
```

Operators must also set `USER_SERVICE_LOCAL_PATH` in their local `.env` after the
GitHub repo is created (P1).

### Required skills

- (none)

### Subtasks

- [ ] Add `user-service` entry to `workspace.yaml -> repos[]`
- [ ] Verify `workspace.yaml` validates against the workflow schema
- [ ] Note in `.env.template` that `USER_SERVICE_LOCAL_PATH` is required once P1 lands

---

## T1a — user-service DB schema v001 (identity + tenancy + sessions)

### Description

Land the canonical DBML for `user_db` covering users, auth_identities, organizations,
memberships, workspace_memberships, organization_invitations, and the scs-managed
sessions table. Captures the design decisions from §Chosen Design as a versioned
snapshot under the per-service schema layout.

This task touches **only** `database/user-service/`. SQL migration files in the
`user-service` repo (T2a) translate these tables into actual `pressly/goose/v3`
migrations.

**Setup status:** the files for this task were authored alongside the technical
design and are already present on the feature-init branch
(`database/user-service/schema.dbml`, `database/user-service/v001/schema.dbml`,
`database/user-service/v001/changelog.md`). Mark `done` when this PR merges.

### Required skills

- postgres-best-practices

### Subtasks

- [x] Create `database/user-service/schema.dbml` (current applied)
- [x] Create `database/user-service/v001/schema.dbml` (snapshot)
- [x] Create `database/user-service/v001/changelog.md` (changes + design notes)
- [x] Document cross-DB references (`workspace_memberships.workspace_id`, `organization_invitations.workspace_ids[]`) as no-FK
- [x] Document `lower(email)` functional indexes
- [x] Document `(provider, provider_sub)` unique constraint on `auth_identities`

---

## T1b — workspace DB schema v002 — add `workspaces.organization_id`

### Description

Bump `workspace_db` to v002 by adding `organization_id uuid NOT NULL` plus a single-
column index on `workspaces`. The column references `user-service`'s `organizations.id`
as a **plain UUID with no foreign key** (cross-DB). Application-level referential
integrity is enforced at the write boundary in `workflow-backend` (T3).

The v002 changelog records the three-step deployment sequence (nullable → backfill
via user-service seed → SET NOT NULL); the v002 snapshot reflects the final post-
migration state.

**Setup status:** the files for this task were authored alongside the technical
design and are already present on the feature-init branch
(`database/workspace/schema.dbml` updated, `database/workspace/v002/schema.dbml`,
`database/workspace/v002/changelog.md`). Mark `done` when this PR merges.

### Required skills

- postgres-best-practices

### Subtasks

- [x] Add `workspaces.organization_id uuid NOT NULL` to `database/workspace/schema.dbml`
- [x] Add single-column index on `organization_id`
- [x] Snapshot to `database/workspace/v002/schema.dbml`
- [x] Document migration sequence in `database/workspace/v002/changelog.md`
- [x] Annotate header comment with the cross-service reference

---

## T2a — `user-service` repo scaffold (Go + Gin + pgx + Dockerfile + goose)

### Description

Stand up the new `user-service` Go repository with the layout specified in the
technical design (§Chosen Design → user-service repo layout). Land the minimum
viable scaffold so T2b can fill in OAuth, sessions, and identity logic.

Includes: `go.mod`, package skeleton under `internal/` (`oauth/`, `sessions/`,
`users/`, `organizations/`, `httpapi/`, `serviceauth/`), `cmd/server/` and
`cmd/seed/` entry points (stubbed), `database/migrations/` directory with goose
config, `Dockerfile`, `docker-compose.yaml` (service + Postgres for local dev),
`Makefile` mirroring `workflow-backend`'s targets (`run-api`, `migrate-up`,
`new-migration`, `lint`, `test`), and CI workflow (lint + test on PR).

No application logic in this task — just the scaffold. A health check endpoint
(`GET /healthz` → `204`) is acceptable to verify the binary runs.

### Required skills

- go-best-practices
- backend-engineer

### Subtasks

- [ ] Initialise `go.mod` at module path `github.com/tiendv89/user-service`
- [ ] Create package skeleton (`cmd/server/`, `cmd/seed/`, `internal/{oauth,sessions,users,organizations,httpapi,serviceauth}/`)
- [ ] Add `pressly/goose/v3` + `pgx/v5` + `gin-gonic/gin` to deps
- [ ] Create `database/migrations/` (empty, goose-ready)
- [ ] Add `Dockerfile` (multi-stage, distroless or alpine)
- [ ] Add `docker-compose.yaml` (user-service + Postgres)
- [ ] Add `Makefile` with `run-api`, `migrate-up`, `migrate-down-1`, `new-migration`, `lint`, `test`
- [ ] Add `golangci-lint` config (match `workflow-backend`)
- [ ] Add CI workflow (`.github/workflows/ci.yml`) — lint + test on PR
- [ ] Implement `GET /healthz` returning 204
- [ ] README with local-dev instructions

---

## T2b — `user-service` — OAuth + sessions + identity + invitations + `/api/me` + `/internal/sessions/validate`

### Description

Fill the scaffold from T2a with the full identity surface:

- **OAuth**: server-side Authorization Code flow for Google and GitHub via
  `golang.org/x/oauth2`. State stored server-side via scs; CSRF-safe.
  Scopes per D1 (Google `openid email profile`; GitHub `read:user user:email`).
- **Sessions**: `alexedwards/scs/v2` + `scs/postgresstore` with HttpOnly Secure
  SameSite=Lax cookies; cookie domain from env (D3 placeholder).
- **Identity model**: CRUD for `users`, `auth_identities`. First-login creates user
  + auth_identity; subsequent same-(provider, provider_sub) login matches existing
  identity. No cross-provider auto-merge by email (per Option 3A).
- **Tenancy**: CRUD for `organizations`, `memberships`, `workspace_memberships`.
- **Invitations**: `organization_invitations` lookup + atomic acceptance inside one
  user_db transaction (creates user + auth_identity + membership + optional
  workspace_memberships).
- **Public endpoints**: `GET /auth/<provider>/start`, `GET /auth/<provider>/callback`,
  `POST /auth/logout`, `GET /api/me`.
- **Internal endpoint**: `POST /internal/sessions/validate` returning
  `{user_id, accessible_workspace_ids[]}`; gated by `USER_SERVICE_TOKEN` Bearer.
- **goose migrations**: SQL files in `database/migrations/` matching v001 from T1a.

### Required skills

- go-best-practices
- backend-engineer
- postgres-best-practices

### Subtasks

- [ ] Write goose migrations matching `database/user-service/v001/schema.dbml`
- [ ] OAuth Google provider config + code exchange + userinfo fetch
- [ ] OAuth GitHub provider config + code exchange + `/user/emails` fetch (primary verified email)
- [ ] OAuth state generation, storage in scs, verification on callback
- [ ] Session middleware: scs cookie config + postgresstore wiring
- [ ] `users` package: `EnsureUser(email, name, avatar)`, `FindByID`
- [ ] `users` package: `LinkAuthIdentity(userID, provider, sub, email, verified)`, `FindByProviderSub`
- [ ] `organizations` package: `CRUD` for organizations + memberships + workspace_memberships
- [ ] `organizations` package: `AccessibleWorkspaceIDs(userID)` — union over memberships, intersected with workspace_memberships where present
- [ ] Invitation acceptance flow (atomic transaction)
- [ ] First-login `PLATFORM_ADMIN_EMAILS` env check → auto-grant `platform_admin` on the Kitelabs org (will be wired with T6's seed)
- [ ] `GET /auth/<provider>/start` handler
- [ ] `GET /auth/<provider>/callback` handler (exchange + user/identity upsert + invitation consumption + session set + redirect)
- [ ] `POST /auth/logout` handler
- [ ] `GET /api/me` handler
- [ ] `serviceauth` middleware for `/internal/*` (Bearer `USER_SERVICE_TOKEN`)
- [ ] `POST /internal/sessions/validate` handler
- [ ] Unit tests: state gen/verify, AccessibleWorkspaceIDs across membership shapes
- [ ] Integration tests: full callback against mocked IdP; invitation atomicity; `/internal/sessions/validate` valid/invalid/expired/missing-token cases
- [ ] Update README env vars (per §Configuration)

---

## T3 — `workflow-backend` — service client + `RequireAuth` + `workspaces.organization_id` + scoped queries

### Description

Wire `workflow-backend` to consume `user-service` and gate every workspace-scoped
read by the caller's accessible workspaces. Three sub-changes:

1. **goose migration v002**: add `workspaces.organization_id` (nullable first;
   T6's seed backfills; follow-up migration sets NOT NULL) matching
   `database/workspace/v002/schema.dbml`.
2. **service client**: typed Go client for `POST /internal/sessions/validate`. Uses
   `USER_SERVICE_INTERNAL_URL` and `USER_SERVICE_TOKEN` from env. In-process LRU
   cache keyed by session cookie value, ~30s TTL, with explicit invalidation hooks
   if needed later.
3. **`RequireAuth` middleware**: reads the session cookie, calls the service client,
   attaches `AuthCtx{UserID, AccessibleWorkspaceIDs}` to the request context; 401
   on miss. Applied to all workspace-scoped routes.
4. **Query-layer filter**: every read query that returns workspace-scoped data
   gains `WHERE workspace_id = ANY($accessible)` via a `q.ScopedWorkspaceIDs(ctx)`
   helper.
5. **Create-workspace**: handler takes `organization_id` from the validated session
   payload (the caller's membership context); stored on the new row.

### Required skills

- go-best-practices
- backend-engineer
- postgres-best-practices

### Subtasks

- [ ] Write goose migration v002 (nullable column)
- [ ] Write goose migration v002b (SET NOT NULL after backfill — sequenced for post-seed deploy)
- [ ] Add single-column index on `organization_id`
- [ ] Implement `internal/serviceclient/user_service/` with typed `ValidateSession(cookie) → {user_id, accessible_workspace_ids}`
- [ ] LRU cache (size + TTL configurable; default 30s)
- [ ] Add env vars `USER_SERVICE_INTERNAL_URL`, `USER_SERVICE_TOKEN` to config; fail-fast on missing
- [ ] Implement `internal/authmw/RequireAuth` middleware
- [ ] Apply `RequireAuth` to all `/api/*` workspace-scoped routes
- [ ] Add `q.ScopedWorkspaceIDs(ctx) []uuid.UUID` helper
- [ ] Update every workspace-scoped read query to filter by `ScopedWorkspaceIDs`
- [ ] Update workspace create handler to read `organization_id` from `AuthCtx`
- [ ] Cross-tenant isolation test (user in org X gets 404, not 403, on resources in org Y)
- [ ] Integration test for middleware behaviour (valid/invalid/expired session; service-client failure → 503)

---

## T4 — `digital-factory-ui` — `/login` page + session-aware root layout + logout

### Description

Add the user-facing login experience. The login page shows two buttons — "Sign in
with Google" and "Sign in with GitHub" — each linking to
`${NEXT_PUBLIC_USER_SERVICE_URL}/auth/<provider>/start`. The root layout fetches
`${NEXT_PUBLIC_USER_SERVICE_URL}/api/me` on mount; on 401 it redirects to `/login`,
otherwise it provides the session context (user, memberships, accessible workspace
IDs) to downstream routes via a React context.

Logout is a single button in the header that calls
`POST ${NEXT_PUBLIC_USER_SERVICE_URL}/auth/logout` and then redirects to `/login`.

Can be implemented against a stubbed `/api/me` contract before T2b ships; E2E
verification against the real `user-service` requires T2b.

### Required skills

- nextjs-best-practices
- frontend-engineer
- typescript-best-practices
- heroui-react

### Subtasks

- [ ] Add `NEXT_PUBLIC_USER_SERVICE_URL` to `.env.template`
- [ ] Add `NEXT_PUBLIC_WORKFLOW_API_URL` to `.env.template` (existing API URL renamed for clarity)
- [ ] Create `/login` page with Google + GitHub buttons linking to `user-service`
- [ ] Create a typed `MeResponse` interface matching `user-service`'s `/api/me`
- [ ] Implement a `useSession()` hook + provider that fetches `/api/me` on mount
- [ ] Root layout: gate every non-`/login` route on session presence
- [ ] On 401 from `/api/me`, redirect to `/login`
- [ ] Add logout button + handler in the app header
- [ ] Ensure all subsequent fetches send the session cookie (browser default for same-parent-domain)
- [ ] Update README env table

---

## T5 — `digital-factory-ui` — organization / workspace switcher driven by `/api/me`

### Description

Add a switcher in the header that lets a logged-in user move between organizations
they are a member of and, within each organization, between accessible workspaces.
Driven entirely by the `memberships` and `accessible_workspace_ids` fields from
`/api/me` — no extra API call needed.

For a single-organization / single-workspace user (the common M1 case), render a
non-interactive label rather than a switcher.

### Required skills

- nextjs-best-practices
- frontend-engineer
- typescript-best-practices
- heroui-react

### Subtasks

- [ ] Header component: organization selector (visible when user has ≥2 memberships)
- [ ] Header component: workspace selector (visible when accessible workspaces ≥2 for the current org)
- [ ] Persist selected org + workspace in URL params (e.g. `?org=<slug>&ws=<slug>`)
- [ ] Update routes to scope data fetches by the current selection
- [ ] Empty state when memberships is empty ("contact your delivery team")
- [ ] Loading + error states

---

## T6 — `user-service` seed — Kitelabs organization + workspaces backfill + `PLATFORM_ADMIN_EMAILS` auto-grant

### Description

Implement the one-shot `cmd/seed/main.go` for `user-service`:

1. Create the `Kitelabs` organization in `user_db` if absent
   (`organizations(slug='kitelabs', name='Kitelabs')`).
2. Read `WORKFLOW_DB_DSN` and update `workspace_db.workspaces.organization_id` for
   every existing row to the Kitelabs org's UUID. Idempotent — re-running is a
   no-op once backfill is complete.
3. Wire the first-login `PLATFORM_ADMIN_EMAILS` auto-grant logic added in T2b to
   the seeded Kitelabs org. (The check itself is in T2b's OAuth callback; this
   task ensures the org exists and is wired correctly.)

After T6 runs once successfully, T3's follow-up `SET NOT NULL` migration can be
applied. T6 is run as part of the M1 deploy sequence (documented in the user-
service README).

### Required skills

- go-best-practices
- backend-engineer
- postgres-best-practices

### Subtasks

- [ ] Implement `cmd/seed/main.go` reading `USER_DB_DSN` and `WORKFLOW_DB_DSN`
- [ ] Idempotent insert: `organizations(slug='kitelabs', name='Kitelabs')`
- [ ] Idempotent update: `UPDATE workflow_db.workspaces SET organization_id = $kitelabs WHERE organization_id IS NULL`
- [ ] Print a summary (org UUID, rows updated, rows already set)
- [ ] Document run order in `user-service/README.md` (T2b deploy → T3 nullable migration → T6 seed → T3 NOT NULL migration)
- [ ] Verify `PLATFORM_ADMIN_EMAILS` auto-grant works against the seeded Kitelabs org (manual end-to-end check)
