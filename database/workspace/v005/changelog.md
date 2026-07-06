# v005 — go-orchestrator autonomy: task dispatch tracking + feature handoffs

**Features**: `go-orchestrator-autonomy` (00021)
**Date**: 2026-07-05
**Migrations**: 00021

## Tables altered

### `workspace_tasks`

- **Added** (all nullable or safe-defaulted — backward compatible):
  - `dispatch_handle text`, `dispatch_nonce text`, `dispatched_at timestamptz` — identify and timestamp the current in-flight dispatch. Re-enqueue reuses the SAME handle+nonce so the reconciler can tell a stale dispatch from the current one.
  - `reenqueue_attempts int NOT NULL DEFAULT 0` — bumped durably before each reconciler re-enqueue.
  - `review_incomplete_count int NOT NULL DEFAULT 0` — escalates to `blocked` after `MAX_REVIEW_INCOMPLETES`.
  - `max_turns_retry_count int NOT NULL DEFAULT 0`.
  - `rebase_attempts int NOT NULL DEFAULT 0` — capped at `MAX_REBASE_ATTEMPTS`.
  - `conflict_state text NOT NULL DEFAULT 'none'` — in-flight conflict state (`'none'` / `'resolving'` / etc.).
  - `dispatch_kind text` — kind of the current dispatch (claim / fix / reviewer / rebase).
  - `blocked_from_status text` — status the task was in immediately before transitioning to `blocked`, for the Error/stuck recovery flow.
  - `blocked_details text` — free-form failure context alongside the machine-readable `blocked_reason`.
- **Index added**: `idx_workspace_tasks_go_inflight` — partial index on `(workspace_id) WHERE owner='go' AND (status IN ('in_progress','reviewing') OR conflict_state='resolving')`. Serves the per-cycle soft-claim in-flight count and the reconciler deadline scan.

## Tables added

### `workspace_feature_handoffs` (00021)

One row per feature handoff event. `UNIQUE(feature_id)` doubles as the multi-instance handoff-trigger guard — only one handoff can exist per feature. Lifecycle: starts `'draft'`, promoted to `'open'` once every handoff PR is created; finalize acts on `'open'`. `create_attempts` bounds retries of the handoff-reconcile PR-creation loop before the handoff is marked terminally `'failed'`. `updated_at` tracks the last state transition, aligning with the convention already used on `workspaces` / `workspace_features` / `workspace_tasks`.

### `workspace_feature_handoff_prs` (00021)

One row per implementation-repo PR opened during a feature handoff. FK's to `workspace_feature_handoffs.id` `ON DELETE CASCADE`. `conflict_resolution_attempts` tracks attempts to resolve a merge conflict between an open handoff PR and its base branch — a distinct counter from `workspace_tasks.rebase_attempts` (routine rebases, not handoff-PR conflict resolution). Carries its own dispatch-tracking columns (`dispatch_handle`, `dispatch_nonce`, `dispatched_at`, `reenqueue_attempts`) mirroring `workspace_tasks`, since handoff-PR rebase is dispatched the same way task work is. `UNIQUE(handoff_id, repo)` — one PR row per repo per handoff.

- **Index added**: `handoff_id` — FK-join index (Postgres does not auto-create indexes on FK columns); serves finalize checks (are all PRs of a handoff merged?) and per-handoff PR listings.
- **Index added**: `idx_workspace_feature_handoff_prs_resolving` — partial index on `(id) WHERE conflict_state='resolving'`, mirroring the `workspace_tasks` inflight index for the handoff-PR half of `MAX_INFLIGHT`.

## Migration sequence

| # | File | Feature | Change |
|---|------|---------|--------|
| 00021 | `go_orchestrator_autonomy.sql` | go-orchestrator-autonomy | `workspace_tasks` dispatch/counter/state columns + partial inflight index; `workspace_feature_handoffs` and `workspace_feature_handoff_prs` tables created |

## Design notes

- **Dispatch tracking.** `dispatch_handle` + `dispatch_nonce` together identify one in-flight execution attempt. The reconciler scans `in_progress` / `reviewing` tasks past `EXECUTION_DEADLINE_MS`, re-enqueues with the SAME handle+nonce (not a new one), and bumps `reenqueue_attempts` durably *before* enqueueing — so a crash between the bump and the enqueue never loses the attempt count.
- **Handoff lifecycle guard.** `UNIQUE(feature_id)` on `workspace_feature_handoffs` is intentionally the only guard against a duplicate handoff trigger firing twice for the same feature (no separate advisory lock) — a second trigger's insert simply conflicts.
- **Two independent conflict trackers.** `workspace_tasks.rebase_attempts`/`conflict_state` cover a task branch's routine pre-PR rebase; `workspace_feature_handoff_prs.conflict_resolution_attempts`/`conflict_state` cover a merge conflict on an already-open handoff PR. They are not the same counter and must not be conflated.
- **Inflight indexes are partial by design.** Both `idx_workspace_tasks_go_inflight` and `idx_workspace_feature_handoff_prs_resolving` exist purely to make the per-cycle `MAX_INFLIGHT` headroom count cheap; the dispatcher's in-process cap remains the hard enforcement point, these indexes only serve the read.

## Promotion

The top-level `database/workspace/schema.dbml` is promoted to this v005 snapshot at documentation time. Source of truth for the physical schema remains `workflow-backend/migrations`.
