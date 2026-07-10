# Tasks — `backend-unify-feature-task-id`

## Dependency Diagram

```
T1 (no dependencies)
```

## Index

| ID | Title | Repo | Depends On | Actor |
|---|---|---|---|---|
| T1 | Unify id with feature_id/task_id in CreateWorkspaceFeature and insertGoTask | workflow-backend | | agent |

## T1 — Unify id with feature_id/task_id in CreateWorkspaceFeature and insertGoTask

### Description
Implement the chosen design from the approved technical design (`docs/features/backend-unify-feature-task-id/technical-design.md`, "Chosen Design" section) in `workflow-backend`:

1. **`Reader.CreateWorkspaceFeature`** (`internal/database/queries.go:1063-1103`): the function already generates `fid` (a `pgtype.UUID`) via `fid.Scan(uuid.New().String())` for the `feature_id` column. Add `id` to the `INSERT` column list and pass `fid` as its value too, so both `id` and `feature_id` receive the identical generated UUID in the same statement. No other logic in the function changes — `fid` continues to be used afterward for `featureIDStr := UUIDString(f.FeatureID)` and the activity-event insert exactly as today.

2. **`insertGoTask`** (`internal/database/queries.go:1231-1272`): the function currently omits `task_id` from its `INSERT` column list entirely, letting it take an independent database default from `id`. Generate a single UUID in Go (mirroring the `fid` pattern above — a new local `pgtype.UUID`, e.g. `tid`, via `tid.Scan(uuid.New().String())`), and add `task_id` to the column list so both `id` and `task_id` receive that same generated value in the same `INSERT` statement.

Both changes are additive/logic-only:
- No schema change, no new migration, no column added or removed on `workspace_features` or `workspace_tasks`.
- No change to `RETURNING` column lists, request/response shapes, or API contracts.
- No change to validation/conflict-check logic (`existingTaskNames`, `validateCreateTaskInputs`) or activity-event emission (`insertActivityEventSavepoint`).
- No migration or backfill of existing rows — this only affects rows inserted after this change ships.
- Do not modify `workspace-github-adapter`'s `UpsertWorkspaceTask` (ts-owned task sync path) — it already satisfies `id == task_id` and is explicitly out of scope.

### Required skills
- go-best-practices

### Subtasks
- [ ] In `Reader.CreateWorkspaceFeature`, add `id` to the `INSERT INTO workspace_features` column list and bind it to the existing `fid` value (passed twice: once for `id`, once for `feature_id`).
- [ ] In `insertGoTask`, generate a new UUID (`tid`) the same way `fid` is generated in `CreateWorkspaceFeature`, and add `task_id` to the `INSERT INTO workspace_tasks` column list, binding it to `tid` (passed twice: once for `id`, once for `task_id`).
- [ ] Update `TestCreateWorkspaceFeature_UsesExplicitTransaction` (`internal/database/activity_event_test.go:184-206`) and `TestActivityEvent_CreateWorkspaceFeature_PerCallSite` (`internal/database/activity_event_integration_test.go:294-318`) if either asserts `id != feature_id` — change to assert `id == feature_id` on the returned/persisted row.
- [ ] Add or update a unit/integration test asserting `insertGoTask`'s returned `WorkspaceTask` has `id == task_id`.
- [ ] Review `fakeDBWithFeatureCreate.CreateWorkspaceFeature` (`internal/service/feature_create_test.go:55-80`) and other `CreateWorkspaceFeature` test fakes/mocks (`internal/handler/workspace_test.go:359-371`, `internal/service/workspace_test.go:475-487`, `pkg/testhelpers/fixtures.go:716-728`) — update them to return `id == feature_id` for realism where practical, since they simulate DB behavior for handler/service-level tests.
- [ ] Run the full `workflow-backend` test suite (`go test ./...`) and `golangci-lint run ./...` — zero failures, zero lint errors — before opening the PR, per the repo's pre-push rule.
- [ ] Open a PR titled `feat(backend-unify-feature-task-id/T1): unify id with feature_id/task_id on create` targeting the correct base branch per the rebase-before-PR rule.
