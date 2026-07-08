# Product Specification

## Feature
- Feature ID: `go-orchestrator-activity-logging`
- Title: Activity logging for workflow-backend feature/task mutations (Go orchestrator flow)

## Problem

`workflow-backend` maintains a `workspace_activity_events` table (feature-level `history[]` +
task-level `log[]` equivalents, migration `00006_workspace_activity_events.sql`) that is the single
source of activity truth for both flows:

- **TS/git flow**: activity is authored as git commits (`status.yaml` stage history, task YAML
  `log[]` entries) on the feature branch. `workspace-github-adapter`'s sync worker parses those commits
  and upserts rows into `workspace_activity_events` — git history is therefore the source of truth,
  and the adapter is only a projection of it into the shared table.
- **Go/Postgres flow**: there is no git history to project from — `owner='go'` rows are explicitly
  excluded from the adapter's sync/reconciliation scope (`workflow-db` design, §4.2). The **only** way
  a `workspace_activity_events` row can exist for a go-owned feature/task is a direct `INSERT` from
  `workflow-backend` itself.

Auditing `workflow-backend`'s actual code (`internal/database/queries.go`, `internal/service/workspace.go`,
`internal/handler/workspace.go`) shows this direct-insert path is inconsistently implemented:

**Already inserting an activity row (verified in code):**
- `UnblockTask` → inserts `action='unblocked'`
- `RecoverTask` → inserts `action='recovered'`

Both source `actor` from `authmw.FromContext(ctx).UserID` — the raw `X-User-Id` header value (a UUID),
**not** a human-readable email or display name. This differs from the TS/git flow, where task log
`actor` values are readable identities (e.g. `pye@swellnetwork.io`) synced from real git commit
authors. Surfacing a bare UUID as "actor" in the UI is not acceptable — engineering wants readable
identity here too.

**NOT inserting any activity row (verified — no `INSERT INTO workspace_activity_events` present):**
- `UpdateFeatureStage` (`PATCH /api/workspaces/:workspaceId/features/:featureId/stage`) — feature
  stage-review decisions (approve/reject/reopen) and the resulting `feature_status`/`current_stage`/
  `next_action` changes (e.g. `in_design` → `in_tdd` → `ready_for_implementation` → ... → `done`).
- `CreateWorkspaceTasks` (`POST /api/workspaces/:workspaceId/features/:featureId/tasks`) — bulk
  all-or-nothing task creation for a go-owned feature at tasks-stage approval.
- `ActivateReadyTasks` (`POST /api/workspaces/:workspaceId/features/:featureId/tasks/activate-ready`)
  — auto-ready `todo` → `ready` transitions for tasks whose dependencies just completed.
- `CreateWorkspaceFeature` (`POST /api/workspaces/:workspaceId/features`) — feature creation.

Net effect: for a go-owned feature, a human looking at its activity feed today sees task
`unblocked`/`recovered` events (with an unreadable actor) but **no record at all** of when the
feature was created, when each stage was approved/rejected/reopened, when tasks were created, or
when tasks auto-readied. This is a materially incomplete activity trail compared to the TS/git flow,
where every one of these events has a git-commit-backed log entry.

## Scope

This feature covers **`workflow-backend` only**. The Go orchestrator process (`workflow-orchestrator`
repo) already has its own internal activity logger (`internal/orchestrator/activity.go`:
`AppendLogTx`/`appendLogInsert`, used by `GuardedTransition`, `DispatchReviewer`, `DispatchFix`,
`SetBlocked*`, `ReapCompleted`, `PollMergedPRs`, etc.) and is explicitly **out of scope** here — this
feature does not touch the orchestrator's own poll-loop transitions, only the `workflow-backend` HTTP
API surface that is invoked directly by hermes-agent / `digital-factory-ui` (not by the orchestrator).

Per direction: both feature-level and task-level activity must be tracked, matching the breadth of
what `workspace-github-adapter` does for TS-owned features (feature `history[]` + task `log[]` →
`workspace_activity_events`).

## Goals

1. **Log every currently-unlogged mutation** in `workflow-backend` that changes `workspace_features`
   or `workspace_tasks` state, by inserting a `workspace_activity_events` row in the same transaction
   as the mutation:
   - `UpdateFeatureStage` — one event per stage-review decision (approve/reject/reopen), `scope_type='feature'`.
   - `CreateWorkspaceTasks` — one event per created task (or one feature-scoped summary event covering
     the batch — resolved in technical design), `scope_type` depends on the choice.
   - `ActivateReadyTasks` — one event per task transitioned `todo` → `ready`, `scope_type='task'`.
   - `CreateWorkspaceFeature` — one event marking feature creation, `scope_type='feature'`.
2. **Fix actor readability** for all go-flow activity events — existing (`unblocked`, `recovered`) and
   newly-added — so `actor` reflects a human-readable identity (email or display name), not a bare
   `X-User-Id` UUID. The concrete mechanism (BFF-forwarded header vs. read-time join to `user-service`)
   is an open question for technical design, not decided here.
3. Preserve the existing event shape/consumption contract: `WorkspaceActivityEvent` /
   `domain.ActivityEvent` fields (`action`, `scope_type`, `actor`, `note`, `occurred_at`, `sequence`,
   `feature_id`, `task_id`), the `ListActivity` endpoint's `audience=internal|client` behavior, and the
   `clientAudienceAllowlist` relabeling mechanism in `internal/service/workspace.go`. New `action`
   values introduced by this feature must be added to `clientAudienceAllowlist` if they should be
   client-visible (open question for technical design: which of the new actions are client-facing).
4. All new inserts must be transactional with their corresponding state mutation (mirroring the
   existing `UnblockTask`/`RecoverTask` pattern: single DB transaction, guarded update + activity
   insert, commit together) — no mutation should succeed while its activity log write silently fails
   or vice versa.

## Non-goals

- No changes to the Go orchestrator (`workflow-orchestrator` repo) or its existing `AppendLogTx`
  activity logging — that path is already complete and is out of scope.
- No changes to the TS/git flow or `workspace-github-adapter`'s sync/reconciliation logic.
- No backfill of historical activity for existing go-owned features/tasks — forward-only from when
  this ships.
- No new activity-consuming UI work — this feature only ensures the data exists in
  `workspace_activity_events`; any UI changes to surface it are out of scope (tracked separately, cf.
  `go-orchestrator-status-ui`, `ui-go-owned-task-status-and-block`).
- Mechanism for actor email/display-name resolution (header-forwarding vs. read-time join) is
  explicitly deferred to technical design, not specified here.

## Open questions for technical design

- How does `workflow-backend` obtain a human-readable actor identity from `X-User-Id`? Two options
  identified during spec research:
  (a) `workflow-bff`'s proxy resolves `user_id` → email/display_name via its existing `userservice`
      service client (already used for `UpsertIdentity`) and forwards an additional header (e.g.
      `X-User-Email` / `X-User-Name`) that `workflow-backend` stores directly as `actor`.
  (b) `workflow-backend` stores `user_id` as `actor` and resolves email/display name at **read time**
      in `ListActivity`, via a new service-to-service call to `user-service` (which owns `users.email`,
      `users.display_name` — see `internal/users/users.go` `Store.FindByID`).
- Should `CreateWorkspaceTasks` log one `workspace_activity_events` row per task, or a single
  feature-scoped summary event for the whole batch?
- Which of the new `action` values (e.g. `stage_approved`, `stage_rejected`, `stage_reopened`,
  `tasks_created`, `auto_readied`, `feature_created` — exact names TBD) should be added to
  `clientAudienceAllowlist` for `audience=client` visibility, vs. internal-only?
- Should `hermes-agent`'s service-to-service calls (vs. a human's direct BFF-proxied action) surface a
  distinguishable actor (e.g. "hermes-agent on behalf of `<user>`"), or is the underlying human actor
  sufficient?
