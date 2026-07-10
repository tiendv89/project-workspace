# Technical Design

## Feature
- Feature ID: `backend-unify-feature-task-id`
- Title: `Unify id and feature_id/task_id on feature and task creation`

## Current State
`workflow-backend` owns the `workspace_features` and `workspace_tasks` tables (schema originally introduced in migration `00009_use_uuid_feature_ids_for_tasks_documents_and_activity_events.sql`, with the `feature_id` FK direction later corrected in migration `00016_fix_feature_id_fk.sql` to point at `workspace_features(feature_id)`, the business key, rather than the surrogate `id`). Both tables carry two independently-nullable-looking but always-populated UUID columns:

- `workspace_features.id` (surrogate PK) and `workspace_features.feature_id` (business key, referenced by `workspace_tasks.feature_id`, `workspace_activity_events.feature_id`, etc.)
- `workspace_tasks.id` (surrogate PK) and `workspace_tasks.task_id` (business key, referenced by `workspace_activity_events.task_id`, and used in `GetWorkspaceTaskByID`'s lookup: `WHERE t.workspace_id = $1 AND t.task_id = $2`)

Two Go insert paths in `internal/database/queries.go` create rows in these tables without unifying the two ID columns:

**`Reader.CreateWorkspaceFeature`** (`internal/database/queries.go:1063-1103`), called from `WorkspaceService.CreateFeature` (`internal/service/feature_create.go:162-230`, the Create Feature API handler chain):
```go
var fid pgtype.UUID
if scanErr := fid.Scan(uuid.New().String()); scanErr != nil { ... }
...
const q = `
    INSERT INTO workspace_features
        (workspace_id, feature_id, feature_name, title, feature_status, owner)
    VALUES ($1, $2, $3, $4, 'in_design', $5)
    RETURNING id, workspace_id, feature_id, feature_name, title, feature_status, current_stage, next_action,
              stages, source_path, source_hash, owner, init_pr_url, init_pr_merged, created_at, updated_at`
row := tx.QueryRow(ctx, q, wid, fid, featureName, input.Title, nullableStr(input.Owner))
```
`id` is absent from the column list, so it receives the column's own DB default (`gen_random_uuid()`), independent of the `fid` value generated in Go for `feature_id`. Confirmed via `scanFeature`, which scans `id` and `feature_id` into distinct struct fields with no equality guarantee.

**`insertGoTask`** (`internal/database/queries.go:1231-1272`), called from `Reader.CreateWorkspaceTasks` (the Create Tasks API path for go-owned tasks):
```go
const q = `
    INSERT INTO workspace_tasks
        (workspace_id, feature_id, feature_name, task_name, title, repo, status, depends_on, execution, owner)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'go')
    RETURNING id, workspace_id, feature_id, feature_name, task_id, task_name, title,
              repo, status, depends_on, blocked_reason, branch, execution,
              pr, workspace_pr, source_path, source_hash, owner, created_at, updated_at,
              dispatched_at, conflict_state, blocked_details, blocked_from_status`
```
`task_id` is likewise absent from the column list, taking its own independent DB default separate from `id`'s default.

By contrast, the ts-owned task sync path in `workspace-github-adapter` (`internal/database/workspace_tasks.sql.go`, `UpsertWorkspaceTask`) already generates a single UUID (`task_uuid`) via a `COALESCE(..., gen_random_uuid())` CTE and inserts that same value into both `id` and `task_id` columns in one statement — `id == task_id` always holds for ts tasks today. This divergence between go-owned and ts-owned tasks already caused a confirmed production bug (go-orchestrator task-diff/review-thread view resolving zero rows because a lookup keyed on `task_id` was called with `id` — documented in `docs/features/go-orchestrator-ui-tasks/technical-design.md`).

## Constraints
- No database migration or schema change (per approved product spec Non-goals) — column set, types, and defaults on `workspace_features` and `workspace_tasks` are untouched.
- No backfill of existing rows — this is a forward-only fix affecting only rows inserted after deployment.
- No change to the ts-owned sync path (`workspace-github-adapter`) — it already satisfies the invariant.
- No change to API request/response contracts, `RETURNING` column lists, or client-facing DTOs.
- No change to existing validation/conflict-check logic (`existingTaskNames`, `validateCreateTaskInputs`) or to activity-event emission (`insertActivityEventSavepoint`) call sites or semantics.
- No Figma links in the product spec — no `## Figma` section required; this is a backend-only, non-UI change.

## Options Considered
### Option A — Generate one UUID in Go, pass it explicitly to both columns in the same INSERT
Mirror the pattern `workspace-github-adapter`'s `UpsertWorkspaceTask` already uses: generate a single `uuid.New()` value in Go before the `INSERT`, and add the surrogate column (`id` / omit nothing) to the column list so both columns receive the identical parameter in the same statement.
- Pros: Minimal diff — one new local variable plus one added column + one added placeholder per statement; no schema change; deterministic parity with the already-correct ts path; easy to unit test (assert `id == feature_id` / `id == task_id` on the returned struct).
- Cons: None significant — this is a pure application-code change with no runtime cost beyond one extra UUID generation call already being done today.

### Option B — Database-level default/trigger that copies `feature_id`/`task_id` from `id` (or vice versa) at INSERT time
Add a `BEFORE INSERT` trigger or a generated column expression so Postgres itself keeps `id` and `feature_id`/`task_id` in sync without touching Go code.
- Pros: Centralizes the invariant at the DB layer — any future INSERT path (not just these two) would automatically satisfy it.
- Cons: Requires a migration (explicitly a non-goal), touches schema (explicitly a non-goal), and is unnecessary — only two Go insert paths write these tables from `workflow-backend`, so DB-level enforcement is out of proportion to the fix requested.

### Option C — Application code with two independent `gen_random_uuid()` calls in SQL, string-injected into both columns
Instead of generating the UUID in Go, use SQL-side `gen_random_uuid()` once as a scalar in a `WITH` CTE (matching `workspace-github-adapter`'s CTE style exactly) and reference that CTE value in both columns.
- Pros: Matches the ts-adapter's SQL structure most closely (CTE-based).
- Cons: `workflow-backend`'s Go code already generates the `feature_id`/`fid` value in application code (`uuid.New().String()`) prior to the INSERT — switching to a SQL-side CTE would mean discarding that existing pattern and diverging from how the rest of `workflow-backend`'s insert code is written (e.g. `CreateWorkspace` also generates values in Go, not via CTEs). Introduces unnecessary inconsistency with the surrounding codebase for no functional benefit over Option A.

## Chosen Design
**Option A.** Generate a single UUID in Go for each row and insert it into both the surrogate (`id`) and business-key (`feature_id`/`task_id`) columns in the same `INSERT` statement, exactly mirroring the invariant `workspace-github-adapter`'s `UpsertWorkspaceTask` already establishes for ts tasks.

### `Reader.CreateWorkspaceFeature` (`internal/database/queries.go`)
Change the existing `fid` generation to also be inserted into `id`:
```go
var fid pgtype.UUID
if scanErr := fid.Scan(uuid.New().String()); scanErr != nil {
    return WorkspaceFeature{}, fmt.Errorf("generate feature_id: %w", scanErr)
}
...
const q = `
    INSERT INTO workspace_features
        (id, workspace_id, feature_id, feature_name, title, feature_status, owner)
    VALUES ($1, $2, $3, $4, $5, 'in_design', $6)
    RETURNING id, workspace_id, feature_id, feature_name, title, feature_status, current_stage, next_action,
              stages, source_path, source_hash, owner, init_pr_url, init_pr_merged, created_at, updated_at`
row := tx.QueryRow(ctx, q, fid, wid, fid, featureName, input.Title, nullableStr(input.Owner))
```
`fid` is passed twice — once as `id`, once as `feature_id` — so both columns receive the identical UUID value generated once in Go. No other line in the function changes: the same `fid` is still used afterward for `featureIDStr := UUIDString(f.FeatureID)` and the activity-event insert.

### `insertGoTask` (`internal/database/queries.go`)
Generate a UUID once and insert it into both `id` and `task_id`:
```go
func insertGoTask(ctx context.Context, tx txQuerier, workspaceID, featureID pgtype.UUID, featureName string, t CreateTaskInput) (WorkspaceTask, error) {
    ...
    var tid pgtype.UUID
    if scanErr := tid.Scan(uuid.New().String()); scanErr != nil {
        return WorkspaceTask{}, fmt.Errorf("generate task_id: %w", scanErr)
    }

    const q = `
        INSERT INTO workspace_tasks
            (id, workspace_id, feature_id, feature_name, task_name, title, repo, status, depends_on, execution, task_id, owner)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $1, 'go')
        RETURNING id, workspace_id, feature_id, feature_name, task_id, task_name, title,
                  repo, status, depends_on, blocked_reason, branch, execution,
                  pr, workspace_pr, source_path, source_hash, owner, created_at, updated_at,
                  dispatched_at, conflict_state, blocked_details, blocked_from_status`
    row := tx.QueryRow(ctx, q,
        tid, workspaceID, featureID, featureName,
        strings.TrimSpace(t.Name), strings.TrimSpace(t.Title),
        nullableStr(repo), status,
        dependsOnJSON, executionJSON,
    )
    ...
}
```
Note: `$1` (the generated `tid`) is referenced twice in the `VALUES` clause — once positionally for `id`, once again for `task_id` — so the driver binds the same parameter value to both columns without needing a duplicate argument in the call. (Equivalent alternative: pass `tid` twice as two separate positional args if the query-builder/linter prefers no repeated placeholders — either form produces the same persisted values and is a purely stylistic choice for the implementing task.)

### Invariant established
After this change:
- Every `workspace_features` row created via `CreateWorkspaceFeature` has `id == feature_id`.
- Every `workspace_tasks` row created via `insertGoTask` (go-owned tasks) has `id == task_id`.
- Every `workspace_tasks` row created via `workspace-github-adapter`'s `UpsertWorkspaceTask` (ts-owned tasks) already has `id == task_id` (unchanged, out of scope).
- Rows inserted before this change keep whatever `id`/`feature_id`/`task_id` values they already have (no migration, no backfill).

## Dependency Analysis
- **No new external dependencies.** `uuid.New()` (`github.com/google/uuid`) is already imported and used in `queries.go` for the existing `fid` generation in `CreateWorkspaceFeature`; `insertGoTask` will use the same package, already present in `go.mod`.
- **No FK impact.** The `workspace_tasks.feature_id → workspace_features.feature_id` FK (migration `00016`) is unaffected — `feature_id`'s value origin changes (now equal to `id`) but its type, nullability, and referenced column are untouched.
- **No downstream consumer changes required.** `scanFeature`/`scanTask` (`internal/database/queries.go`) already scan both `id` and `feature_id`/`task_id` as separate struct fields — no scan-shape change. API handlers, DTOs, and the frontend (`digital-factory-ui`) are unaffected since `RETURNING` column sets are unchanged; the API surface (`feature_id`/`task_id` in JSON responses) already exposes the business key today, and will simply now equal the previously-hidden `id` for new rows.
- **Test dependency:** existing unit tests asserting the previous independent-generation behavior must be updated:
  - `TestCreateWorkspaceFeature_UsesExplicitTransaction` (`internal/database/activity_event_test.go:184-206`) and `TestActivityEvent_CreateWorkspaceFeature_PerCallSite` (`internal/database/activity_event_integration_test.go:294-318`) — verify these do not assert `id != feature_id`; if so, update to assert equality.
  - Any test relying on `insertGoTask`'s returned `task_id` being independently generated from `id` should be updated to assert `id == task_id`.
  - `fakeDBWithFeatureCreate.CreateWorkspaceFeature` (`internal/service/feature_create_test.go:55-80`) and other fake/mock implementations of `CreateWorkspaceFeature` used in handler/service tests should continue to return consistent `id`/`feature_id` pairs if they simulate real DB behavior (recommended: update fakes to also set `id == feature_id` for realism, though not strictly required since they are test doubles independent of the real `INSERT`).

## Parallelization / Blocking Analysis
- The two changes (`CreateWorkspaceFeature` and `insertGoTask`) are independent of each other — they touch different functions in the same file (`internal/database/queries.go`) with no shared code path, so they can be implemented and tested in parallel by two different tasks, or combined into a single task since both are small, mechanical, same-file changes.
- No blocking dependency on any other in-flight feature — the migration `00016` FK fix and the `owner`/discriminator columns from migration `00015` are already merged to `main` (confirmed via RAG: `workflow-db` PRs #30, #35).
- Single repo (`workflow-backend`) — per the "one task changes one repo only" rule, this fits in a single task.
- Recommended task breakdown for Phase 2: **one task** covering both function changes (`CreateWorkspaceFeature` and `insertGoTask`), since both are small, mechanical, same-file (`internal/database/queries.go`) edits with no shared code path and no meaningful benefit from splitting review across two PRs. `depends_on: []`.
