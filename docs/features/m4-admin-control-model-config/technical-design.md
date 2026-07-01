# Technical Design

## Feature
- Feature ID: `m4-admin-control-model-config`
- Title: Admin-Configurable Model Catalog & Pricing

---

## 1. Current State

Three existing repos are involved — no new repo is introduced.

**`user-service`** (Go · Gin · pgx · Goose migrations). [[m4-agent-cost]] added
`migrations/00006_billing_quota_platform_roles.sql`, which created `model_pricing`:

```sql
CREATE TABLE model_pricing
(
    model_id                  TEXT PRIMARY KEY,
    input_cost_per_mtok       NUMERIC     NOT NULL,
    output_cost_per_mtok      NUMERIC     NOT NULL,
    cache_read_cost_per_mtok  NUMERIC     NOT NULL,
    cache_write_cost_per_mtok NUMERIC     NOT NULL,
    effective_from            TIMESTAMPTZ NOT NULL,
    effective_to              TIMESTAMPTZ
);
```

Seeded with 5 rows: `claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5`,
`deepseek-v4-flash`, `deepseek-v4-pro` (list price + ~5% margin). `internal/billing/store.go`'s
`GetModelPricing` already queries `WHERE model_id = $1 AND effective_to IS NULL` — i.e. the
code was written *as if* a model could have a history of priced periods — but **`model_id` is
the sole primary key**, so a second row for the same model can never be inserted. Today the
only way to "change" a price is an in-place `UPDATE`, which silently rewrites the rate for
every historical `turn_cost` lookup that re-derives cost, and provides no way to add a model
without a migration. There is no CRUD API for this table at all — only the internal
`GetModelPricing` read used by `RecordTurnCost`. `model_pricing` carries **no display name, no
provider, no active/default flag** — it is pricing-only.

`user-service` also already has everything needed to check whether a caller is a platform
admin: `internal/billing/service.go` exposes `GetUserPlatformRoles(ctx, userID)` and
`HasPlatformRole(ctx, userID, roleKey)` against the `platform_role`/`platform_role_assignment`
tables from [[m4-agent-cost]] (Decision F). Today these are only reachable via the
browser-facing `/me` endpoint — there is no service-to-service endpoint exposing them yet.

**`hermes-agent`** (Python · FastAPI · **its own Postgres DB**, `asyncpg` + SQLAlchemy async).
`src/api/model_catalog.py` is a **hardcoded module**:

```python
CLAUDE_MODELS: list[ModelInfo] = [
    {"id": "claude-opus-4-8", "label": "Claude Opus 4.8", "provider": "anthropic"},
    {"id": "claude-sonnet-4-6", "label": "Claude Sonnet 4.6", "provider": "anthropic"},
    {"id": "claude-haiku-4-5", "label": "Claude Haiku 4.5", "provider": "anthropic"},
]
DEEPSEEK_MODELS: list[ModelInfo] = [
    {"id": "deepseek-v4-flash", "label": "DeepSeek V4 Flash", "provider": "deepseek"},
    {"id": "deepseek-v4-pro", "label": "DeepSeek V4 Pro", "provider": "deepseek"},
]
SUPPORTED_MODELS: list[ModelInfo] = [*CLAUDE_MODELS, *DEEPSEEK_MODELS]
```

This module backs three things: `GET /models` (`src/api/routers/models.py`, returns
`{models, default}` for the FE picker), `is_supported()`/`default_model()` (the latter reads
`HERMES_MODEL` env, else falls back to the hardcoded `claude-sonnet-4-6`), and
`resolve_model()` (`agent_dispatch.py:577`, maps an id to `{model, provider, api_key,
base_url}` using `ANTHROPIC_API_KEY` / `DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL`). Adding
Claude Sonnet 5 today means editing this list and redeploying `hermes-agent`.

`hermes-agent` owns a real, independent Postgres database — its own raw-SQL migration set
(`migrations/001_initial_schema.sql` … `005_session_id_uuid.sql`, tracked via a
`schema_migrations` table and a custom runner in `src/db/store.py`, applied in filename
order) — tables `sessions`, `messages`, `session_members`, `message_mentions`. It already
calls `user-service` **directly, server-to-server** for cost/quota
(`src/services/cost_client.py`) — `USER_SERVICE_URL` + `USER_SERVICE_TOKEN` env vars, bearer
auth, **fail-open** on any network error, 5–10s timeout. This bypasses `workflow-bff`
entirely ("the BFF only adds value for browser/cookie callers, which hermes is not").

`hermes-agent` also already has a trusted-identity pattern for requests that *do* come via the
BFF: `src/api/identity.py`'s `require_identity()` reads `X-User-Id`/`X-Org-Id` — headers the
BFF injects after resolving the browser session — gated by a shared `GATEWAY_SERVICE_TOKEN`
presented as `Authorization: Bearer <token>`. `hermes-agent` trusts these headers as
authoritative and never sees the browser cookie itself.

**`digital-factory-ui`** (Next.js). The chat model picker (`src/services/hermes-agent/chat.ts:
listModels()`) already **fetches** the catalog from `${getBffBaseUrl()}/bff/hermes-agent/api/v1/models`
at runtime — it does not hardcode model names itself. The `/admin/` tree
(`src/app/(shell)/admin/`) exists per `m1-admin-panel` and `m4-agent-cost`: a layout guard
(`layout.tsx`) checks `isPlatformAdmin(meData)` and renders a left nav (`Plans`, `Users`,
`Orgs`) plus routed pages under `admin/plans`, `admin/users`, `admin/orgs`. Admin API calls to
`user-service` go through `workflow-bff`'s existing generic reverse-proxy
(`/bff/user-service/admin/*` → `user-service /admin/*`), which required **no new BFF code**
when Plans/Users/Orgs shipped — the same generic proxy also fronts `hermes-agent`
(`/bff/hermes-agent/...`), injecting the same trusted identity headers to any downstream
service, not just `user-service`.

### Current limitations

- **No admin surface for pricing at all.** `model_pricing` has zero HTTP handlers beyond the
  internal read used at cost-recording time.
- **Model identity (name, provider) is hardcoded in `hermes-agent`, not stored anywhere as
  data.** The product spec's framing ("hardcoded on FE") is imprecise: `digital-factory-ui`
  already fetches the catalog dynamically. The actual hardcoding is one repo upstream, in
  `hermes-agent/src/api/model_catalog.py`.
- **`model_pricing`'s schema cannot support price history despite looking like it can.** The
  `effective_to IS NULL` read pattern is already there; the write side (a real versioned
  insert) is not, because of the single-column primary key.
- **No active/retired or default concept anywhere in the DB.** Retiring a model or changing
  the default today means removing/reordering the hardcoded Python list.
- **No service-to-service way to check platform-admin status.** `GetUserPlatformRoles`/
  `HasPlatformRole` exist in `user-service`'s billing service but are only wired to the
  session-authenticated `/me` handler — not to the internal, service-token-gated group that
  `hermes-agent` already calls into.

## 2. Problem Framing

### What must change

- Model **identity** (id, display name, provider, active flag, default flag) needs to become
  admin-editable data instead of a hardcoded Python list.
- Model **pricing** needs a real versioned history in `user-service` (not just
  query-shaped-for-it), with admin CRUD.
- `hermes-agent` needs a way for its own `/admin/*` routes to verify the caller is a
  `platform_admin`, without duplicating `user-service`'s role-assignment storage.
- `digital-factory-ui` needs a new admin page spanning both concerns.

### What must remain stable

- The `GET /api/v1/models` response shape (`{models: [{id, label, provider}], default}`) —
  `digital-factory-ui`'s chat picker requires **zero changes**.
- `resolve_model()`'s credential-resolution branches (`anthropic` → `ANTHROPIC_API_KEY`;
  `deepseek` → `DEEPSEEK_API_KEY`/`DEEPSEEK_BASE_URL`). Only two providers have credential
  wiring today; the catalog can add new **models** under either provider, but adding a
  genuinely new **provider** (e.g. OpenAI) is still a `hermes-agent` code change — the admin
  UI does not attempt to make provider wiring itself data-driven.
- `turn_cost` keeps **no FK** to pricing (unpriced/unknown models still record at cost 0,
  logged for backfill) — this feature does not change that resilience choice, and in fact
  leans on it (see Decision A).
- The `HERMES_MODEL` env var ops override in `default_model()` — it still wins over the
  catalog default, for infra-level emergency overrides.
- `hermes-agent`'s `cost_client.py`/`identity.py` fail-open convention for **availability**
  concerns — but not for the new **authorization** check, which must fail closed (§3,
  Decision C).

### Fixed assumptions (carried from product spec, refined here)

- Admin-only (`platform_admin`, reusing [[m4-agent-cost]] Decision F) — no self-serve model
  management (NG2).
- No retroactive re-pricing of `turn_cost` (NG4) — a rate change only affects future turns.
- No provider auto-discovery (NG1).
- **Refinement of NG5:** the product spec scoped this to "the Anthropic/Claude family," but
  `model_pricing` already prices DeepSeek models too, and `hermes-agent` already has DeepSeek
  credential wiring. The catalog therefore covers **both currently-wired providers**
  (Anthropic, DeepSeek) — admin can add new models under either. A new provider requiring new
  credential-wiring code remains out of scope, consistent with the spec's intent.

## 3. Options Considered

### Decision A — Where does model identity live relative to pricing?

**A1 — Both in `user-service`, one joined table or two FK'd tables.** Model identity
(display name/provider/active/default) and pricing history live together in `user-service`,
joined by a real foreign key, all admin writes in one transactional service.
- Pros: one transactional boundary for "create a model + its initial price"; one admin API
  surface; one authorization check (`RequirePlatformRole`, already built).
- Cons: `hermes-agent` never needs pricing at all — only identity, to decide what's
  selectable and how to route a call. Fetching identity from `user-service` means either a
  network call on every chat turn/picker load (Decision C below then has to solve for
  staleness, fail-open, and a first-boot fallback) or living with that complexity permanently
  for data that `hermes-agent` — not `user-service` — is the natural runtime owner of.

**A2 — Split by domain: `model_catalog` owned by `hermes-agent`'s own DB (identity), `model_pricing`
stays in `user-service` (rates), joined only by the `model_id` string (chosen).**
- Pros: matches domain ownership exactly — `hermes-agent` already decides "what can I run and
  what's the default" (`resolve_model()`/`default_model()` already live there); `user-service`
  already owns "what does it cost" (`RecordTurnCost`/`computeCostUSD`). `hermes-agent` reads
  its own local table directly — no network hop, no cache, no staleness window, no
  fail-open logic needed for the hot path (`resolve_model()` is called per-turn). This removes
  a whole category of complexity that A1 would otherwise need to solve.
- Cons: "create a model" becomes two writes across two services instead of one transaction —
  catalog row in `hermes-agent`, initial price row in `user-service`. If one succeeds and the
  other fails, the system is in a partial state.
- **Why the con is acceptable here:** the partial-failure states are exactly the ones the
  existing design already tolerates. A catalog entry with no priced row yet degrades to the
  existing "unpriced model, cost 0, logged for backfill" path (`turn_cost` has no FK to
  `model_pricing` for precisely this reason). A priced row for a model_id that was never
  created in `hermes-agent`'s catalog is simply inert — nothing ever looks it up, because
  `resolve_model()` only resolves ids that exist in `hermes-agent`'s own table. Neither
  partial state corrupts anything; both are already-designed-for degradations, not new ones.
- No cross-database FK is possible between two separate Postgres instances anyway — A2's
  "joined by convention, not FK" is not a compromise unique to this option, it's just made
  explicit.

**Chosen: A2.** This was raised directly in review and is the better fit: it assigns each
table to the service that actually needs it at request time, and it removes the
cache/staleness/fail-open machinery A1 would otherwise require purely to work around a
network dependency for data `hermes-agent` could just own locally.

### Decision B — How does `hermes-agent`'s new `/admin/*` gate check `platform_admin`?

`hermes-agent`'s admin routes need the same authorization `user-service`'s `/admin/*` already
has, but `hermes-agent` has no `platform_role_assignment` table of its own — that data lives
in `user-service`.

**B1 — Have `workflow-bff` forward a resolved role header (e.g. `X-Platform-Roles`) on every
proxied request, the same way it already forwards `X-User-Id`/`X-Org-Id`.**
- Rejected on inspection: `workflow-bff`'s `Session` struct
  (`internal/pkg/model/session.go`) does not carry platform roles today, and no such
  header exists anywhere in the proxy handler. Building this would mean teaching the BFF to
  resolve and cache roles at login and change the generic proxy for every downstream service
  — a real, broader change to justify for one feature.

**B2 — `hermes-agent` calls a new internal `user-service` endpoint to check the role, the same
way it already calls `quota/check` (chosen).** Add `GET
/internal/users/:userId/platform-roles/check?role=platform_admin` to `user-service`'s existing
`RegisterInternal` group (service-token gated, same group as `quota/check`/`turn-costs`),
backed by the **already-existing** `Billing.HasPlatformRole(ctx, userID, roleKey)`. In
`hermes-agent`, add `src/services/platform_role_client.py` (structurally like
`cost_client.py`: `USER_SERVICE_URL`/`USER_SERVICE_TOKEN`) and a new
`require_platform_admin()` dependency in `identity.py` that calls `require_identity()` first
(validates `GATEWAY_SERVICE_TOKEN`, reads `X-User-Id`), then checks the role.
- Pros: reuses backend logic that already exists (`HasPlatformRole`); no `workflow-bff`
  change at all — the existing generic proxy already forwards `X-User-Id`, which is all this
  needs; consistent with the established `cost_client.py` direct-call pattern.
- Cons: **must fail closed**, not fail-open like `cost_client.py`/`check_quota` — an
  unreachable `user-service` must deny admin actions, not silently allow them. This is a
  deliberate, explicit deviation from the existing fail-open convention, called out so it
  isn't copy-pasted incorrectly from `cost_client.py`.

**Chosen: B2.** `workflow-bff` stays untouched by this feature entirely.

### Decision C — Freshness of `hermes-agent`'s catalog reads

Since `model_catalog` now lives in `hermes-agent`'s own database (Decision A2), this is no
longer the cross-service staleness question it would have been under A1 — `is_supported()`,
`default_model()`, and `resolve_model()` query the local table directly, same as any other
`hermes-agent` read (e.g. `sessions`/`messages`). No cache, no background refresh task, and no
fail-open fallback logic are needed for identity at all. The only fallback kept is a
single-entry built-in default (`claude-sonnet-4-6`) for the theoretical case for a
not-yet-migrated database — the same safety net `_FALLBACK_MODEL` already provides today.

## 4. Chosen Design

### Data flow

```
digital-factory-ui (/admin/models)
  ├── identity CRUD  ──►  workflow-bff (generic /bff/hermes-agent/admin/* proxy, unchanged)  ──►  hermes-agent /admin/models*
  └── pricing CRUD   ──►  workflow-bff (generic /bff/user-service/admin/* proxy, unchanged)   ──►  user-service /admin/pricing*

digital-factory-ui (chat picker)  ── GET /api/v1/models (unchanged contract) ──►  hermes-agent (local DB read)

hermes-agent (/admin/models* request)  ── GET /internal/users/:id/platform-roles/check (direct, USER_SERVICE_URL) ──►  user-service
```

`hermes-agent` is the system of record for model identity/selectability. `user-service`
remains the system of record for pricing. `workflow-bff` is untouched — both admin surfaces
ride its existing generic per-service proxy. `digital-factory-ui` gains one new admin page
that talks to two backends and merges by `model_id`; the existing chat picker is untouched.

### `hermes-agent`: model catalog (new local table + admin API)

New migration `hermes-agent/migrations/006_model_catalog.sql` (own numbering/runner,
consistent with `001`–`005`):

```sql
-- model_catalog: admin-editable model identity. One row per model.
CREATE TABLE IF NOT EXISTS model_catalog
(
    model_id     TEXT PRIMARY KEY,
    display_name TEXT        NOT NULL,
    provider     TEXT        NOT NULL,   -- 'anthropic' | 'deepseek' (enforced in service layer)
    is_active    BOOLEAN     NOT NULL DEFAULT TRUE,
    is_default   BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Enforce at most one default model at a time.
CREATE UNIQUE INDEX model_catalog_one_default ON model_catalog (is_default) WHERE is_default;

-- Backfill from today's hardcoded SUPPORTED_MODELS.
INSERT INTO model_catalog (model_id, display_name, provider, is_active, is_default) VALUES
  ('claude-opus-4-8',   'Claude Opus 4.8',    'anthropic', TRUE, FALSE),
  ('claude-sonnet-4-6', 'Claude Sonnet 4.6',  'anthropic', TRUE, TRUE),
  ('claude-haiku-4-5',  'Claude Haiku 4.5',   'anthropic', TRUE, FALSE),
  ('deepseek-v4-flash', 'DeepSeek V4 Flash',  'deepseek',  TRUE, FALSE),
  ('deepseek-v4-pro',   'DeepSeek V4 Pro',    'deepseek',  TRUE, FALSE);
```

A corresponding SQLAlchemy model is added to `src/db/models.py` (`ModelCatalog`,
`__tablename__ = "model_catalog"`), plus store methods in `src/db/store.py` for list/create/
update, following the existing async session patterns used by `Session`/`Message`.

`src/api/model_catalog.py` drops `SUPPORTED_MODELS`/`_BY_ID` entirely. `is_supported()`,
`default_model()`, `resolve_model()` query `model_catalog` directly (active rows only for
selection; `is_default` for the default, `HERMES_MODEL` env still taking priority). A
single-entry built-in fallback (`claude-sonnet-4-6`) is kept as a constant for defense in
depth. `GET /models` (`src/api/routers/models.py`) reads the same table — response shape
unchanged.

New `src/api/routers/admin_models.py`, all routes depending on the new
`require_platform_admin` dependency:
- `GET /admin/models` — list all catalog entries.
- `POST /admin/models` — create a catalog row. Validates `provider` against the known set.
- `PATCH /admin/models/{model_id}` — update `display_name`/`is_active`/`is_default`. Setting
  `is_default: true` clears the previous default in the same DB transaction (also enforced by
  `model_catalog_one_default`). Rejects `is_active: false` on the current default with a 400
  — an admin must reassign the default first.

`src/api/identity.py` gains:
- `platform_roles` is **not** added to the shared `Identity` model (it's specific to the
  admin-gate check, not general request identity).
- A new dependency `require_platform_admin(request: Request) -> Identity` — calls
  `require_identity(request)`, then `platform_role_client.has_role(user_id, "platform_admin")`
  (new `src/services/platform_role_client.py`, mirroring `cost_client.py`'s
  `USER_SERVICE_URL`/`USER_SERVICE_TOKEN` config but **failing closed**: any error, timeout,
  or unset `USER_SERVICE_URL` raises `403`, it never defaults to "allowed").

### `user-service`: versioned pricing + one new internal endpoint

New migration `migrations/00007_model_pricing_versioning.sql`:

```sql
-- Swap the single-column PK for a surrogate id, in place — no data movement,
-- no temp table. model_id keeps its NOT NULL (a column attribute, not
-- something that disappears when the constraint backing it is dropped).
ALTER TABLE model_pricing DROP CONSTRAINT model_pricing_pkey;
ALTER TABLE model_pricing ADD COLUMN id UUID NOT NULL DEFAULT gen_random_uuid();
ALTER TABLE model_pricing ADD PRIMARY KEY (id);

-- model_id has no FK here: model_pricing lives in a separate database from
-- hermes-agent's model_catalog (Decision A2) — cross-database FKs aren't possible.
CREATE UNIQUE INDEX model_pricing_one_current ON model_pricing (model_id) WHERE effective_to IS NULL;
```

`id` ends up as the last physical column (Postgres always appends new columns) — cosmetic
only; nothing selects this table by column position. The 5 existing rows keep their data and
simply gain a generated `id`; no rows are recreated or moved.

`internal/billing/store.go`'s `GetModelPricing` query is unchanged in shape (`WHERE model_id
= $1 AND effective_to IS NULL`) — it now actually behaves as originally written, since a
second row per model can finally exist. `RecordTurnCost`/`computeCostUSD` are unaffected.

New admin endpoint (`RegisterAdmin`, existing `RequirePlatformRole("platform_admin")`):
- `GET /admin/pricing` — list all `model_pricing` rows (current + history), grouped by
  `model_id`.
- `POST /admin/pricing` — insert a new pricing row for a `model_id` (`effective_from` defaults
  to now, or admin-specified for a scheduled change), closing the previous current row's
  `effective_to` in the same transaction. `model_id` is accepted as a plain string — not
  validated against `hermes-agent`'s catalog (no cross-DB check is possible; an admin pricing
  a not-yet-created or already-retired model_id is harmless, matching the no-FK philosophy
  already used by `turn_cost`).

New internal endpoint (`RegisterInternal`, existing `RequireServiceToken`):
- `GET /internal/users/:userId/platform-roles/check?role=platform_admin` — thin wrapper over
  the already-existing `Billing.HasPlatformRole`, returns `{"has_role": bool}`. This is the
  only new internal endpoint; it exists purely so `hermes-agent` can gate its own admin routes
  without duplicating `user-service`'s role storage.

### `digital-factory-ui`: admin Models page

- New `src/app/(shell)/admin/models/page.tsx`, following `admin/plans/page.tsx`'s structure:
  a list view that fetches both `hermes-agent`'s catalog and `user-service`'s current pricing
  and merges them client-side by `model_id`; a create flow (id, display name, provider select,
  initial rates) that posts to `hermes-agent` first, then `user-service` — if the second call
  fails, the UI surfaces the model as "unpriced" (a valid, tolerated state per Decision A2)
  with a retry action, rather than attempting a fake cross-service rollback; an edit dialog
  (display name/active/default) hitting `hermes-agent`; a "update pricing" action hitting
  `user-service`.
- New `src/hooks/admin/use-admin-models.ts`, mirroring `use-admin-plans.ts`, composing two
  React Query hooks (catalog + pricing) and a merge selector.
- New methods in `src/services/hermes-agent/` (catalog CRUD, `/bff/hermes-agent/admin/models*`)
  and `src/services/user-service/` (pricing CRUD, `/bff/user-service/admin/pricing*`) — both
  ride the existing generic proxies, **no `workflow-bff` change required**.
- `layout.tsx`'s `NAV` array gains one entry (`{ href: "/admin/models", label: "Models", icon:
  Cpu }`) — the existing `isPlatformAdmin` guard already covers the new route.
- The chat model picker (`chat.ts: listModels()`) is **not touched**.

### Affected repositories

| Repo | Role | Why touched |
|---|---|---|
| `hermes-agent` | system of record for identity | new local `model_catalog` table + migration; admin CRUD; `require_platform_admin` gate |
| `user-service` | system of record for pricing | `model_pricing` migrated to support real versioning; admin pricing CRUD; one new internal role-check endpoint |
| `digital-factory-ui` | consumer | new admin page under the existing `/admin/` tree, calling two backends |
| `workflow-bff` | — | **not touched** — both admin surfaces ride the existing generic per-service proxy (Decision B) |

### Compatibility & operational implications

- Two independent, additive migrations (`hermes-agent` 006, `user-service` 00007) — no
  coordination required between them beyond both landing before their respective admin APIs.
- No new env vars in any repo — `hermes-agent` reuses `USER_SERVICE_URL`/`USER_SERVICE_TOKEN`
  already present for `cost_client.py`.
- `GET /api/v1/models` and `resolve_model()`'s external contract are unchanged — zero risk to
  the existing chat picker or agent dispatch call sites.
- The new `platform-roles/check` internal endpoint is the only new cross-service coupling;
  it's read-only and low-frequency (admin actions only, not per-turn).

## 5. Dependency Analysis

**Internal dependencies:**
- `hermes-agent`'s admin catalog API depends on its own migration (006) landing first.
- `hermes-agent`'s `require_platform_admin` gate depends on `user-service`'s new
  `platform-roles/check` internal endpoint existing — but this is a small, independently
  testable contract (mockable in `hermes-agent`'s tests), not a hard sequencing blocker on the
  same PR.
- `user-service`'s admin pricing API depends on its own migration (00007) landing first.
- `digital-factory-ui`'s admin page depends on both `hermes-agent`'s and `user-service`'s
  admin APIs existing.

**External dependencies:** none. No new vendor, no new infra, no new third-party service.

**Blocking decisions:** none open — Decisions A, B, and C above are resolved in this document.

**Configuration dependencies:** none new — no env vars are added in any repo.

**Release dependency:** `user-service`'s `platform-roles/check` endpoint should deploy before
or alongside `hermes-agent`'s admin routes — if `hermes-agent` shipped first, its admin routes
would 403 everything (fail-closed, per Decision B) until `user-service` catches up. This is
safe (admin actions simply unavailable, nothing else affected) but should still be sequenced
deliberately.

## 6. Parallelization / Blocking Analysis

No external decisions are pending — all schema and API details are resolved above by reusing
established `hermes-agent`/`user-service` conventions.

```
T1: hermes-agent — migration 006 (model_catalog + backfill)
T2: user-service — migration 00007 (model_pricing versioning + backfill)
  └── T1 and T2 run in parallel — independent schemas in independent databases
  │
  T3: user-service — internal platform-roles/check endpoint + admin/pricing CRUD
        └── BLOCKED on T2 (needs the versioned model_pricing schema for admin/pricing CRUD)
  │
  T4: hermes-agent — require_platform_admin gate + admin/models CRUD + catalog-backed model_catalog.py
        └── BLOCKED on T1 (schema must exist for store/CRUD code)
        └── BLOCKED on T3 (needs the real platform-roles/check contract to gate against)
  │
  T5: digital-factory-ui — admin Models page
        └── BLOCKED on T3 (needs /admin/pricing)
        └── BLOCKED on T4 (needs /admin/models)
```

## 7. Repository Impact

| Repo | Files/areas touched |
|---|---|
| `hermes-agent` | `migrations/006_model_catalog.sql` (new); `src/db/models.py` (`ModelCatalog`); `src/db/store.py` (catalog CRUD methods); `src/api/model_catalog.py` (hardcoded list → local DB reads); `src/api/routers/models.py` (unchanged response shape, new data source); `src/api/routers/admin_models.py` (new); `src/api/identity.py` (`require_platform_admin`); `src/services/platform_role_client.py` (new). |
| `user-service` | `migrations/00007_model_pricing_versioning.sql` (new); `internal/billing/store.go` (`ModelPricing` struct + `GetModelPricing`/insert queries for the new schema); `internal/billing/service.go` (pricing-version-rotation tx); `internal/handler/router.go` (`RegisterAdmin`: `GET/POST /admin/pricing`; `RegisterInternal`: `GET /internal/users/:userId/platform-roles/check`). |
| `digital-factory-ui` | `src/app/(shell)/admin/models/page.tsx` (new); `src/app/(shell)/admin/layout.tsx` (`NAV` +1 entry); `src/hooks/admin/use-admin-models.ts` (new); `src/services/hermes-agent/` + `src/services/user-service/` (new client methods). |
| `workflow-bff` | none — see Decision B. |

Task `repo` values: `hermes-agent`, `user-service`, `digital-factory-ui` (all match
`workspace.yaml -> repos[].id`).

## 8. Validation and Release Impact

**Testing expectations:**
- `hermes-agent`: pytest coverage for `model_catalog.py`'s DB-backed `is_supported()`/
  `default_model()`/`resolve_model()`; `require_platform_admin` unit tests (allowed, denied,
  and **fail-closed on `user-service` unreachable** — this is the one place a network error
  must produce a 403, not a pass-through, so it needs an explicit negative test); admin route
  tests for catalog CRUD and the one-default invariant.
- `user-service`: `go test ./... -race` covering pricing versioning (assert the old row's
  `effective_to` closes correctly and `model_pricing_one_current` prevents two open rows) and
  the new internal `platform-roles/check` endpoint (service-token gated, correct boolean for
  both a role-holder and a non-holder). `golangci-lint` clean.
- `digital-factory-ui`: component/contract tests for the new admin page and both new service
  client method sets, following the existing `__tests__/services/user-service/admin-types.test.ts`
  pattern; a test for the merge-by-`model_id` behavior when one side is missing (unpriced
  model / retired-but-still-priced model).

**Migration/config impact:** one additive migration in `hermes-agent` (006) and one in
`user-service` (00007); no new env vars in any repo.

**Rollout concerns:** `user-service`'s `platform-roles/check` endpoint should be live before
`hermes-agent`'s admin routes are exercised (§5) — otherwise admin actions in `hermes-agent`
403 until it catches up (safe, but should be sequenced deliberately, not accidentally).
Catalog changes in `hermes-agent` are immediate (local DB read, no cache) — no propagation
delay, unlike a cross-service-cache design would have introduced.

**Backward compatibility:** `GET /api/v1/models`'s response shape and `resolve_model()`'s
credential-resolution contract are unchanged, so `digital-factory-ui`'s existing chat picker
and `agent_dispatch.py`'s call site require no changes.

**Deployment/handoff implications:** `hermes-agent` (T1, T4) and `user-service` (T2, T3) are
independent migration/deploy tracks that only need to converge before `digital-factory-ui`
(T5) and before `hermes-agent`'s admin gate can actually authorize anyone (T4 depends on T3
for that reason, per §6).
