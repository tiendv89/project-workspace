# v003 — orchestrator ownership (`owner` discriminator)

**Feature**: `workflow-db`
**Date**: 2026-06-06 (drafted; migration pending — this is workflow-db task **T1**)
**Status**: planned — design-stage. The goose migration is not yet written; this snapshot specifies its post-migration state.

> **Baseline reconciliation (included in this v003).** The v001/v002 `schema.dbml` snapshots were a simplified model that had drifted from the actual `workflow-backend` migrations. This v003 snapshot is **reconciled to the true physical schema** (migrations `00001–00014`) before layering the `owner` change, correcting: `feature_id`/`task_id` are surrogate **UUIDs** (the human slugs live in `feature_name`/`task_name`, added by `00009`/`00010`); `feature_id` FKs to `workspace_features.id` on tasks/documents; `workspace_sync_runs.feature_id`/`task_id` are UUID FKs (`00011`, `ON DELETE SET NULL`); `workspaces.slack_channel_id` exists (`00012`); the `workspace_tasks` unique is `(workspace_id, feature_id, task_name)` + `(workspace_id, task_id)`. Source of truth = `workflow-backend/migrations`.

## Tables altered

- `workspace_features`
  - **Added**: `owner text` (nullable) — `NULL`/absent = legacy git/YAML feature (driven by the TS orchestrator + adapter sync); `'go'` = DB-native feature (driven by the Go/Postgres orchestrator). An absent/`NULL` value means **TS**, so every existing row is unaffected and needs **no backfill**.
  - **Relaxed**: `source_path` from `NOT NULL` to nullable — DB-native (`owner='go'`) rows have no YAML origin. (`source_hash` was already nullable.)
  - **Added index**: `(workspace_id, owner)` — scopes each orchestrator to its own features.
- `workspace_tasks`
  - **Added**: `owner text` (nullable) — **denormalized** from the owning feature so the Go orchestrator's eligibility scan needs no join to `workspace_features`. The writer keeps it consistent with the feature's `owner` on every insert/update.
  - **Relaxed**: `source_path` from `NOT NULL` to nullable — same reason as features.
  - **Added index**: `(workspace_id, owner, status)` — the Go orchestrator's eligibility scan (`owner='go' AND status='ready'`).

## Migration sequence

Implemented by a single **additive** goose migration in `workflow-backend/migrations/` (next sequence: `00015_*_owner`):

1. `ALTER TABLE workspace_features ADD COLUMN owner TEXT;`
   `ALTER TABLE workspace_features ALTER COLUMN source_path DROP NOT NULL;`
   `CREATE INDEX ... ON workspace_features (workspace_id, owner);`
2. `ALTER TABLE workspace_tasks ADD COLUMN owner TEXT;`
   `ALTER TABLE workspace_tasks ALTER COLUMN source_path DROP NOT NULL;`
   `CREATE INDEX ... ON workspace_tasks (workspace_id, owner, status);`

Purely additive — safe for the running read API (api-service) and the YAML→DB sync (adapter-service), which keep operating on `owner IS NULL` rows unchanged until workflow-db task **T2** scopes the adapter's reconciliation to `owner IS NULL`.

## Design notes

- **Absent `owner` ⇒ TS.** No backfill; existing rows keep `owner = NULL` and behave exactly as today.
- **Second writer to the core tables.** Today `adapter-service` is the sole writer of the core tables (upsert from YAML). v003 introduces a second writer — the **Go orchestrator** (`workflow-orchestrator`), scoped to `owner='go'` rows. The single-owner-per-feature invariant keeps the two from colliding. See `docs/features/workflow-db/technical-design.md` §4.
- **`tasks.owner` denormalization (resolved).** `workflow-db` left "denormalize onto `workspace_tasks` vs join-to-feature" open; v003 resolves it as **denormalized** for query cost.
- Cross-DB `workspaces.organization_id → user-service organizations.id` is unchanged from v002 (plain UUID, no FK).
- Physical names remain lowercase `snake_case`.

## Promotion

Per the established practice — the v002 snapshot was published in its feature's **Phase-1 technical-design commit** (`m1-identity-and-workspaces`, #401), *before* its migration shipped — the top-level `database/workspace/schema.dbml` is promoted to this v003 snapshot **at design time** (now). The goose migration that realizes it is workflow-db task **T1** (`workflow-backend/migrations/00015_*_owner`); the published snapshot is the spec the migration must match.
