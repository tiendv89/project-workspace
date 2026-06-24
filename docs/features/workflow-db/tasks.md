# Tasks — `workflow-db`

**Feature status**: `in_tdd` | **Stage**: `tasks` (awaiting human approval)
Machine state (status, log, PR, branch) lives in `tasks/T<n>.yaml`. This document is narrative only — agents tick subtasks here and do not modify task YAML structure.
Technical design: `docs/features/workflow-db/technical-design.md` (approved 2026-06-24).

---

## Index

| ID | Wave | Title | Repo | Depends on |
|---|---|---|---|---|
| T1 | 1 | Schema migration (`00015_*_owner`) | `workflow-backend` | — |
| T3 | 1 | Broker owner-partitioning + TS declares `owner='ts'` | `workflow` | — |
| T4 | 1 | TS orchestrator owner guards | `workflow` | — |
| T17b | 1 | `start-implementation` owner-gate | `workflow` | — |
| T2 | 2 | Sync adapter: scope to `owner IS NULL` | `workspace-github-adapter` | T1 |
| T5 | 2 | DB access layer (pgx/sqlc setup) | `workflow-orchestrator` | T1 |
| T16 | 2 | `init-feature` owner-aware | `workflow` | T4 |
| T6 | 3 | Feature/task creation + materializer/seed | `workflow-orchestrator` | T5 |
| T7 | 3 | Eligibility scan | `workflow-orchestrator` | T5 |
| T8 | 3 | Atomic claim | `workflow-orchestrator` | T5 |
| T9 | 3 | Status transitions + activity log | `workflow-orchestrator` | T5 |
| T11 | 3 | Dispatch | `workflow-orchestrator` | T5, T3 |
| T10 | 4 | Dependency auto-ready | `workflow-orchestrator` | T9 |
| T12 | 4 | Reap | `workflow-orchestrator` | T11, T9 |
| T13 | 4 | PR-merge poll | `workflow-orchestrator` | T9, T6 |
| T15 | 4 | Read API: verify go-owned rows + optional owner DTO | `workflow-backend` | T1, T6 |
| T17 | 4 | `tech-lead` owner-aware | `workflow` | T4, T6 |
| T14 | 5 | Orchestration loop | `workflow-orchestrator` | T7, T8, T9, T10, T11, T12, T13 |
| T18 | 6 | E2E coexistence test | `workflow-orchestrator` | T2, T4, T14, T15 |
| T24 | 1 | DB layer: `CreateWorkspaceTasks` (bulk, all-or-nothing) | `workflow-backend` | — |
| T25 | 1 | Features API: `?name=` exact-match filter | `workflow-backend` | — |
| T28 | 1 | `workflow-mcp` scaffold (TS, stdio) | `workflow-mcp` | — |
| T34 | 1 | `tech-lead`: drop Materialization (go) block | `workflow` | — |
| T35 | 1 | Orchestrator: remove `create.go` + `cmd/seed` | `workflow-orchestrator` | — |
| T36 | 1 | `approve-feature`: go-mode create-tasks guide | `workflow` | — |
| T26 | 2 | Task-create endpoint (bulk, all-or-nothing) | `workflow-backend` | T24 |
| T32 | 2 | `install.sh`: clone+build+register `workflow-mcp` | `workflow` | T28 |
| T27 | 3 | BFF: verify proxy + passthrough test | `workflow-bff` | T26, T25 |
| T29 | 4 | `workflow-mcp` auth (session cookie) | `workflow-mcp` | T28, T27 |
| T30 | 5 | `workflow-mcp` tools: `get_feature` + `create_tasks` | `workflow-mcp` | T28, T29, T26, T25 |
| T31 | 6 | `workflow-mcp` E2E | `workflow-mcp` | T30 |
| T33 | 6 | `create-tasks` skill (go mode) | `workflow` | T30, T32 |

---

## T1 — Schema migration (`00015_*_owner`)

### Description

Add a new goose migration `workflow-backend/migrations/00015_YYYYMMDD_owner.sql` that implements the `database/workspace/v003` snapshot already published in the management repo at `database/workspace/v003/schema.dbml`.

The migration is purely additive (nullable columns, relaxed constraints, new indexes) and safe for the running read API and adapter.

**Exact SQL to write:**

```sql
-- +goose Up
ALTER TABLE workspace_features ADD COLUMN owner TEXT;
ALTER TABLE workspace_features ALTER COLUMN source_path DROP NOT NULL;
CREATE INDEX IF NOT EXISTS workspace_features_owner_idx
    ON workspace_features (workspace_id, owner);

ALTER TABLE workspace_tasks ADD COLUMN owner TEXT;
ALTER TABLE workspace_tasks ALTER COLUMN source_path DROP NOT NULL;
CREATE INDEX IF NOT EXISTS workspace_tasks_owner_status_idx
    ON workspace_tasks (workspace_id, owner, status);

-- +goose Down
-- Rollback contract (destructive): owner='go' rows are DB-native and carry
-- source_path = NULL by design, so they cannot survive re-imposing NOT NULL.
-- Purge them (tasks before features, to respect the FK order) before restoring
-- the legacy-only schema. A rollback therefore DISCARDS all DB-native (go)
-- workflow state — which by definition has no git/YAML representation to restore
-- from. Do not roll back with live go features in flight.
DROP INDEX IF EXISTS workspace_tasks_owner_status_idx;
DELETE FROM workspace_tasks WHERE owner = 'go';
ALTER TABLE workspace_tasks ALTER COLUMN source_path SET NOT NULL;
ALTER TABLE workspace_tasks DROP COLUMN IF EXISTS owner;

DROP INDEX IF EXISTS workspace_features_owner_idx;
DELETE FROM workspace_features WHERE owner = 'go';
ALTER TABLE workspace_features ALTER COLUMN source_path SET NOT NULL;
ALTER TABLE workspace_features DROP COLUMN IF EXISTS owner;
```

Confirm the next filename sequence by listing `workflow-backend/migrations/` — use whatever `00015_*` name follows the convention already in use.

> **The Up is purely additive and safe; the Down is destructive.** The down
> migration purges `owner='go'` rows because they have no git/YAML source to be
> restored from and cannot satisfy the re-imposed `source_path NOT NULL`. This is
> the deliberate rollback contract, not an oversight — see the SQL comment above.

**Verification**: the post-migration schema must match `database/workspace/v003/schema.dbml` for all altered tables (`workspace_features`, `workspace_tasks`). Run `goose up` and `goose down` against a scratch Postgres **seeded with at least one `owner='go'` row** — the down must succeed (purging the go row) and leave the legacy schema intact. Confirm the existing `workflow-backend` test suite passes.

### Required skills
- `postgres-best-practices`
- `backend-engineer`

### Subtasks
- [ ] Inspect `workflow-backend/migrations/` for exact next filename (confirm `00015_*` is available)
- [ ] Write `00015_*_owner.sql` with Up and Down sections above
- [ ] Run `goose up` against a scratch Postgres — zero errors
- [ ] Run `goose down` — reverts cleanly
- [ ] Confirm `workspace_features` and `workspace_tasks` column/index state matches `database/workspace/v003/schema.dbml`
- [ ] Run existing `workflow-backend` test suite — all pass

---

## T2 — Sync adapter: scope to `owner IS NULL`

### Description

The YAML→DB sync adapter (`workspace-github-adapter`) currently reconciles all rows indiscriminately — its bulk-delete queries remove any row not found in the YAML source. After T1 adds the `owner` column, the adapter must be scoped so it never creates, updates, or deletes a `'go'`-owned row.

**Files to change:**

`workspace-github-adapter/database/queries/workspace_features.sql` — add `AND (owner IS NULL OR owner = '')` to the `WHERE` clause of `DeleteWorkspaceFeaturesNotIn` and any other bulk-delete or upsert query that targets `workspace_features` without an owner filter.

`workspace-github-adapter/database/queries/workspace_tasks.sql` — same pattern for `DeleteWorkspaceTasksNotIn` and any equivalent task-scoped query.

`workspace-github-adapter/internal/adapter/db/adapter.go` — ensure all upsert paths either write `owner = NULL` explicitly (for new rows being synced from YAML) or leave an existing `owner` value untouched using `ON CONFLICT ... DO UPDATE SET owner = EXCLUDED.owner` where `EXCLUDED.owner IS NULL` (i.e. do not overwrite a `'go'` `owner` with NULL on upsert).

After query changes, run `sqlc generate` from the adapter root and commit the regenerated Go code.

**Verification**: seed one `owner='go'` feature + tasks in the shared DB, run a full sync cycle, assert those rows are unchanged. Legacy (`owner IS NULL`) rows must still reconcile normally.

### Required skills
- `go-best-practices`
- `postgres-best-practices`

### Subtasks
- [ ] Locate all bulk-delete SQL queries in `database/queries/` that target `workspace_features` and `workspace_tasks` without owner filter
- [ ] Add `AND (owner IS NULL OR owner = '')` to each delete query
- [ ] Audit upsert paths in `internal/adapter/db/adapter.go` — ensure they write `owner = NULL` and do not overwrite non-null `owner`
- [ ] Run `sqlc generate` — regenerated Go compiles without errors
- [ ] Write test: seed `owner='go'` feature/tasks, run sync, assert rows unchanged
- [ ] Write test: legacy feature is still reconciled correctly after the change
- [ ] Full adapter test suite passes

---

## T3 — Broker owner-partitioning + TS declares `owner='ts'`

### Description

The completion broker currently drains completions from a single `broker:pending` queue. Any orchestrator can drain any completion, which is unsafe when two orchestrators co-exist. This task partitions completions by `owner` using separate Redis keys (`broker:pending:go`, `broker:pending:ts`) while preserving the legacy queue for absent-owner clients.

**Files to change (all in `agent-workflow`):**

`runtime/broker/internal/store/store.go` (lines 57–88) — extend the `Store` interface with owner-aware methods, and update the Redis adapter:
- `Register` gains an optional `owner string` field; records it alongside the handle.
- `/callback` handler: when `owner` is non-empty, enqueue into `broker:pending:<owner>`; otherwise use the legacy `broker:pending`.
- `/list-completed` handler: read from `broker:pending:<owner>` when `owner` is supplied; fall back to legacy `broker:pending` for absent `owner`.

`runtime/broker/internal/server/server.go` (handlers for `/register`, `/callback`, `/list-completed`) — wire the store changes through the HTTP handlers, adding `owner` as an optional JSON field.

`runtime/orchestrator/src/loop/http-broker-adapter.ts` (or equivalent broker client) — add `owner: 'ts'` to all `register` and `list-completed` calls so TS completions land in and are drained from `broker:pending:ts`.

**Verification** (per technical design §8, T3):
- A `go`-owner callback lands only in `broker:pending:go`.
- A `ts`-owner callback lands only in `broker:pending:ts`.
- An absent-owner callback degrades to legacy `broker:pending`.
- `list-completed?owner=go` returns only go completions.
- TS orchestrator unit test: declares `owner='ts'`, still drives a legacy feature unchanged.

### Required skills
- `go-best-practices`
- `typescript-best-practices`

### Subtasks
- [ ] Locate exact `Store` interface and Redis adapter in `runtime/broker/internal/store/store.go:57-88`
- [ ] Add optional `owner` field to `/register` JSON body and `store.Register`
- [ ] Update `/callback` to enqueue into `broker:pending:<owner>` (or legacy key when absent)
- [ ] Update `/list-completed` to read from owner-specific queue with absent-owner fallback
- [ ] Update TS `HttpBrokerAdapter` to declare `owner: 'ts'` on all broker calls
- [ ] Broker unit test: go callback → go queue only; ts callback → ts queue only
- [ ] Absent-owner degradation test: maps to legacy queue
- [ ] TS orchestrator test: declares `owner='ts'`, legacy feature unaffected

---

## T4 — TS orchestrator owner guards

### Description

Three feature-level loops in the TS orchestrator scan `docs/features/*/status.yaml` and act on `feature_status` without checking the feature owner. A go feature's git `status.yaml` is frozen at authoring (live state lives in the DB), so these loops would wrongly create branches, trigger drift detection, and post Slack notifications for go features. This task adds `owner !== 'go'` guards to each affected loop.

**Files to change (all in `agent-workflow`):**

**4a — owner field extraction (prerequisite for all other subtasks):**
In the code path that parses `status.yaml` into a feature object (e.g. `runtime/orchestrator/src/features/feature-loader.ts` or equivalent), extract the `owner` field. Document the convention: absent `owner` = `ts` (never assume `go`). This is the unblocking subtask for T16.

**4b — `runtime/orchestrator/src/feature/lifecycle-manager.ts:419`:**
Add `if (feature.owner === 'go') continue;` (or early return) immediately before the `BRANCH_ELIGIBLE` check. Effect: no branch creation, no `status.yaml` write for go features.

**4c — `runtime/orchestrator/src/feature/review-cycle.ts:476`:**
Add `if (feature.owner === 'go') continue;` before the drift-detection / rebase / escalation block.

**4d — `runtime/orchestrator/src/feature/notification-watcher.ts:225`:**
Add `if (feature.owner === 'go') continue;` before the Slack `feature_start` / status-change notification code.

**4e — defensive guards:**
Add `if (feature.owner === 'go') continue;` for explicitness in `runtime/orchestrator/src/feature/check-tasks-done.ts` and `runtime/orchestrator/src/feature/handle-done.ts`.

**Verification** (per technical design §8, T4):
- A feature with `owner: go` in `status.yaml` is skipped by each of `lifecycle-manager`, `review-cycle`, `notification-watcher` — no branch created, no drift action, no Slack post. One unit test per loop.
- A feature with no `owner` (legacy) is still acted upon unchanged.

### Required skills
- `typescript-best-practices`

### Subtasks
- [ ] 4a: Locate status.yaml parsing path; extract `owner` field into feature object type; document absent-owner = ts convention
- [ ] 4b: Add `owner === 'go'` guard at `lifecycle-manager.ts:419`
- [ ] 4c: Add `owner === 'go'` guard at `review-cycle.ts:476`
- [ ] 4d: Add `owner === 'go'` guard at `notification-watcher.ts:225`
- [ ] 4e: Add defensive guards in `check-tasks-done.ts` and `handle-done.ts`
- [ ] Unit test for lifecycle-manager: go feature is skipped (no branch created, no status.yaml write)
- [ ] Unit test for review-cycle: go feature is skipped (no drift action)
- [ ] Unit test for notification-watcher: go feature is skipped (no Slack post)
- [ ] Regression: legacy feature (absent owner) unchanged across all loops

---

## T5 — DB access layer (pgx/sqlc setup)

### Description

Initialize the Go module for `workflow-orchestrator` and set up the database access layer using pgx/v5 and sqlc. This task is the root dependency for all other Go orchestrator tasks (T6–T14).

**Files to create (`workflow-orchestrator` repo):**

`go.mod` / `go.sum` — new Go module `github.com/tiendv89/workflow-orchestrator`; add `github.com/jackc/pgx/v5`, `github.com/sqlc-dev/sqlc` (as a toolchain dep), `github.com/rs/zerolog` (structured logging), and `github.com/pressly/goose/v3` (consumed as a library for schema inspection).

`internal/config/config.go` — read from environment: `DATABASE_URL`, `WORKSPACE_ID` (UUID), `ORGANIZATION_ID` (UUID), `BROKER_URL`, `GITHUB_TOKEN`, `POLL_INTERVAL_SECONDS` (default 15).

`internal/database/db.go` — `Open(ctx, databaseURL string) (*pgxpool.Pool, error)` wrapping `pgxpool.New`; expose `Close()`.

`internal/database/queries/` — sqlc query files targeting the `workflow-backend` migration schema (through `00015`). Minimum queries needed: `GetFeatureByName`, `GetTaskByUUID`, `ListEligibleTasks` (used by T7), `InsertFeature`, `InsertTask`, `GuardedUpdateTaskStatus`. Point `sqlc.yaml` at a local copy of the `workflow-backend` migrations dir (or a checked-in schema snapshot).

`sqlc.yaml` — configure sqlc to generate into `internal/database/queries/`, targeting Postgres.

**Verification:**
- `go build ./...` succeeds.
- `sqlc generate` succeeds without errors or warnings.
- Integration test (or `TestMain`): connect to a local Postgres via `DATABASE_URL`, run `SELECT 1`, assert success.

### Required skills
- `go-best-practices`
- `postgres-best-practices`

### Subtasks
- [ ] Initialize `go.mod` with module path and required dependencies
- [ ] Write `internal/config/config.go` — parse all required env vars with clear error messages for missing required ones
- [ ] Write `internal/database/db.go` — pgx connection pool with `Open` / `Close`
- [ ] Write `sqlc.yaml` pointing at migration schema
- [ ] Write minimum sqlc queries needed by T6–T14 (see list above)
- [ ] Run `sqlc generate` — zero errors/warnings
- [ ] Run `go build ./...` — clean build
- [ ] Integration test: connect + `SELECT 1` passes against local Postgres

---

## T6 — Feature/task creation + materializer/seed

### Description

Implement the Go orchestrator's feature and task creation path, plus a CLI seed tool the v1 integration test (T18) will use to insert a go feature directly into the DB.

**Files to create (`workflow-orchestrator`):**

`internal/orchestrator/create.go`:
- `CreateFeature(ctx context.Context, pool *pgxpool.Pool, spec GoFeatureSpec) (uuid.UUID, error)` — inserts into `workspace_features` with `owner='go'`, `source_path=NULL`, `feature_name=spec.Slug`, `workspace_id=spec.WorkspaceID`, `organization_id=spec.OrgID`. Returns the auto-generated `feature_id` UUID.
- `CreateTask(ctx, pool, featureUUID uuid.UUID, t GoTaskSpec) (uuid.UUID, error)` — inserts into `workspace_tasks` with `owner='go'`, `feature_id=featureUUID`, `feature_name=spec.FeatureSlug`, `task_name=t.Name` (e.g. `T1`), `status='todo'`, `depends_on=t.DependsOn` (JSON array of task_name slugs), `source_path=NULL`.
- `MaterializeFeature(ctx, pool, spec GoFeatureSpec) error` — calls `CreateFeature` then `CreateTask` × len(spec.Tasks); then calls `InitialAutoReady` (see below) to seed `status='ready'` for tasks with empty `depends_on`.
- `InitialAutoReady(ctx, pool, workspaceID, featureUUID uuid.UUID) error` — `UPDATE workspace_tasks SET status='ready' WHERE feature_id=$fid AND depends_on='[]'::jsonb AND status='todo'`.

`cmd/seed/main.go` — CLI that reads a JSON fixture file and calls `MaterializeFeature`. The fixture schema:
```json
{
  "workspace_id": "<uuid>",
  "organization_id": "<uuid>",
  "slug": "my-feature",
  "title": "My Feature",
  "tasks": [
    {"name": "T1", "title": "...", "repo": "...", "depends_on": [], "actor_type": "agent"}
  ]
}
```

**Verification:**
- `cmd/seed --fixture <path>` inserts feature + tasks; go-owned rows have `owner='go'`, `source_path=NULL`, valid `workspace_id` + `organization_id`.
- Tasks with no `depends_on` start at `status='ready'`; tasks with deps start at `status='todo'`.
- Created feature surfaces via `workflow-backend` read API (`GET /workspaces/:id/features`).
- Unit tests: `CreateFeature`, `CreateTask`, `InitialAutoReady` each tested in isolation.

### Required skills
- `go-best-practices`
- `postgres-best-practices`

### Subtasks
- [ ] Define `GoFeatureSpec` and `GoTaskSpec` types
- [ ] Implement `CreateFeature` with correct `owner`, `source_path=NULL`, `workspace_id`, `organization_id`
- [ ] Implement `CreateTask` with correct owner, FK references, and `depends_on` JSON
- [ ] Implement `InitialAutoReady` — advance tasks with empty `depends_on` to `status='ready'`
- [ ] Implement `MaterializeFeature` composing the above
- [ ] Write `cmd/seed/main.go` CLI with JSON fixture parsing
- [ ] Unit tests for each creation function
- [ ] Smoke test: run `cmd/seed` against a local DB; inspect rows; verify read API returns the feature

---

## T7 — Eligibility scan

### Description

Implement `FindEligibleTasks` in the Go orchestrator — the query that identifies which go-owned tasks are ready for dispatch.

**File to create (`workflow-orchestrator`):**

`internal/orchestrator/eligibility.go`:
- `FindEligibleTasks(ctx context.Context, pool *pgxpool.Pool, workspaceID uuid.UUID) ([]db.WorkspaceTask, error)`:
  ```sql
  SELECT * FROM workspace_tasks
  WHERE workspace_id = $1
    AND owner = 'go'
    AND status = 'ready'
  ORDER BY created_at ASC;
  ```
  This uses the `(workspace_id, owner, status)` index from T1. The auto-ready invariant (T10) ensures tasks in `ready` have all deps satisfied, so no secondary dep check is needed here after T10 is in place. Until T10 is wired, optionally add a defensive filter in Go code after the DB fetch.

**Verification:**
- Seed tasks in states `todo`, `ready`, `in_progress`, `done`, `blocked` and with `owner='go'` / `owner IS NULL`.
- Assert `FindEligibleTasks` returns only `owner='go' AND status='ready'` rows.
- Assert it does not return rows with unmet dependencies (if the defensive filter is applied).
- Unit test with in-memory pgx mock or real test DB.

### Required skills
- `go-best-practices`
- `postgres-best-practices`

### Subtasks
- [ ] Write `FindEligibleTasks` using the eligibility index
- [ ] Add optional defensive Go-side dep filter (verify all `depends_on` task names are `done`)
- [ ] Unit test: mixed-state seeded tasks; assert correct subset returned
- [ ] Verify query plan uses `workspace_tasks_owner_status_idx` (via `EXPLAIN`)

---

## T8 — Atomic claim

### Description

Implement the `ClaimTask` guarded `UPDATE` — the DB-atomic equivalent of the git first-push-wins claim.

**File to create (`workflow-orchestrator`):**

`internal/orchestrator/claim.go`:
- `ClaimTask(ctx context.Context, pool *pgxpool.Pool, workspaceID, taskUUID uuid.UUID, executorID string) (bool, error)`:
  ```sql
  UPDATE workspace_tasks
     SET status    = 'in_progress',
         execution = jsonb_build_object(
                       'last_updated_by', $executor_id,
                       'last_updated_at', now()::text
                     ),
         updated_at = now()
   WHERE workspace_id = $ws
     AND task_id      = $task_uuid
     AND status       = 'ready'
  RETURNING id;
  ```
  Returns `true` if exactly one row returned (claim won). Returns `false, nil` if zero rows (claim lost — not an error). Returns `false, err` only for DB errors.

**Verification (per technical design §8, T8):**
- Concurrency test: N goroutines simultaneously call `ClaimTask` on the same task UUID; exactly one returns `(true, nil)`; all others return `(false, nil)`.
- Illegal-precondition test: calling `ClaimTask` on a task already in `in_progress` returns `(false, nil)`.
- DB error test: pool closed → returns `(false, err)`.

### Required skills
- `go-best-practices`
- `postgres-best-practices`

### Subtasks
- [ ] Write `ClaimTask` with guarded `UPDATE ... WHERE status = 'ready' RETURNING id`
- [ ] Return `(false, nil)` on zero-rows result (loser path — not an error)
- [ ] Concurrency test: N goroutines, exactly one winner
- [ ] Illegal-precondition test: task already `in_progress` → `(false, nil)`

---

## T9 — Status transitions + activity log

### Description

Implement the guarded-`UPDATE` helpers for all v1 lifecycle transitions, and the `AppendLog` function that writes to `workspace_activity_events`.

**Files to create (`workflow-orchestrator`):**

`internal/orchestrator/transitions.go`:
- `GuardedTransition(ctx, pool, workspaceID, taskUUID uuid.UUID, fromStatus, toStatus string, extra map[string]any) (bool, error)` — the shared primitive:
  ```sql
  UPDATE workspace_tasks
     SET status     = $to_status,
         <extra fields>,
         updated_at = now()
   WHERE workspace_id = $ws
     AND task_id      = $task_uuid
     AND status       = $from_status
  RETURNING id;
  ```
  Returns `(true, nil)` on match, `(false, nil)` on zero rows.
- `SetInReview(ctx, pool, workspaceID, taskUUID uuid.UUID, prURL string) (bool, error)` — wraps `GuardedTransition("in_progress", "in_review")` + sets `pr = jsonb_build_object('url', $pr_url, 'status', 'open')`.
- `SetBlocked(ctx, pool, workspaceID, taskUUID uuid.UUID, reason string) (bool, error)` — wraps `GuardedTransition(*, "blocked")` (from any status) + sets `blocked_reason`.
- `SetDone(ctx, pool, workspaceID, taskUUID uuid.UUID) (bool, error)` — `GuardedTransition("in_review", "done")`.

`internal/orchestrator/activity.go`:
- `AppendLog(ctx, pool, workspaceID, featureUUID, taskUUID uuid.UUID, action, by, note string) error` — `INSERT INTO workspace_activity_events (workspace_id, feature_id, task_id, sequence, action, by, note, created_at)` where `sequence` is `COALESCE(MAX(sequence), 0) + 1` for this task.

**Verification:**
- `SetInReview`: transitions `in_progress→in_review`, sets `pr.url`; verify with `SELECT`.
- `SetBlocked`: sets `blocked_reason`, transitions correctly.
- `SetDone`: transitions `in_review→done`.
- Guarded transition returns `(false, nil)` when precondition not met.
- `AppendLog` inserts a row; duplicate sequence collision handled (wrap in transaction).

### Required skills
- `go-best-practices`
- `postgres-best-practices`

### Subtasks
- [ ] Write `GuardedTransition` as the shared transition primitive
- [ ] Write `SetInReview`, `SetBlocked`, `SetDone` wrapping `GuardedTransition`
- [ ] Write `AppendLog` — insert activity event with sequence
- [ ] Unit tests: each transition with matching precondition → `(true, nil)`
- [ ] Unit tests: each transition with wrong precondition → `(false, nil)` (not error)
- [ ] Unit test: `AppendLog` inserts correctly; sequence increments per task

---

## T10 — Dependency auto-ready

### Description

Implement `AutoReadyDependents` — called in the same DB transaction as `SetDone` to advance tasks whose full dependency set is now met.

**File to create (`workflow-orchestrator`):**

`internal/orchestrator/auto_ready.go`:
- `AutoReadyDependents(ctx context.Context, tx pgx.Tx, workspaceID, doneTaskName string) ([]uuid.UUID, error)`:
  1. Query `workspace_tasks WHERE workspace_id=$ws AND owner='go' AND status='todo'`.
  2. For each row, parse `depends_on` (JSON array of task_name slugs) and check whether all listed task names are `done` in this workspace.
  3. For each qualifying task: `UPDATE workspace_tasks SET status='ready', updated_at=now() WHERE task_id=$uuid AND status='todo' RETURNING id`.
  4. Call `AppendLog` for each advanced task (action: `ready`, note: `dependencies met`).
  5. Return the list of advanced task UUIDs.

Called from `SetDone` (T9) — wrap both in a single `pgx.BeginTx` transaction.

**Verification:**
- Diamond-dependency test: T1→{T2, T3}→T4. Mark T1 done; T2 and T3 advance to `ready`; T4 stays `todo`. Mark T2 and T3 done; T4 advances to `ready`.
- No qualifying task: returns empty slice without error.
- Transaction test: if the `UPDATE` of `SetDone` rolls back, no dependents are advanced.

### Required skills
- `go-best-practices`
- `postgres-best-practices`

### Subtasks
- [ ] Write `AutoReadyDependents` with transactional `SetDone` + dependent advance
- [ ] Integrate with `SetDone` in `transitions.go` (wrap both in one transaction)
- [ ] Diamond-dependency test (3-task chain)
- [ ] No-qualifying-task test: empty return, no error
- [ ] Rollback test: `SetDone` failure leaves dependents as `todo`

---

## T11 — Dispatch

### Description

Implement the dispatch step: register the task handle with the broker (`owner='go'`) and enqueue a `DispatchJob` onto the shared `platform:dispatch` Redis stream.

**Files to create (`workflow-orchestrator`):**

`internal/orchestrator/dispatch.go`:
- `DispatchTask(ctx context.Context, cfg *config.Config, pool *pgxpool.Pool, task db.WorkspaceTask, handle string) error`:
  1. POST to `$BROKER_URL/register` with body `{ "handle": handle, "owner": "go", "metadata": { "FeatureID": task.FeatureName, "TaskID": task.TaskName, "TenantID": cfg.OrgID, "StartedAt": now } }`.
  2. Enqueue a `DispatchJob` onto Redis stream `platform:dispatch` using `XADD`:
     - `task_id`: `task.TaskName`
     - `feature_id`: `task.FeatureName`
     - `workspace_id`: `cfg.WorkspaceID`
     - `handle`: handle
     - `management_repo`: from `workspace.yaml` / config
     - `base_branch`: `main` (from task config)
     - Any other ABI fields from `abi/src/types.ts:50-96` (re-declared in Go).

`internal/orchestrator/handle_store.go`:
- `HandleStore` — an in-process map `handle → { TaskUUID, FeatureName, TaskName }` with mutex. Used by the reap loop (T12) to resolve completions back to DB rows without an extra DB round-trip.
- `Register(handle string, entry HandleEntry)`, `Lookup(handle string) (HandleEntry, bool)`, `Delete(handle string)`.

**Verification:**
- After `DispatchTask`, the broker's `/register` returns 200 and the handle appears in `broker:pending:go`.
- The `platform:dispatch` stream gains one entry with correct `task_id`, `feature_id`, `workspace_id`.
- `HandleStore.Lookup` returns the registered entry immediately after `Register`.
- Unit test: mock broker + Redis client; assert both registration and stream entry.

### Required skills
- `go-best-practices`

### Subtasks
- [ ] Write `DispatchTask` — broker `/register` POST with `owner='go'`
- [ ] Write `DispatchTask` — `XADD` to `platform:dispatch` with correct ABI fields
- [ ] Write `HandleStore` (in-process map, thread-safe)
- [ ] Unit test: mock broker returns 200; assert handle registered with `owner='go'`
- [ ] Unit test: mock Redis; assert stream entry fields match ABI spec

---

## T12 — Reap

### Description

Implement the reap loop: drain the go completion queue from the broker, resolve each completion back to a DB task row, and write the resulting status transition.

**File to create (`workflow-orchestrator`):**

`internal/orchestrator/reap.go`:
- `ReapCompleted(ctx context.Context, cfg *config.Config, pool *pgxpool.Pool, hs *HandleStore) error`:
  1. `GET $BROKER_URL/list-completed?owner=go&max=50` to drain the go queue.
  2. For each completion record, resolve `metadata.TaskID` (slug) + `metadata.FeatureID` (slug) → task UUID via `HandleStore.Lookup(handle)` (fast path) or a DB `SELECT WHERE feature_name=$f AND task_name=$t` (slow path).
  3. Inspect `result.json` payload: if `status == 'in_review'`, call `SetInReview(ctx, pool, …, prURL)` (T9); if `status == 'blocked'`, call `SetBlocked(ctx, pool, …, reason)` (T9).
  4. Call `HandleStore.Delete(handle)` after processing.
  5. Append a `reap` log entry via `AppendLog`.

**Verification:**
- A completion from the go queue is drained and the correct DB row transitions to `in_review` with `pr_url` set.
- A completion from the `ts` queue is **not** drained (go queue only — `?owner=go`).
- Unknown handle (not in `HandleStore` or DB) logs a warning and skips without crashing.
- Unit test: mock broker returns one go completion; assert DB row updated, handle deleted.

### Required skills
- `go-best-practices`

### Subtasks
- [ ] Write `ReapCompleted` — `GET /list-completed?owner=go`
- [ ] Implement slug→UUID resolution via `HandleStore` fast path, DB slow path
- [ ] Write transition dispatch (`SetInReview` / `SetBlocked`) based on `result.json` payload
- [ ] Write `HandleStore.Delete` after successful processing
- [ ] Write `AppendLog` reap entry
- [ ] Unit test: one go completion → correct DB transition
- [ ] Unit test: unknown handle → warning logged, loop continues

---

## T13 — PR-merge poll

### Description

Implement the PR-merge poll — the mechanism that drives `in_review → done` for go features in the v1 human-merge slice. Without this, completed tasks dead-end at `in_review` and never reach a terminal state.

**Files to create (`workflow-orchestrator`):**

`internal/github/client.go`:
- `GetPR(ctx context.Context, token, prURL string) (*PRStatus, error)` — thin GitHub API client; GET `$prURL` (GitHub REST); return `PRStatus { Merged bool, State string }`.

`internal/orchestrator/pr_merge_poll.go`:
- `PollMergedPRs(ctx context.Context, ghClient *github.Client, pool *pgxpool.Pool, workspaceID uuid.UUID) error`:
  1. `SELECT task_id, pr FROM workspace_tasks WHERE workspace_id=$ws AND owner='go' AND status='in_review' AND pr->>'url' IS NOT NULL`.
  2. For each row: call `ghClient.GetPR(ctx, pr.URL)`; if `Merged == true`:
     a. `SetDone` (T9) + `AutoReadyDependents` (T10) in one transaction.
     b. Append `done` log entry.
  3. If GitHub API returns an error for one PR, log and continue (do not abort the whole poll).

**Verification (per technical design §8, T13):**
- A task in `in_review` with a merged PR transitions to `done`; dependents are auto-readied.
- A task in `in_review` with an open PR is not touched.
- GitHub API error on one PR: logged, loop continues to the next.
- Unit test: mock GitHub client returning `merged: true` / `merged: false`.

### Required skills
- `go-best-practices`

### Subtasks
- [ ] Write `internal/github/client.go` — `GetPR` using `GITHUB_TOKEN` from config
- [ ] Write `PollMergedPRs` — query `in_review` go tasks with `pr_url`
- [ ] Call `SetDone` + `AutoReadyDependents` in one transaction for merged PRs
- [ ] Unit test: merged PR → task done, dependents auto-readied
- [ ] Unit test: open PR → task unchanged
- [ ] Unit test: GitHub API error → warning logged, loop continues

---

## T14 — Orchestration loop

### Description

Wire all Go orchestrator components (T5–T13) into a single continuous poll cycle and produce a buildable binary.

**Files to create (`workflow-orchestrator`):**

`cmd/orchestrator/main.go`:
1. Parse config (T5).
2. Open DB pool (T5).
3. Initialize `HandleStore` (T11).
4. Initialize GitHub client (T13).
5. Main loop (sleep `POLL_INTERVAL_SECONDS`):
   a. `FindEligibleTasks` (T7) → for each task, generate a handle UUID and call `ClaimTask` (T8); if won, call `DispatchTask` (T11) and `HandleStore.Register`.
   b. `ReapCompleted` (T12).
   c. `PollMergedPRs` (T13).
6. Each step's errors are logged (zerolog) and do not crash the loop — retry on next cycle.
7. `GET /healthz` HTTP endpoint returns `200 OK` (used by docker-compose health checks).

`Dockerfile` — multi-stage build producing a minimal image; build `cmd/orchestrator` and `cmd/seed`.

`docker-compose.yml` (or integration with the existing agent-runtime stack) — service `go-orchestrator` pointing at the shared Postgres, Redis, and broker; health check on `/healthz`.

**Verification:**
- `docker build` produces a working image.
- Loop completes one poll cycle against a test DB + mock broker without panicking or crashing.
- `/healthz` returns 200 while the loop is running.
- Integration smoke test: start orchestrator, wait for one cycle, assert no fatal errors in logs.

### Required skills
- `go-best-practices`

### Subtasks
- [ ] Wire all components into `cmd/orchestrator/main.go`
- [ ] Implement main poll loop: eligibility → claim → dispatch → reap → merge-poll → sleep
- [ ] Implement error isolation per step (log + continue, don't crash)
- [ ] Add `/healthz` HTTP endpoint
- [ ] Write `Dockerfile` — multi-stage, produces `orchestrator` and `seed` binaries
- [ ] `docker build` succeeds with no errors
- [ ] Integration smoke test: one full poll cycle, no panics

---

## T15 — Read API: verify go-owned rows + optional owner DTO

### Description

Verify that go-owned features and tasks created by the Go orchestrator (T6) surface correctly through the existing `workflow-backend` read API. Add `owner` to the DTO if not already present.

**Files to check/change (`workflow-backend`):**

1. Inspect `internal/handler/workspace.go:42–52` and the underlying queries: confirm `GET /workspaces/:id/features` and `GET /workspaces/:id/features/:fid/tasks` select by `workspace_id` without an owner filter. No code change expected — verify only.

2. If `owner` is absent from the DTO, add it:
   - `internal/domain/dto.go` — add `Owner *string \`json:"owner,omitempty"\`` to `FeatureDTO` and `TaskDTO`.
   - Update the query in `internal/handler/workspace.go` (or its `db.*` layer) to SELECT `owner` and populate the DTO field.

3. Write or update an existing test in the `workflow-backend` test suite:
   - Seed a go-owned feature + tasks (insert rows with `owner='go'` directly via the test DB setup).
   - Call `GET /workspaces/:id/features` and assert the go-owned feature is present with `owner: "go"`.
   - Call `GET /workspaces/:id/features/:fid/tasks` and assert tasks are present with `owner: "go"`.

**Verification:**
- Go-owned feature/tasks surface alongside legacy (null-owner) ones.
- `owner` field present in response (`"go"` for go-owned, `null`/absent for legacy).
- All existing read-API tests still pass.

### Required skills
- `go-best-practices`
- `backend-engineer`

### Subtasks
- [ ] Inspect `/features` and `/features/:fid/tasks` queries — confirm no `owner IS NULL` filter
- [ ] Add `Owner *string` to `FeatureDTO` and `TaskDTO` in `dto.go` (if absent)
- [ ] Update query/scan to populate `owner` field
- [ ] Write test: seed go-owned rows, call read API, assert correct response
- [ ] All existing read-API tests pass

---

## T16 — `init-feature` owner-aware (claude skill)

### Description

Update the `init-feature` skill to explicitly ask whether a feature is `go` or `ts` before creating any files. Never silently default to either. Absent `owner` always means `ts` — this is the canonical convention documented here.

**Files to change (`workflow` repo — `claude/workflow_skills/init-feature/SKILL.md` or equivalent):**

Add a prompt step at the start of feature creation that asks: "Is this a `go` (Go/Postgres orchestrator) or `ts` (legacy git/YAML) feature?" and blocks until answered.

For `go`:
- Write `owner: go` into `status.yaml`.
- Create `tasks.md` skeleton.
- Do **not** create any `tasks/*.yaml` files.

For `ts` (or absent/default):
- Current behavior unchanged (no `owner` field in `status.yaml`, full YAML skeleton created).

Add a note to the skill doc: "Absent `owner` = `ts` — never assume `go`."

**Verification:**
- `init-feature` for a go feature → `status.yaml` has `owner: go`, `tasks.md` exists, zero `tasks/*.yaml` files.
- `init-feature` for a ts feature → existing behavior unchanged, no `owner` field.
- The skill does not silently default — it asks.

### Required skills

### Subtasks
- [ ] Locate `init-feature` skill source in `workflow` repo (claude skill tree)
- [ ] Add explicit go/ts prompt before file creation
- [ ] For go: write `owner: go` in status.yaml; create tasks.md; skip tasks/*.yaml
- [ ] For ts: verify existing behavior unchanged
- [ ] Document convention: absent owner = ts
- [ ] Smoke test both paths

---

## T17 — `tech-lead` owner-aware (claude skill)

### Description

Update the `tech-lead` skill's Phase 2 behavior for go features: produce `tasks.md` + a `## Materialization (go)` block only — no `tasks/T<n>.yaml` files. The materialization block must use a schema compatible with the `cmd/seed` CLI from T6.

**Files to change (`workflow` repo — `claude/workflow_skills/tech-lead/SKILL.md`):**

In the Phase 2 gate logic, add a check for `status.yaml.owner`:
- `go`: produce `tasks.md` narrative (same structure as for ts) plus a `## Materialization (go)` block at the end. Do **not** write `tasks/T<n>.yaml`. The materialization block lists each task's machine fields in the fixture JSON schema `cmd/seed` expects (per T6): `{ id, title, repo, depends_on, actor_type }`.
- `ts` / absent: current behavior unchanged.

The materialization block format:
```markdown
## Materialization (go)

Fixture for `cmd/seed --fixture <path>` (workflow-orchestrator T6):

\`\`\`json
{
  "workspace_id": "<fill from .env>",
  "organization_id": "<fill from .env>",
  "slug": "<feature_id>",
  "title": "<feature title>",
  "tasks": [
    { "name": "T1", "title": "...", "repo": "...", "depends_on": [], "actor_type": "agent" },
    ...
  ]
}
\`\`\`
```

**Verification:**
- For a go feature: Phase 2 produces `tasks.md` + `## Materialization (go)`, zero `tasks/*.yaml` files.
- For a ts feature: existing behavior unchanged.
- The materialization block's task schema matches T6's `GoTaskSpec` JSON structure.

### Required skills

### Subtasks
- [ ] Locate Phase 2 gate in `tech-lead` skill source
- [ ] Add `status.yaml.owner` check at Phase 2 entry
- [ ] For go: write tasks.md only; append `## Materialization (go)` block in cmd/seed fixture format
- [ ] Verify materialization block schema matches T6's `GoTaskSpec`
- [ ] For ts: confirm existing behavior unchanged
- [ ] Smoke test both paths

---

## T17b — `start-implementation` owner-gate (claude + hermes)

### Description

Gate Hard Rule #3's `started`-log git write in `start-implementation` on `owner !== 'go'`. For a go task there is no `tasks/*.yaml` in git, so attempting to append a started log entry would fail or write to the wrong file. Skip it; the Go orchestrator records the `started` entry in the DB.

**Files to change (`workflow` repo):**

`claude/workflow_skills/start-implementation/SKILL.md` — in the section implementing Hard Rule #3 (append `started` log entry, commit, push to management repo), add a guard: if `status.yaml` in the feature directory has `owner: go` (or `owner === 'go'`), skip the git-commit step entirely. Continue with all other implementation steps unchanged.

`hermes/workflow_skills/start-implementation/SKILL.md` — add an explicit note: "hermes `start-implementation` already writes zero management-repo state (executor runtime stops before push; the orchestrator wrapper owns all state writes). This skill is go-safe by construction. No functional change; this note is for parity and auditability."

**Verification:**
- For a go task: `start-implementation` completes without attempting a git commit on the task YAML.
- For a ts task (absent `owner` or `owner: ts`): existing behavior unchanged — `started` log entry is committed to the task YAML as today.

### Required skills

### Subtasks
- [ ] Locate Hard Rule #3 in claude `start-implementation` SKILL.md
- [ ] Add `owner === 'go'` guard — skip git-commit step for go tasks
- [ ] Verify ts path (absent owner) is unchanged
- [ ] Update hermes `start-implementation` SKILL.md with go-safe parity note

---

## T18 — E2E coexistence test

### Description

The load-bearing integration test for the entire feature. Drives a seeded go feature to `done` via a human-merged impl PR (v1 human-merge slice), in parallel with a legacy ts feature, and verifies the six coexistence invariants.

**File to create (`workflow-orchestrator`):**

`test/e2e/coexistence_test.go` (build tag `//go:build integration`):

1. **Setup**: start a local Postgres (testcontainers-go or docker-compose) and Redis; apply migrations; start the broker (real or mock); start the Go orchestrator loop (T14) and the TS orchestrator (real or a stub that drives the legacy feature).
2. **Seed go feature**: use `cmd/seed` (T6) to insert a go feature with a single task in `ready` state.
3. **Seed legacy feature**: write a YAML feature to the management repo (or stub it in the adapter) and run a sync cycle (T2 adapter).
4. **Run N cycles**: let both orchestrators run until:
   - The go task reaches `in_review` (executor opened an impl PR, or mock PR URL injected).
   - Simulate a PR merge (update the mock GitHub client to return `merged: true`).
   - Go orchestrator poll writes `in_review → done`.
5. **Assertions**:
   - **A1**: Go feature task reaches `done`.
   - **A2**: TS orchestrator **never** drains a go completion (assert `broker:pending:ts` never contained a go handle).
   - **A3**: Go orchestrator **never** drains a ts completion.
   - **A4**: A sync cycle does **not** delete the go feature or its tasks.
   - **A5**: Both features surface via `workflow-backend` read API (`GET /workspaces/:id/features`).
   - **A6**: Legacy (ts) feature's lifecycle is unaffected by the presence of the go orchestrator.
6. **Teardown**: stop all services; clean up DB.

Invoked with: `go test ./test/e2e/... -tags integration`; must complete in under 5 minutes.

### Required skills
- `go-best-practices`

### Subtasks
- [ ] Set up testcontainers-go (Postgres + Redis) in `TestMain`
- [ ] Apply migrations via goose up to test DB
- [ ] Seed go feature using `cmd/seed` or direct DB insert
- [ ] Seed legacy ts feature (YAML + sync or stub)
- [ ] Start Go orchestrator loop in a goroutine (or subprocess)
- [ ] Inject mock GitHub client; simulate PR merge after `in_review`
- [ ] Assert A1: go task reaches `done`
- [ ] Assert A2: TS never drains go completion
- [ ] Assert A3: Go never drains ts completion
- [ ] Assert A4: sync cycle does not delete go rows
- [ ] Assert A5: both features surface via read API
- [ ] Assert A6: ts feature lifecycle unaffected
- [ ] Test completes in under 5 minutes

---

## T24 — DB layer: `CreateWorkspaceTasks` (bulk, all-or-nothing)

### Description

Add the data-layer function that inserts a go feature's tasks in **one transaction, all-or-nothing** (technical-design §4.8). Inserts each task with `owner='go'`, `source_path=NULL`, and per-task initial `status` (`ready` if `depends_on=[]`, else `todo`); `depends_on` is stored as `task_name` slugs (resolved at runtime — forward/intra-batch references are fine). Validates every task first (non-empty unique `name`; `actor_type` defaults to `agent`, else ∈ `{agent,human,either}`; existing `task_name` = conflict) and **rolls back the whole batch on any failure**, returning a failure list `[{name, reason}]`.

### Required skills
- `postgres-best-practices`
- `go-best-practices`
- `backend-engineer`

### Subtasks
- [ ] Add the sqlc query + `Reader`/writer method twinning `CreateWorkspaceFeature`
- [ ] One transaction; validate all tasks before any insert; roll back on any failure
- [ ] Return the per-task failure list `[{name, reason}]`; existing task_name = conflict
- [ ] Unit + DB tests: all-valid inserts all with correct initial status; one bad/conflicting task creates nothing

## T25 — Features API: `?name=` exact-match filter

### Description

Extend `GET /api/workspaces/:wsId/features` with an additive **`?name=<slug>` exact-match filter** that returns the matching feature (including its UUID) or an empty result, org-scoped exactly like the unfiltered list. Backs the MCP `get_feature` tool (§4.8); the BFF proxies it unchanged.

### Required skills
- `go-best-practices`
- `backend-engineer`

### Subtasks
- [ ] Add the `name` query param + query path (exact match on `feature_name`)
- [ ] Preserve org-scoping (`AccessibleOrgIDs`)
- [ ] Tests: filter returns the feature or empty; org-scope enforced

## T26 — Task-create endpoint: `POST .../features/:id/tasks`

### Description

Service + gin handler for `POST /api/workspaces/:workspaceId/features/:featureId/tasks` — a **BFF-identity** route, twin of `CreateFeature` (§4.8). Bulk array body; authorize via injected identity (workspace ∈ `AccessibleOrgIDs`, `organization_id` server-derived); assert feature `owner='go'`; call `CreateWorkspaceTasks` (T24) in one all-or-nothing transaction; respond with created tasks or `409`/`422` + the failure list `[{name, reason}]`.

### Required skills
- `go-best-practices`
- `backend-engineer`
- `postgres-best-practices`

### Subtasks
- [ ] Handler + service + request/response DTOs
- [ ] BFF-identity auth + org-scope; feature `owner='go'` check
- [ ] Map failure list to `409`/`422`; success DTO for created tasks
- [ ] Handler tests incl. org-scope rejection + all-or-nothing behavior

## T27 — BFF: verify proxy forwards create + `?name=` routes

### Description

Confirm the generic `/bff/workflow-backend/*` proxy already forwards `POST .../features/:id/tasks` **and** `GET .../features?name=` with `auth_required` + identity injection. **No code change expected** — the deliverable is a passthrough integration test proving both routes reach the backend with `X-User-Id`/`X-Org-Id` set. Workspace-membership enforcement is out of scope (org-scoping is the bar).

### Required skills
- `go-best-practices`
- `backend-engineer`

### Subtasks
- [ ] Confirm the two routes are covered by the existing upstream config
- [ ] Passthrough test: identity headers reach the backend
- [ ] If (and only if) a gap is found, add the minimal route/config

## T28 — `workflow-mcp` scaffold (TypeScript, MCP TS SDK, stdio)

### Description

Scaffold the new `workflow-mcp` repo (§4.8): TypeScript, MCP TS SDK, **stdio** transport. `package.json` with a `build` script (tsc → `dist/`) and a stdio entry point so it runs via `node dist/index.js` from the local clone — **not published to npm in this version** (built and installed locally). Read config from process `env` (`WORKFLOW_BFF_URL` with a default + override; `session_id` cookie). **Ship agent usage docs in the repo** (`README.md` / `AGENTS.md`): the `get_feature`/`create_tasks` tools, the cookie auth/config, the create-tasks flow, and conflict/failure-list handling.

**Human prerequisite:** the `workflow-mcp` GitHub repo must exist and `WORKFLOW_MCP_LOCAL_PATH` be set before this runs.

### Required skills
- `typescript-best-practices`

### Subtasks
- [ ] `package.json` + tsconfig + `build` script (tsc → `dist/`); stdio entry point
- [ ] MCP server bootstrap (stdio); config read from process env (BFF URL + cookie)
- [ ] Agent usage docs (`README.md` / `AGENTS.md`): tools, auth, flow, conflicts
- [ ] Verify `node dist/index.js` starts a stdio MCP server

## T29 — `workflow-mcp` auth: session cookie

### Description

Read the `session_id` cookie from the `mcpServers` `env`; send it as `Cookie: session_id=…` on every BFF call (the proxy authenticates on this cookie — no BFF auth change, §4.8). On a `401`, return clear "re-login and update the cookie" guidance.

### Required skills
- `typescript-best-practices`

### Subtasks
- [ ] BFF HTTP client that attaches `Cookie: session_id`
- [ ] Configurable `WORKFLOW_BFF_URL` (default + override)
- [ ] `401` → actionable re-auth message

## T30 — `workflow-mcp` tools: `get_feature` + `create_tasks`

### Description

Implement exactly two MCP tools (§4.8): `get_feature` (by name → feature incl. UUID via the T25 `?name=` filter, or not-found) and `create_tasks` (bulk → created tasks, or the failure list `[{name, reason}]`). Both call the BFF with the authed identity. **No `create_feature`, no `list_features`** in this slice.

### Required skills
- `typescript-best-practices`

### Subtasks
- [ ] `get_feature(workspace_id, name)` → feature/UUID or not-found
- [ ] `create_tasks(workspace_id, feature_id, tasks[])` → created or failure list
- [ ] Map backend errors/failure list back to the tool caller
- [ ] Tool tests against a mock BFF

## T31 — `workflow-mcp` E2E

### Description

End-to-end through `workflow-mcp` → BFF → backend: create a go feature via the **existing** `CreateFeature` endpoint, then `get_feature` → `create_tasks`; assert all rows + initial `ready` + that the orchestrator's eligibility scan picks up no-dependency tasks. A batch containing an already-existing task → **whole batch rejected with the failure list** (nothing created).

### Required skills
- `typescript-best-practices`

### Subtasks
- [ ] Spin up backend + BFF (or fakes) with a seeded session
- [ ] Happy path: create feature → create_tasks → rows + initial ready
- [ ] Conflict path: existing task → whole batch rejected, failure list returned

## T32 — `install.sh`: clone + build + register `workflow-mcp`

### Description

Update `agent-workflow/scripts/install.sh` to clone `workflow-mcp` (workspace sibling), build it locally (`npm ci && npm run build`), and **register it via a command**: `claude mcp add workflow-mcp --scope local --env WORKFLOW_BFF_URL=<default> --env WORKFLOW_SESSION_COOKIE=<placeholder> -- node ${WORKFLOW_MCP_LOCAL_PATH}/dist/index.js`. The `--env` values land in the gitignored local MCP config. **No npm publish.** (Fallback if `claude mcp add` is unavailable in the setup environment: write the equivalent `mcpServers` stdio entry into the local settings, per the figma-mcp `setup.sh` pattern.)

### Required skills

### Subtasks
- [ ] Clone (if absent) + `npm ci && npm run build`
- [ ] Register via `claude mcp add` (local scope; `--env` BFF URL + cookie; `node …/dist/index.js`)
- [ ] Idempotent re-run; document the cookie placeholder; fallback to JSON entry if no `claude` CLI

## T33 — `create-tasks` skill (go mode)

### Description

New `claude/workflow_skills/create-tasks` skill (§4.8): resolve the feature from session context (ask + confirm if ambiguous); precondition `owner: go` + tasks approved; resolve `WORKSPACE_ID` from `.env`; resolve the feature UUID via the MCP `get_feature`; parse the `tasks.md` index table (actor_type defaults to `agent`); create in one bulk `create_tasks` call; on rejection show each failed task + reason and ask **stop / retry / skip-failing-and-retry-rest**; notify when the feature isn't found. Writes nothing to git.

### Required skills

### Subtasks
- [ ] SKILL.md: feature resolution + confirm; preconditions hard-stop
- [ ] Parse the `tasks.md` index table → task array (actor_type → `agent`)
- [ ] Call MCP `get_feature` then `create_tasks`; handle rejection (stop/retry/skip)
- [ ] Not-found → notify; writes nothing to git

## T34 — `tech-lead` skill: drop the Materialization (go) block

### Description

Update the `tech-lead` skill so a go feature's Phase-2 output is `tasks.md` only — **no `## Materialization (go)` JSON block**. The `tasks.md` index table (`ID | Wave | Title | Repo | Depends on`) is the parseable source the `create-tasks` skill (T33) reads; `actor_type` defaults to `agent`. Supersedes the old T17 materialization-block behavior.

### Required skills

### Subtasks
- [ ] Remove the `## Materialization (go)` block instructions
- [ ] Ensure the documented `tasks.md` index table carries `repo` + `depends_on`
- [ ] Note: `create-tasks` (T33) consumes the index table

## T35 — Orchestrator: remove `create.go` + `cmd/seed` from production

### Description

Remove `internal/orchestrator/create.go` + `cmd/seed` from the `workflow-orchestrator` production path: delete them or move them behind a **test-only build** (fixtures used solely by the E2E harness); assert no production code references them; add a README/doc note that **the backend API is the creation path** (§4.8). The orchestrator is execution-only.

### Required skills
- `go-best-practices`

### Subtasks
- [ ] Delete or test-only-gate `create.go` + `cmd/seed`
- [ ] Assert no production reference remains; build/tests green
- [ ] README note: creation is the backend API

## T36 — `approve-feature`: go-mode create-tasks guide

### Description

Make `approve-feature` owner-aware at the `tasks` stage (§4.7): for a go feature there are no git `tasks/*.yaml` to activate, so skip YAML activation and instead **emit a guide to run `/create-tasks <feature>`** (materialize the approved tasks into the DB) and set `next_action` accordingly. A ts feature still auto-activates its YAMLs unchanged.

### Required skills

### Subtasks
- [ ] Read `owner` from `status.yaml` at tasks-stage approval
- [ ] go: skip YAML activation; print the `/create-tasks` guide; set `next_action`
- [ ] ts: unchanged (activate eligible YAMLs)
