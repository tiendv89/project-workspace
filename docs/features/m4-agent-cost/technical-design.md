# Technical Design

## Feature
- Feature ID: `m4-agent-cost`
- Title: Agent Cost Tracking — Credits, Billing Plans, and Quota

---

## 1. Current State

Four existing repos are involved — no new repo is introduced.

**`user-service`** (Go 1.25 · Gin · pgx · Goose migrations).
- Tables today (`migrations/00001_initial_identity_schema.sql`): `users`, `auth_identities`, `organizations`, `memberships` (`user_id`, `organization_id`, `role` — `role='admin'` is the existing admin concept), `workspace_memberships` (`user_id`, `workspace_id`, **no FK** — workspaces live in `workflow_db`), `organization_invitations`, `sessions`.
- Layering: handler → service → store. Stores satisfy a `DBTX` interface (`*pgxpool.Pool` or `pgx.Tx`); services run serializable transactions (`withSerializableTx`).
- Routing (`internal/handler/router.go`): `RegisterPublic` (`/api/*`, guarded by `RequireBFFIdentity` reading `X-User-Id`), `RegisterInternal` (`/internal/*`, guarded by `serviceauth.RequireServiceToken`), org-admin routes guarded by `RequireOrgAdminAuth` (checks `memberships.role='admin'` for a path org).
- Migrations: SQL files under `migrations/`, run on startup when `db.auto_migration: true`. Seed via `cmd seed`. Tests: `make test` (`go test ./... -race`), `make lint` (`golangci-lint`).

**`workflow-bff`** (Go 1.25 · Gin · Redis sessions).
- Transparent reverse-proxy: `/bff/<service>/...` → `<service>/...` with identity headers injected (`X-User-Id`, `X-Org-Id`, `X-Accessible-Org-Ids`, `Authorization: Bearer <internalToken>`) — `proxy_handler.go:146`.
- Hand-written typed clients in `internal/pkg/serviceclient/userservice` and `.../workflowbackend` (std `net/http`, bearer token). Downstream URLs in config (`user_service.internal_url`).
- SSE responses are streamed through unbuffered (`proxy_handler.go:171`). WebSocket returns 501.
- Owns the session: `currentUser(c)` resolves `user_id` from the session cookie (`sessions_handler.go:23`). Tests: `make test`, `make lint`.

**`hermes-agent`** (Python · FastAPI · Anthropic SDK).
- Turn lifecycle in `src/api/agent_dispatch.py`: `schedule_agent_turn()` → `_run_agent_turn()` (worker thread). Context (`session_id`, `user_id`, `workspace_id`, `feature_id`) is set at `agent_dispatch.py:260`; the Claude call happens inside the vendored `conversation_loop.py:1147`.
- Usage block is normalized at `conversation_loop.py:1810-1854` (`input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`) from the Anthropic SDK `Message`.
- Stop (`src/api/routers/threads.py:133`, handler in `agent_dispatch.py:169`): `agent.interrupt()` aborts the in-flight call; `mark_stopped()` returns partial text but **suppresses the final usage frame** — so the SDK usage object is never retrieved on a stopped turn.
- Existing outbound pattern: `src/services/user_service_client.py` (aiohttp). Messages posted to the thread via `src/db/store.py:277` `append_message()` (no Claude call).
- Tests: `pytest`, `make lint` (ruff).

**`digital-factory-ui`** (Next.js 16 · React 19 · HeroUI v3 · Tailwind v4 · React Query · SSE).
- Chat in `src/components/agent-chat/` (`message.tsx`, `message-thread.tsx`, `agent-chat-panel.tsx`). The SSE stream **already carries `usage` events** (`services/hermes-agent/chat.ts`, `{type:"usage", inputTokens, outputTokens, cachedTokens}`).
- Settings tabs in `src/components/settings/settings-page.tsx` (a `TABS` array). API via axios clients to the BFF (`constants/axios.ts`: `userServiceApi = createBffClient("/bff/user-service")`). Auth user via `session-context.tsx`. Design tokens (`success`/`warning`/`danger`) in `globals.css`. Tests: `npm run test` (Vitest), `npm run lint`, `npm run type-check`.
- **Admin tree already exists**: `src/app/admin/` has a layout guard checking the `platform_admin` (and `admin`) role in the user's memberships, hosting `/admin/connect` and `/admin/members` (added by `m1-admin-panel`). New admin pages drop into this same tree under the same guard — no new app, no new auth model.

### Current limitations
- The Claude `usage` block is discarded in `hermes-agent`; no cost is stored or surfaced anywhere.
- No billing-plan / pricing / quota tables exist; every user is implicitly uncapped.
- No admin surface for plan management — the `/admin/` tree exists but has no Plans/Users/Orgs pages.

---

## 2. Problem Framing

### What must change
1. **`user-service`** becomes the system of record: billing/quota tables (`billing_plan`, `org_plan_assignment`, `model_pricing`, `credit_config`, `turn_cost`, `user_usage_quota`) plus 2 platform-role tables (`platform_role`, `platform_role_assignment`), a plan-resolution function, lazy quota reset, internal cost/quota APIs, admin plan-management APIs, a `RequirePlatformRole` guard, and exposure of the caller's platform roles in the identity payload. *(As-built: plans are org-only — `user_plan_assignment` was dropped; see §9.)*
2. **`hermes-agent`** gains a **pre-turn quota guard** (reject before any tokens are spent) and **post-turn cost emission**, including a partial count for stopped turns.
3. **`workflow-bff`** exposes the cost/quota API surface the UI and hermes use, proxying to `user-service`.
4. **`digital-factory-ui`** shows per-message credit badges, a session header credit/quota indicator, a Settings → Usage page, **and the plan/assignment admin pages under the existing `/admin/` tree** (Plans/Users/Orgs).

### What must remain stable
- `turn_cost` is append-only (G7) — never mutated after insert.
- USD never reaches any UI (NG2) — credits only.
- `workflow-bff` owns **no** cost/quota tables — all storage is in `user-service`.
- Existing chat behaviour is unchanged when a user is under quota.

### Fixed assumptions (from product spec)
- Admin-assigned plans only — no self-serve payment (NG1). Plan caps are DB data, admin-editable, never env-driven.
- Schema is runtime-ready (`source_type`, `source_label`, nullable `task_id`) but **no** agent-runtime wiring in this feature (NG7).
- No retroactive backfill (NG6); records start at deploy.

---

## 3. Options Considered

### Decision A — `workflow-bff`: transparent proxy vs. explicit owned handlers

**A1 — Proxy through the existing `/bff/user-service/*` prefix.** Zero new BFF code; the UI/hermes hit user-service paths directly through the generic proxy.
- Pros: no BFF work.
- Cons: the spec defines BFF-scoped paths (`POST /sessions/:id/turn-costs`, `GET /users/me/quota`) that don't map 1:1 to user-service internal paths; `users/me` needs the session identity the BFF holds; leaks user-service's internal path shape to clients.

**A2 — Explicit thin BFF handlers using the `userservice` service client (chosen).** Small owned handlers that resolve identity/session and call user-service `/internal/*`.
- Pros: matches the spec's API contract; `users/me` resolves from the BFF session; keeps user-service internal endpoints service-only (not publicly proxied); BFF still owns no tables.
- Cons: a handful of new handlers + client methods.

**Chosen: A2.** It honours the published contract and keeps the internal API private, at the cost of a few thin handlers — consistent with the existing `serviceclient` pattern.

### Decision B — Stopped-turn token accounting (the key constraint)

On a stop, `hermes-agent` interrupts the SDK call and the final usage frame is suppressed (`conversation_loop` / `mark_stopped`), so the SDK `usage` object is unavailable (G1 still requires "tokens consumed up to cancellation").

**B1 — Accumulate usage incrementally from the stream (chosen).** Maintain a running token tally as streaming deltas arrive (input tokens are known at request build; output tokens accrue per delta). On stop, emit the accumulated partial with `stopped: true`.
- Pros: satisfies G1 precisely; no estimation; reuses the streaming path the SSE translator already taps.
- Cons: requires hooking the stream loop / translator to keep a tally; the partial may slightly differ from a server-final count (acceptable — it is a stopped turn).

**B2 — Estimate from partial text length.** Pros: trivial. Cons: inaccurate; not real token counts.

**B3 — Record zero on stop.** Pros: simplest. Cons: violates G1 and undercounts spend.

**Chosen: B1.** This is the feature's main technical risk and is called out in §5/§8. A completed (non-stopped) turn uses the exact normalized `usage` block; only stopped turns rely on the running tally.

### Decision C — Quota reset: lazy vs scheduled

**C1 — Lazy reset at check/increment time (chosen).** On each quota check or increment, if `now >= daily_reset_at` (or weekly), zero that counter and advance the reset timestamp before applying the cap.
- Pros: no scheduler/cron infra; correct per user; matches the spec's "applies lazy reset if needed".
- Cons: a user who never sends a turn keeps a stale `updated_at` until their next check (harmless — caps are read live from `billing_plan`).

**C2 — Scheduled cron resets all rows.** Pros: counters always fresh. Cons: new infra; mass write at midnight; redundant given caps are read live.

**Chosen: C1.**

### Decision D — Org context for plan resolution (multi-org users)

Plan resolution is individual → org → `free`. A user may belong to multiple orgs (`memberships` is many-to-many), and the org row lives in `user-service` while workspace→org lives in `workflow_db`.

**D1 — Resolve org from the user's membership, disambiguated by the request's active org (chosen).** The quota check accepts an optional org context: the BFF forwards `X-Org-Id` (the session's current org) on UI-originated checks; for hermes-originated checks the active org is derived from the turn's workspace where available, else the user's sole membership. If the resolved org has no plan, fall through to `free`.
- Pros: unambiguous for single-org users (the common case); honours the user's current org for multi-org; no cross-DB join required in the hot path.
- Cons: the multi-org-from-hermes path needs the org passed through; documented as an explicit contract.

**D2 — First/primary membership only.** Pros: simplest. Cons: wrong plan for multi-org users on a non-primary org.

**Chosen: D1**, with the org-context contract documented in §5. Single-org users (current reality) are unaffected either way.

### Decision E — Where the admin plan UI lives

**E1 — New standalone admin app (rejected).** A separate Next.js repo, deployed independently, mirroring `digital-factory-ui`'s stack and auth.
- Pros: clean separation of admin from product surface.
- Cons: a whole new repo to register, build, deploy, and maintain; duplicates the auth/session/`session-context` integration and the `/admin/` layout guard that *already exist* in `digital-factory-ui`; slower to ship; two frontends to keep in design-system sync.

**E2 — Pages inside `digital-factory-ui`'s existing `/admin/` tree (chosen).** Add Plans/Users/Orgs pages under `src/app/admin/` (`/admin/plans`, `/admin/users`, `/admin/orgs`), reusing the existing admin layout guard that already gates `/admin/members` (`m1-admin-panel`).
- Pros: zero new repo/deploy/auth; reuses the exact `platform_admin`/`admin` guard, `session-context`, BFF axios clients, and HeroUI design system already present; consistent with how `m1-admin-panel` added admin membership management; fastest path.
- Cons: admin and product surfaces share one deployment (acceptable — the layout guard already isolates `/admin/*` access; this is the established pattern).

**Chosen: E2.** No new repo. This supersedes the product spec's earlier "standalone admin app" framing — admin plan management is folded into `digital-factory-ui`'s existing `/admin/` tree, eliminating the previously-open repo-registration dependency (former D1).

### Decision F — Admin authorization model (resolves D1)

Billing-plan management is **platform-global** (mint a `Pro` plan; assign `Team` to any org), but today's only admin primitive is the **org-scoped** `memberships.role` string (`'admin'` checked by `RequireOrgAdminAuth`; `'platform_admin'` checked by the UI `/admin/` layout guard). Hanging a platform capability off a per-org membership row is a scope mismatch. The product owner also requires headroom for **more internal roles** later (e.g. billing ops, support), not just a single admin flag.

**F1 — Reuse `memberships.role='platform_admin'` (rejected).** No new table; the UI guard already checks it. But "platform" scope encoded on an inherently org-scoped row is ambiguous for multi-org users, and it offers no path to additional internal roles without overloading the same string further.

**F2 — Single-purpose `platform_admins(user_id)` table (rejected).** Honest platform scope, but a boolean that would need re-migrating the moment a second internal role appears — which the product owner has explicitly flagged as imminent.

**F3 — Role-general platform-role tables (chosen).** A `platform_role` catalog (seedable role keys + display metadata) and a `platform_role_assignment` join (`user_id` × `role_key`, many-to-many). A `RequirePlatformRole(<key>)` guard checks assignment membership. Capability→role mapping stays in code (M4: plan management requires `platform_admin`); no permission-matrix table yet.
- Pros: platform-scoped and honest; **adding a future internal role is pure data** (insert a `platform_role` row + assignments — no migration), matching this feature's "config is data" philosophy; cleanly separated from org roles.
- Cons: a second source of admin truth alongside `memberships.role` (mitigated by the migration backfilling existing `platform_admin` memberships — see §8); the identity payload must learn to carry `platform_roles`.

**Chosen: F3.** **M4 scope boundary:** ship the two tables + `platform_admin` seed, the `RequirePlatformRole` guard on `/admin/*`, and `platform_roles` in the identity payload — but **no role-management UI and only the one role in use**. Multi-role assignment screens belong to the future internal-team feature. This resolves the formerly-open D1.

---

## 4. Chosen Design

`user-service` is the single system of record for pricing, plans, cost history, and quota. `hermes-agent` is the cost **producer** and quota **enforcer**; `workflow-bff` is the thin API gateway; `digital-factory-ui` is the consumer for both the chat/usage surfaces and the admin plan-management pages (under its existing `/admin/` tree).

### Data flow

```
                 ┌──── pre-turn quota check ────►┐
 hermes-agent ───┤  (reject before Claude call)  ├──► workflow-bff ──► user-service
                 └──── post-turn cost event ─────┘     (thin handlers)   (tables + logic)
                                                                              ▲
 digital-factory-ui (chat/usage) ── GET cost / quota ──► workflow-bff ──────── ┘
 digital-factory-ui (/admin/*)   ── admin plan APIs ───► workflow-bff (/bff/user-service proxy) ─► user-service /admin/*
```

### user-service: storage + logic
- **Tables** exactly as the product-spec Data Model: `billing_plan`, `user_plan_assignment`, `org_plan_assignment`, `model_pricing`, `credit_config`, `turn_cost` (append-only, indices `(user_id, created_at)` and `(source_type, created_at)`), `user_usage_quota` (counters + reset timestamps; **caps not stored** — read live from `billing_plan`), plus the platform-role tables `platform_role` (catalog) and `platform_role_assignment` (`user_id` × `role_key`, many-to-many) (Decision F).
- **Seeds** (initial migration): a `free` `billing_plan` with sensible default caps (admin-editable post-deploy), `model_pricing` rows for current Anthropic models, the single `credit_config` row (`usd_to_credits`), and the `platform_admin` row in `platform_role`. The migration also **backfills** existing `memberships.role='platform_admin'` users into `platform_role_assignment` so current admins keep access (§8).
- **Platform-role guard** (Decision F): `RequirePlatformRole("platform_admin")` middleware checks `platform_role_assignment` for the caller; the identity/`me` payload is extended with `platform_roles: string[]` so the BFF and UI can read it.
- **Plan resolution**: `user_plan_assignment` (not expired) → `org_plan_assignment` for the resolved org (not expired) → `free`.
- **Lazy reset** (Decision C) inside the quota check/increment.
- **Internal API** (`/internal/*`, service-token): `GET /internal/users/:id/quota/check` (resolve plan, lazy reset, return `{allowed, reason?, resets_at?, plan_name, daily_cap, weekly_cap}`), `POST /internal/turn-costs` (compute `cost_usd` from `model_pricing` × tokens, convert to `credits_used` via `credit_config`, insert `turn_cost`, increment `user_usage_quota` in one serializable tx), `GET /internal/users/:id/cost`.
- **Admin API** (`/admin/*`, guarded by `RequirePlatformRole("platform_admin")` — Decision F, not the org-scoped `RequireOrgAdminAuth`): plan CRUD, user/org plan assign/remove, `GET /admin/users/:id/effective-plan` (returns plan + source).

### workflow-bff: thin gateway
- Owned handlers (Decision A2) calling the `userservice` client: `POST /sessions/:id/turn-costs`, `GET /sessions/:id/cost`, `GET /sessions/:id/quota/check`, `GET /users/me/quota` (uses session identity, no `:id`). Admin plan endpoints are served by the **existing generic proxy** (`/bff/user-service/admin/*`) — no new BFF code for admin.

### hermes-agent: producer + enforcer
- **Pre-turn quota guard** at `agent_dispatch.py` after context is set (`:260`) and **before** agent construction (`:328`): call the BFF quota-check; if `allowed:false`, `append_message()` a system message (quota type + reset time) and return — zero tokens spent. Composer stays enabled (no error state).
- **Post-turn cost emission**: on completion, read the normalized `usage` block (`conversation_loop.py:1810`) and POST a cost event to the BFF. On stop, emit the **accumulated partial** (Decision B1) with `stopped:true`.

### digital-factory-ui (chat/usage + admin pages)
- Chat: per-message credit `Badge` (reuse `common/badge.tsx`), session header credit/quota indicator fed by `GET /sessions/:id/cost` plus the SSE `usage` events already in the stream. Settings → **Usage** tab (new `TABS` entry + `usage-tab.tsx`): daily/weekly progress bars (neutral→amber≥80%→red 100% via existing tokens), client-side reset countdowns, manual refresh of `GET /users/me/quota`.
- Admin pages under the existing `src/app/admin/` tree — `/admin/plans`, `/admin/users`, `/admin/orgs` — calling the admin API through the BFF (`/bff/user-service/admin/*`). They reuse the existing `/admin/` layout guard, which is updated to read `platform_roles` from the session identity payload and require `platform_admin` (Decision F). No new tree, page shell, or auth integration is added — only the guard's role source changes (it previously read `memberships.role`).

### Affected repositories

| Repo (`workspace.yaml` id) | Role | Change |
|---|---|---|
| `user-service` | system of record | 9 tables + seeds (7 billing/quota + `platform_role`, `platform_role_assignment`); plan resolution; lazy quota; internal cost/quota APIs; admin plan APIs behind `RequirePlatformRole`; `platform_roles` in identity payload. |
| `workflow-bff` | gateway | thin owned cost/quota handlers → user-service client; admin via existing proxy; forward `platform_roles` in the session/me payload. |
| `hermes-agent` | producer/enforcer | pre-turn quota guard; post-turn cost emission; stopped-turn partial tally. |
| `digital-factory-ui` | consumer | credit badge, session header indicator, Settings → Usage page, **and Plans/Users/Orgs admin pages under the existing `/admin/` tree**; `/admin/` layout guard reads `platform_roles` from the session. |

### Compatibility & operational implications
- Additive only; no existing schema mutated. `turn_cost` append-only enforced in tests.
- Runtime-ready schema (`source_type`/`source_label`/`task_id`) ships unused (NG7).
- No backfill (NG6); cost history begins at deploy. Caps are live DB data — an admin cap edit takes effect on the next quota check with no migration/redeploy.

---

## 5. Dependency Analysis

**Internal**
- `user-service` schema (T1) is the foundation for everything else.
- Plan resolution + internal APIs (T2) gate the BFF gateway (T4) and the admin APIs (T3, which reuses the resolution for `effective-plan`).
- The BFF cost/quota surface (T4) gates both consumers (hermes T5; UI T6/T7).
- Admin APIs (T3) gate the admin pages (T8). The admin pages live in `digital-factory-ui`'s existing `/admin/` tree, so there is **no scaffold/auth task** — the layout guard and session integration already exist (`m1-admin-panel`); the guard's role *source* changes to `platform_roles` (Decision F).
- The platform-role tables + `platform_admin` seed + `platform_roles` payload exposure are part of the foundation (T1 ships the tables/seed/backfill; the `RequirePlatformRole` guard + payload field land with the admin API in T3). The BFF forwards `platform_roles` (T4 surface / session path); the UI guard consumes it (T8).

**External / blocking decisions**
- **D1 — Admin authorization model. RESOLVED (Decision F):** a role-general platform-role model (`platform_role` + `platform_role_assignment`), platform-scoped and distinct from org-scoped `memberships.role`. M4 ships and uses only `platform_admin`; future internal roles are pure data. No external/human action is outstanding.

**Configuration**
- New env: `WORKFLOW_BFF_URL` in `hermes-agent` (cost/quota calls); user-service `model_pricing`/`credit_config` are seed data, not env.
- Org-context contract: the BFF forwards `X-Org-Id` on UI quota checks; hermes passes the turn's workspace/org where available. Documented contract; single-org users unaffected.

**Unresolved**
- None. D1 is resolved by Decision F; no repo registration is required (admin pages reuse `digital-factory-ui`). All tasks are gated by internal ordering only.

---

## 6. Parallelization / Blocking Analysis

```
D1: Admin authorization model ── RESOLVED (Decision F): platform-role tables; no open action

T1: user-service — migrations + seeds (9 tables: 7 billing/quota + platform_role(+seed)
  │                + platform_role_assignment(+backfill); free plan, pricing, credit_config)
  └── Can begin now — no blockers
  │
  T2: user-service — plan resolution + lazy quota + internal cost/quota APIs
  │     └── BLOCKED on T1 (tables + seeds must exist)
  │
  T3: user-service — admin plan/assignment APIs + RequirePlatformRole guard + platform_roles in payload
  │     └── BLOCKED on T2 (plan resolution reused by effective-plan)
  │     └── BLOCKED on T1 (platform_role tables must exist)
  │
  T4: workflow-bff — thin cost/quota handlers → user-service client
  │     └── BLOCKED on T2 (internal endpoints must exist)
  │     └── T3 and T4 run in parallel (both after T2)
  │     │
  │     T5: hermes-agent — pre-turn quota guard + cost emission + stopped tally
  │     T6: digital-factory-ui — chat credit badge + session header indicator
  │     T7: digital-factory-ui — Settings → Usage page
  │           └── BLOCKED on T4 (BFF cost/quota endpoints must exist)
  │           └── T5, T6, T7 run in parallel (Wave 4)
  │
  T8: digital-factory-ui — admin Plans / Users / Orgs pages under existing `/admin/` tree
        └── BLOCKED on T3 (admin APIs + platform_roles payload must exist via `/bff/user-service/admin/*`)
        └── No scaffold task: the `/admin/` layout + guard already exist (m1-admin-panel);
            the guard is updated to read `platform_roles` from the session (Decision F)
```

**Waves**
- **Wave 1:** T1 (D1 already resolved — Decision F).
- **Wave 2:** T2 (after T1).
- **Wave 3:** T3 and T4 (both after T2).
- **Wave 4:** T5, T6, T7 (after T4) and T8 (after T3) — all parallel.

---

## 7. Repository Impact

| Repo | Why affected | Representative touch points |
|---|---|---|
| `user-service` | System of record for pricing/plans/cost/quota + platform roles. | `migrations/` (new SQL migration + seeds, incl. `platform_role`/`platform_role_assignment` + `platform_admin` seed + backfill of existing `platform_admin` memberships), new `internal/billing` stores + service (mirroring `users.Store`/`organizations.Store`), a `platform_role` store + `RequirePlatformRole` middleware, `internal/handler/router.go` (`RegisterInternal` cost/quota, new admin group behind `RequirePlatformRole`), reuse `RequireServiceToken`; extend the identity/`me` payload with `platform_roles`. |
| `workflow-bff` | Thin cost/quota gateway. | `internal/pkg/serviceclient/userservice/client.go` (new methods), new handler group under `internal/app/api/handler/`, route registration in `internal/app/api/server/server.go`; surface `platform_roles` on the session/me payload. Admin via existing proxy upstream. |
| `hermes-agent` | Cost producer + quota enforcer. | `src/api/agent_dispatch.py` (quota guard ~`:260`, cost emission post-turn), vendored `conversation_loop.py` stream tally for stopped turns, new BFF client (extend `src/services/user_service_client.py` pattern), `src/db/store.py:append_message` for the block message. |
| `digital-factory-ui` | Chat cost display + Usage page + admin plan pages. | Chat/usage: `src/components/agent-chat/message.tsx` (badge), new session-header component in `agent-chat-panel.tsx`, `src/components/settings/settings-page.tsx` (+`usage-tab.tsx`), new hook under `src/hooks/settings/`, `services/*` client method. Admin: new pages under `src/app/admin/` (`plans/`, `users/`, `orgs/`) reusing the existing admin layout guard, new React Query hooks + `services/*` methods hitting `/bff/user-service/admin/*`. |

All affected repo ids already exist in `workspace.yaml` — no new repo is registered.

---

## 8. Validation and Release Impact

**Testing expectations**
- **Quota guard (G8):** with an exhausted daily/weekly quota, hermes rejects the turn before any Claude call (assert zero tokens, system message posted, composer enabled). Same for weekly.
- **Append-only ledger (G7):** `turn_cost` rows are never updated after insert (assert in user-service tests).
- **Credit math:** `cost_usd` = Σ(tokens × `model_pricing`), `credits_used` = `cost_usd` × `usd_to_credits`; verified against seeded pricing.
- **Plan resolution:** individual > org > free; multi-org disambiguation by org context (Decision D1); org member without individual plan inherits org caps; member with individual plan unaffected.
- **Lazy reset:** daily counter resets at midnight UTC, weekly Monday midnight UTC, computed at check time.
- **Stopped-turn cost (B1):** a stopped turn emits `stopped:true` with the accumulated partial token count (> 0, ≤ a comparable full turn).
- **No USD in UI (NG2):** UI/admin snapshot tests assert credits only.
- **Admin flows:** create plan, assign to user, assign to org, view effective plan + source.
- **Platform-role guard (Decision F):** `/admin/*` rejects a caller without `platform_admin` (assert 403 for a plain user and for an org-scoped `memberships.role='admin'` user); accepts a `platform_role_assignment` holder. Migration backfill: an existing `memberships.role='platform_admin'` user holds the role after migrate (assert access preserved). Identity payload includes `platform_roles`.
- Each repo's full suite + lint + type-check must pass before its PR (per workspace rules).

**Migration / config impact**
- One additive user-service migration: 9 tables + indices + seeds (7 billing/quota + `platform_role`/`platform_role_assignment`, seeding `platform_admin` and backfilling existing `platform_admin` memberships). New env `WORKFLOW_BFF_URL` in hermes. No new repo or `workspace.yaml` entry — admin pages ship inside `digital-factory-ui`.

**Rollout concerns**
- Order: user-service (T1→T2→T3) → workflow-bff (T4) → consumers (T5/T6/T7) and admin pages (T8, after T3). The quota guard (T5) should ship only after the BFF + user-service quota path is live, else checks would fail open/closed unexpectedly — until T5 ships, behaviour is unchanged (no guard).
- Stopped-turn tally (B1) is the main implementation risk; if the partial count proves unreliable it degrades to a conservative estimate without blocking the feature.

**Backward compatibility**
- Schema is additive; no existing table mutated. Chat behaviour unchanged for under-quota users. Runtime schema fields ship dormant (NG7).
- **Admin guard role source moves** from `memberships.role` to `platform_roles` (Decision F). The T1 migration backfills existing `memberships.role='platform_admin'` users into `platform_role_assignment`, so current admins (and the existing `/admin/connect`, `/admin/members` pages) keep access with no manual step. Org-scoped `RequireOrgAdminAuth` (m1 membership management) is untouched — only the billing `/admin/*` group uses `RequirePlatformRole`.

**Deployment / handoff**
- Admin plan pages ship as part of the normal `digital-factory-ui` deployment, gated by the existing `/admin/` layout guard — no separate app or deployment, and no new identity integration.

---

## 9. As-Built (implementation notes)

The feature shipped with several deliberate changes from the design above. Where this section conflicts with §1–§8, **this section is authoritative**.

### 9.1 Plans are org-only (no individual plans)
`user_plan_assignment` was **removed entirely** (table, store, service methods, admin `POST/DELETE /admin/users/:id/plan`, and the per-user plan UI). A user's plan resolves **org plan → free**; there is no individual tier. `ResolvePlan(userID, orgID)` only consults `org_plan_assignment` then falls back to `free`. Decision D's individual→org→free is reduced to org→free; Decision F (platform roles) is unchanged. The admin **Users** page is a read-only list (plans are managed per org); the **Orgs** page assigns plans.

### 9.2 Usage is tracked per (user, org)
`user_usage_quota` is keyed by **`(user_id, org_id)`** (unique), with `org_id` a real FK to `organizations(id) ON DELETE CASCADE`. Each org the user belongs to has its own daily/weekly counters. `org_plan_assignment.org_id` is likewise an FK with cascade. Lazy reset (Decision C) is unchanged. Caps `0` = unlimited.

### 9.3 No BFF cost handlers — browser uses one endpoint; hermes goes direct
Decision A2 was **reversed**. The BFF owns **no** cost/quota handlers:
- **Browser/UI** calls **`GET /api/me/usage`** (optional `?org=<id>`) on user-service, reached through the **generic `/bff/user-service/*` proxy** (which injects identity); served by `handler.MeUsage` behind `RequireBFFIdentity`. Response: `{sections:[{org_id, org_slug, org_name, role, plan_name, plan_display_name, daily/weekly used+cap+reset}]}`. The Usage page renders **only the active org** (matched on the org switcher's `selectedOrgSlug`). `/api/me/quota` and `/api/me/cost` were **removed**; the per-message credit badge and the session-cost header were **removed**.
- **hermes-agent** calls user-service **`/internal/*` directly** (`GET /internal/users/:id/quota/check?org_id=`, `POST /internal/turn-costs`) via `src/services/cost_client.py` (renamed from `bff_client.py`) using **`USER_SERVICE_URL` / `USER_SERVICE_TOKEN`** — **not** `WORKFLOW_BFF_URL`, and not through the BFF. org_id is threaded from the request identity (`X-Org-Id`) through `schedule_agent_turn → _run_agent_turn → check_quota/emit_turn_cost`.

### 9.4 Credit math + pricing
`credits_used = cost_usd × credit_config.usd_to_credits`, with `usd_to_credits = 10000` (1 credit = $0.0001). `model_pricing` rates are the provider **list price + ~5%** margin (billing rate, not raw cost), seeded for the ids `hermes/model_catalog.py` emits: `claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5`, `deepseek-v4-flash`, `deepseek-v4-pro`. **`turn_cost` has no FK to `model_pricing`** — a turn for an unpriced model still records (cost 0, logged for backfill) instead of failing.

### 9.5 hermes session ids are UUIDs
hermes migration `005_session_id_uuid.sql` converted `sessions.id` (+ FK columns) from `"sess_<hex>"` TEXT to native **UUID** (legacy rows cleared), so the id is valid for user-service's UUID-typed `turn_cost.session_id`. `_new_session_id()` returns `str(uuid4())`; ORM uses `UUID(as_uuid=False)` so Python still sees strings. (The two hermes store modules `store.py`/`store_v4.py` were also merged into one `store.py`.)

### 9.6 Platform-admin bootstrap + session roles
- First admins are bootstrapped from config: `platform_admin.emails` (env `PLATFORM_ADMIN_EMAILS`) grants `platform_admin` on **startup** (for existing users) and **on login** (for OAuth-created users), self-granted.
- `UpsertIdentity` now returns **`platform_roles`** so the BFF caches them in the session (`session.PlatformRoles`); the BFF/admin guards and the platform-admin org-delete read this. (Users must re-login after being promoted for their session to carry the role.)

### 9.7 Org deletion cascade (workspaces + agent chat) — BFF-orchestrated
Deleting an org cascades across all three services, orchestrated by the **BFF** (workflow-backend and user-service stay unaware of hermes):
1. BFF → workflow-backend `DELETE /internal/workspaces?organization_id=` → deletes the org's workspaces (features/tasks cascade in its DB) and **returns the deleted workspace IDs**.
2. BFF → hermes `DELETE /api/v1/internal/workspaces/{id}/sessions` (service-token) per workspace → deletes **all** that workspace's agent chat (all users + channels). Best-effort; never blocks the delete.
3. BFF forwards the org delete to user-service (members/invitations/plan/quota cascade in its DB).

Two entry points: **self-serve** `DELETE /bff/user-service/api/orgs/:id` (`orgHandler.Delete`) and **platform-admin** `DELETE /bff/user-service/admin/orgs/:id` (`orgHandler.AdminDelete`, which verifies `platform_admin` from the session **before** any destructive action; user-service re-checks live). New config: `hermes_agent.internal_url` on the **BFF** (empty disables chat cleanup).

### 9.8 Admin pages live in the shell
The `/admin/*` pages moved under the `(shell)` route group, inheriting the topbar (breadcrumb + search + avatar) and the left nav rail (which gained a platform-admin-only **Admin** icon above Settings). Pages: Plans, Users (read-only), Orgs.

---

> **Phase 1 (Design) complete.** Task breakdown (`tasks.md` + `tasks/T<n>.yaml`) is produced in Phase 2, after this design is approved.
