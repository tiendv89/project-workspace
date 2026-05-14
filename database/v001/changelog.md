# v001 — workspace-data-backend initial schema

**Feature**: `workspace-data-backend`
**Date**: 2026-05-15

## Tables added

- `workspaces` — one row per saved workspace; holds repo URL, name, active snapshot pointer, and source state.
- `workspace_snapshots` — immutable record per import or sync result; tracks status, source ref, commit SHA, and error info.
- `workspace_features` — one row per feature per snapshot; mirrors `status.yaml` fields as queryable columns.
- `workspace_feature_documents` — one row per feature document per snapshot; preserves raw markdown and YAML content for UI rendering.
- `workspace_tasks` — one row per task YAML per snapshot; stores all task state fields as queryable columns.
- `workspace_activity_events` — derived timeline rows from feature `history[]` and task `log[]`; enables timeline queries without scanning JSON arrays.

## Sync strategy additions

- `workspace_snapshots.last_targeted_sync_at` — tracks when a targeted webhook sync last updated rows in this snapshot in place, separate from `created_at` which reflects the full reconciliation time.
- `workspace_sync_runs` — one row per sync attempt (full or targeted). Records trigger type (`import`, `poll`, `webhook_base`, `webhook_feature`, `webhook_task`), mode, status, commit SHA, and changed file paths. Used for audit and detecting missed webhook deliveries.

## Design notes

- All tables include `workspace_id` for future multi-tenancy partitioning.
- Snapshots are immutable after creation. `workspaces.active_snapshot_id` is updated only after a snapshot is fully written.
- No credentials or expanded local paths are stored in any table.
- Physical names use lowercase `snake_case` throughout.
