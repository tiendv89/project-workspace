# Product Specification

## Feature
- Feature ID: `backend-unify-feature-task-id`
- Title: `Unify id and feature_id/task_id on feature and task creation`

## Problem
In `workflow-backend`, the two create-write paths generate the row's surrogate primary key (`id`) and its business-key identifier (`feature_id` on `workspace_features`, `task_id` on `workspace_tasks`) independently, so the two columns always end up with different UUID values on every new row:

- **`Reader.CreateWorkspaceFeature`** (`internal/database/queries.go:1063-1103`, called from `WorkspaceService.CreateFeature` in `internal/service/feature_create.go:162-230` — the Create Feature API): generates `feature_id` explicitly in Go (`fid.Scan(uuid.New().String())`), but does not include `id` in the `INSERT` column list at all, so `id` takes its own independent database default. Result: `id != feature_id` on every feature row.
- **`insertGoTask`** (`internal/database/queries.go:1231-1272`, called from `Reader.CreateWorkspaceTasks` — the Create Tasks API for go-owned tasks): does not include `task_id` in the `INSERT` column list, so `task_id` takes its own independent database default, separate from `id`'s default. Result: `id != task_id` on every go-owned task row.

This has already caused at least one confirmed production bug: the go-orchestrator task-diff/review-thread view broke because a lookup keyed on the business key `task_id` was called with the surrogate `id`, and the two are never equal for go tasks (documented in `docs/features/go-orchestrator-ui-tasks/technical-design.md`).

By contrast, the ts-owned task sync path (`workspace-github-adapter`'s `UpsertWorkspaceTask`, `internal/database/workspace_tasks.sql.go`) already generates a single UUID (`task_uuid`) and inserts it into both `id` and `task_id` in the same statement:
```sql
WITH task_input AS (
    SELECT COALESCE(
        (SELECT id FROM workspace_tasks WHERE workspace_id = $1 AND feature_id = $2 AND task_name = $4),
        gen_random_uuid()
    ) AS task_uuid
)
INSERT INTO workspace_tasks (id, workspace_id, feature_id, feature_name, task_id, task_name, ...)
SELECT task_uuid, $1, $2, $3, task_uuid, $4, ...
```
`id == task_id` always holds for ts tasks today, by construction. This spec brings the two go-owned Go API paths (`CreateFeature`, `CreateTasks`), both confirmed in repo `workflow-backend` (indexed in GitNexus, `Reader.CreateWorkspaceFeature` at `internal/database/queries.go:1063`, `insertGoTask` at `internal/database/queries.go:1231`), in line with that same pattern.

## Goals
- In `Reader.CreateWorkspaceFeature` (Create Feature API path, `internal/database/queries.go`): generate a single UUID in application code and insert it explicitly into **both** the `id` and `feature_id` columns of the new `workspace_features` row, so `id == feature_id` for every feature created going forward.
- In `insertGoTask` (Create Tasks API path, go-owned tasks, `internal/database/queries.go`): generate a single UUID in application code and insert it explicitly into **both** the `id` and `task_id` columns of the new `workspace_tasks` row, so `id == task_id` for every go-owned task created going forward.
- Preserve all existing behavior of both endpoints otherwise: request/response shapes, `RETURNING` columns, validation, conflict checks (duplicate task names via `existingTaskNames`, `actor_type` validation via `validateCreateTaskInputs`), activity-event emission (`insertActivityEventSavepoint`), and transaction boundaries are unchanged.
- Change is additive/logic-only in application code — no schema change, no new migration, no column added or removed.

## Non-goals
- No database migration and no backfill of existing `workspace_features` or `workspace_tasks` rows where `id != feature_id`/`task_id` today — those rows are left exactly as they are.
- No change to the ts-owned task sync path (`workspace-github-adapter`'s `UpsertWorkspaceTask`) — it already generates one UUID for both `id` and `task_id` and is out of scope.
- No change to any other table's id-generation logic (e.g. `workspaces.id`, `workspace_feature_documents.id`, `workspace_activity_events.id`).
- No change to any foreign key definitions (e.g. the `workspace_tasks.feature_id → workspace_features.feature_id` FK added in migration `00016` is unaffected).
- No change to API request/response contracts, route params, or client-facing DTOs.

## Acceptance Criteria
- A new feature created via the Create Feature API (`WorkspaceService.CreateFeature` → `Reader.CreateWorkspaceFeature`) has `id == feature_id` in the persisted `workspace_features` row.
- A new go-owned task created via the Create Tasks API (`Reader.CreateWorkspaceTasks` → `insertGoTask`) has `id == task_id` in the persisted `workspace_tasks` row.
- Existing rows (created before this change) are untouched — no migration runs against them.
- Existing unit/integration tests for `CreateWorkspaceFeature` and `CreateWorkspaceTasks`/`insertGoTask` (e.g. `TestCreateWorkspaceFeature_UsesExplicitTransaction`, `TestActivityEvent_CreateWorkspaceFeature_PerCallSite`) continue to pass, updated only where they assert on `id` vs `feature_id`/`task_id` being independently generated.
- The ts-owned task sync path is unmodified and continues to produce `id == task_id` as it does today.
