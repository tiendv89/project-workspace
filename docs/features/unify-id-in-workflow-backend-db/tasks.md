## Feature: unify-id-in-workflow-backend-db

### Dependency diagram

```
T1 (workflow-backend: migration 00022 + reconcile + hand-written query updates)
 ├──> T2 (workflow-orchestrator: sqlc schema fix + ~25 query rewrite + FSM code)
 ├──> T3 (workspace-github-adapter: refresh vendored schema.sql + UpsertWorkspaceTask/Feature + syncRunReferenceIDs)
 ├──> T4 (digital-factory-ui: TaskSummary/FeatureSummary + call sites)
 └──> T5 (hermes-agent: _resolve_feature_id_by_name fix)
        │
        ▼
  [Human Verification Phase — deploy + rollout, not tracked as a task; see below]
```

T1 is the sole blocker: it owns the schema authority and the migration that every other
repo's code change is written against. T2–T5 touch four independent repos and have no
code dependency on each other — only a data/schema dependency on T1 having landed
(so they can be implemented and reviewed in parallel once T1's migration file exists,
though the migration should not be *run* against shared environments until all five
code changes are ready to deploy together — see the Human Verification Phase below).

### Index

| ID | Title | Repo | Depends On | Actor |
|---|---|---|---|---|
| T1 | Migration 00022 (unify identity) + workflow-backend query/handler updates | workflow-backend | | agent |
| T2 | workflow-orchestrator: sqlc schema fix + query/FSM rewrite to `id` | workflow-orchestrator | T1 | agent |
| T3 | workspace-github-adapter: refresh vendored `schema.sql` + writer updates to `id` | workspace-github-adapter | T1 | agent |
| T4 | digital-factory-ui: TaskSummary/FeatureSummary + call-site updates | digital-factory-ui | T1 | agent |
| T5 | hermes-agent: fix `_resolve_feature_id_by_name` slug-fallback | hermes-agent | T1 | agent |

---

## T1 — Migration 00022 (unify identity) + workflow-backend query/handler updates

### Description
Author and land the single migration that collapses `workspace_features` and
`workspace_tasks` onto their surrogate `id` column (Option B, per the approved
technical design), and update every `workflow-backend`-owned consumer of the
columns being dropped.

Concretely:
1. **Pre-migration verification queries** — write and run (against a scratch/staging
   copy first, then confirm applicability to prod) the verification queries from the
   design's "Pre-migration verification" section:
   - Internal-duplicate collision guards (`GROUP BY task_id/feature_id HAVING count(*) > 1`).
   - Cross-collision guards (`JOIN ... ON a.task_id = b.id AND a.id != b.id`, and the
     `feature_id` equivalent).
   - Divergence census (`count(*) FILTER (WHERE id != task_id) ... GROUP BY owner`).
   All must return zero rows for the collision guards before the migration is safe to run.
2. **Migration `00022_unify_identity.sql`** (goose, single transaction) — implement exactly
   the six steps in the technical design's "Chosen Design" section:
   1. Drop `workspace_sync_runs`'s surrogate-key FKs (`workspace_sync_runs_feature_id_fkey`,
      `workspace_sync_runs_task_id_fkey`).
   2. Translate `workspace_sync_runs.feature_id`/`.task_id` from surrogate `.id` values to
      business values (join against the not-yet-reconciled `workspace_features`/`workspace_tasks`).
   3. Reconcile: `UPDATE workspace_tasks SET id = task_id WHERE id != task_id;` and the
      `workspace_features` equivalent.
   4. Re-point `workspace_tasks_feature_id_fkey` and `workspace_feature_documents_feature_id_fkey`
      to reference `workspace_features(id)`.
   5. Drop `task_id`/`feature_id` columns and their now-redundant unique constraints
      (`workspace_tasks_workspace_task_id_unique`, `workspace_features_feature_id_key`,
      `workspace_features_workspace_feature_id_unique`).
   6. Re-add `workspace_sync_runs`'s FKs pointing at `id`.
   - Confirm the real constraint names against `\d workspace_features` / `\d workspace_tasks`
     / `\d workspace_sync_runs` / `\d workspace_feature_documents` on a live/staging DB before
     finalizing — the design flags `workspace_feature_documents_feature_id_fkey` specifically
     as needing confirmation.
   - Write the down migration: re-add `task_id`/`feature_id` as
     `uuid NOT NULL DEFAULT gen_random_uuid()`, set them `= id`, restore the unique constraints,
     re-point FKs back to the business columns.
3. **Code updates in `workflow-backend`** (hand-written `internal/database/queries.go`, no sqlc):
   - Move every own-key read/write from `feature_id`/`task_id` to `id` (all `Reader` methods:
     `GetWorkspaceFeature`, `GetFeatureByFeatureID`, `ListWorkspaceFeatures`,
     `SearchWorkspaceFeatures`, `CreateWorkspaceFeature`, `ListFeatureTaskCounts`,
     `GetWorkspaceTask`, `ListFeatureTasks`, `ListWorkspaceTasks`, `CreateWorkspaceTasks`/
     `insertGoTask`, `UnblockTask`, `RecoverTask`, `UpdateFeatureStage`, `ActivateReadyTasks`,
     `GetHandoffForFeature`, etc. — grep every `feature_id`/`task_id` column reference).
   - `insertGoTask`: drop the now-unnecessary omission workaround — `task_id` no longer exists,
     so the INSERT column list naturally shrinks; no divergence is possible going forward.
   - Rename `GetWorkspaceTaskByID` (its query genuinely keys on `id` now — the misleading name
     from when it secretly matched on `task_id` is resolved).
   - Update handler DTOs/response shapes (`internal/handler/*.go`) that currently serialize
     `task_id`/`feature_id` as JSON field names — change to `id`. This is the API surface change
     that T2–T5 depend on.
   - Update `scanFeature`/`scanTask` column lists to match the new schema.
4. Run `go test ./...` and `golangci-lint run` — zero errors required per workspace rules.
5. Update `database/workspace/schema.dbml` (management repo) to v006 reflecting the new
   single-`id` shape — flag this as a follow-up note in the PR description if it's out of
   scope for this task's repo (schema.dbml lives in `project-workspace`, not `workflow-backend`);
   do not write to another repo from this task.

### Required skills
- go-best-practices

### Subtasks
- [ ] Write and run pre-migration verification queries against a staging copy of the DB; confirm zero collisions
- [ ] Write `00022_unify_identity.sql` up migration (6 steps) with confirmed real constraint names
- [ ] Write the down migration restoring `task_id`/`feature_id` with `id == task_id`/`id == feature_id` invariant
- [ ] Update all `Reader` methods in `queries.go` to read/write `id` instead of `feature_id`/`task_id`
- [ ] Rename `GetWorkspaceTaskByID`; update `scanFeature`/`scanTask` column lists
- [ ] Update handler DTOs to serialize `id` instead of `task_id`/`feature_id`
- [ ] `go test ./...` and `golangci-lint run` clean
- [ ] Note the `database/workspace/schema.dbml` v006 update as a follow-up (do not edit `project-workspace` from this task)

---

## T2 — workflow-orchestrator: sqlc schema fix + query/FSM rewrite to `id`

### Description
Update `workflow-orchestrator`'s entire task/feature FSM to key on `id` instead of
`task_id`/`feature_id`, and fix its stale local sqlc schema copy.

1. **Fix the stale schema mirror**: `db/schema/schema.sql` still declares
   `feature_id ... REFERENCES workspace_features(id)` (pre-00016) — update it to match the
   post-00022 shape (single `id` column on each table, FKs pointing at `id`).
2. **Rewrite all ~25 production queries** in `db/queries/tasks.sql` (and any feature-level
   queries) from `WHERE task_id = $N` / `WHERE feature_id = $N` (own-key usage) to
   `WHERE id = $N`. This includes at minimum: `AdvanceTaskToReadyIfTodo`,
   `BlockTaskReviewIncompleteExceeded`, `BumpReenqueueAttempts`, `CountInFlight`,
   `FindAutoReadyCandidates`, `FindConflictedTasks`, `GetDistinctTaskRepos`,
   `GetMaxTurnsRetryCount`, `GetTaskByUUID`, `GetTaskRebaseAttemptsStatus`,
   `GetTaskStatusByName`, `GuardedUpdateTaskStatus`, `InitialAutoReady`, `InsertTask`,
   `ListChangeRequestedTasksForOwner`, `ListEligibleTasks`,
   `ListInProgressAndReviewingForOwner`, `ListInReviewTasksForOwner`,
   `ListMergeablePRTasksForOwner`, `ListReviewableTasksForOwner`, `ListTasksByFeature`,
   `LookupTaskBySlug`, `MarkTaskRebaseRetry`, `RollbackTaskResolving`, `SetTaskConflicted`,
   `SetTaskDoneFromInReview`, `SetTaskDoneFromMergedPR`, `SetTaskReadyFromMaxTurns`,
   `SetTaskResolved`, `SetTaskResolving`, `SetTaskReviewIncomplete`,
   `SetTaskReviewIncompleteIfUnderMax`, `TouchDispatchedAt`, and the `handoffs.sql`
   queries referencing `feature_id`.
   - Note: parent-reference columns that point at a *different* table's row (e.g. a task's
     `feature_id` referencing `workspace_features.id`) are NOT own-key usage and keep their
     current column name — only the *own* identity column changes name/semantics.
3. **Convert `FindConflictedTasks`'s `SELECT *`** (`db/queries/tasks.sql:375`) to an explicit
   column list before regenerating — sqlc expands `*` against the schema file at generate time,
   so a stale expansion would silently reference a dropped column.
4. Run `sqlc generate` against the corrected schema file.
5. Update `internal/orchestrator/*.go` call sites: struct field references change from
   `.TaskID`/`.FeatureID` (for the task/feature's *own* identity) to `.ID`; parent-reference
   fields (e.g. a task row's reference to its owning feature) keep whatever field name the
   regenerated struct assigns to the surviving reference column.
6. Verify `test/e2e/coexistence_test.go` (`TestCoexistence`, `TestFullAutonomousPath`,
   `TestUnblockChain`) passes against the new schema — this is called out in the design as
   the highest-value regression suite for this change.
7. Run `go test ./...` and `golangci-lint run` — zero errors required.

### Required skills
- go-best-practices

### Subtasks
- [ ] Update `db/schema/schema.sql` to the post-00022 single-`id` shape
- [ ] Convert `FindConflictedTasks`'s `SELECT *` to an explicit column list
- [ ] Rewrite all ~25 `tasks.sql`/`handoffs.sql` queries' own-key filters from `task_id`/`feature_id` to `id`
- [ ] Run `sqlc generate`; fix any resulting compile errors in `internal/orchestrator/*.go`
- [ ] Run and confirm green: `test/e2e/coexistence_test.go` (`TestCoexistence`, `TestFullAutonomousPath`, `TestUnblockChain`)
- [ ] `go test ./...` and `golangci-lint run` clean

---

## T3 — workspace-github-adapter: refresh vendored `schema.sql` + writer updates to `id`

### Description
Update the YAML→DB sync adapter's writers to the new single-`id` schema, and refresh its
vendored schema snapshot.

`workspace-github-adapter` carries a **vendored, consolidated schema snapshot** at
`database/schema/schema.sql` (produced via `pg_dump --schema-only` against
`workflow-backend`'s applied migrations, not a live pointer at the migrations directory),
with `sqlc.yaml` pointing `schema: "database/schema"` at it. Confirmed current contents
(pre-00022) show the dual-column shape on both tables and `workspace_sync_runs`'s FKs
pointing at the surrogate `workspace_features(id)` / `workspace_tasks(id)` — consistent
with the rest of this feature's findings.

1. **Refresh `database/schema/schema.sql`** per the file's own documented procedure (its
   header comment): apply `workflow-backend`'s migrations (including `00022`) to a scratch
   Postgres via `goose -dir <path-to-migrations> postgres "<dsn>" up`, then
   `pg_dump --schema-only --no-owner --no-privileges -T goose_db_version` against that
   database, and replace this file's body with the output. The refreshed snapshot must show:
   single `id` PK on `workspace_features`/`workspace_tasks` (no more `feature_id`/`task_id`
   columns), `workspace_tasks_feature_id_fkey`/`workspace_feature_documents_feature_id_fkey`
   pointing at `workspace_features(id)`, and `workspace_sync_runs_{feature,task}_id_fkey`
   pointing at `workspace_features(id)`/`workspace_tasks(id)` (already the surrogate-`id`
   convention pre-migration, but confirm those FKs still resolve correctly against the
   post-reconcile values).
2. **Update `database/queries/*.sql`** for the changed columns per the same refresh
   procedure, in particular:
   - `UpsertWorkspaceTask` (`workspace_tasks.sql`) and the equivalent features upsert
     (`workspace_features.sql` / `UpsertWorkspaceFeature`): these currently resolve one UUID
     and insert it into both `id` and `task_id`/`feature_id`. Post-migration there is only
     `id` to write — update the SQL source and there is no remaining divergence risk to guard
     against (this repo's ts/legacy path was already the "safe" side of the original bug).
3. **`syncRunReferenceIDs`** (`internal/worker/workspace_sync.go:438-468`) — this function
   currently explicitly resolves and returns `feature.ID`/`task.ID` (the surrogate) for
   writing into `workspace_sync_runs.feature_id`/`.task_id`. Confirmed as the **only live,
   non-test consumer of the surrogate `id`** across all repos prior to this migration. Since
   `id` is now the sole identity column (holding what used to be the business value after
   the T1 reconcile step), this function's *existing* behavior of returning `.ID` continues
   to work correctly post-migration with no logic change — but update its comment
   (currently: `"sync_runs.feature_id FKs workspace_features.id (the surrogate), so the
   returned reference is feature.ID..."`) since that comment's premise (a surrogate vs.
   business distinction) no longer exists after T1. Add/update a test confirming
   `workspace_sync_runs` rows continue to resolve correctly against the new schema.
4. Run `make sqlc` (or `sqlc generate` directly, per the schema header's documented refresh
   steps); fix any resulting compile errors in `internal/adapter/db` and related callers.
5. Run `go test ./...` and `golangci-lint run` — zero errors required.

### Required skills
- go-best-practices

### Subtasks
- [ ] Refresh `database/schema/schema.sql` via the documented `goose up` + `pg_dump --schema-only` procedure against migration 00022
- [ ] Update `workspace_tasks.sql` / `workspace_features.sql` (UpsertWorkspaceTask + features equivalent) for the single-`id` shape
- [ ] Run `make sqlc`/`sqlc generate`; fix compile errors in `internal/adapter/db/adapter.go` and related callers
- [ ] Update `syncRunReferenceIDs`'s comment in `internal/worker/workspace_sync.go` to remove the stale surrogate/business distinction
- [ ] Add/update a test confirming `workspace_sync_runs.feature_id`/`.task_id` resolve correctly post-migration
- [ ] `go test ./...` and `golangci-lint run` clean

---

## T4 — digital-factory-ui: TaskSummary/FeatureSummary + call-site updates

### Description
Update the frontend's type shapes and every call site that reads `task_id`/`feature_id`
off workflow-backend API responses, now that the field is named `id`.

1. **`src/services/workflow-backend/types.ts`**: `TaskSummary` and `FeatureSummary` currently
   declare both `id` and `task_id`/`feature_id` as separate fields. Drop `task_id`/`feature_id`;
   `id` becomes the sole identifier field.
2. **Call sites** (confirmed in the design/prior investigation):
   - `TaskDiffTab` (`src/components/features/task-diff-tab.tsx`) — currently calls
     `useTaskDiff(..., task.id, ...)`; this becomes correct-by-construction (no change needed
     to *which* field it reads, since `task.id` is now the only field), but verify no other
     code path in this file reads `task.task_id`.
   - `useTaskReviewThread` (`src/hooks/tasks/use-task-review-thread.ts`) — same pattern check.
   - `SpecPanel` — currently renders `task.task_id?.toUpperCase()` as the task's displayed
     label; change to `task.id?.toUpperCase()`.
   - `board-meta.ts` (`toFeatureRows`, `FEATURE_COLUMNS`) — check for any `feature_id`/`task_id`
     field access and update to `id`.
   - `src/services/workflow-backend/client.ts` — route builders that construct URLs like
     `GET /api/workspaces/:workspaceId/tasks/:taskId/diff` using `task.id`/`task.task_id` —
     confirm they now uniformly use `.id`.
   - `src/utils/workspaces/workspace-adapter.ts` (`adaptTaskSummariesToFeatures`,
     `adaptFeatureWithTasksToFeatures`) — check for dual-field handling that can now collapse
     to just `.id`.
3. Grep the full `src/` tree for `.task_id` and `.feature_id` accesses on any object typed as
   `TaskSummary`/`FeatureSummary` (or their derived types) to catch any call site not listed
   above.
4. Run the full test suite and lint (`npm test` / project's configured runner, and
   `eslint`) — zero errors required.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Update `TaskSummary`/`FeatureSummary` types: drop `task_id`/`feature_id`, keep only `id`
- [ ] Update `SpecPanel` to render `task.id?.toUpperCase()`
- [ ] Grep and fix all remaining `.task_id`/`.feature_id` accesses on `TaskSummary`/`FeatureSummary`-typed values across `src/`
- [ ] Verify `TaskDiffTab` / `useTaskReviewThread` / route builders in `client.ts` are correct under the single-`id` shape
- [ ] Run full test suite and lint clean

---

## T5 — hermes-agent: fix `_resolve_feature_id_by_name` slug-fallback

### Description
Fix the one confirmed `hermes-agent` consumer of the `feature_id` response field name that
breaks once workflow-backend's API returns `id` instead.

1. **`src/services/workflow_backend_client.py`**, function `_resolve_feature_id_by_name`
   (used by `get_feature_detail`'s slug-fallback path): change
   `items[0]["feature_id"] if items else None` to `items[0]["id"] if items else None`.
2. Confirm both live call sites still function correctly end-to-end:
   - `plugins/tools/approve.py` (`approve_feature` tool, `handle()` → `get_feature_detail`).
   - `plugins/tools/create_tasks.py` (`create_tasks` backup command,
     `load_feature_tasks_md()` → `get_feature_detail`).
3. Grep `src/services/workflow_backend_client.py` and the rest of `plugins/tools/` for any
   other `["feature_id"]` or `["task_id"]` dict-key access against a workflow-backend API
   response (not a locally-constructed request payload — e.g. `create_feature_tasks`'s
   outbound `{"tasks": [{"id": "T1", ...}]}` body is a *request* payload and is unaffected)
   to confirm no other consumer was missed.
4. Add/update a unit test exercising `_resolve_feature_id_by_name` against a mocked response
   shaped like the new API (`{"items": [{"id": "...", ...}]}`).
5. Run the project's test suite and lint — zero errors required.

### Required skills
- python-best-practices

### Subtasks
- [ ] Change `_resolve_feature_id_by_name` to read `items[0]["id"]`
- [ ] Confirm `approve.py` and `create_tasks.py` call sites work against the new field name
- [ ] Grep for any other `["feature_id"]`/`["task_id"]` response-key access in `src/services/workflow_backend_client.py` and `plugins/tools/`
- [ ] Add/update a unit test for `_resolve_feature_id_by_name` against the new response shape
- [ ] Run test suite and lint clean

---

## Human Verification Phase (not a tracked task)

This feature's actual rollout — applying migration `00022` and cutting over all five
services — is deliberately **not** represented as a task in the Index above and will not
be created in the database. It is a manual, human-executed operational phase that runs
after T1–T5 are all merged, per the technical design's "Deployment sequence" and
"Backup & rollback" sections:

1. **Pre-stage all five images** (`workflow-backend`, `workflow-orchestrator`,
   `workspace-github-adapter`, `digital-factory-ui`, `hermes-agent`) with the T1–T5 code
   changes built and pushed to the registry.
2. **Backup**: full `pg_dump` off-host (`docker exec ... pg_dump -Fc`, then `docker cp` off
   the container), with writers quiesced. Verify the dump (exit code/size; ideally restore
   into a scratch DB).
3. **Swap the `workflow-backend` image first, alone.** Its startup runs migration `00022`.
   Wait for healthy status — schema flipped and reconciled.
4. **Then swap `workspace-github-adapter`, `digital-factory-ui`, `workflow-orchestrator`,
   and `hermes-agent`** — order among these four does not matter for correctness. Minimize
   the interval between step 3 and this step (old code does not tolerate the new schema).
5. **Post-deploy verification**:
   - `workflow-orchestrator` e2e (`coexistence_test.go`) green on the new build.
   - `rg -ni 'select \*\s+from\s+workspace_(tasks|features)'` returns empty across the three
     Go repos.
   - One full orchestrator poll cycle and one sync cycle complete without error.
   - Confirm `workspace_sync_runs` rows written post-deploy resolve correctly.
6. **Update `database/workspace/schema.dbml`** (management repo, `project-workspace`) to v006
   reflecting the new schema, and trigger a GitNexus re-index once all five repos' code
   changes are merged.
7. **If anything goes wrong**: restore per the rollback runbook (`pg_restore --clean
   --if-exists` from the pre-migration dump, then start the OLD images back up).

This phase is monitored manually by a human operator and intentionally has no corresponding
task file, status, or lifecycle tracking — it is operational execution of an already-approved
plan, not a unit of implementation work.
