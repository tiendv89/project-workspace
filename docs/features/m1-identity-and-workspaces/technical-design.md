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
- `workflow-backend` — owns all server-side identity, session, and scoping logic.
- `digital-factory-ui` — owns login UI, session-aware routing, and account/workspace UX.
- `management-repo` (this repo) — owns `database/schema.dbml` and version folders.
- `workspace-github-adapter` — unaffected. Its `workspace_id`-scoped writes continue to
  work; it does not need an authenticated user.

## Problem Framing

**What must change:**

1. Introduce an identity spine: `users`, `auth_identities` (Google/GitHub), `accounts`,
   `memberships`, `workspace_memberships`, `account_invitations`, `sessions`.
2. Add `account_id` to `workspaces` so every workspace is owned by exactly one account.
3. Add server-side OAuth flows for **Google** and **GitHub** in `workflow-backend`.
4. Add a session/cookie layer (library-handled — not a custom auth system).
5. Add a scoping middleware: every workspace-scoped read endpoint must filter by the
   logged-in user's accessible workspaces.
6. Add login UI + session-aware layout in `digital-factory-ui`.
7. Seed an internal "Kitelabs" account and migrate existing workspaces onto it so
   nothing breaks for the delivery team.

**What must stay stable:**

- The `workspace_id`-scoped read API surface — the sibling feature
  `m1-client-delivery-visibility` consumes these endpoints once they're auth-gated.
- The GitHub adapter's write path — no changes needed; it writes by `workspace_id`,
  which is preserved.
- All existing core table columns and indexes — additions only, no destructive change.

**Fixed assumptions:**

- Self-hosted identity in the Go backend (no managed provider like Auth0 / Clerk /
  Supabase Auth). We consume Google and GitHub as IdPs only.
- B2B services model — clients are invited; no self-serve account creation in M1.
- Read-only client surface (per sibling feature) — no client mutations in M1.

## Options Considered

### Option 1 — Session storage layer

**Option 1A: Server-side sessions in Postgres (opaque cookie)**
- Library: `alexedwards/scs/v2` with `scs/postgresstore`.
- Pros:
  - Trivial to invalidate (delete the row); supports logout-everywhere.
  - Cookie is opaque and small.
  - Active maintenance, idiomatic Go, postgres-native store (no new infra).
- Cons:
  - One DB read per authenticated request (mitigatable with in-memory cache later).

**Option 1B: Stateless JWT in cookie**
- Pros:
  - No DB read on every request.
- Cons:
  - Hard to invalidate (need a deny-list = state anyway).
  - Larger cookie; key rotation is non-trivial.
  - We don't need stateless scaling at M1 traffic; this is premature optimization.

**Selected: 1A.** Postgres-backed sessions are the simplest correct choice and match
the "library-handled glue, not an auth system" framing in the spec.

### Option 2 — OAuth client architecture

**Option 2A: Server-side Authorization Code flow (backend handles callback)**
- Frontend redirects to backend `/auth/<provider>/start`; backend redirects to IdP;
  IdP redirects back to backend `/auth/<provider>/callback`; backend exchanges code for
  token, fetches user info, creates/links `user` + `auth_identity`, sets session cookie,
  redirects to the frontend.
- Pros:
  - Client secret never leaves the server.
  - Cookie set as `HttpOnly Secure SameSite=Lax` by the backend on its own domain.
  - Single cookie domain story; no token shuttling between FE and BE.
- Cons:
  - Backend must host two routes per provider; frontend cannot host OAuth callbacks.

**Option 2B: Frontend handles OAuth, exchanges with backend afterward**
- Pros: SPA-friendly callback in Next.js.
- Cons: Client secret either lives in Next.js server runtime (extra surface) or in a
  serverless function — additional moving parts. Cookie domain coordination becomes
  more awkward.

**Selected: 2A.** Standard, secure, and matches a single-domain deployment.

### Option 3 — Account linking across providers

**Option 3A: First-login creates user; subsequent same-provider login matches by
`(provider, provider_sub)`; cross-provider linking only when a logged-in user adds
the second provider.**
- Pros: No automatic merge by email — avoids the GitHub-unverified-email pitfall.
- Cons: A user who logs in with Google then later with GitHub (logged out) gets two
  separate `user` rows. Manual merge is a future feature.

**Option 3B: Auto-link by verified email**
- Pros: Single user identity across providers without manual linking.
- Cons: GitHub's primary email may not always be verified or may differ from the user's
  Google email. False merges (or false non-merges) are easy.

**Selected: 3A for M1.** Conservative and reversible. We can layer email-verified
auto-linking in M3+ if it becomes a real client complaint.

### Option 4 — Per-workspace scoping model

**Option 4A: Account membership + optional per-workspace overrides**
- `memberships(user_id, account_id, role)` grants account-wide access (all workspaces
  in that account).
- `workspace_memberships(user_id, workspace_id)` is **opt-in scoping** — if a user has
  **any** rows in `workspace_memberships` for the account, they are limited to those
  workspaces. Otherwise account membership grants access to everything in the account.
- Pros:
  - Default behaviour is the common case (small account, one workspace).
  - Larger accounts (multiple engagements, multiple client teams) can scope members.
  - Two-table model is clear to query.

**Option 4B: Per-workspace membership only (no account-wide grants)**
- Every user has explicit rows for every workspace they can see.
- Pros: Single rule for scoping; no fallback logic.
- Cons: Provisioning overhead — every new workspace requires inserting N rows per
  account member.

**Selected: 4A.** Matches the product spec phrasing ("`user_id` ↔ `account_id` ↔
role; per-workspace scoping") and keeps the common case ergonomic.

### Option 5 — Account provisioning model for M1

**Option 5A: Invitation-only**
- An internal `platform_admin` provisions accounts + workspaces + invitations.
- New client logs in → backend matches a pending invitation by verified provider email
  → consumes it, creates `membership` (and optional `workspace_memberships`).
- No invitation match → user lands on an empty state ("contact your delivery team").
- Pros: Matches B2B services model; no self-serve risk; aligns with "no client actions
  in M1".

**Option 5B: Self-serve account creation**
- Any logged-in user can create an account and become its admin.
- Pros: Faster onboarding for prospects.
- Cons: Out of scope for M1 (we sell by hand); creates spam/identity-squatting risk.

**Selected: 5A.**

## Chosen Design

### Identity tables (additions to `database/schema.dbml` v002)

```text
users(
  id uuid pk,
  email text not null,            -- last-known primary email; not unique (linked accounts can share)
  display_name text,
  avatar_url text,
  created_at, updated_at
)
indexes: lower(email)

auth_identities(
  id uuid pk,
  user_id uuid -> users.id not null,
  provider text not null,         -- 'google' | 'github'
  provider_sub text not null,     -- the IdP's stable user id
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
  workspace_id uuid -> workspaces.id not null,
  created_at
)
indexes: (user_id, workspace_id) unique, workspace_id
-- presence of any row here for (user, account) scopes the user to those workspaces only

account_invitations(
  id uuid pk,
  account_id uuid -> accounts.id not null,
  email text not null,            -- matched against verified provider email at first login
  role text not null,
  invited_by_user_id uuid -> users.id,
  workspace_ids jsonb,            -- null = all workspaces in the account
  created_at, expires_at, accepted_at, accepted_by_user_id uuid -> users.id
)
indexes: (account_id, lower(email)), expires_at

sessions(
  -- managed by scs/postgresstore — schema dictated by the library
  -- recorded here so it appears in the canonical schema doc
)
```

### Modifications to existing tables

```text
workspaces
  + account_id uuid -> accounts.id not null   -- backfilled to internal Kitelabs account
  + index on account_id
```

No other core tables change. `workspace_id` continues to be the universal partition key
and remains untouched.

### Roles (M1)

Two preset roles, encoded as a string column:

- `platform_admin` — Kitelabs internal team. Full access to all accounts and
  workspaces. Created by seeding.
- `client_member` — invited client user. Read-only at the application layer (the M1
  surface has no write endpoints; the role exists so M2+ can layer permissions).

Custom roles are out of scope (M6).

### OAuth + session flow (Go backend)

Libraries:
- `golang.org/x/oauth2` + Google and GitHub endpoint configs.
- `alexedwards/scs/v2` + `scs/postgresstore`.

Routes added to `workflow-backend`:

| Method | Path | Purpose |
|---|---|---|
| GET | `/auth/<provider>/start` | Generates per-flow `state`, stores in temp cookie, redirects to IdP authorize URL |
| GET | `/auth/<provider>/callback` | Verifies `state`, exchanges code, fetches user info, upserts `user` + `auth_identity`, consumes any matching `account_invitation`, sets session cookie, redirects to FE |
| POST | `/auth/logout` | Destroys session, clears cookie |
| GET | `/api/me` | Returns `{ user, memberships, accessible_workspace_ids }` for the current session; 401 otherwise |

Cookie attributes: `HttpOnly`, `Secure`, `SameSite=Lax`, 30-day rolling. CSRF on
mutating endpoints uses a double-submit token derived from the session (out of M1
scope beyond `/auth/logout`).

### Scoping middleware

A single `RequireAuth` middleware:

1. Loads session via scs.
2. Resolves `user_id`; on miss returns 401.
3. Lazily resolves accessible workspace IDs for the user (cached per-request):
   - For each membership, list workspaces in that account.
   - If any `workspace_memberships` rows exist for that user **in that account**,
     intersect down to just those workspace IDs.
4. Attaches `AuthCtx{UserID, AccessibleWorkspaceIDs[]}` to the request context.

Every existing workspace-scoped read handler is updated to filter by
`AccessibleWorkspaceIDs`. The handler signature does not change; the filter is added
at the query layer.

### Frontend (`digital-factory-ui`)

- New `/login` page: two buttons — "Sign in with Google", "Sign in with GitHub".
  Both link to `/auth/<provider>/start` on the backend.
- Session-aware root layout: on mount, fetch `/api/me`; on 401, redirect to `/login`.
- Account / workspace context resolved from `/api/me` response.
- Logout control in the header → `POST /auth/logout`.
- No callback page on the frontend — the backend redirect lands directly on the home
  route after the cookie is set.

### Account seeding & data migration

A one-time seed (in v002 migration or a one-shot Go cmd) creates:

- `accounts(slug='kitelabs', name='Kitelabs')` — the internal account.
- Backfills all existing `workspaces.account_id` to the Kitelabs account.
- Provisions `platform_admin` memberships for the Kitelabs delivery team via an env-
  driven email list (`PLATFORM_ADMIN_EMAILS=alice@kitelabs.dev,bob@…`). On first login
  these emails auto-promote to `platform_admin`.

### Configuration (env)

New env values required for the backend:

| Var | Purpose |
|---|---|
| `OAUTH_GOOGLE_CLIENT_ID`, `OAUTH_GOOGLE_CLIENT_SECRET` | Google OAuth app |
| `OAUTH_GITHUB_CLIENT_ID`, `OAUTH_GITHUB_CLIENT_SECRET` | GitHub OAuth app |
| `OAUTH_REDIRECT_BASE_URL` | Public URL of backend (used to build callback URLs) |
| `SESSION_COOKIE_DOMAIN` | e.g. `.app.kitelabs.dev` for prod; `localhost` for dev |
| `PLATFORM_ADMIN_EMAILS` | Comma-separated emails auto-granted `platform_admin` on first login |
| `FRONTEND_BASE_URL` | Used for post-login redirect |

## Dependency Analysis

**Internal:**
- Database schema lives in `management-repo` at `database/schema.dbml`. Schema bump to
  v002 must be authored here. Migration runner lives in `workflow-backend`.
- The sibling feature `m1-client-delivery-visibility` consumes the scoping middleware
  + `/api/me`. It is **gated on this feature** but does not block any task here.

**External:**
- **Google OAuth client registration** — must be created in the Kitelabs Google Cloud
  project. Callback URL pattern: `<OAUTH_REDIRECT_BASE_URL>/auth/google/callback`.
  Owner: ops / whoever holds GCP admin.
- **GitHub OAuth App registration** — created in the Kitelabs GitHub org. Callback
  URL: `<OAUTH_REDIRECT_BASE_URL>/auth/github/callback`. Owner: GitHub org admin.
- **Deployment URLs locked** — both callback URLs must be known at OAuth-app creation
  time; redirect URI mismatch will block end-to-end testing.

**Unresolved decisions** (must be locked before tasks T2/T3 reach implementation):

- **D1** — Final OAuth scopes:
  - Google: `openid email profile` (sufficient for identity).
  - GitHub: `read:user user:email` (sufficient; **no `repo` scope** — bot work is M6).
  - Lock: confirm scopes with security review.
- **D2** — Final list of `PLATFORM_ADMIN_EMAILS` for first deploy.
- **D3** — Cookie domain for production (e.g. `.app.kitelabs.dev` vs single host).
- **D4** — Migration runner: confirm `workflow-backend` already runs SQL migrations on
  startup (or via a CLI) and which tool (`golang-migrate`, `goose`, or hand-rolled).
  This affects how v002 is packaged.

**Vendor / tooling:**
- Postgres ≥ 14 (already in use).
- Go ≥ 1.22 (already in use).
- Next.js (already in use).
- No new infra (no Redis, no managed identity service).

## Parallelization / Blocking Analysis

External decisions (low-effort; unblock early):

```
D1: OAuth scopes confirmed                ──┐
D2: PLATFORM_ADMIN_EMAILS list            ──┤  all four are config-level; run in parallel
D3: Production cookie domain              ──┤  with task work, must land before T2 ships
D4: Migration tool in workflow-backend    ──┘
```

External provisioning (owner: ops):
- **P1**: Google OAuth client created (callback URL configured)
- **P2**: GitHub OAuth App created (callback URL configured)
- P1/P2 must land before T2 can be end-to-end tested but **do not block writing T2**.

Task graph (proposed — finalised in Phase 2):

```
T1: Schema v002 — add identity tables + workspaces.account_id (management-repo)
  └── Can begin now — no blockers
  │
  T2: workflow-backend — OAuth (Google + GitHub) + session + identity models + /auth/* + /api/me
        └── BLOCKED on T1 (identity tables must exist in schema)
        └── BLOCKED on D1/D4 (scopes + migration tool decided)
        └── Soft-blocked on P1/P2 for E2E test; can be implemented + unit-tested without
        │
        T3: workflow-backend — scoping middleware + workspace queries filtered by AccessibleWorkspaceIDs
              └── BLOCKED on T2 (session + AuthCtx must exist)
              │
              T6: workflow-backend — seed Kitelabs account + backfill workspaces.account_id + PLATFORM_ADMIN_EMAILS auto-grant on first login
                    └── BLOCKED on T2 (auth_identities consume invitations on first login)
                    └── BLOCKED on T3 (no point seeding scoping data before middleware reads it)

T4: digital-factory-ui — /login page + session-aware root layout + /api/me consumer + logout control
  └── Can begin now using a stub /api/me contract (can be developed in parallel with T2)
  └── BLOCKED on T2 for end-to-end test
  │
  T5: digital-factory-ui — account / workspace switcher driven by /api/me memberships
        └── BLOCKED on T4 (layout + session context must exist)
        └── BLOCKED on T2 for end-to-end test
```

Parallelism summary:
- **T1** runs alone first (schema must be frozen).
- **T2** and **T4** run in parallel once T1 lands and the `/api/me` contract is
  agreed; T4 stubs the contract until T2 ships.
- **T3** depends on T2.
- **T5** depends on T4.
- **T6** depends on T2 and T3.

## Repository Impact

| Repo (`workspace.yaml -> repos[].id`) | Change |
|---|---|
| `management-repo` | New `database/v002/changelog.md` + `database/v002/schema.dbml`; updated root `database/schema.dbml`. |
| `workflow-backend` | OAuth handlers, session middleware, identity models, scoping middleware, /api/me, seed/migration cmd, updated query layer. |
| `digital-factory-ui` | Login page, session-aware layout, account/workspace switcher, logout control. |

`workspace-github-adapter` is **not** affected — its writes are keyed by `workspace_id`
which is preserved.

## Validation and Release Impact

**Testing expectations:**

- Unit: OAuth state generation/verification; session resolver; AccessibleWorkspaceIDs
  derivation for combined account + per-workspace membership shapes.
- Integration (Go): full OAuth callback against a mocked IdP; invitation consumption;
  scoping middleware applied to a sample workspace endpoint.
- Frontend: login flow; protected route redirect; logout; account-with-multiple-
  workspaces UX.
- Cross-tenant isolation test: user A in account X gets 404 (not 403, no enumeration)
  when accessing a workspace in account Y.

**Migration / config:**

- Schema v002 is additive except for `workspaces.account_id` (new NOT NULL column).
  Backfill must run inside the migration: insert Kitelabs account first, then update
  all existing `workspaces.account_id`, then add NOT NULL constraint. No production
  client data exists yet, so risk is bounded.
- New env vars (listed above) must be set before deploy. Backend must fail fast on
  missing OAuth client IDs/secrets.

**Rollout:**

- Dev first; verify with two test Google accounts + one GitHub account.
- Promote when E2E suite is green and P1/P2 (OAuth apps) are provisioned for the
  target environment.
- No staging environment in this workspace (`workspace.yaml -> staging: enabled: false`).

**Backward compatibility:**

- The existing dashboard's API surface gains an auth gate. Internal callers (manual
  curl, dashboards) must include a session cookie or be migrated to authenticated
  service tokens later (out of M1 scope; document as known follow-up).
- The GitHub adapter is unaffected.

**Handoff implications:**

- `m1-client-delivery-visibility` can begin once T2 (and ideally T3) merge — its read
  endpoints sit behind the same scoping middleware.
- M2/M3 inherit `users`, `accounts`, `memberships`, `sessions` — they do not need to
  rebuild identity.
- M6 (enterprise SSO / SCIM) will replace federated-only login with SAML/OIDC IdPs;
  the data model added here is compatible (auth_identities just gain new provider
  values).
