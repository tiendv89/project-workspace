# Technical Design

## Feature
- Feature ID: `m4-agent-cost`
- Title: Agent Cost Tracking — Credits, Billing Plans, and Quota

---

## 1. Current State

Five surfaces are involved — four existing repos plus one new repo.

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

**New admin app** — does not exist yet. The spec mandates a **standalone** admin frontend, separate from `digital-factory-ui`, admin-role gated, deployed independently.

### Current limitations
- The Claude `usage` block is discarded in `hermes-agent`; no cost is stored or surfaced anywhere.
- No billing-plan / pricing / quota tables exist; every user is implicitly uncapped.
- No admin surface for plan management.

---

## 2. Problem Framing

### What must change
1. **`user-service`** becomes the system of record: new tables (`billing_plan`, `user_plan_assignment`, `org_plan_assignment`, `model_pricing`, `credit_config`, `turn_cost`, `user_usage_quota`), a plan-resolution function, lazy quota reset, internal cost/quota APIs, and admin plan-management APIs.
2. **`hermes-agent`** gains a **pre-turn quota guard** (reject before any tokens are spent) and **post-turn cost emission**, including a partial count for stopped turns.
3. **`workflow-bff`** exposes the cost/quota API surface the UI and hermes use, proxying to `user-service`.
4. **`digital-factory-ui`** shows per-message credit badges, a session header credit/quota indicator, and a Settings → Usage page.
5. A **new admin app repo** provides plan/assignment management.

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

### Decision E — New admin app stack

**E1 — Mirror `digital-factory-ui` (Next.js 16 + HeroUI v3 + React Query) (chosen).** Reuse the identity/session integration (login via BFF, `session-context`) and component library, adding an admin-role route guard.
- Pros: fastest path; shared auth model and design system; engineers already know the stack.
- Cons: some boilerplate duplication across two frontends (acceptable; they deploy independently).

**E2 — Minimal bespoke stack.** Pros: lean. Cons: re-solves auth/session/build with no reuse.

**Chosen: E1.** New repo proposed id **`admin-ui`** (see Decision D1 dependency in §5).

---

## 4. Chosen Design

`user-service` is the single system of record for pricing, plans, cost history, and quota. `hermes-agent` is the cost **producer** and quota **enforcer**; `workflow-bff` is the thin API gateway; `digital-factory-ui` and the new `admin-ui` are the consumers.

### Data flow

```
                 ┌──── pre-turn quota check ────►┐
 hermes-agent ───┤  (reject before Claude call)  ├──► workflow-bff ──► user-service
                 └──── post-turn cost event ─────┘     (thin handlers)   (tables + logic)
                                                                              ▲
 digital-factory-ui ── GET cost / quota ──► workflow-bff ──────────────────── ┘
 admin-ui ─────────── admin plan APIs ───► workflow-bff (/bff/user-service proxy) ─► user-service /admin/*
```

### user-service: storage + logic
- **Tables** exactly as the product-spec Data Model: `billing_plan`, `user_plan_assignment`, `org_plan_assignment`, `model_pricing`, `credit_config`, `turn_cost` (append-only, indices `(user_id, created_at)` and `(source_type, created_at)`), `user_usage_quota` (counters + reset timestamps; **caps not stored** — read live from `billing_plan`).
- **Seeds** (initial migration): a `free` `billing_plan` with sensible default caps (admin-editable post-deploy), `model_pricing` rows for current Anthropic models, and the single `credit_config` row (`usd_to_credits`).
- **Plan resolution**: `user_plan_assignment` (not expired) → `org_plan_assignment` for the resolved org (not expired) → `free`.
- **Lazy reset** (Decision C) inside the quota check/increment.
- **Internal API** (`/internal/*`, service-token): `GET /internal/users/:id/quota/check` (resolve plan, lazy reset, return `{allowed, reason?, resets_at?, plan_name, daily_cap, weekly_cap}`), `POST /internal/turn-costs` (compute `cost_usd` from `model_pricing` × tokens, convert to `credits_used` via `credit_config`, insert `turn_cost`, increment `user_usage_quota` in one serializable tx), `GET /internal/users/:id/cost`.
- **Admin API** (`/admin/*`, admin-role guard reusing the `m1-admin-panel` admin model): plan CRUD, user/org plan assign/remove, `GET /admin/users/:id/effective-plan` (returns plan + source).

### workflow-bff: thin gateway
- Owned handlers (Decision A2) calling the `userservice` client: `POST /sessions/:id/turn-costs`, `GET /sessions/:id/cost`, `GET /sessions/:id/quota/check`, `GET /users/me/quota` (uses session identity, no `:id`). Admin plan endpoints are served by the **existing generic proxy** (`/bff/user-service/admin/*`) — no new BFF code for admin.

### hermes-agent: producer + enforcer
- **Pre-turn quota guard** at `agent_dispatch.py` after context is set (`:260`) and **before** agent construction (`:328`): call the BFF quota-check; if `allowed:false`, `append_message()` a system message (quota type + reset time) and return — zero tokens spent. Composer stays enabled (no error state).
- **Post-turn cost emission**: on completion, read the normalized `usage` block (`conversation_loop.py:1810`) and POST a cost event to the BFF. On stop, emit the **accumulated partial** (Decision B1) with `stopped:true`.

### digital-factory-ui + admin-ui
- Chat: per-message credit `Badge` (reuse `common/badge.tsx`), session header credit/quota indicator fed by `GET /sessions/:id/cost` plus the SSE `usage` events already in the stream. Settings → **Usage** tab (new `TABS` entry + `usage-tab.tsx`): daily/weekly progress bars (neutral→amber≥80%→red 100% via existing tokens), client-side reset countdowns, manual refresh of `GET /users/me/quota`.
- `admin-ui`: Plans / Users / Orgs pages calling the admin API through the BFF; admin-role guard on every route.

### Affected repositories

| Repo (`workspace.yaml` id) | Role | Change |
|---|---|---|
| `user-service` | system of record | 7 tables + seeds; plan resolution; lazy quota; internal cost/quota APIs; admin plan APIs. |
| `workflow-bff` | gateway | thin owned cost/quota handlers → user-service client; admin via existing proxy. |
| `hermes-agent` | producer/enforcer | pre-turn quota guard; post-turn cost emission; stopped-turn partial tally. |
| `digital-factory-ui` | consumer | credit badge, session header indicator, Settings → Usage page. |
| `admin-ui` *(new — to register)* | consumer | standalone admin app: Plans/Users/Orgs management, admin-role guard. |

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
- Admin APIs (T3) + admin-app scaffold (T8) gate the admin pages (T9).

**External / blocking decisions**
- **D1 — Register the new admin app repo.** A GitHub repo for `admin-ui` must be **created and registered in `workspace.yaml`** (`repos[].id: admin-ui`) before T8/T9 can be marked `ready` (task `repo` values must match `workspace.yaml`). This is a human action; it is **unresolved** until done. *Not* edited in this design (Phase 1 produces the design only).
- **D2 — Confirm the platform-admin role/guard.** The admin plan APIs and `admin-ui` reuse the admin identity/guard from `m1-admin-panel`. Confirm whether plan management is a **platform** admin role or org-scoped (`memberships.role='admin'` is org-scoped today). This shapes T3's guard and T8's route guard.

**Configuration**
- New env: `WORKFLOW_BFF_URL` in `hermes-agent` (cost/quota calls); user-service `model_pricing`/`credit_config` are seed data, not env.
- Org-context contract (Decision D1): the BFF forwards `X-Org-Id` on UI quota checks; hermes passes the turn's workspace/org where available. Documented contract; single-org users unaffected.

**Unresolved**
- D1 (repo registration) and D2 (admin role model) are open and must be closed before the admin-app tasks start. All other tasks are unblocked by internal ordering only.

---

## 6. Parallelization / Blocking Analysis

```
D1: Create + register `admin-ui` repo in workspace.yaml ──┐ human action; unblock before T8/T9
D2: Confirm platform-admin role/guard (m1-admin-panel)   ──┘ low-effort; unblock before T3 guard / T8

T1: user-service — migrations + seeds (7 tables, free plan, pricing, credit_config)
  └── Can begin now — no blockers
  │
  T2: user-service — plan resolution + lazy quota + internal cost/quota APIs
  │     └── BLOCKED on T1 (tables + seeds must exist)
  │
  T8: admin-ui — scaffold app + auth/admin-role guard
        └── BLOCKED on D1 (repo must be registered in workspace.yaml)
        └── BLOCKED on D2 (admin role/guard model must be confirmed)
        │
        T3: user-service — admin plan/assignment APIs + admin guard
        │     └── BLOCKED on T2 (plan resolution reused by effective-plan)
        │     └── BLOCKED on D2 (admin guard model)
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
        T9: admin-ui — Plans / Users / Orgs pages
              └── BLOCKED on T3 (admin APIs must exist)
              └── BLOCKED on T8 (app scaffold + guard must exist)
```

**Waves**
- **Wave 1:** T1 (D1, D2 run immediately in parallel as external actions).
- **Wave 2:** T2 (after T1); T8 (after D1+D2).
- **Wave 3:** T3 and T4 (both after T2).
- **Wave 4:** T5, T6, T7 (after T4) and T9 (after T3+T8) — all parallel.

---

## 7. Repository Impact

| Repo | Why affected | Representative touch points |
|---|---|---|
| `user-service` | System of record for pricing/plans/cost/quota. | `migrations/` (new SQL migration + seeds), new `internal/billing` stores + service (mirroring `users.Store`/`organizations.Store`), `internal/handler/router.go` (`RegisterInternal` cost/quota, new admin group), reuse `RequireServiceToken` + admin guard. |
| `workflow-bff` | Thin cost/quota gateway. | `internal/pkg/serviceclient/userservice/client.go` (new methods), new handler group under `internal/app/api/handler/`, route registration in `internal/app/api/server/server.go`. Admin via existing proxy upstream. |
| `hermes-agent` | Cost producer + quota enforcer. | `src/api/agent_dispatch.py` (quota guard ~`:260`, cost emission post-turn), vendored `conversation_loop.py` stream tally for stopped turns, new BFF client (extend `src/services/user_service_client.py` pattern), `src/db/store.py:append_message` for the block message. |
| `digital-factory-ui` | Chat cost display + Usage page. | `src/components/agent-chat/message.tsx` (badge), new session-header component in `agent-chat-panel.tsx`, `src/components/settings/settings-page.tsx` (+`usage-tab.tsx`), new hook under `src/hooks/settings/`, `services/*` client method. |
| `admin-ui` *(new)* | Standalone admin app. | New repo scaffold (Next.js/HeroUI), BFF auth integration, admin-role guard, Plans/Users/Orgs pages. **Repo id must be registered in `workspace.yaml` (D1).** |

All repo ids except `admin-ui` already exist in `workspace.yaml`. `admin-ui` is pending D1.

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
- Each repo's full suite + lint + type-check must pass before its PR (per workspace rules).

**Migration / config impact**
- One additive user-service migration (7 tables + indices + seeds). New env `WORKFLOW_BFF_URL` in hermes. New repo + `workspace.yaml` entry for `admin-ui` (D1).

**Rollout concerns**
- Order: user-service (T1→T2→T3) → workflow-bff (T4) → consumers (T5/T6/T7) and admin (T8/T9). The quota guard (T5) should ship only after the BFF + user-service quota path is live, else checks would fail open/closed unexpectedly — until T5 ships, behaviour is unchanged (no guard).
- Stopped-turn tally (B1) is the main implementation risk; if the partial count proves unreliable it degrades to a conservative estimate without blocking the feature.

**Backward compatibility**
- Purely additive; no existing endpoint or schema changes. Chat behaviour unchanged for under-quota users. Runtime schema fields ship dormant (NG7).

**Deployment / handoff**
- `admin-ui` deploys independently behind the admin-role guard, authenticating against the same identity layer as `digital-factory-ui`.

---

> **Phase 1 (Design) complete.** Task breakdown (`tasks.md` + `tasks/T<n>.yaml`) is produced in Phase 2, after this design is approved.
