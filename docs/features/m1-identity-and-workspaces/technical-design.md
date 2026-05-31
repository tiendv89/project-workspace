# Technical Design

## Feature
- Feature ID: `m1-identity-and-workspaces`
- Title: `Identity, Org & Workspace Foundation`
- Milestone: **M1 — Open the Black Box**

## Current State

The platform today has **no identity layer**. The backend (`workflow-backend`,
Go/Gin/pgx) and frontend (`digital-factory-ui`, Next.js) operate without a logged-in
user — there is no `user`, no `account`/`org`, no `membership`, and the existing
`workspaces` table has no owner.

What does exist:

- `workflow-backend` — Go + Gin HTTP API; pgx for Postgres access; serves the dashboard.
- `workspace-github-adapter` — service that ingests feature/task YAML from GitHub into
  the core workspace tables (write side). Out of scope for M1 identity work.
- `digital-factory-ui` — Next.js dashboard that reads workflow state and renders it.
  No auth-gated routes today; everything is implicitly "the operator".
- `database/schema.dbml` (v001) — declares the **core** workspace tables: `workspaces`,
  `workspace_repos`, `workspace_features`, `workspace_tasks`,
  `workspace_feature_documents`, `workspace_activity_events`. Every core table already
  carries `workspace_id`. No identity tables exist.

Repo-level boundaries (per `workspace.yaml`):
- `workflow-backend` — owns workflow state reads and writes. Will gain a
  service-to-service client for `user-service` and a `RequireAuth` middleware; will
  **not** own identity tables.
- `digital-factory-ui` — owns login UI, session-aware routing, and account/workspace UX.
  Talks to **both** services after M1.
- `management-repo` (this repo) — owns the canonical schema docs for **both** DBs and
  the feature/workflow YAML.
- `workspace-github-adapter` — unaffected. Its `workspace_id`-scoped writes continue
  to work; it does not need an authenticated user.
- `user-service` — **new Go repo, to be created.** Same stack family as
  `workflow-backend` (Go + Gin + pgx). Owns identity entirely.

## Problem Framing

**What must change:**

1. Stand up a **new `user-service`** repo + service + database. Owns: `users`,
   `auth_identities`, `accounts`, `memberships`, `workspace_memberships`,
   `account_invitations`, `sessions`.
2. Implement server-side OAuth flows for **Google** and **GitHub** in `user-service`
   (Authorization Code, library-handled session/cookie — not a custom auth system).
3. Expose two surfaces from `user-service`:
   - **Public** (browser-facing): `/auth/*`, `/api/me`, `/auth/logout`.
   - **Internal** (service-to-service): `/internal/sessions/validate` returning
     `{user_id, accessible_workspace_ids}` to other services.
4. Add `account_id` to `workspaces` in `workflow-backend`'s database — as a plain
   UUID column, **no cross-DB FK** (the two services run separate Postgres instances).
5. Add a `RequireAuth` middleware in `workflow-backend` that validates the session
   via `user-service` and scopes every workspace-scoped read by
   `accessible_workspace_ids`.
6. Add login UI + session-aware layout + account/workspace switcher in
   `digital-factory-ui`. The frontend gains two base URLs — one per service.
7. Seed an internal "Kitelabs" account in `user-service`'s DB, backfill all existing
   workspaces with that account's ID, and grant the delivery team `platform_admin`
   memberships via an env-driven email list.

**What must stay stable:**

- The existing `workspace_id`-scoped read API surface in `workflow-backend` — the
  sibling feature `m1-client-delivery-visibility` consumes it once it sits behind
  `RequireAuth`.
- The GitHub adapter's write path — no changes; it writes by `workspace_id`, which
  is preserved.
- All existing v001 columns and indexes — additions only, no destructive change.

**Fixed assumptions:**

- **`user-service` is written in Go.** Same language as `workflow-backend`, same
  team toolchain, same migration tool (`pressly/goose/v3`), same DB driver (`pgx`).
  No new language is introduced by M1. Concrete stack: Go 1.22+, Gin (HTTP
  router), pgx (Postgres driver), `golang.org/x/oauth2` (OAuth client),
  `alexedwards/scs/v2` + `scs/postgresstore` (sessions).
- Self-hosted identity in our own Go code (no Auth0 / Clerk / Supabase Auth). We
  consume Google + GitHub as IdPs only.
- B2B services model — clients are invited; no self-serve account creation in M1.
- Read-only client surface (per sibling feature) — no client mutations in M1.
- **Microservice split from day one** — `user-service` and `workflow-backend` are
  separate services with separate Postgres instances. This is a deliberate decision
  to avoid a future extraction migration. See Option 6 and Option 7 below.

## Options Considered

### Option 1 — Session storage layer

**Option 1A: Server-side sessions in Postgres (opaque cookie)**
- Library: `alexedwards/scs/v2` with `scs/postgresstore`.
- Pros:
  - Trivial to invalidate (delete the row); supports logout-everywhere.
  - Cookie is opaque and small.
  - Active maintenance, idiomatic Go, postgres-native store (no new infra).
- Cons:
  - One DB read per `/internal/sessions/validate` call (mitigated by an in-process
    cache in workflow-backend with short TTL).

**Option 1B: Stateless JWT in cookie**
- Pros: no DB read on every request.
- Cons: hard to invalidate (need a deny-list — state anyway); larger cookie; key
  rotation is non-trivial. Not needed at M1 traffic.

**Selected: 1A.** Sessions live in `user_db`. workflow-backend never touches the
session store directly — it calls `/internal/sessions/validate`.

### Option 2 — OAuth client architecture

**Option 2A: Server-side Authorization Code flow (`user-service` handles callback)**
- Frontend redirects to `user-service` `/auth/<provider>/start`; service redirects
  to IdP; IdP redirects back to `user-service` `/auth/<provider>/callback`; service
  exchanges code, fetches user info, creates/links `user` + `auth_identity`, sets
  session cookie, redirects to the frontend.
- Pros:
  - Client secret stays inside `user-service`.
  - Cookie set as `HttpOnly Secure SameSite=Lax` by `user-service` on its own
    domain (must be a sibling subdomain of the FE — see D3).
  - Service-to-service trust is the only place secrets travel.
- Cons: requires cookie-domain coordination (covered by D3).

**Option 2B: Frontend handles OAuth, exchanges with backend afterward**
- Cons: client secret lives in Next.js server runtime; extra surface; cookie domain
  story is awkward across two backend services.

**Selected: 2A.**

### Option 3 — Account linking across providers

**Option 3A: First-login creates user; subsequent same-provider login matches by
`(provider, provider_sub)`; cross-provider linking only when a logged-in user adds
the second provider.**
- Pros: avoids GitHub-unverified-email pitfalls; deterministic.
- Cons: a user who logs in with Google then later with GitHub (logged out) gets two
  separate `user` rows. Manual merge is a future feature.

**Option 3B: Auto-link by verified email**
- Cons: false merges (or false non-merges) easy to create.

**Selected: 3A for M1.**

### Option 4 — Per-workspace scoping model

**Option 4A: Account membership + optional per-workspace overrides**
- `memberships(user_id, account_id, role)` grants account-wide access.
- `workspace_memberships(user_id, workspace_id)` is **opt-in scoping** — if any rows
  exist for that user in that account, they are limited to those workspaces.
  Otherwise account membership grants access to everything in the account.

**Option 4B: Per-workspace membership only**
- Cons: provisioning overhead.

**Selected: 4A.**

### Option 5 — Account provisioning model for M1

**Option 5A: Invitation-only.** Internal admin creates accounts + workspaces +
invitations; new client logs in, invitation matched by verified provider email
consumed atomically inside `user-service`.

**Option 5B: Self-serve account creation.** Out of scope for M1.

**Selected: 5A.**

### Option 6 — Service topology

**Option 6A: Monolith now, design seam for future extraction.**
- Identity lives as three packages inside `workflow-backend`; narrow internal API;
  extract later when M2/M3 needs it.
- Pros: ~3–4 weeks less M1 work; no service-to-service auth needed yet; FKs intact
  if the DB also stays single-instance.
- Cons: extraction later requires app-level surgery; team builds identity habits
  that bleed across the boundary.

**Option 6B: Separate `user-service` from day one.**
- Two services from M1: `user-service` (identity) + `workflow-backend` (workflow).
- Pros: no future service split needed; forces clean API from the start; security
  isolation of OAuth secrets and session table; reusable for M2 Hermes and M3
  Thread without any rework.
- Cons: doubles M1 service-scaffold work; introduces service-to-service auth;
  requires a new repo and CI pipeline; local-dev grows by one container.

**Selected: 6B.** The user has chosen to absorb the upfront cost now to avoid any
future extraction work. See Chosen Design for the contract surface.

### Option 7 — Database topology

**Option 7A: Shared DB, shared schema.** Identity tables and workflow tables in one
Postgres. FKs intact (`workspaces.account_id → accounts.id`). Cheapest path; ties
hard to 6A.

**Option 7B: Shared DB, separate Postgres schemas (`users.*` + `public.*`).** One
Postgres instance, logical separation. Cross-schema FKs still work. Future
extraction is `pg_dump --schema=users` into a new instance. Compatible with 6A or
6B; cheap.

**Option 7C: Separate Postgres instances per service from day one.** Two DBs
deployed independently. `workspaces.account_id` is a plain UUID column with no
cross-DB FK — application-level referential integrity only. No future DB
migration.

**Selected: 7C.** Mandated by 6B — each service owns its own DB. The cost is the
loss of an FK on `workspaces.account_id` and the need to enforce that integrity in
`user-service` (the service that issues `account_id` values in session payloads)
and in `workflow-backend` (which trusts those values).

## Chosen Design

### Two services, two databases

```
┌────────────────────┐                ┌──────────────────────┐
│ digital-factory-ui │                │     IdP (Google,     │
│  (Next.js, browser)│                │       GitHub)        │
└────┬──────────┬────┘                └──────────┬───────────┘
     │          │                                │
     │ /auth/*  │  /api/me                       │ OAuth redirect
     │          │  /auth/logout                  │
     │          ▼                                ▼
     │  ┌───────────────────────────────────────────────────┐
     │  │              user-service (NEW)                   │
     │  │  Go + Gin + pgx + golang.org/x/oauth2 +           │
     │  │  alexedwards/scs/v2 (postgresstore)               │
     │  │                                                   │
     │  │  PUBLIC:                                          │
     │  │   GET  /auth/<provider>/start                     │
     │  │   GET  /auth/<provider>/callback                  │
     │  │   POST /auth/logout                               │
     │  │   GET  /api/me                                    │
     │  │                                                   │
     │  │  INTERNAL (service-token auth):                   │
     │  │   POST /internal/sessions/validate                │
     │  │     → { user_id, accessible_workspace_ids[] }     │
     │  │                                                   │
     │  │  Owns: users, auth_identities, accounts,          │
     │  │  memberships, workspace_memberships,              │
     │  │  account_invitations, sessions                    │
     │  └────────────────────┬──────────────────────────────┘
     │                       │ pgx
     │                       ▼
     │                 ┌─────────────┐
     │                 │  user_db    │ (Postgres instance #1)
     │                 └─────────────┘
     │
     │ /api/* (everything else)
     ▼
┌─────────────────────────────────────────┐
│        workflow-backend (existing)      │
│                                         │
│  + RequireAuth middleware               │
│    → calls user-service                 │
│      /internal/sessions/validate        │
│    → caches result per session in       │
│      memory (~30s TTL)                  │
│  + AccessibleWorkspaceIDs from cache    │
│  + workspaces.account_id (plain UUID,   │
│    no cross-DB FK)                      │
│                                         │
│  Owns: workspaces, workspace_features,  │
│  workspace_tasks, workspace_activity_   │
│  events, workspace_repos,               │
│  workspace_feature_documents,           │
│  workspace_github_sources,              │
│  workspace_sync_runs                    │
└──────────────────┬──────────────────────┘
                   │ pgx
                   ▼
            ┌──────────────┐
            │ workflow_db  │ (Postgres instance #2)
            └──────────────┘
```

### `user-service` (new Go repo)

**Language:** Go (same as `workflow-backend`). **No other language is allowed in
this repo for M1** — all OAuth, session, and identity logic is implemented in Go.

**Stack:** Go 1.22+, Gin (HTTP router), pgx (Postgres driver),
`golang.org/x/oauth2` (OAuth client), `alexedwards/scs/v2` + `scs/postgresstore`
(server-side sessions), `pressly/goose/v3` (migrations — matches workflow-backend).

**Repo layout (proposed):**

```
user-service/
  cmd/server/main.go         # HTTP entrypoint
  cmd/seed/main.go           # one-shot Kitelabs-account seeder
  internal/
    oauth/                   # provider configs, code exchange, userinfo fetch
    sessions/                # scs configuration, /internal/sessions/validate
    users/                   # users + auth_identities CRUD
    accounts/                # accounts, memberships, workspace_memberships, invitations
    httpapi/                 # gin routes wiring the above together
    serviceauth/             # service-token middleware for /internal/*
  database/
    schema.dbml              # canonical DBML for user_db
    migrations/              # SQL migrations (pressly/goose/v3 — same as workflow-backend)
  Dockerfile
  docker-compose.yaml        # for local dev (service + Postgres)
  go.mod / go.sum
```

**Public HTTP surface** (cookie-based, no service token required):

| Method | Path | Purpose |
|---|---|---|
| GET | `/auth/<provider>/start` | Generates per-flow `state`, stores in scs, redirects to IdP authorize URL |
| GET | `/auth/<provider>/callback` | Verifies `state`, exchanges code, fetches user info, upserts user + auth_identity, consumes any matching `account_invitation` inside a single user_db transaction, sets session cookie, redirects to FE |
| POST | `/auth/logout` | Destroys session, clears cookie |
| GET | `/api/me` | Returns `{user, memberships, accessible_workspace_ids}` for current session; 401 otherwise |

**Internal HTTP surface** (service-token authenticated via `Authorization: Bearer
<USER_SERVICE_TOKEN>`):

| Method | Path | Purpose |
|---|---|---|
| POST | `/internal/sessions/validate` | Body: `{cookie_value}` → Returns `{user_id, accessible_workspace_ids[]}` or 401. Used by workflow-backend's RequireAuth. |

Cookie attributes: `HttpOnly`, `Secure`, `SameSite=Lax`, 30-day rolling. Cookie
domain must be the parent of both FE and `user-service` (e.g. `.app.kitelabs.dev`)
— covered by D3.

### Tables in `user_db`

```text
users(
  id uuid pk,
  email text not null,            -- last-known primary email
  display_name text,
  avatar_url text,
  created_at, updated_at
)
indexes: lower(email)

auth_identities(
  id uuid pk,
  user_id uuid -> users.id not null,
  provider text not null,         -- 'google' | 'github'
  provider_sub text not null,
  email text,
  email_verified boolean,
  created_at
)
indexes: (provider, provider_sub) unique, user_id

accounts(
  id uuid pk,
  slug text unique not null,
  name text not null,
  created_at, updated_at
)

memberships(
  id uuid pk,
  user_id uuid -> users.id not null,
  account_id uuid -> accounts.id not null,
  role text not null,             -- 'platform_admin' | 'client_member' for M1
  created_at, updated_at
)
indexes: (user_id, account_id) unique, account_id

workspace_memberships(
  id uuid pk,
  user_id uuid -> users.id not null,
  workspace_id uuid not null,     -- NOTE: workspace lives in workflow_db; no FK
  created_at
)
indexes: (user_id, workspace_id) unique, workspace_id
-- presence of any row here for (user, account) scopes the user to those workspaces only

account_invitations(
  id uuid pk,
  account_id uuid -> accounts.id not null,
  email text not null,
  role text not null,
  invited_by_user_id uuid -> users.id,
  workspace_ids jsonb,            -- null = all workspaces in the account; otherwise specific UUIDs from workflow_db
  created_at, expires_at, accepted_at, accepted_by_user_id uuid -> users.id
)
indexes: (account_id, lower(email)), expires_at

sessions(
  -- managed by scs/postgresstore — schema dictated by the library
)
```

### Tables in `workflow_db`

```text
workspaces  (existing — modified)
  + account_id uuid not null      -- plain UUID; no FK (account lives in user_db)
  + index on account_id

-- All other workflow_db tables remain unchanged (v001 schema).
```

### `workflow-backend` changes

- **`internal/serviceclient/user_service/`** — typed Go client for user-service's
  `/internal/sessions/validate`. Uses `USER_SERVICE_TOKEN` from env. Includes an
  in-process session cache (LRU, key = session cookie value, value =
  `{user_id, accessible_workspace_ids, fetched_at}`, TTL ~30s).
- **`internal/authmw/`** — `RequireAuth` middleware. Reads session cookie, calls
  the service client, attaches `AuthCtx{UserID, AccessibleWorkspaceIDs}` to the
  request context; 401 on miss.
- **Query layer** — every workspace-scoped read query gains a
  `WHERE workspace_id = ANY($accessible)` filter. Helper:
  `func (q *Queries) ScopedWorkspaceIDs(ctx) []uuid.UUID` reads from `AuthCtx`.
- **`internal/workspaces/`** — `account_id` becomes a required field on create.
  On create, the handler reads `account_id` from the validated session payload
  (the caller's membership context) and stores it on the row.

### Roles (M1)

- `platform_admin` — Kitelabs internal team. Sees all accounts and workspaces.
  Auto-granted on first login if the user's verified email is in
  `PLATFORM_ADMIN_EMAILS`.
- `client_member` — invited client user. Read-only at the application layer.

### Account seeding & data migration

A one-shot `cmd/seed` in `user-service`:
1. Creates `accounts(slug='kitelabs', name='Kitelabs')` if absent.
2. Reads `WORKFLOW_DB_DSN` and updates `workflow_db.workspaces.account_id` for all
   existing rows to the Kitelabs account ID. (This is the one cross-DB write in
   M1; it runs once at deploy and is idempotent.)
3. `PLATFORM_ADMIN_EMAILS` is consulted at first-login time inside
   `user-service` — no seeded user rows. When an admin first logs in via Google
   or GitHub, the callback handler checks the verified email against the env
   list and creates the `platform_admin` membership.

### Frontend (`digital-factory-ui`)

- New `/login` page: "Sign in with Google" + "Sign in with GitHub" buttons. Both
  link to `${NEXT_PUBLIC_USER_SERVICE_URL}/auth/<provider>/start`.
- Session-aware root layout: on mount, fetch `${NEXT_PUBLIC_USER_SERVICE_URL}/api/me`;
  on 401, redirect to `/login`.
- Account / workspace switcher reads from `/api/me`.
- Logout control → `POST ${NEXT_PUBLIC_USER_SERVICE_URL}/auth/logout`.
- All workflow data fetches go to `${NEXT_PUBLIC_WORKFLOW_API_URL}` and send the
  session cookie (browser does this automatically once cookie domain is
  configured per D3).

### Configuration (env)

**`user-service`:**

| Var | Purpose |
|---|---|
| `USER_DB_DSN` | Postgres DSN for user_db |
| `OAUTH_GOOGLE_CLIENT_ID`, `OAUTH_GOOGLE_CLIENT_SECRET` | Google OAuth app |
| `OAUTH_GITHUB_CLIENT_ID`, `OAUTH_GITHUB_CLIENT_SECRET` | GitHub OAuth app |
| `OAUTH_REDIRECT_BASE_URL` | Public URL of user-service (used to build callback URLs) |
| `SESSION_COOKIE_DOMAIN` | e.g. `.app.kitelabs.dev` for prod; `localhost` for dev |
| `FRONTEND_BASE_URL` | Used for post-login redirect |
| `PLATFORM_ADMIN_EMAILS` | Comma-separated emails auto-granted `platform_admin` on first login |
| `USER_SERVICE_TOKEN` | Shared secret accepted on `/internal/*` (must match the same env var in workflow-backend) |
| `WORKFLOW_DB_DSN` (seed cmd only) | For one-time backfill of `workspaces.account_id` |

**`workflow-backend`:**

| Var | Purpose |
|---|---|
| `USER_SERVICE_INTERNAL_URL` | Base URL for `/internal/sessions/validate` |
| `USER_SERVICE_TOKEN` | Shared secret presented to user-service `/internal/*` (must match user-service's value) |

## Dependency Analysis

**Internal:**
- **New repo registration** in `workspace.yaml`:
  ```yaml
  - id: user-service
    github: git@github.com:tiendv89/user-service.git
    local_path: env:USER_SERVICE_LOCAL_PATH
    base_branch: main
    owner_role: tech_lead
  ```
  The GitHub repo itself must be created (by ops with admin in the org). The
  `USER_SERVICE_LOCAL_PATH` env value must be set by every operator's local `.env`.
- The schema docs for both DBs live under `database/` in this management repo.
  Proposal: rename current `database/schema.dbml` → `database/workflow/schema.dbml`
  and add `database/user/schema.dbml`. (To be confirmed in T1.)
- The sibling feature `m1-client-delivery-visibility` consumes the `RequireAuth`
  middleware in `workflow-backend` + `/api/me` from `user-service`. It is **gated
  on this feature** but does not block any task here.

**External:**
- **Google OAuth client registration** in the Kitelabs GCP project. Callback URL
  pattern: `<OAUTH_REDIRECT_BASE_URL>/auth/google/callback`.
- **GitHub OAuth App registration** in the Kitelabs GitHub org. Callback URL:
  `<OAUTH_REDIRECT_BASE_URL>/auth/github/callback`.
- **Public DNS for `user-service`** — must be a sibling subdomain of the FE so a
  parent-domain cookie covers both (e.g. FE on `app.kitelabs.dev`,
  user-service on `users.app.kitelabs.dev`, cookie domain `.app.kitelabs.dev`).

**Resolved decisions:**

- **D1 — OAuth scopes:**
  - Google: `openid email profile`. (`openid` enables id_token + the `sub` claim
    used as `auth_identities.provider_sub`; `email` and `profile` cover the user
    info fetch.)
  - GitHub: `read:user user:email`. (`read:user` enables `GET /user` for profile;
    `user:email` enables `GET /user/emails` for the primary verified email,
    which GitHub does not always return on the profile endpoint.)
  - **No `repo` scope on GitHub** — repo-side bot work is M6, not M1. We will
    request it under a separate OAuth flow at that time.
- **D2 — `PLATFORM_ADMIN_EMAILS` for first deploy: placeholder.** `.env.template`
  and deployment configs ship `PLATFORM_ADMIN_EMAILS=placeholder@example.com` and
  the operator overrides per environment before first login. M1 does not block on
  the real list.
- **D4 — Migration tool: `pressly/goose/v3`** for both `user_db` and `workflow_db`.
  This matches what `workflow-backend` already uses (`migrations/*.sql` with
  `-- +goose Up` / `-- +goose Down` directives; Makefile targets `migrate-up` and
  `new-migration`). `user-service` adopts the same layout and Makefile targets;
  the binary embeds goose and the migration command runs via
  `go run ./cmd migration -u 0` per workflow-backend's pattern.
- **D5 — `USER_SERVICE_TOKEN` rotation policy: static per environment for M1.**
  Set once at deploy time via env. No rotation tooling, no key versioning. A real
  rotation policy (and the mTLS upgrade discussed in §Constraints) is a known
  follow-up for M6 enterprise trust.
- **D6 — Schema docs layout: split.** `database/user/schema.dbml` (new) +
  `database/workflow/schema.dbml` (renamed from current `database/schema.dbml`).
  Each DB has its own migration cadence, so a single combined DBML would obscure
  ownership.
- **D3 — Cookie domain: placeholder per environment.** The contract is fixed:
  FE and `user-service` must share a parent domain; `SESSION_COOKIE_DOMAIN` is
  set to that parent. Concrete values are operator-provided per environment.
  `.env.template` ships placeholders that any operator can override before first
  deploy of each env:
  ```
  # FE and user-service must be sibling subdomains of SESSION_COOKIE_DOMAIN.
  # Example dev:  FRONTEND_BASE_URL=http://app.lvh.me:3000
  #               OAUTH_REDIRECT_BASE_URL=http://users.lvh.me:8081
  #               SESSION_COOKIE_DOMAIN=.lvh.me
  # Example prod: FRONTEND_BASE_URL=https://app.example.com
  #               OAUTH_REDIRECT_BASE_URL=https://users.app.example.com
  #               SESSION_COOKIE_DOMAIN=.app.example.com
  FRONTEND_BASE_URL=<placeholder>
  OAUTH_REDIRECT_BASE_URL=<placeholder>
  SESSION_COOKIE_DOMAIN=<placeholder>
  ```
  Concrete dev/prod values lock at deploy time, not at design time.

**Unresolved decisions:** none.

**External provisioning (owner: ops):**
- **P1**: GitHub `tiendv89/user-service` repo created.
- **P2**: Google OAuth client created (callback URL configured).
- **P3**: GitHub OAuth App created (callback URL configured).
- **P4**: DNS for `user-service` in target environments (per D3).

P1–P4 must land before T2b can be end-to-end tested but **do not block writing
T2a (scaffold) or T2b (logic)**.

**Vendor / tooling:**
- Postgres ≥ 14 (already in use). Two instances now.
- Go ≥ 1.22 (already in use).
- Next.js (already in use).
- No new managed services (no Redis, no managed identity).

## Parallelization / Blocking Analysis

External decisions: **all resolved.**

```
D1 = Google openid+email+profile / GitHub read:user+user:email
D2 = placeholder PLATFORM_ADMIN_EMAILS (operator overrides per env)
D3 = placeholder cookie domain (operator overrides per env)
D4 = pressly/goose/v3
D5 = static USER_SERVICE_TOKEN per env
D6 = split schema docs (database/user/ + database/workflow/)
```

External provisioning (owner: ops):

```
P1: Create user-service GitHub repo       ──┐  blocks T2a only at push time
P2: Google OAuth client created           ──┤  blocks T2b E2E test
P3: GitHub OAuth App created              ──┤  blocks T2b E2E test
P4: Public DNS configured (per env)       ──┘  blocks first deploy
```

Task graph (proposed — finalised in Phase 2):

```
T0: workspace.yaml — register user-service repo (management-repo)
  └── Can begin now — no blockers
  │
  T1a: Schema for user_db (management-repo: database/user/schema.dbml)
  T1b: Schema for workflow_db — add workspaces.account_id (management-repo: database/workflow/schema.dbml)
       └── T1a and T1b run in parallel
       └── Both can begin now (D6 resolved — split layout)

T2a: user-service repo scaffold — Go + Gin + pgx + Dockerfile + CI (user-service)
       └── BLOCKED on T0 (workspace.yaml entry) and P1 (GitHub repo exists)
       │
       T2b: user-service — OAuth + sessions + identity + invitations
            + /api/me + /internal/sessions/validate (user-service)
              └── BLOCKED on T1a (user_db schema must exist)
              └── BLOCKED on T2a (service scaffold must exist)
              └── Soft-blocked on P2/P3 for E2E test; can be implemented + unit-tested without
              └── Concrete D3 cookie-domain values needed at deploy time only
              │
              T3: workflow-backend — service client + RequireAuth middleware
                  + workspaces.account_id + scoped queries (workflow-backend)
                    └── BLOCKED on T1b (workspaces.account_id column must exist)
                    └── BLOCKED on T2b (/internal/sessions/validate must exist)
                    │
                    T6: user-service seed — Kitelabs account + workspaces backfill
                        + first-login PLATFORM_ADMIN_EMAILS auto-grant (user-service)
                          └── BLOCKED on T2b (invitation + membership logic exists)
                          └── BLOCKED on T3 (account_id column exists in workflow_db)
                          └── (D2 resolved as placeholder; operator overrides per env)

T4: digital-factory-ui — /login page + session-aware root layout
    + /api/me consumer + logout control (digital-factory-ui)
      └── Can begin now using a stub /api/me contract (parallel with T2a/T2b)
      └── BLOCKED on T2b for end-to-end test
      │
      T5: digital-factory-ui — account / workspace switcher driven by /api/me (digital-factory-ui)
            └── BLOCKED on T4 (layout + session context must exist)
            └── BLOCKED on T2b for end-to-end test
```

Parallelism summary:
- **T0** runs first (just one workspace.yaml edit).
- **T1a, T1b, T4** all run in parallel as soon as T0 lands. T4 uses a stub
  `/api/me` contract.
- **T2a** runs in parallel with T1a/T1b once P1 lands.
- **T2b** depends on T1a and T2a.
- **T3** depends on T1b and T2b.
- **T5** depends on T4.
- **T6** depends on T2b and T3.

## Repository Impact

| Repo (`workspace.yaml -> repos[].id`) | Change |
|---|---|
| `management-repo` | T0 (`workspace.yaml` entry for `user-service`); schema docs split into `database/user/` + `database/workflow/`; `database/workflow/schema.dbml` adds `workspaces.account_id`; `database/user/schema.dbml` is new. |
| `user-service` (**new**) | Whole repo scaffold + OAuth + sessions + identity models + invitations + seeding cmd + Dockerfile + docker-compose. |
| `workflow-backend` | Service client for user-service; `RequireAuth` middleware; `workspaces.account_id` column; scoped query layer; updated env (`USER_SERVICE_INTERNAL_URL`, `USER_SERVICE_TOKEN`). |
| `digital-factory-ui` | Login page, session-aware layout, account/workspace switcher, logout control; two new env vars (`NEXT_PUBLIC_USER_SERVICE_URL`, `NEXT_PUBLIC_WORKFLOW_API_URL`). |
| `workspace-github-adapter` | **No change** — `workspace_id` partitioning preserved. |

## Validation and Release Impact

**Testing expectations:**

- **user-service unit:** OAuth state generation/verification; session resolver;
  AccessibleWorkspaceIDs derivation across account + per-workspace membership
  shapes; invitation acceptance atomicity.
- **user-service integration:** full OAuth callback against a mocked IdP;
  `/internal/sessions/validate` with valid/invalid/expired sessions and missing
  service tokens.
- **workflow-backend integration:** `RequireAuth` middleware applied to a sample
  workspace endpoint; service-client retry/timeout behaviour; cache TTL behaviour
  under churn.
- **Cross-service E2E (docker-compose):** boot both services + both DBs; full
  login flow → land on workspace → see scoped data → logout. Repeat with two
  test accounts to verify isolation (404, not 403, on cross-account access).
- **Frontend:** login flow against the real user-service; protected route
  redirect; logout; account-with-multiple-workspaces UX.

**Migration / config:**

- `user_db` is a brand-new database — clean schema install via `pressly/goose/v3`
  (same tool used by `workflow-backend`).
- `workflow_db` schema gains `workspaces.account_id`. Migration sequence:
  1. Add column as nullable.
  2. Run the seed cmd (creates Kitelabs account in user_db, backfills
     `workflow_db.workspaces.account_id` to that account's UUID).
  3. Apply NOT NULL constraint in a follow-up migration.

  No production client data exists yet, so risk is bounded.
- New env vars (listed above) must be set before deploy. Backends must fail fast
  on missing OAuth client IDs/secrets and `USER_SERVICE_TOKEN`.

**Rollout:**

- Dev first; verify with two test Google accounts + one GitHub account on
  docker-compose.
- Promote when E2E suite is green and P1–P4 are provisioned for the target
  environment.
- No staging environment in this workspace (`workspace.yaml -> staging: enabled:
  false`).

**Backward compatibility:**

- workflow-backend's existing API surface gains an auth gate. Internal callers
  (manual curl, scripted dashboards) must include a session cookie or be migrated
  to authenticated service tokens later — documented as known follow-up.
- The GitHub adapter is unaffected.

**Handoff implications:**

- `m1-client-delivery-visibility` can begin once T2b and T3 merge — its read
  endpoints sit behind `RequireAuth`.
- M2 (Hermes agent) and M3 (Thread) consume `user-service` from day one — no
  rework required.
- M6 (enterprise SSO / SCIM) will replace federated-only login with SAML/OIDC
  IdPs; the data model added here is compatible (`auth_identities` just gain new
  provider values).
- `USER_SERVICE_TOKEN` rotation and mTLS hardening are M6 concerns.
