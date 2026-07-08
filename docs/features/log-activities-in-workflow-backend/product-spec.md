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
   - `CreateWorkspaceTasks` — one event per created task, `scope_type='task'` (see field-mapping table
     below; batch-vs-per-task granularity is fixed here, not left open).
   - `ActivateReadyTasks` — one event per task transitioned `todo` → `ready`, `scope_type='task'`.
   - `CreateWorkspaceFeature` — one event marking feature creation, `scope_type='feature'`.
2. **Fix actor readability** for all go-flow activity events — existing (`unblocked`, `recovered`) and
   newly-added — so `actor` reflects a human-readable identity (email or display name), not a bare
   `X-User-Id` UUID. The concrete mechanism (BFF-forwarded header vs. read-time join to `user-service`)
   is an open question for technical design, not decided here.
3. Preserve the existing event shape/consumption contract: `WorkspaceActivityEvent` /
   `domain.ActivityEvent` fields (`action`, `scope_type`, `actor`, `note`, `occurred_at`, `sequence`,
   `feature_id`, `task_id`) and the `ListActivity` endpoint's `audience=internal|client` behavior.
   `clientAudienceAllowlist` (`internal/service/workspace.go`) is the hardcoded map that `ListActivity`
   uses to filter+relabel events when the caller requests `audience=client`: any `action` value not
   present as a key in this map is silently dropped from client-facing responses, and present keys are
   relabeled to a friendlier client string (e.g. internal `done` → client `"Completed"`). Every new
   `action` introduced by this feature MUST be added to `clientAudienceAllowlist`, or it will be logged
   to the database but invisible to any `audience=client` consumer. See the field-mapping table below
   for the exact entries to add.
4. `ActivateReadyTasks` currently has no caller-supplied actor at all (it is invoked without any
   identity input). This feature requires the caller to supply an explicit `actor` on that request —
   auto-ready is a side effect of a caller's action (e.g. a tasks-stage approval or a task being marked
   done) and should attribute to that caller, not to a synthetic `"system"` value. See the field-mapping
   table below for the required request-shape change.
5. All new inserts must be transactional with their corresponding state mutation (mirroring the
   existing `UnblockTask`/`RecoverTask` pattern: single DB transaction, guarded update + activity
   insert, commit together) — no mutation should succeed while its activity log write silently fails
   or vice versa.

## Activity event field mapping (per action)

To avoid mismatch at implementation time, every new/fixed insert into `workspace_activity_events`
must populate exactly these columns. Column names are taken verbatim from the live schema and the two
working inserts (`UnblockTask`, `RecoverTask` in `internal/database/queries.go`) — new actions follow
the same shape.

`workspace_activity_events` columns (every insert uses this same 10-column shape):
`workspace_id, scope_type, feature_id, task_id, action, actor, occurred_at, note, sequence, raw_event`

Columns that are **identical across every row regardless of action** (not repeated per-row below):
- `workspace_id` — always the resolved `wsID` (`pgtype.UUID`) for the request's workspace.
- `occurred_at` — always `time.Now().UTC().Format(time.RFC3339)`, set at insert time (matches
  `UnblockTask`/`RecoverTask` today).
- `sequence` — always `(SELECT COALESCE(MAX(sequence), 0) + 1 FROM workspace_activity_events WHERE
  workspace_id = $1 AND feature_id = $2 AND task_id = $3)`, scoped identically to the existing
  `UnblockTask`/`RecoverTask` inserts (task_id is `NULL` for feature-scoped events, so the same
  scoping expression naturally partitions sequences per feature when task_id is absent).
- `raw_event` — always `'{}'` (jsonb empty object) for this feature, matching current behavior
  exactly. No structured payload is introduced now — a future feature may populate it.

| # | Action / API | Code path (handler → service → query) | `scope_type` | `action` value | `feature_id` | `task_id` | `actor` | `note` |
|---|---|---|---|---|---|---|---|---|
| 1 | Feature created | `CreateFeature` handler → `WorkspaceService.CreateFeature` → `Reader.CreateWorkspaceFeature` | `feature` | `feature_created` | new feature's `feature_id` (UUID returned by insert) | `NULL` | resolved identity for the calling user (`authmw.FromContext(ctx).UserID` → resolved per Open Question) | feature `title` (e.g. `"Add payment retry logic"`) — gives a human-readable label without a join |
| 2 | Stage decision: approve | `UpdateFeatureStage` handler → `WorkspaceService.UpdateFeatureStage` → `Reader.UpdateFeatureStage` | `feature` | `stage_approved` | `feat.FeatureID` | `NULL` | resolved identity for `input.Actor` (already threaded from caller — only needs identity resolution, no new plumbing) | `input.Stage` value (e.g. `"technical_design"`) — required because `action` alone doesn't say which stage |
| 3 | Stage decision: reject | same as #2 | `feature` | `stage_rejected` | `feat.FeatureID` | `NULL` | same as #2 | `input.Stage` value, plus the reject comment if the caller supplied one (thread through `UpdateFeatureStageInput` if not already present — confirm in tech design) |
| 4 | Stage decision: reopen | same as #2 | `feature` | `stage_reopened` | `feat.FeatureID` | `NULL` | same as #2 | `input.Stage` value |
| 5 | Task created (bulk create, one row per task) | `CreateTasks` handler → `WorkspaceService.CreateTasks` → `Reader.CreateWorkspaceTasks` (loop `insertGoTask`) | `task` | `task_created` | `fid` (feature UUID passed into `CreateWorkspaceTasks`) | each created task's `task_id` (UUID returned per row by `insertGoTask`) | resolved identity for the calling user (BFF identity on this endpoint per `RequireBFFIdentity`) | task `title` (e.g. `"Add retry queue schema"`) — mirrors the `feature_created` note choice for readability |
| 6 | Task auto-readied (`todo` → `ready`) | `ActivateReadyTasks` handler → `WorkspaceService.ActivateReadyTasks` → `Reader.ActivateReadyTasks` (loop) | `task` | `activate` | `fid` | each activated task's UUID (the `t.id` used in the `UPDATE ... WHERE id = t.id` loop) | **required, caller-supplied** — `ActivateReadyTasks` today takes no actor input at all; this feature adds a required `actor` field to the request body (`POST .../tasks/activate-ready`), validated the same way `UpdateFeatureStage` already requires `input.Actor` (missing → 400). No default/fallback value — the caller (e.g. hermes-agent completing a tasks-stage approval, or whatever triggers the auto-ready) must supply the identity performing the triggering action. | `"Activated by {display_name}"` — `{display_name}` is the resolved human-readable identity for the caller-supplied actor (same value as the `actor` column, restated in `note` for readability) |
| 7 | Task unblocked *(existing — fix actor only)* | `UnblockTask` handler → `WorkspaceService.UnblockTask` → `Reader.UnblockTask` | `task` (existing, unchanged) | `unblocked` (existing, unchanged) | `featureIDStr` (existing, unchanged) | `taskIDStr` (existing, unchanged) | **change**: resolved human identity instead of raw `input.Actor` UUID | `input.Note` (existing, unchanged — already optional caller-supplied text) |
| 8 | Task recovered *(existing — fix actor only)* | `RecoverTask` handler → `WorkspaceService.RecoverTask` → `Reader.RecoverTask` | `task` (existing, unchanged) | `recovered` (existing, unchanged) | `featureIDStr` (existing, unchanged) | `taskIDStr` (existing, unchanged) | **change**: resolved human identity instead of raw `input.Actor` UUID | `input.Note` (existing, unchanged) |

### Worked examples (one concrete row per action)

These show actual sample values the table above would produce, so the shape can be sanity-checked
before implementation. Assume workspace `ws-9f2a`, feature `feat-77c1` ("Add payment retry logic"),
actor resolves to display name `"Alice Nguyen"` (email `alice@acme.com`) throughout.

| # | Action | Example row (`scope_type` / `action` / `feature_id` / `task_id` / `actor` / `note`) |
|---|---|---|
| 1 | Feature created | `feature` / `feature_created` / `feat-77c1` / `NULL` / `Alice Nguyen` / `"Add payment retry logic"` |
| 2 | Stage approved | `feature` / `stage_approved` / `feat-77c1` / `NULL` / `Alice Nguyen` / `"technical_design"` |
| 3 | Stage rejected | `feature` / `stage_rejected` / `feat-77c1` / `NULL` / `Alice Nguyen` / `"technical_design: needs more detail on rollback plan"` (stage + reject comment, if supplied) |
| 4 | Stage reopened | `feature` / `stage_reopened` / `feat-77c1` / `NULL` / `Alice Nguyen` / `"product_spec"` |
| 5 | Task created | `task` / `task_created` / `feat-77c1` / `task-T3` / `Alice Nguyen` / `"Add retry queue schema"` |
| 6 | Task auto-readied | `task` / `activate` / `feat-77c1` / `task-T4` / `Alice Nguyen` / `"Activated by Alice Nguyen"` |
| 7 | Task unblocked | `task` / `unblocked` / `feat-77c1` / `task-T2` / `Alice Nguyen` / `"retried after fixing Qdrant auth"` (caller-supplied, optional) |
| 8 | Task recovered | `task` / `recovered` / `feat-77c1` / `task-T5` / `Alice Nguyen` / `"force-reset from stuck in_progress"` (caller-supplied, optional) |

Note for row 6: `actor` and the human-readable name inside `note` are the same resolved identity —
`note` intentionally restates it as `"Activated by {display_name}"` so the activity feed reads well
as a standalone sentence even before any UI joins `actor` into a nicer display, consistent with the
other rows using `note` for a short human-readable description of what happened.

### `clientAudienceAllowlist` entries to add

`internal/service/workspace.go`'s `clientAudienceAllowlist` maps internal `action` → client-facing
label; actions absent from the map are dropped from `audience=client` responses. This feature adds the
following entries (existing entries are unchanged):

| `action` (map key) | Client label (map value) | Notes |
|---|---|---|
| `feature_created` | `"Created"` | mirrors the existing task `created` → `"Created"` mapping |
| `stage_approved` | `"Approved"` | new |
| `stage_rejected` | `"Rejected"` | new |
| `stage_reopened` | `"Reopened"` | new |
| `task_created` | `"Created"` | new |
| `auto_readied` | `"Ready"` | mirrors the existing `ready` → `"Ready"` mapping — **note**: map key updated to `activate` per the action-value correction above (was `auto_readied` in an earlier draft) |
| `unblocked` | `"Unblocked"` | not currently in the allowlist — added so client audiences can see unblock history |
| `recovered` | `"Recovered"` | not currently in the allowlist — added so client audiences can see recovery history |

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
- No structured `raw_event` payloads introduced by this feature — `raw_event` stays `'{}'` for every
  new insert, matching current behavior.

## Open questions for technical design

- How does `workflow-backend` obtain a human-readable actor identity from `X-User-Id`? Two options
  identified during spec research:
  (a) `workflow-bff`'s proxy resolves `user_id` → email/display_name via its existing `userservice`
      service client (already used for `UpsertIdentity`) and forwards an additional header (e.g.
      `X-User-Email` / `X-User-Name`) that `workflow-backend` stores directly as `actor`.
  (b) `workflow-backend` stores `user_id` as `actor` and resolves email/display name at **read time**
      in `ListActivity`, via a new service-to-service call to `user-service` (which owns `users.email`,
      `users.display_name` — see `internal/users/users.go` `Store.FindByID`).
- For row #3 (`stage_rejected`), does `UpdateFeatureStageInput` already carry a reject comment end to
  end from the approval UI, or does that plumbing need to be added as part of this feature?
- For row #6 (`activate`), is it cheap to include the specific dependency task names that just
  completed and triggered the auto-ready in `note`, in addition to the actor attribution — or is
  `"Activated by {display_name}"` alone sufficient?
- For row #6, which caller(s) invoke `ActivateReadyTasks` today and will need to be updated to pass
  the new required `actor` field? (e.g. hermes-agent's tasks-stage approve flow, and any other caller
  found in the codebase.) Confirm the full caller list in technical design so none are missed.
- Confirm the `clientAudienceAllowlist` entries above are complete and correctly labeled before
  implementation — in particular whether `unblocked`/`recovered` becoming client-visible for the first
  time has any downstream UI impact that needs coordinating.
- Should `hermes-agent`'s service-to-service calls (vs. a human's direct BFF-proxied action) surface a
  distinguishable actor (e.g. "hermes-agent on behalf of `<user>`"), or is the underlying human actor
  sufficient?
