# v006 — activity actor enrichment + unified feature/task identity

**Features**: `log-activities-in-workflow-backend` (00022), `unify-id-in-workflow-backend-db` (00023)
**Date**: 2026-07-11
**Migrations**: 00022, 00023

## Tables altered

### `workspace_activity_events` (00022)

- **Added**:
  - `actor_id text` — typed, stable reference to the identity that performed the action (e.g. `"user:3f9ab21e-..."`). No FK — soft reference to user-service.
  - `enriched boolean NOT NULL DEFAULT true` — whether `actor_id` has been display-name-resolved into `actor`. Defaults to `true` so that all pre-existing rows, and all rows written by `workflow-orchestrator`'s own `AppendLogTx` (a separate writer this column does not apply to), are never picked up by the enrichment poller. Only rows explicitly written with `enriched = false` by workflow-backend's own write paths are enrichment candidates.
- **Index added**: `idx_workspace_activity_events_unenriched` — partial index on `(id) WHERE enriched = false`. Keeps the poller's batch scan cheap regardless of table growth.

### `workspace_features` (00023)

- **Removed**: `feature_id` — the independently-generated business-key column. `id` (the row's original surrogate primary key) is now the sole identity column, reconciled to hold the pre-existing business-key value (see Design notes).
- **Removed constraints**: `workspace_features_feature_id_key` (standalone unique on `feature_id`, added in 00016), `workspace_features_workspace_feature_id_unique` (composite unique on `(workspace_id, feature_id)`).
- `id` is still `uuid PRIMARY KEY DEFAULT gen_random_uuid()`; no default change, only the reconciliation UPDATE and column drop.

### `workspace_tasks` (00023)

- **Removed**: `task_id` — the independently-generated business-key column (no standalone unique constraint previously; this was the more fragile of the two dual-ID cases, with a confirmed shipped bug for go-owned tasks where `id != task_id`).
- **Removed constraint**: `workspace_tasks_workspace_task_id_unique` (composite unique on `(workspace_id, task_id)`).
- **FK re-pointed**: `feature_id` now references `workspace_features(id)` (previously `workspace_features(feature_id)`).
- `id` is still `uuid PRIMARY KEY DEFAULT gen_random_uuid()`.

### `workspace_feature_documents` (00023)

- **FK re-pointed**: `feature_id` now references `workspace_features(id)` (previously `workspace_features(feature_id)`); `ON DELETE CASCADE` unchanged.

### `workspace_sync_runs` (00023)

- **FK semantics fixed**: `feature_id`/`task_id` continue to reference `workspace_features(id)` / `workspace_tasks(id)` by column name, but the *values they hold* change meaning — before 00023 these FKs pointed at the surrogate key (the only table in the schema doing so, an inconsistency called out during technical design); the migration translates existing rows from surrogate → business value first, then re-adds the FKs once `id` itself has been reconciled to the business value. After 00023 this table's FK convention matches every other table's.

## Migration sequence

| # | File | Feature | Change |
|---|------|---------|--------|
| 00022 | `activity_events_actor_enrichment.sql` | log-activities-in-workflow-backend | `workspace_activity_events` gains `actor_id`, `enriched` + partial unenriched index |
| 00023 | `unify_identity.sql` | unify-id-in-workflow-backend-db | `workspace_features`/`workspace_tasks` collapsed onto `id`; `feature_id`/`task_id` columns dropped; dependent FKs (`workspace_tasks`, `workspace_feature_documents`, `workspace_sync_runs`) re-pointed/reconciled |

## Design notes

- **Enrichment default direction.** `enriched` defaults to `true`, not `false` — this is an opt-in poller target, not an opt-out one. Only workflow-backend write paths that explicitly set `enriched = false` (alongside a resolvable `actor_id`) enter the enrichment queue; every other writer (including `workflow-orchestrator`'s direct `AppendLogTx` inserts, and all historical rows) is inert by default.
- **Option B, chosen over Option A (single migration).** Two designs were considered for the dual-ID problem: keep the business key and drop the surrogate `id` (Option A), or keep `id` and drop the business key (Option B). Option A was rejected because `workspace_sync_runs` already had FKs pointing at the surrogate `id` for both tables — collapsing onto the business key would still require a *second* rename migration and a second full code sweep to get `id` out of the picture entirely. Option B reaches the same end state (one identity column) in a single migration.
- **Reconciliation rule: business value wins.** Where `id != feature_id`/`task_id` (confirmed only for go-owned rows — ts-owned rows already had `id == task_id` by construction via `workspace-github-adapter`'s `UpsertWorkspaceTask`), the migration sets `id := feature_id`/`task_id`, not the other way around — the business key was the value already referenced externally (API responses, activity events, FKs), so it is the one preserved.
- **Six-step single transaction.** `workspace_sync_runs`' surrogate-pointing FKs are dropped first (step 1), translated to business values while both columns still coexist (step 2), then `id` is reconciled (step 3), dependent FKs are re-pointed at `id` (step 4), the now-redundant business-key columns and their unique constraints are dropped (step 5), and `workspace_sync_runs`' FKs are re-added — now correctly pointing at `id`, which holds business values (step 6). All in one transaction: a failure at any step rolls back to the pre-migration dual-column schema intact.
- **API compatibility preserved.** `workflow-backend`'s DTOs still expose `feature_id`/`task_id` in JSON responses — both fields are now populated from the single `id` column instead of two independently-generated values. No client-facing contract change.
- **Out of scope.** `workspace_activity_events.feature_id`/`task_id` are untouched — that table has no FK (denormalized timeline) and was explicitly excluded from this unification.

## Promotion

The top-level `database/workspace/schema.dbml` is promoted to this v006 snapshot at documentation time. Source of truth for the physical schema remains `workflow-backend/migrations`.
