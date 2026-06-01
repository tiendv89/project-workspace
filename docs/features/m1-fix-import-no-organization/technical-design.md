# Technical Design

## Feature

- Feature ID: `m1-fix-import-no-organization`
- Title: `Workspace Import — Attach to Organization`
- Milestone: **M1 — Open the Black Box** (companion fix to `m1-identity-and-workspaces`)

## Current State

The M1 identity feature (`m1-identity-and-workspaces`) added `organization_id`
to the `workspaces` table in `workflow_db`:

- Migration `00013_workspaces_organization_id.sql` adds the column as nullable.
- Migration `00014_workspaces_organization_id_not_null.sql` flips it to
  `NOT NULL` once T6's seed has backfilled every existing row.

Authenticated wiring in `workflow-backend` is already in place:

- `internal/authmw/middleware.go` — `RequireAuth` validates the session via
  `user-service`'s `/internal/sessions/validate`, then attaches an `AuthCtx`
  with `UserID`, `OrganizationID`, and `AccessibleWorkspaceIDs` to the request
  context.
- `internal/handler/workspace.go::ImportWorkspace` overwrites
  `ImportInput.OrganizationID` with `ac.OrganizationID` — the session is
  authoritative, a client-supplied body value is ignored.
- `internal/service/workspace.go::ImportWorkspace` forwards the field as
  `adapter.ImportRequest.OrganizationID`.
- `internal/adapter/rpc.go` serialises `organization_id` into the JSON body of
  `POST /internal/workspaces/import` against the adapter service.

The break is in **`workspace-github-adapter`**, which receives that POST and
ultimately INSERTs into `workspaces`:

- `internal/handler/import.go::importWorkspaceRequest` has only
  `RepoURL`, `DefaultBranch`, `Name` — `organization_id` is dropped at decode
  time.
- `database/queries/workspaces.sql` defines `UpsertWorkspaceByID` (and the
  unused `UpsertWorkspace`-by-slug) with the column list
  `(id, slug, name, management_repo_id, branch_pattern, slack_channel_id,
  created_at, updated_at)` — no `organization_id`.
- `internal/database/workspaces.sql.go::UpsertWorkspaceByIDParams` correspondingly
  has no `OrganizationID` field; `createImportPlaceholderWithQueries` does not
  populate one.

`workspace-github-adapter` does **not** maintain its own copy of the workspace
schema — its `sqlc.yaml` declares `schema: "database/migrations"` but that
directory does not exist in the repo. Schema authority lives in
`workflow-backend/migrations`; the adapter shares the same `workflow_db`
Postgres instance and the same `workspaces` table. sqlc inference for the
adapter's generated code therefore depends entirely on the query column lists,
which is exactly where this fix is anchored.

Repo-level boundaries (per `workspace.yaml`):

- `workspace-github-adapter` — owns the import HTTP entrypoint
  (`POST /internal/workspaces/import`), the sqlc queries, the generated Go
  client for the `workspaces` table, and the in-tx placeholder writer. **This
  is the only repo this fix changes.**
- `workflow-backend` — already wired end-to-end; no code change. Used here
  only as a verification surface (integration test through the live RPC
  client).
- `digital-factory-ui` — unaffected. The import modal posts `repo_url`,
  `default_branch`, `name`; the session cookie supplies the organization. No
  UI work required.
- `management-repo` (this repo) — unaffected. Schema docs in
  `database/workspace/v002/` already declare `organization_id NOT NULL`.

## Problem Framing

**What must change:**

1. `workspace-github-adapter`'s `importWorkspaceRequest` JSON struct must
   accept `organization_id` and validate it as a non-empty UUID at the
   decode boundary.
2. `database/queries/workspaces.sql` must include `organization_id` in the
   INSERT column list of both `UpsertWorkspaceByID` and `UpsertWorkspace`
   (the latter is unused live but exists in the generated package and stays
   consistent so a future caller cannot reintroduce the bug). On conflict,
   `organization_id` is **not** overwritten — once a workspace is owned, it
   stays owned by that organization (see Option 2 below).
3. `sqlc` regeneration: `UpsertWorkspaceByIDParams` and `UpsertWorkspaceParams`
   gain an `OrganizationID pgtype.UUID` field; `Workspace` row struct gains
   `OrganizationID pgtype.UUID`.
4. `createImportPlaceholderWithQueries` must accept the `organization_id`
   from the handler and pass it through to the params struct.
5. The adapter's import handler must **reject** the request with HTTP 400 if
   `organization_id` is missing, malformed, or the zero UUID — no fallback,
   no default-to-NULL insert attempt.
6. Tests: existing handler tests in `webhook_handler_test.go` and any
   `import_test.go` must be updated to supply `organization_id` in the
   request body; new negative tests must cover the missing/malformed cases.

**What must stay stable:**

- The HTTP path and verb (`POST /internal/workspaces/import`) — `workflow-backend`'s
  RPC client encodes this exact path, so the adapter's route table does not move.
- The 202 / 200 response shape — the UI already consumes `workspace_id`, `name`,
  `slug`, `repo_url`, `default_branch`, `sync_run_id`, `task_id`, `queue`,
  `type`. Adding `organization_id` to the response is acceptable and forward-
  compatible; removing existing keys is not.
- Existing column names, indexes, and the `(slug)` and `(id)` unique
  constraints on `workspaces`. The new `idx_workspaces_organization_id` is
  already created by migration `00013` — we are not adding indexes here.
- The conflict semantics for `slug` and `id` upserts — already-imported
  workspaces continue to be detected by `findExistingImport` before any
  INSERT is attempted.

**Fixed assumptions:**

- `workflow_db` already carries `workspaces.organization_id` (nullable in
  prod until T6 has run; non-null thereafter). This fix targets the
  steady-state schema where the column is `NOT NULL` and migration `00014`
  has been applied — it does not own the rollout sequencing, which is
  `m1-identity-and-workspaces`'s problem.
- `workflow-backend`'s `RequireAuth` is the only entry point that hits this
  endpoint in production. The adapter exposes `/internal/*` on its internal
  network and is fronted by `workflow-backend` — direct calls bypassing
  `workflow-backend` are not a supported public surface.
- Backfill of historical workspace rows with `organization_id` is owned by
  `m1-identity-and-workspaces` T6 (the Kitelabs-org seeder). Out of scope for
  this feature.
- One workspace belongs to exactly one organization. Cross-organization moves
  are not in M1.

## Options Considered

### Option 1 — Where the adapter sources `organization_id`

**Option 1A: Take `organization_id` from the request body (current wiring).**

- The handler reads `request.OrganizationID` directly. Trust comes from the
  fact that the caller is `workflow-backend`, which has already validated the
  session and overwritten any client-supplied value with the authoritative
  session value.

- Pros:
  - No new service-to-service call introduced; smallest possible change.
  - Matches how `workflow-backend` already serialises the field today —
    nothing else needs to move.
  - Keeps the adapter's `/internal/*` interface explicit: every call carries
    the org it acts on. Easier to audit and to migrate to a different
    fronting service later.
  - Lets `workflow-backend`'s `OrganizationID` overwrite rule stay the single
    place where "client-supplied → ignored, session → authoritative" lives.

- Cons:
  - The adapter trusts the caller to have done the session check. This is a
    real cost — but the adapter is already an internal-only service and is
    already trusted in this exact way for `RepoURL` (which is also taken from
    the request body without cross-checking the user's permission to import
    that repo).

**Option 1B: Adapter calls `user-service` `/internal/sessions/validate` itself,
forwarding the session cookie from `workflow-backend`.**

- Pros:
  - Adapter independently verifies the session and pulls `OrganizationID`
    from the validated payload. No reliance on the caller's trust.

- Cons:
  - Requires `workflow-backend` to forward the session cookie value over its
    RPC client to the adapter — new transport surface, new failure mode.
  - Adds a synchronous network hop to `user-service` on every import. M1
    traffic does not justify this.
  - Couples the adapter to the identity service. The adapter is meant to
    have a narrow job (ingest GitHub state into `workflow_db`); making it
    a session validator widens that scope.
  - Token / cookie domain handling becomes a cross-service concern.

**Selected: 1A.** The minimum-change path that uses the wiring
`m1-identity-and-workspaces` already shipped. The adapter trusts the
session-validated value from `workflow-backend`; this is consistent with how
every other field in the same request body is treated.

### Option 2 — Behaviour on `ON CONFLICT` for `organization_id`

**Option 2A: `EXCLUDED.organization_id` overwrites on conflict.**

- A second import of the same `id` or `slug` from a different organization
  would silently reassign ownership.

- Pros: trivial — no special-casing in the UPSERT.
- Cons: cross-org ownership theft. Loses tenancy integrity even though every
  individual call was authenticated.

**Option 2B: Preserve existing `organization_id` on conflict; only set it
during the initial INSERT.**

- `ON CONFLICT (id) DO UPDATE SET ... organization_id = workspaces.organization_id`
  (i.e. keep the current value).
- Equivalent for the `(slug)` conflict path.

- Pros:
  - Ownership is immutable through the import endpoint. The only way to
    change a workspace's organization is an explicit admin path (out of M1
    scope).
  - Matches the product-spec promise: an imported workspace belongs to
    exactly one organization.

- Cons:
  - The handler must still detect "already exists" via `findExistingImport`
    and return the existing record cleanly — that code path already exists
    and is preserved.

**Selected: 2B.** Tenancy stability outweighs the cost of explicitly
preserving the column on conflict. The semantics align with the product spec:
"every imported workspace is attached to exactly one organization."

### Option 3 — Validation strictness at the adapter boundary

**Option 3A: Best-effort.** Accept missing `organization_id`; let the DB raise
the `NOT NULL` violation; map to 500.

- Pros: zero validation code.
- Cons: opaque error surface; no clear distinction between "you forgot to
  attach an org" and a real DB outage; violates the product-spec goal of
  "fail loudly and early".

**Option 3B: Strict at decode.** Require `organization_id` non-empty and
parseable as UUID, return HTTP 400 (validation error) on failure with a
specific error code.

- Pros:
  - Clear, machine-readable failure mode.
  - Stops the call before any side-effect (no async sync task is enqueued).
  - Mirrors the existing handling of `RepoURL` ("repo_url is required").

- Cons: a few lines of validation; tests must cover both branches.

**Selected: 3B.** Aligns with the product-spec success criterion that an
unresolved org never produces a partial / orphan row.

## Chosen Design

### Scope

One repo (`workspace-github-adapter`); one logical change (wire
`organization_id` end-to-end through the import path).

### Request / response contract

`POST /internal/workspaces/import` request body becomes:

```json
{
  "repo_url": "https://github.com/<owner>/<repo>",
  "default_branch": "main",
  "name": "Optional override",
  "organization_id": "<uuid-of-organizations.slug='kitelabs'>"
}
```

- `organization_id` is the UUID of the caller's organization in `user_db.organizations`.
  In M1 the only organization that exists is the Kitelabs internal org, identified by
  `slug = 'kitelabs'` and seeded by `user-service`'s `cmd/seed/seed.go::seedKitelabsOrg`.
  Its UUID is generated at seed time (not a fixed literal); callers obtain it from
  the session via `user-service`'s `/internal/sessions/validate` payload, which
  `workflow-backend`'s `RequireAuth` already injects as `AuthCtx.OrganizationID`.
- `organization_id` is **required**, non-empty, and must parse as a UUID.
- Empty string, zero UUID (`00000000-...`), and malformed UUID all return
  HTTP 400 with `domain.ErrValidationMissingInput` /
  `domain.ErrValidationInvalidInput`.
- All other fields keep their current semantics.
- The 200 / 202 response gains a new field `"organization_id": "<uuid>"` to
  let the caller assert what was persisted; existing keys are unchanged.

### Adapter code path

1. `importWorkspaceRequest` struct gains `OrganizationID string
   \`json:"organization_id"\``.
2. `ImportWorkspaceHandler` validates `OrganizationID` after `RepoURL`; on
   failure, writes a validation error and returns.
3. `createImportPlaceholder` / `createImportPlaceholderWithQueries` gain an
   `organizationID string` parameter and pass it as `pgtype.UUID` into
   `UpsertWorkspaceByIDParams.OrganizationID`.
4. The placeholder write happens inside the same transaction as the
   GitHub-source upsert (already the case today) — the org assignment is
   atomic with the workspace creation.

### SQL changes (`database/queries/workspaces.sql`)

Both upsert queries are updated to include `organization_id`. The conflict
clause **preserves** the existing value (Option 2B):

```sql
-- name: UpsertWorkspaceByID :one
INSERT INTO workspaces (
    id, organization_id, slug, name, management_repo_id,
    branch_pattern, slack_channel_id, created_at, updated_at
)
VALUES ($1, $2, $3, $4, $5, $6, $7, now(), now())
ON CONFLICT (id) DO UPDATE SET
    slug               = EXCLUDED.slug,
    name               = EXCLUDED.name,
    management_repo_id = EXCLUDED.management_repo_id,
    branch_pattern     = EXCLUDED.branch_pattern,
    slack_channel_id   = EXCLUDED.slack_channel_id,
    -- organization_id intentionally NOT updated on conflict
    updated_at         = now()
RETURNING id, organization_id, slug, name, management_repo_id,
          branch_pattern, slack_channel_id, created_at, updated_at;
```

`UpsertWorkspace` (by `slug`) follows the same pattern even though there is
no live caller — keeping the two upserts symmetric prevents a future caller
from silently regressing the fix.

### Generated Go (post `sqlc generate`)

- `UpsertWorkspaceByIDParams` gains `OrganizationID pgtype.UUID` (positionally
  second, matching the SQL).
- `UpsertWorkspaceParams` gains the same.
- `Workspace` row struct gains `OrganizationID pgtype.UUID`.
- Callers of `UpsertWorkspaceByID` (only `createImportPlaceholderWithQueries`)
  must pass the new field; the build will not compile until they do, which
  is the intended forcing function.

### Error surface

| Condition | HTTP | Code | Message |
|---|---|---|---|
| `organization_id` missing | 400 | `ValidationMissingInput` | `"organization_id is required"` |
| `organization_id` malformed | 400 | `ValidationInvalidInput` | `"organization_id must be a UUID"` |
| `organization_id` is zero UUID | 400 | `ValidationInvalidInput` | `"organization_id must not be the zero UUID"` |
| All else | unchanged | | |

### Workflow-backend verification (no code change)

- Unit test in `workflow-backend/internal/handler/workspace_test.go` already
  asserts that the session's `OrganizationID` overrides the body — keep that.
- Add an adapter-client integration test under
  `workflow-backend/internal/adapter/rpc_test.go` (or extend the existing one)
  that sets `ImportRequest.OrganizationID` and asserts the marshalled JSON
  carries it. This is light-weight insurance that the field is not dropped
  in transit.

## Dependency Analysis

### Internal

- **`m1-identity-and-workspaces` migrations `00013`+`00014` are deployed.**
  This fix targets the steady-state schema where `organization_id` is
  `NOT NULL`. If `00014` has not run yet, the SQL change is still safe (the
  column already exists from `00013`), but the strict validation in this fix
  is what guarantees no NULL row is ever written.
- **`m1-identity-and-workspaces` T6 (Kitelabs-org seed + backfill) has
  succeeded in every deployed environment.** Without this, migration `00014`
  cannot apply. Out of scope here; tracked there.
- **`workflow-backend`'s `RequireAuth` is wired on the workspace router.**
  Already shipped in the identity feature. Verified by reading
  `internal/handler/workspace.go:79-81` — present.

### External

- None. No new third-party libraries, no schema vendor decisions, no new IdP
  flow.

### Tooling / configuration

- `sqlc` (already present in the repo). `sqlc generate` must run as part of
  the implementation task; the regenerated `internal/database/workspaces.sql.go`
  is committed alongside the SQL changes.
- No new env vars, no new secrets.

### Release dependencies

- Must ship **after** `m1-identity-and-workspaces` is in the target
  environment (otherwise the `organization_id` column does not exist).
- Must ship **before** migration `00014` runs in that environment (otherwise
  every import attempt fails until this fix lands). The intended sequence is:
  `00013` → backfill (T6) → **this fix deployed** → `00014`.

### Unresolved dependencies

- None known. All required schema, middleware, and RPC wiring already exist.

## Parallelization / Blocking Analysis

External / cross-feature gates (already satisfied at design time, listed for
completeness — not new blockers introduced here):

```
m1-identity ↘
  ├── migration 00013 (organization_id nullable column)        ── deployed
  ├── RequireAuth + AuthCtx.OrganizationID                     ── deployed
  └── workflow-backend ImportWorkspace → adapter wiring        ── deployed
```

Per-task diagram for this feature:

```
T1: Wire `organization_id` end-to-end in workspace-github-adapter
    (handler request struct + validation + sqlc queries + regen + handler
     pass-through + adapter unit tests + handler integration test)
  └── Can begin now — no blockers
  │
  T2: Cross-service smoke test from workflow-backend
      (adapter rpc_test asserts JSON contains organization_id;
       workflow-backend handler test asserts session value reaches the wire)
      └── BLOCKED on T1 (adapter must accept the field before
          workflow-backend can verify it round-trips)
```

Two tasks total. T1 does the substantive work in one repo; T2 adds the
cross-repo verification in a different repo and must wait for the adapter
contract to be live on a deployable branch.

## Repository Impact

| Repo | Change | Why |
|---|---|---|
| `workspace-github-adapter` | `database/queries/workspaces.sql`, `internal/database/workspaces.sql.go` (regen), `internal/handler/import.go`, handler tests | The endpoint that writes the workspace row — sole owner of the bug. |
| `workflow-backend` | `internal/adapter/rpc_test.go` (and/or `internal/handler/workspace_test.go`) — verification tests only | Defence-in-depth: ensure the session's org reaches the adapter on the wire. No production code change. |

No other repo is touched. `digital-factory-ui`, `management-repo`,
`user-service`, `rag-service`, `git-nexus`, `workflow` are all unaffected.

## Validation and Release Impact

### Testing expectations

- **`workspace-github-adapter`:**
  - Unit tests on `ImportWorkspaceHandler` for: happy path with a valid UUID;
    missing field; empty string; zero UUID; malformed UUID. Each must assert
    no row is written and no sync task is enqueued on the negative branches.
  - Existing tests
    (`webhook_handler_test.go::TestImportWorkspaceHandler_GitHubNotFoundDoesNotPersistPlaceholder`,
    `TestImportWorkspaceHandler_DifferentRepoWithExistingSlugReturnsConflict`)
    must be updated to send `organization_id` in their request bodies.
  - Adapter-level integration / DB test that the inserted row carries the
    expected `organization_id` (use the existing test harness; assert via
    `GetWorkspace` after import).
  - On-conflict test: re-import the same `id` with a *different*
    `organization_id` and assert the row's `organization_id` is **unchanged**.

- **`workflow-backend`:**
  - Update or add `rpc_test.go` to assert the serialised request body
    contains `"organization_id"`.
  - Verify existing handler test that asserts session-based override is still
    green (no code change but it's the canary for the field).

### Migration / config impact

- **No schema change in this feature.** Migrations `00013` and `00014` are
  owned by `m1-identity-and-workspaces`.
- **No env-var change.**
- `sqlc generate` is the only generated-code step.

### Rollout concerns

- Deploy `workspace-github-adapter` carrying this fix **before** migration
  `00014` (NOT NULL) is applied. Recommended order in each environment:
  1. Identity feature deployed (`00013` + `RequireAuth` + T6 seed + `00014`
     in dev/staging; `00014` last in production).
  2. This fix deployed to `workspace-github-adapter`.
  3. `00014` flipped to NOT NULL in production.
- The fix is backward-compatible with `00013`-only (nullable) environments:
  the new code always writes a value, so the migration upgrade to NOT NULL
  is safe.

### Backward compatibility

- The request body becomes **more restrictive** — a caller that previously
  sent no `organization_id` now gets 400. The only such caller is
  `workflow-backend`, which already supplies the field (verified by reading
  `internal/service/workspace.go::ImportWorkspace` and
  `internal/adapter/rpc.go::ImportWorkspace`). No external API surface is
  affected — `/internal/*` is service-internal by name and routing.
- The response gains `organization_id`; existing keys are preserved (additive
  change; UI consumers won't break).

### Deployment / handoff implications

- No human handoff beyond standard PR review.
- No data migration owned by this feature.
- No coordination with downstream services beyond confirming
  `workflow-backend` is on a version that sets `OrganizationID` on every
  import call (the identity feature already shipped this; the verification
  test in T2 is the durable guarantee).
