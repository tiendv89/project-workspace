# Technical Design

## Feature
- Feature ID: `go-orchestrator-activity-logging`
- Title: Activity logging for workflow-backend feature/task mutations (Go orchestrator flow)

## Current State

`workflow-backend` (repo `workflow-backend`, Go/gin/pgx) exposes the workspace API consumed by
hermes-agent (`src/services/workflow_backend_client.py`, service-to-service via `Authorization: Bearer
<WORKFLOW_BACKEND_SERVICE_TOKEN>` + `X-User-Id`/`X-Org-Id` headers) and by `digital-factory-ui` via
`workflow-bff`'s browser-session proxy (`internal/app/api/handler/proxy/proxy_handler.go`, which
injects `X-User-Id`/`X-Org-Id`/`X-Accessible-Org-Ids` from the session after stripping the browser's
own cookie/Authorization).

`workflow-backend`'s `RequireBFFIdentity` middleware (`internal/authmw/bff_identity.go`) extracts only
`X-User-Id` (a UUID string) into `AuthCtx.UserID` — no email or display name ever reaches
`workflow-backend`. Both existing activity-logging call sites (`UnblockTask`, `RecoverTask` in
`internal/database/queries.go`) store this raw UUID directly as `workspace_activity_events.actor`.

`workspace_activity_events` (migration `00006_workspace_activity_events.sql`) is read via
`Reader.ListActivityEvents` → `WorkspaceService.ListActivity` → `GET
/api/workspaces/:workspaceId/activity`. Four target mutation paths in `internal/database/queries.go` /
`internal/service/workspace.go` currently write no activity row at all: `Reader.CreateWorkspaceFeature`,
`Reader.UpdateFeatureStage`, `Reader.CreateWorkspaceTasks` (loop over `insertGoTask`), and
`Reader.ActivateReadyTasks`.

Separately, `user-service` (repo `user-service`) already exposes exactly the batch identity-resolution
primitive this feature needs: `GET /internal/users?ids=<uuid,uuid,...>` (`Handler.ListUsersByIDs`,
`internal/handler/workspace.go`), a service-token-protected internal route
(`Handler.RegisterInternal`, `internal/handler/router.go`) that returns `{users: [{user_id,
display_name, email, avatar_url}, ...]}`, skipping malformed/unknown IDs rather than failing the whole
batch. `workflow-bff` already has a working reference client for a sibling `user-service` internal
endpoint (`internal/pkg/serviceclient/userservice/client.go`, plain `net/http` + bearer token) that this
feature's new `workflow-backend`→`user-service` client can mirror. `workflow-backend` currently has no
`user-service` client at all.

`ActivateReadyTasks` (`Reader.ActivateReadyTasks`, `WorkspaceService.ActivateReadyTasks`, handler `POST
/api/workspaces/:workspaceId/features/:featureId/tasks/activate-ready`) takes no actor input in its
request body today. Its only known caller is hermes-agent's `activate_ready_tasks`
(`src/services/workflow_backend_client.py`), invoked from the tasks-stage approve flow
(`plugins/tools/approve.py`, referenced as `_activate_tasks_db`'s replacement) — this is the caller that
must be updated to supply the new required `actor`.

## Constraints

- Every insert must land in the existing 10-column `workspace_activity_events` shape
  (`workspace_id, scope_type, feature_id, task_id, action, actor, occurred_at, note, sequence,
  raw_event`) — no schema migration in this feature (per product spec Non-goals: no structured
  `raw_event` payload, no backfill).
- **No external (HTTP) call may execute inside an open database transaction.** Actor resolution (a
  call to `user-service`) must complete, with a bounded timeout and a safe fallback, before any
  `pgx.Tx` for the mutation is opened. This avoids holding a DB connection/lock open across a network
  round-trip, and avoids a `user-service` hiccup ever aborting a DB transaction.
- **Activity logging is best-effort and must never fail or roll back the primary mutation.** Neither
  an actor-resolution failure nor an activity-event insert failure may cause the feature/task mutation
  itself to fail. The primary state change (feature created, stage decision persisted, tasks created,
  tasks activated, task unblocked/recovered) is the mandatory operation; the activity log entry is a
  side effect that degrades gracefully (see Chosen Design §2–3 for the mechanism).
- `workflow-backend` must not create a circular dependency on `workflow-bff` — it must call
  `user-service` directly (mirroring `workflow-bff`'s own client), not proxy through `workflow-bff`.
- `ActivateReadyTasks`'s request-shape change (adding required `actor`) is a breaking change to an
  existing endpoint — every caller must be updated in the same rollout, not after.
- Per product spec Goal 3, every new `action` value must be added to `clientAudienceAllowlist`
  (`internal/service/workspace.go`) in the same change, or it is silently invisible to
  `audience=client` callers.
- Per product spec: this feature covers `workflow-backend` only. `workflow-orchestrator`'s own
  `AppendLogTx`/`GuardedTransition` logging is untouched. `workspace-github-adapter`'s sync/reconciliation
  is untouched.

## Options Considered

### Option A — Actor resolution: read-time join in `ListActivity`
Store raw `user_id` in `actor` at write time (as today); `WorkspaceService.ListActivity` calls
`user-service`'s `GET /internal/users?ids=...` batch endpoint at read time, joining `user_id` → display
name only when serving a response.
- Pros: single source of truth for identity (always current display name); no new outbound call on
  every mutating request (write path stays fast); one batch call covers an entire activity-list page.
- Cons: read path now has an external dependency and added latency on every `ListActivity` call
  (including `audience=internal` polling paths); if `user-service` is briefly unavailable, activity
  reads either degrade to showing raw UUIDs or fail entirely; historical events show the user's
  *current* name, which does not match the "audit trail" semantics of git-commit-authorship (git
  commits are immutable snapshots of the author string at time of commit).

### Option B — Actor resolution: write-time resolution in `workflow-backend`
Every write-path handler that has `authmw.FromContext(ctx).UserID` (or `input.Actor` UUID) calls
`user-service`'s `GET /internal/users?ids=<uid>` once, resolves the display name, and stores the
resolved string directly in `workspace_activity_events.actor`. `ListActivity` needs no join — it is
read-only and unchanged beyond the new event rows appearing.
- Pros: matches the TS/git flow's actual semantics — `actor` in a task/feature log entry is a
  point-in-time record of who acted, immutable afterward (same as a git commit's author field never
  changing even if the person later changes their GitHub display name). Read path (`ListActivity`)
  stays exactly as fast/simple as today — zero added latency, zero new dependency on the hot read path.
  Failure mode is isolated to individual write requests, not every future read.
- Cons: one extra synchronous HTTP call per mutating request (feature create, stage decision, task
  create batch, activate-ready, unblock, recover) before the DB transaction commits; if `user-service`
  is down, the mutating request either fails or must fall back to storing the raw UUID (needs an
  explicit fallback decision, see Chosen Design).

### Option C — Header-forwarding via `workflow-bff`
Extend `workflow-bff`'s proxy (`buildUpstreamRequest` in `proxy_handler.go`) to resolve
`session.UserID` → email/display name via its existing `userservice.Client` and inject a new
`X-User-Email`/`X-User-Name` header alongside `X-User-Id`, which `workflow-backend`'s
`RequireBFFIdentity` reads directly (no outbound call from `workflow-backend` at all).
- Pros: zero new outbound HTTP dependency inside `workflow-backend` itself; identity resolution
  happens once per browser-session request in a place that already has a `user-service` client.
- Cons: **does not cover hermes-agent's calls**, which bypass `workflow-bff` entirely (hermes-agent
  calls `workflow-backend` directly per its client's own docstring: *"hermes-agent calls
  workflow-backend directly (no BFF) to create tasks"*) — hermes-agent has no session, no
  `workflow-bff` proxy in its path, so this option leaves feature-creation, stage-decision, and
  task-creation actors (all triggered via hermes-agent) unresolved. It only fixes the `digital-factory-ui`
  browser path. Rejected as incomplete for this feature's full action set.

## Chosen Design

**Option B — write-time resolution inside `workflow-backend`**, because it is the only option that
covers both callers (hermes-agent direct calls AND `workflow-bff`-proxied browser calls) with one
mechanism, and its "point-in-time actor" semantics match the existing git-flow audit-trail behavior
that this feature is explicitly trying to bring parity with (per product spec Problem statement).

### 1. New `user-service` client in `workflow-backend`

Add `internal/adapter/userservice/client.go` (new package), a plain `net/http` + bearer-token client
mirroring `workflow-bff`'s `internal/pkg/serviceclient/userservice/client.go` shape:

```go
package userservice

type Client struct {
    baseURL    string
    token      string
    httpClient *http.Client // 5s timeout — this call sits in front of every mutating request
}

func New(baseURL, token string) *Client { ... }

// ResolveDisplayNames calls GET /internal/users?ids=<uuid,uuid,...> and returns a
// map[user_id]display_name for every id server-side resolved. IDs absent from the
// response (unknown/malformed) are simply absent from the returned map — callers
// must handle a miss (see fallback rule below), not treat it as an error.
func (c *Client) ResolveDisplayNames(ctx context.Context, userIDs []string) (map[string]string, error)
```

New config: `USER_SERVICE_URL`, `USER_SERVICE_TOKEN` (mirrors `WORKFLOW_BACKEND_URL`/
`WORKFLOW_BACKEND_SERVICE_TOKEN` conventions already used by hermes-agent → `workflow-backend`).
`user-service`'s `RequireServiceToken` middleware already gates `RegisterInternal` routes uniformly —
no `user-service` change needed.

### 2. Actor-resolution helper + fallback rule (runs BEFORE any transaction opens)

Add a small helper in `internal/service/workspace.go`, called at the top of every write-path service
method — **before** the corresponding `Reader` method opens its `pgx.Tx`:

```go
// resolveActor returns a human-readable identity for userID: display name if
// user-service resolves it (within a bounded timeout) and it is non-empty,
// else email, else the raw userID unchanged. Never returns an error — a
// resolution failure (timeout, user-service down, unknown id) degrades to
// the raw UUID rather than blocking the mutation. Called with a short,
// request-scoped timeout (e.g. 2s via context.WithTimeout) so a slow/down
// user-service cannot stall the caller's request; the mutation proceeds
// immediately on timeout with the raw UUID as actor.
//
// IMPORTANT: this must be called and fully resolved BEFORE the caller opens
// any pgx.Tx for the mutation itself — no external HTTP call may execute
// while a DB transaction is open (see Constraints).
func (s *WorkspaceService) resolveActor(ctx context.Context, userID string) string
```

All six write paths call this helper in the `WorkspaceService` method, before invoking the
corresponding `Reader` method — so by the time any `Reader.*` function opens its transaction, `actor`
is already a plain string with no further I/O required. This guarantees no external call is ever made
from inside a `pgx.Tx`.

### 3. Activity-event insert: best-effort via savepoint (never blocks the primary mutation)

The primary state mutation (the guarded `UPDATE`/`INSERT` already present in each `Reader` method) is
the mandatory operation and is unchanged in its failure behavior. The activity-event insert is added
as a **nested transaction (savepoint)** inside the same `pgx.Tx`, so a failure there can be rolled back
in isolation without aborting the outer transaction:

```go
// Inside Reader.<Method>, after the mandatory state-changing statement succeeds
// and before tx.Commit(ctx):
if spTx, spErr := tx.Begin(ctx); spErr == nil { // pgx v5: Begin() on a Tx issues SAVEPOINT
    if _, insErr := spTx.Exec(ctx, insertActivityQ, /* ... */); insErr != nil {
        _ = spTx.Rollback(ctx) // ROLLBACK TO SAVEPOINT — discards only the activity insert
        log.Warn().Err(insErr).Msg("activity event insert failed — mutation proceeds")
    } else {
        _ = spTx.Commit(ctx) // RELEASE SAVEPOINT
    }
} else {
    log.Warn().Err(spErr).Msg("could not open savepoint for activity event — mutation proceeds")
}
// tx.Commit(ctx) below always persists the primary mutation regardless of the
// savepoint outcome above.
```

This is applied identically to all six write paths (`CreateWorkspaceFeature`, `UpdateFeatureStage`,
`CreateWorkspaceTasks`, `ActivateReadyTasks`, `UnblockTask`, `RecoverTask`) — including the two
existing ones (`UnblockTask`/`RecoverTask`), whose current implementation inserts the activity row as
a plain statement in the same transaction as the guarded update; this feature changes that to the
savepoint pattern so a future activity-insert failure there also stops being able to roll back a
successful unblock/recover.

Net effect: the mutation's success/failure is now **fully decoupled** from both (a) `user-service`
availability (resolved pre-transaction, always falls back) and (b) the activity-event insert's own
success (isolated via savepoint) — satisfying both constraints above.

### 4. Per-action implementation (maps 1:1 to product-spec field-mapping table)

All six `Reader` methods gain a savepoint-wrapped activity insert per §3, using the actor string
already resolved (per §2) and passed in as a plain parameter — no `Reader` method calls `user-service`
itself.

| # | Method | Change |
|---|---|---|
| 1 | `Reader.CreateWorkspaceFeature` | Wrap existing single insert in an explicit `tx.Begin`/`tx.Commit` (currently a bare `QueryRow`, no transaction); add `INSERT ... action='feature_created'` in the same tx, `note = input.Title` |
| 2–4 | `Reader.UpdateFeatureStage` | Already wraps its update in `tx.Begin`/`tx.Commit`, add the activity insert alongside; `action` derived from `input.ReviewStatus` (`approved`→`stage_approved`, `rejected`→`stage_rejected`, `draft`→`stage_reopened` — this is the exact 1:1 mapping product spec flagged as needing confirmation: `ReviewStatus` is the only signal available and covers all three cases without ambiguity); `note = input.Stage`, `+ input.RejectComment` appended when present and `ReviewStatus=="rejected"` (see §4a below for the plumbing this requires) |
| 5 | `Reader.CreateWorkspaceTasks` | Inside the existing tx (`Begin`/`Commit` already present around `insertGoTask` loop), add one `INSERT ... action='task_created'` per created task, in the same loop that calls `insertGoTask`, using each task's returned `WorkspaceTask.TaskID` |
| 6 | `Reader.ActivateReadyTasks` | Add `actor` as a **required** parameter (new `actor string` arg on `Reader.ActivateReadyTasks(ctx, workspaceID, featureID, actor string)`); inside the existing tx, add one `INSERT ... action='activate'` per task transitioned in the existing loop, `note = "Activated by " + resolvedActor` |
| — | `Reader.UnblockTask` | Actor-resolution only: replace raw `input.Actor` with `s.resolveActor(ctx, input.Actor)` result before the existing insert; extend `note` to `"Unblocked from status blocked → {toStatus}. Blocked reason: {blocked_reason}."` + `" Blocked details: {blocked_details}."` (omitted when empty) + caller's `input.Note` appended last |
| — | `Reader.RecoverTask` | Actor-resolution only, same pattern; `note` branch-dependent per product spec: `"Recovered from {from} → {to}"` for the two `status`-based branches, `"Recovered from {from} → {to}. Current status: {status}"` for the `conflict_state` branch only |

#### 4a. Reject-comment plumbing (resolves product spec open question for row #3)

`UpdateFeatureStageInput` does **not** currently carry a reject comment end-to-end. This feature adds
`RejectComment string` to `domain.UpdateFeatureStageInput` and `database.UpdateFeatureStageInput`,
threaded from the handler's request body (new optional JSON field `reject_comment`) through
`WorkspaceService.UpdateFeatureStage` to `Reader.UpdateFeatureStage`. hermes-agent's
`update_feature_stage` (`workflow_backend_client.py`) gains an optional `reject_comment` kwarg,
included in the JSON body only when non-empty — this is additive to the existing call signature, no
breaking change for hermes-agent's other callers.

#### 4b. `ActivateReadyTasks` required-actor plumbing (resolves product spec open question for row #6)

- Handler (`WorkspaceHandler.ActivateReadyTasks`): request body gains a required `actor` field
  (`{"actor": "<user_id>"}`); missing/empty → `400` via the same
  `domain.ErrValidationMissingInput` pattern `UpdateFeatureStage` already uses for its own required
  fields.
- Service (`WorkspaceService.ActivateReadyTasks`): new `actor string` parameter, passed through to
  `Reader.ActivateReadyTasks`.
- **Caller update required in the same rollout**: hermes-agent's `activate_ready_tasks`
  (`src/services/workflow_backend_client.py`) is the only caller found in the codebase (invoked from
  the tasks-stage approve flow). It must be updated to pass `actor=user_id` (the same identity already
  threaded through `plugins/context.py`'s `get_user_id()` / the `user_id` parameter pattern every other
  function in that file already uses) in its request body. This is a coordinated two-repo change
  (`workflow-backend` + `hermes-agent`) landing together — `workflow-backend`'s validation must not go
  live before hermes-agent's caller is updated, or the tasks-stage approve flow breaks with a 400.

### 5. `clientAudienceAllowlist` update

Add to the map in `internal/service/workspace.go` (exact entries from product spec):

```go
var clientAudienceAllowlist = map[string]string{
    // ... existing entries unchanged ...
    "feature_created":  "Created",
    "stage_approved":   "Approved",
    "stage_rejected":   "Rejected",
    "stage_reopened":   "Reopened",
    "task_created":     "Created",
    "activate":         "Ready",
    "unblocked":        "Unblocked", // newly added to the allowlist — was internal-only before
    "recovered":        "Recovered", // newly added to the allowlist — was internal-only before
}
```

### 6. `sequence` scoping — no change needed

The existing `(SELECT COALESCE(MAX(sequence), 0) + 1 FROM workspace_activity_events WHERE workspace_id
= $1 AND feature_id = $2 AND task_id = $3)` subquery already used by `UnblockTask`/`RecoverTask` is
reused verbatim for every new insert (task_id is `NULL` for the three feature-scoped actions, which the
`= $3` comparison against `NULL` handles correctly via Postgres's three-valued logic only if the
existing code already special-cases it — **verify at implementation time** whether the existing query
needs `task_id IS NOT DISTINCT FROM $3` instead of `task_id = $3` for the `NULL` case, since a plain
`=` comparison against `NULL` never matches and would always return sequence `1`. This is a pre-existing
subtlety, not introduced by this feature, since `UnblockTask`/`RecoverTask` are both task-scoped
(`task_id` always non-null) — the first feature-scoped user of this subquery pattern surfaces it).

## Dependency Analysis

- **New cross-service dependency**: `workflow-backend` → `user-service` (new, synchronous, called
  before any DB transaction opens, bounded by a short timeout, with a non-blocking fallback to the raw
  UUID). `user-service`'s `GET /internal/users` endpoint and `RequireServiceToken` middleware already
  exist and require no change.
- **`workflow-backend` ↔ `hermes-agent`**: the `ActivateReadyTasks` request-shape change is a
  coordinated breaking change — hermes-agent's `activate_ready_tasks` caller must be updated
  simultaneously (see §4b). The reject-comment addition (§4a) is additive/non-breaking for existing
  hermes-agent callers.
- **No dependency on `workflow-orchestrator`** — confirmed out of scope; no code there is touched.
- **No dependency on `workspace-github-adapter`** — its `owner IS NULL` sync scoping is unaffected;
  `owner='go'` rows remain outside its reconciliation regardless of this feature.
- **No schema migration** — reuses the existing `workspace_activity_events` table as-is.

## Parallelization / Blocking Analysis

- **T1 (workflow-backend): new `user-service` client package + `resolveActor` helper + config wiring**
  — no blockers, can start immediately. All other `workflow-backend` tasks depend on this.
- **T2 (workflow-backend): `CreateWorkspaceFeature` activity insert** — blocked on T1.
- **T3 (workflow-backend): `UpdateFeatureStage` activity insert + reject-comment plumbing (§4a)** —
  blocked on T1.
- **T4 (workflow-backend): `CreateWorkspaceTasks` per-task activity insert** — blocked on T1.
- **T5 (workflow-backend): `ActivateReadyTasks` required-actor + activity insert (§4b, backend half)**
  — blocked on T1.
- **T6 (workflow-backend): `UnblockTask`/`RecoverTask` actor-resolution + note-format fix** — blocked
  on T1. Independent of T2–T5 (different methods), can run in parallel with them once T1 lands.
- **T7 (workflow-backend): `clientAudienceAllowlist` update** — blocked on T2–T6 landing (needs the
  final agreed `action` string values from each; trivial one-file change, sequenced last to avoid
  churn if any action name changes during T2–T6 review).
- **T8 (hermes-agent): update `activate_ready_tasks` caller to pass `actor`** — must land in the same
  rollout as T5, coordinated so `workflow-backend`'s validation does not go live before this ships (see
  §4b). Can be developed in parallel with T5, but deployment must be sequenced: either deploy T8 first
  (harmless — extra field ignored by old backend) then T5, or deploy both atomically. Landing T5 alone
  first would break the tasks-stage approve flow.
- T2, T3, T4, T5, T6 all touch different methods/files-regions within `workflow-backend` and can be
  implemented and reviewed in parallel once T1 is done; only T7 (allowlist) and the T5/T8 deployment
  order have real sequencing constraints.
