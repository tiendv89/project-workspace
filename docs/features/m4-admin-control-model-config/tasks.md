# Tasks — m4-admin-control-model-config

Feature status: `in_tdd` (reference — see `status.yaml` for the live value).
Stage: `tasks` — awaiting human approval of this breakdown.
Machine-mutable state (`status`, `depends_on`, `branch`, `pr`, `log`) lives in
`tasks/T<n>.yaml`, one file per task. This document is narrative only.

## Index

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | hermes-agent — model_catalog migration | [] |
| T2 | 1 | user-service — model_pricing versioning migration | [] |
| T3 | 2 | user-service — admin/pricing API + internal platform-roles/check | [T2] |
| T4 | 3 | hermes-agent — admin/models API + platform-admin gate + catalog-backed dispatch | [T1, T3] |
| T5 | 4 | digital-factory-ui — admin Models page | [T3, T4] |

## T1 — hermes-agent — model_catalog migration

### Description

Add the `model_catalog` table to `hermes-agent`'s own Postgres database — the admin-editable
source of truth for model identity (id, display name, provider, active flag, default flag),
per `technical-design.md` §4 ("`hermes-agent`: model catalog"). This follows `hermes-agent`'s
existing raw-SQL migration convention (`migrations/001_initial_schema.sql` …
`005_session_id_uuid.sql`, tracked via `schema_migrations`, applied in filename order by the
runner in `src/db/store.py`) — add `migrations/006_model_catalog.sql`.

Backfill the table with the 5 models currently hardcoded in
`src/api/model_catalog.py`'s `SUPPORTED_MODELS` (`claude-opus-4-8`, `claude-sonnet-4-6`,
`claude-haiku-4-5`, `deepseek-v4-flash`, `deepseek-v4-pro`), all `is_active = TRUE`, with
`claude-sonnet-4-6` as `is_default = TRUE` (matching today's `_FALLBACK_MODEL`).

This task does **not** touch `src/api/model_catalog.py`'s Python code — that switch to
reading the new table happens in T4, which depends on this migration having landed.

### Required skills

- python-best-practices
- postgres-best-practices

### Subtasks

- [ ] Add `migrations/006_model_catalog.sql`: `CREATE TABLE IF NOT EXISTS model_catalog` (
      `model_id TEXT PRIMARY KEY`, `display_name TEXT NOT NULL`, `provider TEXT NOT NULL`,
      `is_active BOOLEAN NOT NULL DEFAULT TRUE`, `is_default BOOLEAN NOT NULL DEFAULT FALSE`,
      `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`, `updated_at TIMESTAMPTZ NOT NULL
      DEFAULT now()`).
- [ ] Add `CREATE UNIQUE INDEX model_catalog_one_default ON model_catalog (is_default) WHERE
      is_default;` to enforce at most one default model.
- [ ] Backfill the 5 existing models with an `INSERT` matching today's
      `SUPPORTED_MODELS` values (see `technical-design.md` §4 for the exact rows).
- [ ] Add a SQLAlchemy model `ModelCatalog` to `src/db/models.py`
      (`__tablename__ = "model_catalog"`), matching the existing `Session`/`Message` style.
- [ ] Verify the migration applies cleanly against a fresh DB and against a DB already at
      migration `005` (the runner's `schema_migrations` tracking should pick it up as the
      next pending file).
- [ ] Run the existing `hermes-agent` test suite to confirm no regression from the new table
      (no application code reads it yet — this task is schema-only).

## T2 — user-service — model_pricing versioning migration

### Description

Fix `model_pricing`'s schema so it can actually support price history — today
`GetModelPricing` queries `WHERE effective_to IS NULL` as if versioning were supported, but
`model_id` is the sole primary key, so a second row per model can never be inserted. Per
`technical-design.md` §4 ("`user-service`: versioned pricing"), swap the PK for a surrogate
`id` **in place** (no rename/recreate/backfill dance — a straight `ALTER TABLE`), drop the FK
to any catalog table (none exists in this database — `model_catalog` lives in `hermes-agent`'s
separate database per Decision A2), and add a partial unique index to keep "one current row
per model" enforceable.

This task does **not** add any new HTTP handlers — that's T3, which depends on this migration.

### Required skills

- go-best-practices
- postgres-best-practices

### Subtasks

- [ ] Add `migrations/00007_model_pricing_versioning.sql` using the exact in-place `ALTER
      TABLE` sequence from `technical-design.md` §4: `DROP CONSTRAINT model_pricing_pkey`,
      `ADD COLUMN id UUID NOT NULL DEFAULT gen_random_uuid()`, `ADD PRIMARY KEY (id)`.
- [ ] Add `CREATE UNIQUE INDEX model_pricing_one_current ON model_pricing (model_id) WHERE
      effective_to IS NULL;`.
- [ ] Update the `ModelPricing` struct in `internal/billing/store.go` to include the new `ID
      uuid.UUID` field.
- [ ] Confirm `GetModelPricing`'s existing query (`WHERE model_id = $1 AND effective_to IS
      NULL`) still compiles/scans correctly against the new column set — no query shape
      change needed, only the struct.
- [ ] Run `go test ./... -race` and `golangci-lint run` — confirm the 5 existing seeded rows
      survive the migration with generated `id` values and `RecordTurnCost`/`computeCostUSD`
      are unaffected.

## T3 — user-service — admin/pricing API + internal platform-roles/check

### Description

Two additions to `user-service`, per `technical-design.md` §4 ("`user-service`: versioned
pricing + one new internal endpoint"):

1. **Admin pricing CRUD** under the existing `RegisterAdmin` group (already guarded by
   `RequirePlatformRole("platform_admin")`): `GET /admin/pricing` (list all rows, current +
   history, grouped by `model_id`) and `POST /admin/pricing` (insert a new pricing row for a
   `model_id`, closing the previous current row's `effective_to` in the same transaction —
   this is the only way rates change, never an `UPDATE`). `model_id` is accepted as a plain
   string with no existence check against `hermes-agent`'s catalog (no cross-DB check is
   possible; pricing a not-yet-created or already-retired `model_id` is harmless, matching the
   no-FK philosophy already used by `turn_cost`).
2. **One new internal endpoint**, added to `RegisterInternal` (existing
   `RequireServiceToken`): `GET /internal/users/:userId/platform-roles/check?role=platform_admin`,
   a thin wrapper over the already-existing `Billing.HasPlatformRole(ctx, userID, roleKey)`
   method, returning `{"has_role": bool}`. This exists purely so `hermes-agent` (T4) can gate
   its own admin routes without duplicating `user-service`'s role storage.

### Required skills

- go-best-practices
- backend-engineer

### Subtasks

- [ ] Add `internal/billing/service.go` method(s) for inserting a new pricing row + closing
      the prior current row in one serializable transaction (mirrors the existing
      `RecordTurnCost` tx pattern).
- [ ] Add `AdminListPricing` / `AdminCreatePricing` handlers; wire `GET/POST /admin/pricing`
      into `RegisterAdmin` in `internal/handler/router.go`.
- [ ] Add a handler wrapping `Billing.HasPlatformRole`; wire `GET
      /internal/users/:userId/platform-roles/check` into `RegisterInternal`.
- [ ] Unit tests: pricing-row rotation (old row's `effective_to` closes correctly,
      `model_pricing_one_current` prevents two open rows); `RequirePlatformRole` gate on
      `/admin/pricing` (403 for non-admin, matching existing plan-route test patterns);
      `platform-roles/check` returns the correct boolean for both a role-holder and a
      non-holder.
- [ ] Run `go test ./... -race` and `golangci-lint run`.

## T4 — hermes-agent — admin/models API + platform-admin gate + catalog-backed dispatch

### Description

Per `technical-design.md` §4 ("`hermes-agent`: model catalog (new local table + admin API)"),
this task:

1. Replaces `src/api/model_catalog.py`'s hardcoded `SUPPORTED_MODELS`/`_BY_ID` with direct
   reads of the `model_catalog` table added in T1 — `is_supported()`, `default_model()`
   (still honoring the `HERMES_MODEL` env override first), and `resolve_model()` all query the
   table instead of the constant. A single-entry built-in fallback (`claude-sonnet-4-6`) stays
   in code for defense in depth. `GET /models` (`src/api/routers/models.py`) reads the same
   source — its `{models, default}` response shape is **unchanged**.
2. Adds a `require_platform_admin()` dependency to `src/api/identity.py`: calls
   `require_identity()` first (existing `GATEWAY_SERVICE_TOKEN` + `X-User-Id` check), then
   calls a new `src/services/platform_role_client.py` (structurally like `cost_client.py`:
   `USER_SERVICE_URL`/`USER_SERVICE_TOKEN`) to check `platform_admin` via T3's
   `platform-roles/check` endpoint. **This check fails closed** — any network error, timeout,
   or unset `USER_SERVICE_URL` raises `403`, unlike `cost_client.py`'s fail-open convention.
   This deliberate deviation must be called out in code comments, not silently copied from
   `cost_client.py`.
3. Adds `src/api/routers/admin_models.py`: `GET /admin/models`, `POST /admin/models`, `PATCH
   /admin/models/{model_id}` — all depending on `require_platform_admin`. Setting `is_default:
   true` on `PATCH` clears the previous default in the same DB transaction (also enforced by
   T1's `model_catalog_one_default` unique index). Setting `is_active: false` on the current
   default is rejected with a `400` — an admin must reassign the default first.

### Required skills

- python-best-practices
- backend-engineer

### Model overrides

None — workspace defaults apply.

### Subtasks

- [ ] Add store methods to `src/db/store.py` for `model_catalog` list/create/update, following
      the existing async session patterns used by `Session`/`Message`.
- [ ] Rewrite `src/api/model_catalog.py`: remove `SUPPORTED_MODELS`/`_BY_ID`; `is_supported()`,
      `default_model()`, `resolve_model()` read from the store; keep the single-entry built-in
      fallback constant.
- [ ] Confirm `src/api/routers/models.py` (`GET /models`) and `agent_dispatch.py:577`'s
      `resolve_model()` call site require no signature changes — response shape and return
      type stay the same.
- [ ] Add `src/services/platform_role_client.py` (mirrors `cost_client.py`'s
      `USER_SERVICE_URL`/`USER_SERVICE_TOKEN` config; fails **closed**, not open).
- [ ] Add `require_platform_admin()` to `src/api/identity.py`.
- [ ] Add `src/api/routers/admin_models.py` (`GET/POST /admin/models`, `PATCH
      /admin/models/{model_id}`); register it in `src/api/router.py`.
- [ ] Tests: DB-backed `is_supported()`/`default_model()`/`resolve_model()`;
      `require_platform_admin` allowed/denied paths, **plus an explicit test for fail-closed
      behavior when `user-service` is unreachable** (must 403, not pass through); admin route
      tests for catalog CRUD and the one-default invariant (setting a new default clears the
      old one; retiring the current default is rejected).
- [ ] Run the full `hermes-agent` test suite and lint.

## T5 — digital-factory-ui — admin Models page

### Description

Add a new admin page under the existing `/admin/` tree (`src/app/(shell)/admin/`), per
`technical-design.md` §4 ("`digital-factory-ui`: admin Models page"). The page calls **two**
backends and merges by `model_id` client-side: `hermes-agent`'s catalog CRUD
(`/bff/hermes-agent/admin/models*`, from T4) and `user-service`'s pricing CRUD
(`/bff/user-service/admin/pricing*`, from T3) — both ride the existing generic per-service BFF
proxy, so no `workflow-bff` changes are needed anywhere in this feature.

The create flow posts to `hermes-agent` first, then `user-service` for the initial price. If
the second call fails, the UI shows the model as "unpriced" with a retry action rather than
attempting a fake cross-service rollback — this is a tolerated state per the technical
design's Decision A2 (an unpriced model already degrades gracefully to cost-0 recording
elsewhere in the system).

### Figma

No Figma links are present in `product-spec.md` or `technical-design.md` for this feature —
this page's layout should follow the existing `admin/plans/page.tsx` pattern (list view, HeroUI
`@heroui/react` components, `Cpu` icon from `lucide-react` for the nav entry) rather than a
Figma frame.

### Required skills

- frontend-engineer
- nextjs-best-practices
- typescript-best-practices
- heroui-react

### Subtasks

- [ ] Add `src/app/(shell)/admin/models/page.tsx`, following `admin/plans/page.tsx`'s
      structure: list view merging catalog + pricing by `model_id`; create dialog (id, display
      name, provider select, initial rates); edit dialog (display name / active / default);
      "update pricing" action (new rates, closes the prior period).
- [ ] Add `src/hooks/admin/use-admin-models.ts`, mirroring `use-admin-plans.ts` — compose two
      React Query hooks (catalog + pricing) and a merge selector.
- [ ] Add catalog CRUD methods to `src/services/hermes-agent/` and pricing CRUD methods to
      `src/services/user-service/`.
- [ ] Add one `NAV` entry to `src/app/(shell)/admin/layout.tsx`: `{ href: "/admin/models",
      label: "Models", icon: Cpu }` — no guard changes needed, `isPlatformAdmin` already covers
      the route.
- [ ] Confirm `src/services/hermes-agent/chat.ts`'s `listModels()` (the chat picker) is
      untouched.
- [ ] Tests: component/contract tests for the new page and both new service client method
      sets, following `__tests__/services/user-service/admin-types.test.ts`'s pattern; a test
      for the merge-by-`model_id` behavior when one side is missing (unpriced model,
      retired-but-still-priced model).
- [ ] Run the full `digital-factory-ui` test suite, type-check, and lint.
