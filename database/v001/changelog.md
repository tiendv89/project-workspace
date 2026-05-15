# v001 — workspace-data-backend initial schema

**Feature**: `workspace-data-backend`
**Date**: 2026-05-15

## Tables added

- `workspaces` — one row per saved workspace; holds workspace identity, management repo id, and branch routing config. Sync state is derived from `workspace_sync_runs`.
- `workspace_repos` — one row per repo declared in `workspace.yaml`; tasks reference these rows by logical `repo_id`.
- `workspace_features` — one row per current feature; mirrors `status.yaml` fields as queryable columns.
- `workspace_feature_documents` — one row per current feature document; preserves raw markdown and YAML content for UI rendering.
- `workspace_tasks` — one row per current task YAML; stores task state fields as queryable columns.
- `workspace_activity_events` — derived timeline rows from feature `history[]` and task `log[]`; enables timeline queries without scanning JSON arrays.
- `workspace_github_sources` — one GitHub source repository per workspace; stores repo URL, owner, repo name, and default branch.
- `workspace_snapshots` — one row per completed full reconciliation; tracks commit SHA and reconciliation status for adapter bookkeeping.
- `workspace_sync_runs` — one row per sync attempt; records trigger, branch, scope, mode, status, optional `snapshot_id`, changed paths, errors, and metadata.

## Sync strategy additions

- Full reconciliation writes current core tables in one transaction, writes a `workspace_snapshots` row on success, and links the sync run through `workspace_sync_runs.snapshot_id`.
- Targeted feature sync updates only the affected feature rows and records changed paths in `workspace_sync_runs.changed_paths`.
- Task-branch sync is backed by Redis/asynq, not PostgreSQL. The queue payload is `{ WorkspaceID, FeatureID, TaskID }`, deduped with `asynq.Unique(24h)`. Full reconciliation must use workspace-scoped queue clearing or stale-job skipping; it must not delete unrelated workspace jobs from a shared queue.
- Staleness is derived from the latest `workspace_sync_runs` row. The `workspaces` table has no source-state or active-snapshot columns.

## Design notes

- All tables include `workspace_id` for future multi-tenancy partitioning.
- Core tables always reflect the latest known state. `workspace_snapshots` is adapter bookkeeping for full reconciliation, not the read path for active data.
- No credentials or expanded local paths are stored in any table.
- Physical names use lowercase `snake_case` throughout.
