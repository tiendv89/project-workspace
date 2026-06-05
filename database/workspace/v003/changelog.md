# v003 — task status transition timeline

**Feature**: `task-status-transition-timeline`
**Date**: 2026-06-05

## Tables added

- `workspace_task_status_timeline` — one row per task status interval. Tracks when a task enters and leaves each status. A partial unique index (`WHERE ended_at IS NULL`) ensures at most one active (open-ended) interval per task. A `CHECK` constraint guarantees `ended_at >= started_at` when both are present. `task_name` is denormalized from `workspace_tasks.title` for display convenience.

## Triggers added

- `fn_task_status_timeline_insert()` + `trg_task_status_timeline_insert` — PostgreSQL trigger fires on `AFTER INSERT ON workspace_tasks`. When a task is created with a non-empty status, opens the first active timeline interval automatically.
- `fn_task_status_timeline_change()` + `trg_task_status_timeline_change` — PostgreSQL trigger fires on `AFTER UPDATE OF status ON workspace_tasks`. On every status change it closes the prior open interval (`ended_at = now()`) and inserts a new active interval. No adapter-code changes required — every writer (adapter, scripts, manual fixes) is captured automatically.

## Migration notes

- No changes to existing tables.
- `workspace_tasks.status` remains the authoritative field for current task status; the timeline is derived.
- Status transitions that occurred before deployment are **not backfilled** — the first `UPDATE OF status` after migration creates the initial active interval.
- The triggers are no-ops when `NEW.status` equals `OLD.status` (including the first `INSERT` where OLD is null) and when status is empty/null.
- Repeated entry into the same status creates separate timeline rows (e.g. `todo → ready → todo` produces two `todo` intervals).

## Design notes

- Physical names remain lowercase `snake_case`.
- Timeline rows live in the CORE layer, read by `api-service`, written automatically by the trigger (no adapter changes).
- Task APIs batch-read timeline rows and expose them as `status_timeline` in task summary/detail responses.
- Frontend (`digital-factory-ui`) renders the current status interval from `status_timeline` in the task sidebar.
