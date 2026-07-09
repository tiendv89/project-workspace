
# Technical Design

## Feature
- Feature ID: `unify-id-in-workflow-backend-db`
- Title: Unify `id`/`task_id` and `id`/`feature_id` into a single identity column

## Current State

The `workflow-backend` Postgres schema is the single schema authority (all goose migrations live in `workflow-backend/internal/database/migrations`, 00001–00021). The physically-reconciled snapshot is checked into the management repo at `database/workspace/schema.dbml` (v005) and is the ground truth used for this design.

Both core entity tables carry two independently-generated UUID columns:

**`workspace_features`**
- `id uuid PK default gen_random_uuid()` — internal row key. Confirmed (via `schema.dbml`) to be otherwise **unused** as an FK target from any table except `workspace_sync_runs` (see inconsistency below).
- `feature_id uuid NOT NULL default gen_random_uuid()` — the business key. Got a **standalone unique constraint in migration 00016**, making it the sole FK target for `workspace_tasks.feature_id`, `workspace_feature_documents.feature_id`. `workflow-backend`'s `Reader.CreateWorkspaceFeature` (`internal/database/queries.go:998`) is the write path.
- Indexes: `(workspace_id, feature_name)` unique, `(workspace_id, feature_id)` unique, `feature_id` unique standalone.

**`workspace_tasks`**
- `id uuid PK default gen_random_uuid()` — row key.
- `task_id uuid NOT NULL default gen_random_uuid()` — "surrogate UUID," human id lives in `task_name`. **No standalone unique constraint** — only composite `(workspace_id, task_id)` and `(workspace_id, feature_id, task_name)`.
- Two divergent writers, confirmed via GitNexus:
  - **ts/legacy path** (`workspace-github-adapter`, `Queries.UpsertWorkspaceTask`, `internal/database/workspace_tasks.sql.go:248-290`): resolves one UUID (`task_uuid`, looked up by `(workspace_id, feature_id, task_name)` or freshly generated) and inserts the **same value** into both `id` and `task_id` in one `INSERT`. So `id === task_id` always holds for ts tasks — by construction, not by constraint.
  - **go path** (`workflow-backend`, `insertGoTask`, `internal/database/queries.go:1143-1184`, called from `Reader.CreateWorkspaceTasks`): does **not** populate `task_id` in the INSERT column list, so `task_id` gets its own independent `gen_random_uuid()` default — it diverges from `id` for every go-owned task.
  - The read path `Reader.GetWorkspaceTaskByID` (`internal/database/queries.go:713`) queries `WHERE t.workspace_id = $1 AND t.task_id = $2` — i.e., despite the method's name, it matches on the **business key** `task_id`, not the row PK `id`.
  - The frontend (`digital-factory-ui`) `TaskDiffTab` and `useTaskReviewThread` pass `task.id` (the row PK) to this route, which silently worked for ts tasks (`id == task_id`) and silently broke for go tasks (`id != task_id`) — a confirmed shipped bug, documented in `docs/features/go-orchestrator-ui-tasks/technical-design.md`.

**Third writer confirmed in this design phase: `workflow-orchestrator`.** This is a headless Go daemon, not the schema owner, but a first-class direct writer/reader of the shared Postgres for `owner = 'go'` rows:
- Claims tasks via a guarded `UPDATE workspace_tasks SET status = 'in_progress' ... WHERE status = 'ready'` (`internal/orchestrator/claim.go` and the dispatch family — `Dispatch`, `DispatchFix`, `DispatchReviewer`, `DispatchRebase`, `DispatchHandoffPRConflictResolution` in `internal/orchestrator/dispatch.go`).
- Reads/writes via its own sqlc-generated queries under `internal/database/queries/` (`tasks.sql.go` — `AllTasksTerminal`, `AnyTaskDispatched`, `InitialAutoReady`; `handoffs.sql.go` — `GetHandoffFeatureInfo`, `ListDraftHandoffs`, `ListOpenHandoffsToFinalize`).
- Owns `workspace_feature_handoffs` / `workspace_feature_handoff_prs` (added migration 00021, confirmed living in the shared `workflow-backend` migrations by `schema.dbml`, despite an older doc referencing a separate `workflow-orchestrator/db/schema/schema.sql` — **this design treats `schema.dbml` as authoritative and finds no evidence of a second drifted schema copy in the indexed `workflow-orchestrator` repo**; its own test fixtures (`claim_test.go:insertReadyTask`, `conflict_test.go:insertReviewingTask`/`insertReviewPassedTask`, `feature_lifecycle_test.go:insertHandoffAndPR`) construct rows directly against the shared tables using both `id` and `feature_id`/`task_id`).
- `test/e2e/coexistence_test.go` (`TestCoexistence`, `TestFullAutonomousPath`, `TestUnblockChain`) exercises both ts- and go-owned tasks side by side against the same tables — this is the highest-value regression suite for this migration.

**Fourth, confirmed inconsistency**: `workspace_sync_runs.feature_id` / `.task_id` are FKs to `workspace_features.id` / `workspace_tasks.id` (the **surrogate row keys**) — the opposite convention from every other table, which FKs to the business keys (`workspace_features.feature_id`). `workspace_activity_events.feature_id`/`.task_id` have no FK at all (denormalized timeline).

**`digital-factory-ui`** exposes both fields on `TaskSummary`/`FeatureSummary` TypeScript types (`src/services/workflow-backend/types.ts`) and route builders in `client.ts`; GitNexus did not resolve a `TaskSummary` symbol directly (likely a type alias not indexed as a named node), so this design treats the RAG-confirmed shape (`id`, `task_id`, `task_name`, `feature_id`, `feature_name`, ...) as ground truth and flags the exact call sites (`TaskDiffTab`, `useTaskReviewThread`, `SpecPanel`, `board-meta.ts`) for verification at implementation time.

## Constraints

- Schema authority is `workflow-backend/internal/database/migrations` only — no other repo may fork or duplicate schema.
- Cannot break `workflow-orchestrator`'s `owner='go'` write path or `workspace-github-adapter`'s YAML→DB sync path during the migration — both must be updated in lockstep with the schema change, and a window exists where both old and new column names may need to coexist (expand/contract pattern) since these are three independently-deployed Go binaries.
- `task_name`/`feature_name` (human slugs, e.g. `T1`, `<feature-id>`) are untouched — this migration only concerns the surrogate/business UUID duplication.
- No behavior change to git/YAML task files — this is a Postgres-mirror-only concern.
- Zero-downtime requirement: `workspace_tasks` and `workspace_features` are live, actively-written tables (both ts and go orchestrators write continuously); the migration must not lock out writers for an extended period and must tolerate in-flight writes from processes that haven't yet deployed the new code.
- `workspace_sync_runs.feature_id`/`task_id` FK the *other* convention (surrogate `id`) — must be explicitly repointed, not silently left dangling.

## Options Considered

### Option A — Drop the surrogate `id`, keep `feature_id`/`task_id` as PK
Rename `feature_id` → `id` (or keep the name `feature_id` as the sole column and drop internal `id`), doing the same for `task_id`. This preserves the column that's already the universal FK target and already used as the external identifier by API routes and the frontend.
- Pros: `feature_id`/`task_id` are already the correctly-referenced column nearly everywhere (except `workspace_sync_runs`); minimizes the numbre of FK repoints (only `workspace_sync_runs` needs fixing, not every other consumer); matches the existing standalone-unique constraint already in place for `feature_id` (00016); the business key is semantically the "real" identity used across the system (route params, frontend labels like `task.task_id?.toUpperCase()`).
- Cons: requires reconciling `task_id` divergence for go tasks before collapsing (go tasks currently have `id != task_id` — need to pick a winner value, discussed below); requires dropping the internal `id` column and re-pointing any sequence/default logic that assumed a plain `id` PK name; renaming a PK column is a heavier DDL operation than dropping a non-PK column.

### Option B — Drop `feature_id`/`task_id`, keep the surrogate `id` as the sole identity
Make callers use `id` everywhere; drop `feature_id`/`task_id` columns entirely (repoint FKs to `id`).
- Pros: `id` is already the row PK, so no PK-rename DDL is needed — just drop the redundant column and repoint FKs.
- Cons: **breaks the existing external contract** — `task_id`/`feature_id` are already used as request/response field names in workflow-backend's API and as the join key documented in `docs/features/workflow-db/technical-design.md` ("the Go orchestrator uses `workspace_features.feature_id`... as the join key"); would require renaming `id` → some business-key name across API DTOs and frontend types, a much larger and riskier blast radius across 3 repos + the frontend, for no benefit (the surrogate `id` carries no semantic value today that `feature_id`/`task_id` don't already carry, since both are opaque UUIDs). Directly contradicts the already-shipped migration 00016 decision to make `feature_id` the standalone-unique FK target — Option B would revert that intentional prior decision.

### Option C — Keep both columns, just enforce equality via a DB trigger or CHECK
Add a trigger/constraint that forces `id = task_id` (and `id = feature_id`) on every write, without removing either column, and fix `insertGoTask` to populate `task_id` explicitly.
- Pros: smallest DDL change (no column drop, no FK repoint); fixes the immediate bug (go/ts divergence) with minimal migration risk.
- Cons: does not address the root confusion the product spec calls out — two columns still exist, every new endpoint/DTO must still decide which one to read/write, and the trigger is one more thing to keep in sync across 3 writer codebases. Doesn't reduce the schema's cognitive footprint; treats the symptom (divergence) not the disease (duplication). Rejected — the product spec's explicit goal is "collapse each table down to a single identity column," which this option does not satisfy.

## Chosen Design

**Option A** — unify on the business-key column name (`feature_id` for `workspace_features`, `task_id` for `workspace_tasks`), dropping the internal surrogate `id` column, using an **expand/contract migration** executed in the following phases to satisfy the zero-downtime and lockstep-deployment constraints:

### Phase 1 — Reconcile divergence (data fix, no schema change)

**Verified against actual source (not inferred) this phase:** `workflow-backend`'s `insertGoTask` (`internal/database/queries.go:1143-1184`, the sole live production path for go-owned task creation, reached via `POST /workspaces/:workspaceId/features/:featureId/tasks` → `Reader.CreateWorkspaceTasks` → `insertGoTask`) has this INSERT column list:
```sql
INSERT INTO workspace_tasks
    (workspace_id, feature_id, feature_name, task_name, title, repo, status, depends_on, execution, owner)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'go')
```
Neither `id` nor `task_id` appears in this list — **both** get independent `gen_random_uuid()` schema defaults on every insert. Neither column is more "reliably populated" than the other; they diverge randomly, not systematically. (An earlier draft of this design incorrectly asserted `id` was the reliable column — that claim did not hold up under source inspection and has been corrected here.)

Note: `workflow-orchestrator/internal/orchestrator/create.go` (`CreateTask`/`MaterializeFeature`, which explicitly sets `task_id = uuid.New()` matching a freshly generated `id`) is a test-only path (`//go:build integration`, called only from test files per GitNexus) — confirmed by the feature requester not to run in production. It is excluded from this analysis.

**What breaks the tie: `workflow-orchestrator`'s live task FSM keys exclusively on `task_id`.** Every one of its ~25 production queries in `internal/database/queries/tasks.sql.go` — `GuardedUpdateTaskStatus`, `SetTaskDoneFromMergedPR`, `SetTaskResolving`, `SetTaskResolved`, `ListEligibleTasks`, `BumpReenqueueAttempts`, `TouchDispatchedAt`, `GetTaskByUUID`, and all reviewer/rebase/conflict transitions — filters `WHERE workspace_id = $1 AND task_id = $2`. None of them reference `id`. This means `task_id` is the column the live, in-flight claim/dispatch/reviewer/rebase loop is actively tracking for every task right now — it is load-bearing production state, not an incidental column.

**Winner: `task_id`** — reversed from an earlier draft of this design, which incorrectly proposed `id` as the winner. Reconciliation must bring `id` in line with `task_id`, not the other way around, so that no in-flight dispatch (identified by `task_id` in `dispatch_handle`/`dispatch_nonce` bookkeeping) is silently redirected to a different value mid-execution: `UPDATE workspace_tasks SET id = task_id WHERE id != task_id;`

This is safe with respect to existing constraints because `id` is the table's PK (implicitly unique already) and `task_id`'s values are already known-unique via the composite `(workspace_id, task_id)` constraint — so setting `id` to `task_id`'s value cannot introduce a PK collision, provided no other row already has that `task_id` value as its `id` (verify via `SELECT task_id, COUNT(*) FROM workspace_tasks GROUP BY task_id HAVING COUNT(*) > 1` returning zero rows before running the UPDATE, since a PK is being reassigned).

**Mandatory pre-migration verification** (do not run the UPDATE from assertion — confirm against live data first):
1. `SELECT COUNT(*) FROM workspace_tasks WHERE id != task_id;` — quantify actual divergence (expected: all/most `owner='go'` rows, zero `owner IS NULL` rows since the ts upsert path always sets them equal).
2. `SELECT COUNT(*) FROM workspace_tasks WHERE id != task_id AND status IN ('in_progress','reviewing') OR conflict_state = 'resolving';` — identify any task **currently mid-dispatch** at migration time; these are highest-risk and should be drained (allowed to reach a terminal/idle state) before reconciliation runs, to avoid rewriting the PK out from under an active dispatch_handle lookup.
3. Audit `workspace_activity_events.task_id` and `workspace_sync_runs.task_id` values against both the pre- and post-reconciliation `id`/`task_id` to confirm no historical reference silently starts pointing at the wrong row (both are denormalized, unconstrained UUID columns — no FK will catch a mismatch automatically).

`workspace_features` needs no reconciliation — `feature_id` is already the correctly-maintained business key everywhere (confirmed: `CreateWorkspaceFeature` explicitly generates one `fid` and inserts it into `feature_id`; `id` gets its own separate default and is not read back or used by any caller found in `workflow-backend`, `workspace-github-adapter`, or `workflow-orchestrator`). `id` is simply unused elsewhere, so no divergence exists to fix.

### Phase 2 — Add-then-backfill (expand)
1. Migration `NNNN_unify_task_and_feature_identity_expand.sql`:
   - Confirm (do not assume) `feature_id`/`task_id` already satisfy PK-equivalent guarantees (`NOT NULL`, standalone unique for `feature_id`) before proceeding. For `workspace_tasks`, add a standalone `UNIQUE (task_id)` constraint (mirrors what 00016 already did for `feature_id`) — this is safe to add immediately after Phase 1's `id = task_id` reconciliation, since `task_id` was already guaranteed unique by the composite `(workspace_id, task_id)` constraint and Phase 1 did not change any `task_id` value (only `id` was updated to match it).
   - Add new FKs from `workspace_sync_runs.feature_id`/`task_id` pointing at `workspace_features.feature_id` / `workspace_tasks.task_id` (additive; keep the old FK to `.id` temporarily so both old and new code paths work during rollout).
2. Deploy code changes across all three writer/reader repos (`workflow-backend`, `workspace-github-adapter`, `workflow-orchestrator`) updated to:
   - Populate `task_id` explicitly in `insertGoTask`'s INSERT column list (same value as `id`, closing the divergence going forward even before the column is dropped).
   - Read/write via `feature_id`/`task_id` exclusively, never via `id`, in every sqlc query file (`workflow-backend/internal/database/queries.go`, `workspace-github-adapter/internal/database/workspace_tasks.sql.go` and its features equivalent, `workflow-orchestrator/internal/database/queries/*.sql.go`).
   - `Reader.GetWorkspaceTaskByID` renamed to `Reader.GetWorkspaceTaskByTaskID` (or equivalent) for clarity — no more misleading "ByID" naming when the query is actually keyed on the business identifier.
3. Deploy `digital-factory-ui` change: `TaskSummary`/`FeatureSummary` types drop `id`, all consumers (`TaskDiffTab`, `useTaskReviewThread`, `SpecPanel`, `board-meta.ts`) use `task_id`/`feature_id` exclusively. This is a superset of (and replaces the need for) the standalone frontend fix noted in `docs/features/go-orchestrator-ui-tasks/technical-design.md`.

### Phase 3 — Contract (drop old columns)
Once all three Go services and the frontend are confirmed deployed and no code references `workspace_features.id` / `workspace_tasks.id` (grep + GitNexus impact check for zero remaining references):
1. Migration `NNNN_unify_task_and_feature_identity_contract.sql`:
   - Drop the old `workspace_sync_runs` FKs pointing at `.id`; keep only the new FKs pointing at `.feature_id`/`.task_id` (added in Phase 2).
   - Drop `workspace_features.id` and `workspace_tasks.id` columns.
   - Promote `feature_id` to be the table's primary key on `workspace_features` (`ALTER TABLE ... DROP CONSTRAINT workspace_features_pkey, ADD PRIMARY KEY (feature_id)`); same for `task_id` on `workspace_tasks`.
   - Verify all existing FKs (`workspace_tasks.feature_id → workspace_features.feature_id`, `workspace_feature_documents.feature_id → workspace_features.feature_id`) still resolve correctly against the new PK — they already point at `feature_id`, so this is a no-op for them, confirming Option A's lower blast radius versus Option B.
2. Down-migration restores the `id` column with fresh `gen_random_uuid()` defaults (data is not recoverable bit-for-bit since the column is dropped, matching the precedent set by migration 00016's down migration per PR #35).

## Dependency Analysis

- **Blocking**: Phase 1 (data reconciliation) must complete and be verified before Phase 2 migration runs — a partially-reconciled table would let the Phase 2 standalone-unique constraint on `task_id` fail to apply (duplicate values from divergent go/ts pairs).
- **Blocking**: Phase 2 code deploys (all of `workflow-backend`, `workspace-github-adapter`, `workflow-orchestrator`, `digital-factory-ui`) must land and be confirmed live before Phase 3 DDL runs — dropping `id` while any deployed binary still reads/writes it would break that service immediately.
- **Non-blocking / parallel**: the four repos' Phase-2 code changes are independent of each other (different codebases, different call sites) and can be implemented and reviewed in parallel once the Phase-1 data reconciliation and Phase-2 expand migration are in place — each just needs the expand migration to have landed first so both old and new columns exist simultaneously.
- **Sequencing constraint**: `workflow-orchestrator`'s claim/dispatch queries (`internal/orchestrator/claim.go`, `dispatch.go`) must be verified deployed and passing `test/e2e/coexistence_test.go` (`TestCoexistence`, `TestFullAutonomousPath`, `TestUnblockChain`) before Phase 3 — this is the highest-risk consumer since it directly claims/mutates task rows in a hot loop.

## Parallelization / Blocking Analysis

- **Task 1 (blocking, first)**: Phase 1 data reconciliation script + verification, run directly in `workflow-backend`'s migration tooling against the shared DB.
- **Task 2 (blocking on 1)**: Phase 2 expand migration in `workflow-backend/internal/database/migrations`.
- **Tasks 3a/3b/3c/3d (parallel, blocked on 2)**: code updates in `workflow-backend` (rename `GetWorkspaceTaskByID`, fix `insertGoTask`, update all sqlc queries), `workspace-github-adapter` (`UpsertWorkspaceTask` and features equivalent), `workflow-orchestrator` (claim/dispatch/handoff query updates), `digital-factory-ui` (types + call sites) — these touch four different repos and have no code dependency on each other, only a data dependency on Task 2 having landed.
- **Task 4 (blocking on all of 3a–3d being deployed and verified)**: Phase 3 contract migration (drop columns, repoint FKs, promote PK).
- **Verification gate before Task 4**: re-run GitNexus `impact` queries for `workspace_features.id` and `workspace_tasks.id` across all four repos to confirm zero remaining references before dropping the columns.
