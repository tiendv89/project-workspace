# Task Breakdown — Agent Cost Tracking (Credits, Billing Plans, and Quota)

Feature status: `in_tdd` | Stage: `tasks` (awaiting approval)
Machine state lives in `tasks/T<n>.yaml` — do not add status/log fields here.

Source design: `technical-design.md` (approved). Admin plan management is folded into
`digital-factory-ui`'s existing `/admin/` tree (no standalone app). Admin authorization uses
the role-general platform-role model (Decision F): `platform_role` + `platform_role_assignment`,
M4 shipping and using only `platform_admin`.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | user-service: billing/quota + platform-role migrations & seeds | — |
| T2 | 2 | user-service: plan resolution + lazy quota + internal cost/quota APIs | T1 |
| T3 | 3 | user-service: admin plan APIs + RequirePlatformRole guard + platform_roles in identity payload | T2 |
| T4 | 3 | workflow-bff: cost/quota gateway handlers + forward platform_roles | T2 |
| T5 | 4 | hermes-agent: pre-turn quota guard + post-turn cost emission + stopped-turn tally | T4 |
| T6 | 4 | digital-factory-ui: chat credit badge + session header quota indicator | T4 |
| T7 | 4 | digital-factory-ui: Settings → Usage page | T4 |
| T8 | 4 | digital-factory-ui: admin Plans/Users/Orgs pages under /admin/ + platform-role guard | T3, T4 |

---

## T1 — user-service: billing/quota + platform-role migrations & seeds

### Description
Lay the entire storage foundation in `user-service` (the single system of record). One additive
Goose migration creates 9 tables and seeds them. This is the only task that runs DDL; everything
downstream reads these tables.

**Tables (exactly per `technical-design.md` §4 / product-spec Data Model):**
- Billing/quota (7): `billing_plan`, `user_plan_assignment`, `org_plan_assignment`, `model_pricing`,
  `credit_config`, `turn_cost` (append-only; indices `(user_id, created_at)` and `(source_type, created_at)`),
  `user_usage_quota` (counters + reset timestamps; caps **not** stored — read live from `billing_plan`).
- Platform roles (2): `platform_role` (catalog: `key` PK, `display_name`, `description`),
  `platform_role_assignment` (`user_id` × `role_key` FK → `platform_role`, `granted_by`, `granted_at`,
  `UNIQUE (user_id, role_key)`).

**Seeds (in the same migration):**
- One `free` `billing_plan` with sensible default daily/weekly caps (admin-editable post-deploy).
- `model_pricing` rows for current Anthropic models (internal USD rates).
- The single `credit_config` row (`usd_to_credits`).
- The `platform_admin` row in `platform_role` (`'platform_admin'`, `'Platform Admin'`, `'Full internal admin access'`).

**Backfill (in the same migration):** insert a `platform_role_assignment` for every user whose
`memberships.role = 'platform_admin'`, so existing admins (and `/admin/connect`, `/admin/members`)
keep access with no manual step. No backfill of cost data (NG6).

This task adds **migration + table-level stores only** (mirroring the `users.Store`/`organizations.Store`
shape). Business logic (resolution, quota) is T2; HTTP handlers are T2/T3.

### Required skills
- go-best-practices
- postgres-best-practices
- backend-engineer

### Subtasks
- [ ] Author one additive Goose migration under `migrations/` creating all 9 tables with the exact columns/types/constraints from the design.
- [ ] Add the `(user_id, created_at)` and `(source_type, created_at)` indices on `turn_cost`.
- [ ] Seed `free` plan, `model_pricing` (current Anthropic models), `credit_config`, and the `platform_admin` role.
- [ ] Backfill `platform_role_assignment` from existing `memberships.role='platform_admin'` users.
- [ ] Add lean stores (DBTX-satisfying) for the new tables, no business logic yet.
- [ ] Assert `turn_cost` append-only intent (no UPDATE path) and that caps are not duplicated into `user_usage_quota`.
- [ ] `make test` (`go test ./... -race`) + `make lint` (`golangci-lint`, zero errors) pass.

---

## T2 — user-service: plan resolution + lazy quota + internal cost/quota APIs

### Description
Add the cost/quota business logic and the service-token internal API surface on top of T1's tables.

**Plan resolution** (`user_plan_assignment` not expired → `org_plan_assignment` for the resolved
org not expired → `free`), with the org-context contract from Decision D1 (optional org argument;
single-org users unaffected).

**Lazy reset** (Decision C1): inside each quota check/increment, if `now >= daily_reset_at`
(or weekly) zero that counter and advance the reset timestamp before applying the live cap from
`billing_plan`.

**Internal API** (`/internal/*`, guarded by existing `RequireServiceToken`):
- `GET /internal/users/:id/quota/check` — resolve plan, lazy reset, return
  `{ allowed, reason?, resets_at?, plan_name, daily_cap, weekly_cap }`.
- `POST /internal/turn-costs` — compute `cost_usd` from `model_pricing` × tokens, convert to
  `credits_used` via `credit_config`, insert `turn_cost`, increment `user_usage_quota` — all in one
  serializable tx.
- `GET /internal/users/:id/cost` — per-turn credits, session totals, quota state.

### Required skills
- go-best-practices
- postgres-best-practices
- backend-engineer

### Subtasks
- [ ] Implement plan resolution (individual → org → free) with optional org context.
- [ ] Implement lazy daily/weekly reset (midnight UTC / Monday midnight UTC) at check/increment time.
- [ ] Implement credit math: `cost_usd = Σ(tokens × model_pricing)`, `credits_used = cost_usd × usd_to_credits`.
- [ ] Add the three `/internal/*` handlers behind `RequireServiceToken`; register in `internal/handler/router.go`.
- [ ] `POST /internal/turn-costs` writes `turn_cost` + increments `user_usage_quota` in one serializable tx.
- [ ] Tests: resolution priority, multi-org disambiguation, lazy reset, credit math, append-only ledger.
- [ ] `make test` + `make lint` pass.

---

## T3 — user-service: admin plan APIs + RequirePlatformRole guard + platform_roles in identity payload

### Description
Add the platform-admin authorization primitive and the admin plan-management API surface.

**`RequirePlatformRole("platform_admin")` middleware** (Decision F): checks
`platform_role_assignment` for the caller — **not** the org-scoped `RequireOrgAdminAuth`. The
org-scoped guard (m1 membership management) is left untouched.

**Identity payload:** extend the user-service identity/`me` response with `platform_roles: string[]`
so the BFF (T4) and UI (T8) can read it.

**Admin API** (`/admin/*`, behind `RequirePlatformRole`):
- `POST /admin/plans`, `PATCH /admin/plans/:id`, `GET /admin/plans`
- `POST /admin/users/:id/plan`, `DELETE /admin/users/:id/plan`
- `POST /admin/orgs/:id/plan`, `DELETE /admin/orgs/:id/plan`
- `GET /admin/users/:id/effective-plan` (plan + source: `individual` | `org` | `default`) — reuses T2 resolution.

### Required skills
- go-best-practices
- postgres-best-practices
- backend-engineer

### Subtasks
- [ ] Add a `platform_role` store + `RequirePlatformRole(key)` middleware checking `platform_role_assignment`.
- [ ] Extend the identity/`me` payload with `platform_roles: string[]`.
- [ ] Add the 8 `/admin/*` handlers; register a new admin route group guarded by `RequirePlatformRole("platform_admin")`.
- [ ] `GET /admin/users/:id/effective-plan` reuses the T2 resolution to return plan + source.
- [ ] Tests: 403 for plain user and for org-scoped `memberships.role='admin'`; 200 for a `platform_role_assignment` holder; backfilled `platform_admin` membership retains access; payload carries `platform_roles`.
- [ ] `make test` + `make lint` pass.

---

## T4 — workflow-bff: cost/quota gateway handlers + forward platform_roles

### Description
Thin owned BFF handlers (Decision A2) over the `userservice` service client, plus surfacing
`platform_roles` on the session/me payload. The BFF owns **no** cost/quota tables.

**Owned handlers** (resolve identity/session, call user-service `/internal/*`):
- `POST /sessions/:id/turn-costs`, `GET /sessions/:id/cost`, `GET /sessions/:id/quota/check`,
  `GET /users/me/quota` (session identity, no `:id`).

**Admin endpoints** are served by the **existing generic proxy** (`/bff/user-service/admin/*`) — no new BFF code for admin routing.

**platform_roles:** include `platform_roles` on the session/me payload the UI reads (implemented
against the Decision F contract; integration verified once T3 is deployed).

### Required skills
- go-best-practices
- backend-engineer

### Subtasks
- [ ] Add `userservice` client methods for the cost/quota internal endpoints.
- [ ] Add the four owned handlers under `internal/app/api/handler/`; register routes in `internal/app/api/server/server.go`.
- [ ] Surface `platform_roles` on the session/me payload (contract from Decision F).
- [ ] Confirm `/bff/user-service/admin/*` reaches user-service `/admin/*` via the existing proxy (no new admin handler).
- [ ] Tests: each handler resolves identity and forwards correctly; BFF owns no tables.
- [ ] `make test` + `make lint` pass.

---

## T5 — hermes-agent: pre-turn quota guard + post-turn cost emission + stopped-turn tally

### Description
Make `hermes-agent` the cost producer and quota enforcer.

**Pre-turn quota guard (G8):** at `agent_dispatch.py` after context is set (~`:260`) and **before**
agent construction (~`:328`), call the BFF quota-check. If `allowed:false`, `append_message()` a
system message (quota type + reset time) and return — **zero tokens spent**, composer stays enabled.

**Post-turn cost emission:** on completion, read the normalized `usage` block
(`conversation_loop.py:1810`) and POST a cost event to the BFF. On stop, emit the **accumulated
partial** (Decision B1, running stream tally) with `stopped:true`.

New env `WORKFLOW_BFF_URL`. New BFF client extending the `src/services/user_service_client.py` (aiohttp) pattern.

### Required skills
- python-best-practices
- backend-engineer

### Subtasks
- [ ] Add a BFF client (aiohttp) + `WORKFLOW_BFF_URL` config.
- [ ] Insert the pre-turn quota guard before agent construction; post a system message + return on `allowed:false`.
- [ ] Emit a cost event after completion using the normalized `usage` block.
- [ ] Maintain a running token tally on the stream; on stop emit the partial with `stopped:true` (Decision B1).
- [ ] Tests: blocked turn spends zero tokens + posts system message + composer enabled (daily & weekly); stopped turn emits `stopped:true` partial (>0, ≤ comparable full turn).
- [ ] `pytest` + `make lint` (ruff) pass.

---

## T6 — digital-factory-ui: chat credit badge + session header quota indicator

### Description
Show cost in the chat surface. Per-message credit `Badge` (reuse `common/badge.tsx`) on agent
message cards (stopped messages show the badge alongside the stopped indicator). Session/thread
header shows running session total + quota indicator (`Daily: 9,975 / 10,000 · Pro plan`), fed by
`GET /sessions/:id/cost` plus the SSE `usage` events already carried in the stream. No USD anywhere.

### Required skills
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- frontend-engineer

### Subtasks
- [ ] Add a credit `Badge` to `src/components/agent-chat/message.tsx` (reuse `common/badge.tsx`).
- [ ] Add a session-header credit/quota indicator in `agent-chat-panel.tsx`, reacting to SSE `usage` events.
- [ ] Add a `services/*` client method for `GET /sessions/:id/cost`.
- [ ] Snapshot/component tests assert credits-only (no USD).
- [ ] `npm run test` + `npm run lint` + `npm run type-check` pass.

---

## T7 — digital-factory-ui: Settings → Usage page

### Description
Add a **Usage** entry to the Settings tabs (new `TABS` entry + `usage-tab.tsx`). Header
"Your usage limits" + plan-name badge. Daily and weekly sections each render a progress bar
(neutral/blue <80% → amber 80–99% → red 100% via existing `success`/`warning`/`danger` tokens),
an integer "X% used" label, and a client-side reset countdown (daily `Resets in Xh Ym`; weekly
calendar day + local time). Footer shows last-fetched relative timestamp + a manual refresh that
re-fetches `GET /users/me/quota`. Fetch on mount; no auto-polling.

### Required skills
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- frontend-engineer

### Subtasks
- [ ] Add a **Usage** entry to the `TABS` array in `src/components/settings/settings-page.tsx`.
- [ ] Build `usage-tab.tsx`: header + plan badge, daily/weekly progress bars with threshold colors and "% used".
- [ ] Client-side reset countdowns (minute-tick, no re-fetch); weekly shows calendar day + local time.
- [ ] Footer relative timestamp + manual refresh hitting `GET /users/me/quota` via a new `src/hooks/settings/` hook.
- [ ] Tests: percentage + color thresholds (80% amber, 100% red), countdown formatting, manual refresh.
- [ ] `npm run test` + `npm run lint` + `npm run type-check` pass.

---

## T8 — digital-factory-ui: admin Plans/Users/Orgs pages under /admin/ + platform-role guard

### Description
Add billing-plan admin pages under the **existing** `src/app/admin/` tree (the same tree hosting
`/admin/members`) — no new app. Update the `/admin/` layout guard to read `platform_roles` from the
session identity payload and require `platform_admin` (Decision F); this replaces the prior
`memberships.role` source while keeping `/admin/connect` and `/admin/members` working (the backfill
from T1 preserves access).

**Pages** (call admin API via `/bff/user-service/admin/*`):
- `/admin/plans` — list/create plans (name, display name, daily cap, weekly cap), edit caps inline.
- `/admin/users` — per-user effective plan + source; assign/remove an individual plan.
- `/admin/orgs` — per-org current plan; assign/remove an org plan.

### Required skills
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- frontend-engineer

### Subtasks
- [ ] Update the `src/app/admin/` layout guard to read `platform_roles` from the session and require `platform_admin`.
- [ ] Build `/admin/plans` (list/create/inline-edit), `/admin/users` (effective plan + assign/remove), `/admin/orgs` (assign/remove).
- [ ] Add React Query hooks + `services/*` methods hitting `/bff/user-service/admin/*`.
- [ ] Tests: guard denies a non-`platform_admin` user (incl. org-scoped admin) and allows a `platform_admin`; credits-only (no USD); existing `/admin/members` still reachable.
- [ ] `npm run test` + `npm run lint` + `npm run type-check` pass.
