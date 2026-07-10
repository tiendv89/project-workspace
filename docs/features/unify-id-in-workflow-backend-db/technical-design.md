
# Technical Design

## Feature
- Feature ID: `unify-id-in-workflow-backend-db`
- Title: Unify the dual UUID columns on `workspace_features` and `workspace_tasks` into a single `id`

## Current State

`workflow-backend` is the single schema authority — all goose migrations (00001–00021) live in
`workflow-backend/migrations/`. The physically-reconciled snapshot is checked into the management
repo at `database/workspace/schema.dbml` (v005) and is the ground truth for this design.

Both core entity tables carry two independently-generated UUID columns:

**`workspace_features`**
- `id uuid PK default gen_random_uuid()` — surrogate row key.
- `feature_id uuid NOT NULL default gen_random_uuid()` — business key; got a standalone unique
  constraint in 00016 (`workspace_features_feature_id_key`), making it the FK target for
  `workspace_tasks.feature_id` and `workspace_feature_documents.feature_id`.
- `id` and `feature_id` hold **different** values — each has its own default and neither is
  reconciled against the other. `CreateWorkspaceFeature` generates one value into `feature_id`;
  `id` gets its own separate default.
- Constraints: `workspace_features_pkey (id)`, `workspace_features_feature_id_key (feature_id)`,
  `workspace_features_workspace_feature_id_unique (workspace_id, feature_id)`,
  `workspace_features_workspace_feature_name_unique (workspace_id, feature_name)`.

**`workspace_tasks`**
- `id uuid PK default gen_random_uuid()` — row key.
- `task_id uuid NOT NULL default gen_random_uuid()` — surrogate business key; human id lives in
  `task_name`. No standalone unique — only `workspace_tasks_workspace_task_id_unique
  (workspace_id, task_id)` and `workspace_tasks_workspace_feature_task_unique (workspace_id,
  feature_id, task_name)`.
- FK `workspace_tasks_feature_id_fkey`: `feature_id → workspace_features(feature_id)` (00016),
  `ON DELETE CASCADE`.
- Two divergent writers create the core bug:
  - **ts/legacy path** — `workspace-github-adapter`'s `UpsertWorkspaceTask`
    (`internal/database/workspace_tasks.sql.go`) resolves one UUID and inserts the **same value**
    into both `id` and `task_id`. So `id == task_id` always holds for ts tasks, by construction.
  - **go path** — `workflow-backend`'s `insertGoTask`
    (`internal/database/queries.go:1143-1184`, via `Reader.CreateWorkspaceTasks`) omits `task_id`
    from its INSERT column list, so both `id` and `task_id` take independent
    `gen_random_uuid()` defaults and **diverge** for every go-owned task.
  - `Reader.GetWorkspaceTaskByID` (`queries.go:713`) queries `WHERE task_id = $2` despite its
    name — it matches on the business key. The frontend passes `task.id` to this route, which
    worked for ts tasks (`id == task_id`) and silently broke for go tasks — a confirmed shipped
    bug (`docs/features/go-orchestrator-ui-tasks/technical-design.md`).

**Consumers / writers of these columns:**
- **`workflow-orchestrator`** (headless Go daemon; direct writer of `owner='go'` rows) keys its
  entire task FSM on **`task_id`**. All ~25 production queries in `db/queries/tasks.sql`
  (`GuardedUpdateTaskStatus`, `SetTaskDoneFromMergedPR`, `ListEligibleTasks`, reviewer/rebase/
  conflict transitions, etc.) filter `WHERE workspace_id = $1 AND task_id = $2`. It also owns
  `workspace_feature_handoffs` / `workspace_feature_handoff_prs` (00021).
  `test/e2e/coexistence_test.go` (`TestCoexistence`, `TestFullAutonomousPath`, `TestUnblockChain`)
  is the highest-value regression suite for this change.
- **`workspace_sync_runs`** FKs the *opposite* convention: `feature_id → workspace_features.id`
  and `task_id → workspace_tasks.id` (the **surrogate** keys; 00011,
  `workspace_sync_runs_{feature,task}_id_fkey`, `ON DELETE SET NULL`, **no `ON UPDATE`** →
  `NO ACTION`). `workspace-github-adapter`'s `syncRunReferenceIDs`
  (`internal/worker/workspace_sync.go:438-468`) writes `feature.ID`/`task.ID` (the surrogate) on
  every sync run. This is the **only live consumer of the surrogate `id`** across the four repos.
- **`workspace_activity_events.feature_id`/`task_id`** and
  **`workspace_feature_handoffs.feature_id`** have no FK (denormalized) and today hold the
  **business** values.
- **`digital-factory-ui`** exposes both fields on `TaskSummary`/`FeatureSummary`
  (`src/services/workflow-backend/types.ts`) and consumes them in `TaskDiffTab`,
  `useTaskReviewThread`, `SpecPanel`, `board-meta.ts`.

**Codegen facts that shape the migration (verified against source):**
- `workflow-backend/internal/database/queries.go` is **hand-written** (no sqlc) — explicit column
  lists throughout, no `SELECT *` on these tables.
- `workspace-github-adapter/sqlc.yaml` points at `../workflow-backend/migrations` — **not
  drifted**; its structs self-correct on the next `sqlc generate`.
- `workflow-orchestrator` has its **own sqlc schema copy** at `db/schema/schema.sql`
  (`sqlc.yaml → schema: "db/schema/schema.sql"`). It is **stale** (still declares
  `feature_id ... REFERENCES workspace_features(id)`, pre-00016) and must be updated + regenerated
  as part of this feature. It also contains the one `SELECT * FROM workspace_tasks`
  (`db/queries/tasks.sql:375`, `FindConflictedTasks`) — sqlc expands `*` against this schema at
  codegen time, so it must be regenerated after the column change or the generated scan expects a
  dropped column.

## Constraints

- Schema authority is `workflow-backend/migrations/` only. `workflow-orchestrator/db/schema/schema.sql`
  is a codegen mirror that must be kept in sync (ideally repointed at the canonical migrations).
- `task_name`/`feature_name` (human slugs) are untouched — this is purely a UUID-column change.
- No behavior change to git/YAML task files — Postgres-mirror-only concern.
- **A short downtime window is acceptable.** The system is in-house and early-stage, so this
  design does *not* pursue zero-downtime (expand/contract). It uses a single migration plus a
  coordinated redeploy, accepting a brief window (~minutes) during which writers are down.
- The `workspace_sync_runs` surrogate-key FKs must be handled explicitly (dropped, re-pointed),
  not left dangling.

## Options Considered

### Option A — Keep the business keys (`feature_id`/`task_id`), drop the surrogate `id`
Collapse each table onto the business-key column, promote it to PK.
- Pros: business keys are already the FK target and external identifier nearly everywhere; only
  `workspace_sync_runs` needs re-pointing; orchestrator FSM already keys on `task_id` (little
  churn there).
- Cons: requires a PK swap (`DROP CONSTRAINT pkey; ADD PRIMARY KEY (...)`); the surviving column
  keeps the name `feature_id`/`task_id`. **If the desired end state is a column literally named
  `id`, Option A then requires a *second* rename migration + a second full code sweep** — i.e.
  paying two migration cycles to reach the same place Option B reaches in one.

### Option B — Keep the surrogate `id`, drop `feature_id`/`task_id` (CHOSEN)
Make `id` the sole identity on both tables; drop the business-key columns; re-point FKs to `id`.
- Pros: reaches a single column literally named **`id`** — the desired end state — in **one
  migration**. No PK swap (`id` is already the PK). All denormalized references
  (`activity_events`, `handoffs`) become consistent with the surviving `id` as a side effect of
  the reconcile step.
- Cons: heaviest code change lands on the orchestrator's hot loop (~25 queries move from
  `WHERE task_id = $2` to `WHERE id = $2`); changes the API/DTO field names `task_id`/`feature_id`
  → `id`, which every in-tree consumer must adopt in lockstep. Acceptable here because all
  consumers are in-tree and a coordinated deploy with brief downtime is allowed.

The original objection to Option B — that dropping the business columns discards the values used
by every external reference — is removed by **reconciling first** (see Chosen Design): the
surviving `id` is set to the business value before the business column is dropped, so no reference
is orphaned.

### Option C — Keep both columns, enforce `id = task_id`/`id = feature_id` via trigger/CHECK
Rejected — does not satisfy the product-spec goal of collapsing to a single identity column;
leaves the two-column confusion and a cross-repo trigger to maintain.

## Chosen Design — Option B, single migration with accepted downtime

**End state:** `workspace_features` and `workspace_tasks` each have a single identity column `id`
(already the PK), holding the values that were previously in `feature_id`/`task_id`. The
`feature_id`/`task_id` **columns are dropped**. Child reference columns that *point at* these
tables keep their names (`workspace_tasks.feature_id`, `workspace_sync_runs.task_id`,
`workspace_activity_events.task_id`, `workspace_feature_handoffs.feature_id`) — they are foreign
references, and now target `id`. This yields the conventional shape: own PK = `id`, parent ref =
`feature_id`.

### Reconcile first — why the surviving `id` carries the business values
Every external/persisted reference (orchestrator FSM state keyed on `task_id`, `activity_events`,
`handoffs`, frontend URLs) uses the **business** values. So before dropping the business columns,
`id` is set equal to them:
```sql
UPDATE workspace_tasks    SET id = task_id    WHERE id != task_id;
UPDATE workspace_features SET id = feature_id WHERE id != feature_id;
```
For ts tasks this is a no-op (`id == task_id` already); for go tasks it brings the divergent `id`
into line. Because the orchestrator tracks in-flight dispatches by `task_id`, and `id` now holds
that same value, no in-flight dispatch is redirected. `workspace_sync_runs`, which currently
stores surrogate values, is translated to business values in the same migration (step 2 below)
*before* the reconcile changes `features.id`, so its references survive.

### The single migration (`00022_unify_identity.sql`)
Runs in one transaction (goose default). Constraint names below are the real ones from the
migration history — confirm `workspace_feature_documents_feature_id_fkey` against `\d` at
implementation time.
```sql
-- +goose Up
-- 1. Relax sync_runs FKs: they target the surrogate id (and NO ACTION would block the reconcile).
ALTER TABLE workspace_sync_runs
    DROP CONSTRAINT IF EXISTS workspace_sync_runs_feature_id_fkey,
    DROP CONSTRAINT IF EXISTS workspace_sync_runs_task_id_fkey;

-- 2. Translate sync_runs refs from surrogate id -> business value, while old id still exists.
UPDATE workspace_sync_runs s SET feature_id = f.feature_id
    FROM workspace_features f WHERE s.feature_id = f.id;
UPDATE workspace_sync_runs s SET task_id = t.task_id
    FROM workspace_tasks t WHERE s.task_id = t.id;

-- 3. Reconcile: bring the surviving id in line with the business key.
UPDATE workspace_tasks    SET id = task_id    WHERE id != task_id;
UPDATE workspace_features SET id = feature_id WHERE id != feature_id;

-- 4. Re-point child FKs from the business column to id (values already equal -> validates fine).
ALTER TABLE workspace_tasks
    DROP CONSTRAINT workspace_tasks_feature_id_fkey,
    ADD  CONSTRAINT workspace_tasks_feature_id_fkey
        FOREIGN KEY (feature_id) REFERENCES workspace_features(id) ON DELETE CASCADE;
ALTER TABLE workspace_feature_documents
    DROP CONSTRAINT workspace_feature_documents_feature_id_fkey,
    ADD  CONSTRAINT workspace_feature_documents_feature_id_fkey
        FOREIGN KEY (feature_id) REFERENCES workspace_features(id) ON DELETE CASCADE;

-- 5. Drop the business-key columns and their now-redundant unique constraints.
ALTER TABLE workspace_tasks
    DROP CONSTRAINT workspace_tasks_workspace_task_id_unique,
    DROP COLUMN task_id;
ALTER TABLE workspace_features
    DROP CONSTRAINT workspace_features_feature_id_key,
    DROP CONSTRAINT workspace_features_workspace_feature_id_unique,
    DROP COLUMN feature_id;

-- 6. Re-add sync_runs FKs at id (now holding the business values).
ALTER TABLE workspace_sync_runs
    ADD CONSTRAINT workspace_sync_runs_feature_id_fkey
        FOREIGN KEY (feature_id) REFERENCES workspace_features(id) ON DELETE SET NULL,
    ADD CONSTRAINT workspace_sync_runs_task_id_fkey
        FOREIGN KEY (task_id) REFERENCES workspace_tasks(id) ON DELETE SET NULL;
-- id is already the PK on both tables — no PK promotion needed.
```
All steps are metadata-only or small-table scans; in the accepted downtime window there is no
need for `CONCURRENTLY`/`NO TRANSACTION`. Keeping it in one transaction means a failure rolls back
cleanly with the old schema intact.

**Down migration** re-adds `task_id`/`feature_id` as `uuid NOT NULL DEFAULT gen_random_uuid()`,
sets them `= id`, restores the unique constraints, and re-points the FKs back to the business
columns. The pre-migration go-task divergence is not reconstructed (it was the bug); the restored
invariant is `id == task_id`/`id == feature_id`, matching the ts convention.

### Pre-migration verification (run against live data first)
```sql
-- collision guard: setting id := business must not collide (must return 0 rows)
SELECT task_id, count(*) FROM workspace_tasks    GROUP BY task_id    HAVING count(*) > 1;
SELECT feature_id, count(*) FROM workspace_features GROUP BY feature_id HAVING count(*) > 1;

-- cross-collision guard: setting id := task_id/feature_id must not collide with a
-- DIFFERENT row's pre-existing id (the internal-duplicate check above does not catch
-- this; astronomically unlikely with random UUIDs, but cheap to verify before a PK
-- reassignment on a live table -- must return 0 rows).
SELECT count(*) FROM workspace_tasks a
    JOIN workspace_tasks b ON a.task_id = b.id AND a.id != b.id;
SELECT count(*) FROM workspace_features a
    JOIN workspace_features b ON a.feature_id = b.id AND a.id != b.id;

-- divergence census (informational)
SELECT owner, count(*) FILTER (WHERE id != task_id) AS diverging, count(*) FROM workspace_tasks GROUP BY owner;
```
Drain in-flight go dispatches (`status IN ('in_progress','reviewing')` /
`conflict_state = 'resolving'`) before deploying, so no PK is rewritten under an active dispatch —
in practice the orchestrator is down during the swap anyway.

### Code changes (all four repos, shipped in the coordinated deploy)
- **workflow-orchestrator** (heaviest): rewrite the ~25 `tasks.sql` queries from `task_id` → `id`;
  convert `FindConflictedTasks` (`db/queries/tasks.sql:375`) to an explicit column list; update
  `db/schema/schema.sql` (drop `feature_id`/`task_id`, `id` is the sole key) and run
  `sqlc generate`; update `internal/orchestrator/*.go` struct fields (`.TaskID`/`.FeatureID` for
  the *own* key → `.ID`; parent-ref `FeatureID` follows the surviving reference column). Verify
  `test/e2e/coexistence_test.go` green.
- **workflow-backend** (`queries.go`, hand-written): own-key reads/writes move to `id`; drop the
  now-unnecessary `task_id` handling in `insertGoTask`; rename `GetWorkspaceTaskByID` (query is
  now genuinely keyed on `id`). Update handler DTOs (`task_id`/`feature_id` → `id`).
- **workspace-github-adapter**: `UpsertWorkspaceTask` + features equivalent write `id` only;
  `syncRunReferenceIDs` returns `feature.ID`/`task.ID` (unchanged in spirit — the struct now has
  only `ID`); `sqlc generate` against the new migrations.
- **digital-factory-ui**: `TaskSummary`/`FeatureSummary` drop `task_id`/`feature_id`, use `id`;
  fix `TaskDiffTab`, `useTaskReviewThread`, `SpecPanel` (`task.task_id` → `task.id`),
  `board-meta.ts`, and route builders.
- **hermes-agent (fifth deploy target — confirmed, not optional)**: `src/services/workflow_backend_client.py`,
  function `_resolve_feature_id_by_name` (used by `get_feature_detail`'s slug-fallback path), reads
  the literal JSON key `"feature_id"` off `GET /api/workspaces/:workspaceId/features?name=...`:
  ```python
  items = data.get("items") or []
  return items[0]["feature_id"] if items else None
  ```
  This must change to `items[0]["id"]`. Two live call sites depend on this fallback and will break
  the moment a caller resolves a feature by name-slug instead of UUID:
  - `plugins/tools/approve.py` (`approve_feature` tool) — `handle()` calls `get_feature_detail(wid, fid, ...)`
    on every approve/reject/reopen invocation. The tool's `feature_id` parameter is documented as
    accepting either a UUID or a `feature_name` slug, so this is a real, frequently-exercised path,
    not dead code — any human invoking `/approve-feature` with a slug (or a session whose
    thread-local `feature_id` context was set to something other than the UUID) hits it.
  - `plugins/tools/create_tasks.py` (`create_tasks` backup command) — `load_feature_tasks_md()` calls
    the same `get_feature_detail`, same fallback.
  Both call sites route through the one shared function, so the fix is a single-line change, but it
  must ship in the same coordinated deploy window as the other four repos — `hermes-agent` is
  therefore a required fifth target, not an optional cleanup. No other `hermes-agent` code path was
  found to reference `.id`/`.task_id` on workflow-backend's task or feature responses (`get_feature_detail`,
  `get_feature_tasks`, and `create_feature_tasks`'s outbound payload construction were all checked and
  only touch `feature_name`, `title`, `current_stage`, `status`, `next_action`, `owner`, `init_pr_url`,
  `task_name`, `blocked_reason`, `depends_on`, `pr`, `execution` — never the identity column itself).

## Deployment sequence (Portainer, accepting downtime)

Migrations auto-run on `workflow-backend` startup, so swapping the backend image tag is what
applies `00022`.

1. **Pre-stage all five images** — build and push new tags for `workflow-backend`,
   `workflow-orchestrator`, `workspace-github-adapter`, `digital-factory-ui`, and `hermes-agent`
   to the registry so Portainer only pulls and recreates. Every image must already contain its
   code change (especially the orchestrator regen + `SELECT *` fix, and the `hermes-agent`
   `_resolve_feature_id_by_name` fix) or that service breaks after the swap.
2. **Backup** — full `pg_dump` off-host (see Backup & rollback), with writers quiesced.
3. **Swap the backend image first, alone.** Its startup runs the migration; wait until healthy =
   schema flipped and reconciled. From this instant, any still-old container errors on the dropped
   columns (this is the downtime window for the others).
4. **Then swap adapter, UI, orchestrator, and hermes-agent.** Order among them does not matter for
   correctness once the migration is done. Do **not** let a new orchestrator start before the
   migration completes — a new orchestrator reading unreconciled `id` could mis-claim/mis-transition
   a go task. A briefly-down old orchestrator is safe (its queries just error and retry; the
   reconcile preserves its `task_id`-tracked dispatch identity under `id`). `hermes-agent`'s fix only
   matters on the slug-fallback path (`_resolve_feature_id_by_name`); a brief window on the old image
   only risks a `KeyError` on that specific fallback, not data corruption, but it should still swap
   in the same window as the others to avoid user-facing approve/create-tasks failures.

**Why old code can't overlap the new schema:** new code tolerates the old schema (it only touches
`id`, which exists before and after — at worst it briefly reads pre-reconcile values), but old
code does **not** tolerate the new schema (its `WHERE task_id = $2` / `SELECT *` hit a dropped
column and crash). So minimize the interval between step 3 and step 4.

### Post-deploy verification
- `workflow-orchestrator` e2e (`coexistence_test.go`) green on the new build.
- `rg -ni 'select \*\s+from\s+workspace_(tasks|features)'` empty across the three Go repos.
- One full orchestrator cycle + one sync cycle complete without error.
- Update `database/workspace/schema.dbml` to v006 (single `id`, FKs re-pointed), re-index RAG, and
  trigger a GitNexus re-index once the code changes are merged.

## Backup & rollback

A single full `pg_dump` before the migration is the backup and rollback mechanism. This system is
in-house and early-stage — it can tolerate a short window and the small write-delta risk of a
logical dump, so the heavier options (in-DB mapping snapshots, physical volume tars, WAL/PITR) are
deliberately out of scope. (PITR is not available anyway — no WAL archiving is configured.)

### Context
- Postgres **16** (`postgres:16-alpine`) in a Docker container (Portainer in prod), data in the
  named volume `db_data`.
- Database and role **`workflow_backend`** (per `workflow-backend/docker-compose.yml`; confirm the
  prod values). Local dev exposes it on host port `25432`.

Set the container name (find it via `docker ps | grep postgres` or the Portainer stack):
```bash
PG=workflow-backend-db-1      # replace with the real container name
DB=workflow_backend
USER=workflow_backend
```

### Backup — full dump, taken right before the backend image swap
```bash
docker exec -t "$PG" pg_dump -U "$USER" -d "$DB" -Fc \
  -f /tmp/unify_id_pre_$(date +%Y%m%d_%H%M%S).dump
docker cp "$PG:/tmp/unify_id_pre_"*.dump ./     # copy it OFF the container
```
`-Fc` = compressed custom format (supports selective restore). Use plain SQL (`-f *.sql`, no
`-Fc`) if you want a greppable copy.

### Restore — if the migration or new images go bad
```bash
# stop the services first, then:
docker exec -i "$PG" pg_restore -U "$USER" -d "$DB" --clean --if-exists < unify_id_pre_*.dump
# start the OLD images back up
```

### Three things that make the dump actually sufficient
1. **Copy it off-host** (`docker cp`) — a dump inside the volume you might wipe is worthless.
2. **Verify it once** — check the exit code and file size; ideally restore into a scratch DB to
   confirm it's valid. An untested backup isn't a backup.
3. **Take it with writers quiesced** — `pg_dump` is internally consistent, but writes after it
   starts aren't captured. In the downtime window writers are stopped/crashing, so the delta is
   ~zero.

Note: the task-sync queue lives in Redis/asynq, not Postgres, so it is not in the dump — this is
fine, queue items are re-derivable and a full reconciliation clears the queue anyway.
