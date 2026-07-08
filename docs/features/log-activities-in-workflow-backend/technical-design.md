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

The Go orchestrator (`workflow-orchestrator` repo) also writes rows into this same
`workspace_activity_events` table via its own `AppendLogTx` (untouched by this feature). Any schema
change made here must not disrupt those existing writes/rows.

## Constraints

- Every insert must land in the existing `workspace_activity_events` shape, extended only as described
  below (two new nullable/defaulted columns) — no change to `raw_event` semantics (per product spec
  Non-goals: no structured `raw_event` payload, no backfill of historical rows).
- **No external (HTTP) call may execute on the write path at all** — not bounded-and-timed-out, not
  best-effort-inline: zero. Actor display-name resolution must be fully decoupled from the mutation
  request/response cycle (see Chosen Design).
- **Activity logging must never fail or roll back the primary mutation.** The primary state change
  (feature created, stage decision persisted, tasks created, tasks activated, task unblocked/recovered)
  is the mandatory operation; the activity log entry is a side effect.
- `workflow-backend` must not create a circular dependency on `workflow-bff` — it must call
  `user-service` directly (mirroring `workflow-bff`'s own client), not proxy through `workflow-bff`.
  This call now happens only from the async enrichment path, never from a request handler.
- `ActivateReadyTasks`'s request-shape change (adding required `actor`) is a breaking change to an
  existing endpoint — every caller must be updated in the same rollout, not after.
- Per product spec Goal 3, every new `action` value must be added to `clientAudienceAllowlist`
  (`internal/service/workspace.go`) in the same change, or it is silently invisible to
  `audience=client` callers.
- Per product spec: this feature covers `workflow-backend` only. `workflow-orchestrator`'s own
  `AppendLogTx`/`GuardedTransition` logging is untouched. `workspace-github-adapter`'s sync/reconciliation
  is untouched. The schema change below must be additive and backward-compatible with rows the
  orchestrator already writes (see Chosen Design §1 — `enriched` defaults to `true` for exactly this
  reason).
- No new message-broker infrastructure (Kafka, etc.) — assessed as disproportionate to this workspace's
  current scale; see Options Considered.

## Options Considered

### Option A — Sync resolve at write time, bounded timeout + fallback
`resolveActor` calls `user-service` synchronously before opening the mutation's transaction, with a
short timeout (e.g. 2s) and fallback to the raw UUID on failure.
- Pros: `actor` is human-readable immediately on write; simple, single code path.
- Cons: still a synchronous external call on the request path of every mutating call, adding latency
  even in the happy path; write-path availability remains coupled (even if bounded) to `user-service`
  uptime. Rejected once a genuinely dependency-free alternative (Option C) was identified.

### Option B — Read-time lazy join, no persistence
`ListActivity` resolves `actor_id → display name` on every read via `user-service`, never persisting
the result.
- Pros: no write-path dependency at all; always reflects the user's current display name.
- Cons: read path (including internal polling reads) now depends on `user-service`; resolution cost
  repeats on every list call instead of once; historical events show the *current* name rather than a
  point-in-time snapshot, which doesn't match git-commit-authorship semantics this feature is trying to
  parallel.

### Option C — Async enrichment via new columns + in-process poller (chosen)
Write `actor_id` (a typed reference, e.g. `user:<uuid>`) and leave `actor`/`enriched` to be filled in
by a background poller inside `workflow-backend` that batch-resolves outstanding rows via
`user-service` and writes the result back.
- Pros: **zero external calls on the write path** — strictly better than Option A, not just bounded;
  no new infrastructure — reuses Postgres row locking (`FOR UPDATE SKIP LOCKED`), safe across multiple
  `workflow-backend` replicas without a distributed lock; simple and incremental — a small ticker loop,
  not a new service; `enriched` boolean makes "not yet enriched" observable for debugging/monitoring;
  defaulting `enriched=true` cleanly protects every row the Go orchestrator already writes (and all
  pre-migration rows) from ever entering the enrichment queue, with zero code change required in
  `workflow-orchestrator`.
- Cons: eventual consistency — `actor` briefly shows the raw `actor_id` until the next poll cycle runs;
  one more moving part (a background loop) to operate/monitor, though a much smaller one than a queue
  consumer; requires a small additive schema migration (two nullable/defaulted columns, no data
  rewrite).

### Option D — Event-driven (Kafka / message broker + consumer)
Publish an event on write (transactional outbox or best-effort), a separate consumer resolves and
updates.
- Pros: scales indefinitely; reusable event bus for other future async needs.
- Cons: no Kafka (or equivalent broker) exists anywhere in this workspace today — this would be wholly
  new infrastructure just for this feature; producer/consumer wiring, topic/schema conventions, and
  local-dev/test friction are not justified when Option C solves the identical problem (decouple write
  from resolution) using only Postgres, which is already there. Rejected as disproportionate to scale,
  matching the concern raised during design review.

## Chosen Design

**Option C — async enrichment via new columns + in-process poller.** This removes every external call
from the write path entirely (stronger than the previously-considered bounded-timeout approach) while
introducing no new infrastructure, by reusing the activity-event row itself as its own outbox entry —
no separate outbox table is needed.

### 1. Schema change (small additive migration)

Add two columns to `workspace_activity_events`:

| Column | Type | Default | Purpose |
|---|---|---|---|
| `actor_id` | `TEXT` | `NULL` | Typed, stable reference to who/what acted, e.g. `user:3f9ab21e-...`. The `user:` prefix leaves room for other actor kinds later (`system:`, `agent:`) without a further migration. Nullable because rows that don't have a resolvable identity (none exist in this feature's six actions, but future actions might) leave it unset. |
| `enriched` | `BOOLEAN NOT NULL` | `true` | `false` means "`actor` is not yet populated and this row is a candidate for the enrichment poller"; `true` means "`actor` is already display-ready (or enrichment does not apply to this row)." **Defaulting to `true`** is what makes this change fully backward-compatible: every row the Go orchestrator's `AppendLogTx` already writes, and every row that existed before this migration, is `true` by default and is therefore never touched or queried by the new poller — zero `workflow-orchestrator` code changes required. |

Add a partial index to keep poller scans cheap regardless of table growth:
```sql
CREATE INDEX idx_workspace_activity_events_unenriched
    ON workspace_activity_events (id)
    WHERE enriched = false;
```

### 2. Write path — zero external calls

For all six actions in this feature, the `WorkspaceService`/`Reader` write path does the following and
nothing else (no `user-service` client, no HTTP call, no timeout to reason about):

```go
actorID := "user:" + userID       // typed reference, computed in-process — no I/O
var actor *string = nil            // NOT the raw user_id — actor starts unset/NULL until
                                    // the poller resolves a display name for it
enriched := false                  // this row is a candidate for the poller
```

`actor` is a nullable column (already `*string`-shaped in the existing `WorkspaceActivityEvent`/
`domain.ActivityEvent` scan/serialization path, since `derefStr` already handles a `nil` `Action`-style
pointer elsewhere) and is written as `NULL`, not as the raw `user_id` string — the raw reference lives
only in `actor_id`. This is a deliberate change from today's `UnblockTask`/`RecoverTask` behavior,
which currently writes the raw UUID into `actor` directly; this feature stops doing that for every
write path (new and existing) once `actor_id`/`enriched` exist, so `actor` never observably regresses
to a raw UUID at any point — it is either `NULL` (not yet enriched) or a resolved display name
(enriched), never a UUID string.

This is inserted into `workspace_activity_events` (`actor_id`, `actor=NULL`, `enriched=false` alongside
the existing columns) in the same transaction as the primary mutation. Because there is no external
call anywhere in this path, the previously-discussed savepoint-for-isolating-an-external-call concern
no longer applies for that specific reason. A lightweight savepoint around just the activity insert is
still kept as generic defense-in-depth (protects the mutation from an unrelated insert failure, e.g. a
future constraint violation) — see §3.

### 3. Activity-event insert: still isolated via savepoint (defense-in-depth, not resolution-related)

Even with zero external calls, the activity insert is still wrapped in a savepoint inside the
mutation's transaction, so a failure in the insert itself (e.g. a constraint violation, unrelated to
this feature) cannot roll back a successful mutation:

```go
// Inside Reader.<Method>, after the mandatory state-changing statement succeeds
// and before tx.Commit(ctx):
if spTx, spErr := tx.Begin(ctx); spErr == nil { // pgx v5: Begin() on a Tx issues SAVEPOINT
    if _, insErr := spTx.Exec(ctx, insertActivityQ, /* ..., actorID, actor=NULL, enriched=false */); insErr != nil {
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

Applied identically to all six write paths, including retrofitting the two existing ones
(`UnblockTask`/`RecoverTask`), whose current implementation inserts the activity row as a plain
statement in the same transaction as the guarded update (today, an activity-insert failure there
*would* roll back a successful unblock/recover — this feature fixes that as a side effect).

### 4. Async enrichment poller (new)

A single background goroutine in `workflow-backend`, started at process boot alongside the HTTP
server, on a fixed ticker configurable via `ACTIVITY_ENRICH_POLL_INTERVAL` (duration string, e.g. `1m`,
`30s`), **defaulting to `30s`** when unset:

```go
func (s *WorkspaceService) enrichActivityEvents(ctx context.Context) {
    // 1. SELECT id, actor_id FROM workspace_activity_events
    //    WHERE enriched = false AND actor_id IS NOT NULL
    //    ORDER BY id LIMIT 200 FOR UPDATE SKIP LOCKED
    //    (SKIP LOCKED makes this safe to run concurrently across multiple
    //     workflow-backend replicas without any distributed coordination —
    //     each replica's poller just picks up whatever rows aren't already
    //     locked by another replica's in-flight batch)
    // 2. Extract the raw user_id from each actor_id ("user:" prefix stripped),
    //    dedupe, call user-service GET /internal/users?ids=... once for the batch
    // 3. For each row: UPDATE ... SET actor = <resolved display_name, or email
    //    if no display_name>, enriched = true WHERE id = ... — only when
    //    user-service actually resolved that id.
    // 4. Rows whose id was absent from user-service's response (unknown/
    //    malformed id, or a transient user-service failure for the whole
    //    batch) are left actor = NULL, enriched = false and are retried on
    //    the next tick — no separate retry-count/backoff mechanism in this
    //    feature; simple unbounded retry is acceptable at this scale (a stuck
    //    row just means a permanently-unknown user_id, which will never
    //    resolve regardless of retry count, and costs nothing beyond being
    //    re-selected each poll — it simply keeps showing as actor=NULL in
    //    ListActivity responses, which the read/UI side must already handle
    //    as "unknown/unresolved actor", not as an error).
}
```

This is the **only** place `workflow-backend` calls `user-service` in this feature — never from a
request-handling goroutine. `check_workflow_available`-style config (`USER_SERVICE_URL`,
`USER_SERVICE_TOKEN`) gates whether the poller runs at all; if unset, the poller no-ops (logs a warning
once) and rows simply stay `enriched=false` indefinitely — the write path is completely unaffected
either way.

### 5. Read path — unchanged

`WorkspaceService.ListActivity` / `Reader.ListActivityEvents` require no code change. They already
return whatever `actor` currently holds; before enrichment that's `NULL` (the read/serialization path
must render this as an empty/unknown actor — e.g. `derefStr`-style nil-safe handling, consistent with
how other nullable string columns already serialize), after enrichment (on the next poll cycle) it's
the resolved display name. Fully async, eventually consistent, zero new read-path dependency — this
was true under Option C by construction. Consumers that need to distinguish "not yet enriched" from
"resolution permanently failed" can additionally read the `enriched` boolean now exposed alongside
`actor` — this feature's Non-goals scope does not require adding UI for this, but the field is present
for any future consumer that wants it.

### 6. Per-action implementation (maps 1:1 to product-spec field-mapping table)

All six `Reader` methods gain the savepoint-wrapped activity insert per §3, using the `actor_id`/`actor`
values computed in-process per §2 (no `user-service` call in this path).

| # | Method | Change |
|---|---|---|
| 1 | `Reader.CreateWorkspaceFeature` | Wrap existing single insert in an explicit `tx.Begin`/`tx.Commit` (currently a bare `QueryRow`, no transaction); add `INSERT ... action='feature_created', actor_id, actor=NULL, enriched=false` in the same tx, `note = input.Title` |
| 2–4 | `Reader.UpdateFeatureStage` | Already wraps its update in `tx.Begin`/`tx.Commit`, add the activity insert alongside (`actor_id` set, `actor=NULL`, `enriched=false`); `action` derived from `input.ReviewStatus` (`approved`→`stage_approved`, `rejected`→`stage_rejected`, `draft`→`stage_reopened` — the exact 1:1 mapping product spec flagged as needing confirmation: `ReviewStatus` is the only signal available and covers all three cases without ambiguity); `note = input.Stage`, `+ input.RejectComment` appended when present and `ReviewStatus=="rejected"` (see §6a below for the plumbing this requires) |
| 5 | `Reader.CreateWorkspaceTasks` | Inside the existing tx (`Begin`/`Commit` already present around `insertGoTask` loop), add one `INSERT ... action='task_created', actor_id, actor=NULL, enriched=false` per created task, in the same loop that calls `insertGoTask`, using each task's returned `WorkspaceTask.TaskID` |
| 6 | `Reader.ActivateReadyTasks` | Add `actor` as a **required** parameter on the request — semantically this is the caller-supplied `user_id` used to populate `actor_id`, not the `actor` column, which still starts `NULL` (new `actorUserID string` arg on `Reader.ActivateReadyTasks(ctx, workspaceID, featureID, actorUserID string)`); inside the existing tx, add one `INSERT ... action='activate', actor_id, actor=NULL, enriched=false` per task transitioned in the existing loop; `note = "Activated by " + actorUserID` at write time necessarily uses the **raw** user id (since `actor` is not yet enriched at write time) — see open question below on whether `note` should be re-synthesized by the poller too, or left as written |
| — | `Reader.UnblockTask` | Stop writing the raw `input.Actor` UUID into `actor` (today's behavior); write `actor_id = "user:" + input.Actor`, `actor = NULL`, `enriched = false` instead; extend `note` to `"Unblocked from status blocked → {toStatus}. Blocked reason: {blocked_reason}."` + `" Blocked details: {blocked_details}."` (omitted when empty) + caller's `input.Note` appended last |
| — | `Reader.RecoverTask` | Same `actor_id`/`actor=NULL`/`enriched=false` change (stops writing the raw UUID into `actor`, as it does today); `note` branch-dependent per product spec: `"Recovered from {from} → {to}"` for the two `status`-based branches, `"Recovered from {from} → {to}. Current status: {status}"` for the `conflict_state` branch only |

**Open question carried forward**: for row #6, `note` embeds the actor's raw user id at write time
(since `actor` itself is `NULL` until enrichment) — e.g. `"Activated by 3f9a..."` until the poller runs
and populates `actor` with a display name, at which point `note`'s embedded text does not
retroactively update. Confirm at implementation time whether this is acceptable (likely yes, since
`note` is supplementary and `actor`/`actor_id` are the canonical fields a UI would prefer to render),
or whether `note` for row #6 should instead avoid embedding any actor text at all (e.g. client renders
"Activated by {actor}" by joining `actor` client-side once enriched, rather than baking a phrase into
`note` at write time) to avoid ever showing a stale raw id in `note` after `actor` is enriched.

#### 6a. Reject-comment plumbing (resolves product spec open question for row #3)

`UpdateFeatureStageInput` does **not** currently carry a reject comment end-to-end. This feature adds
`RejectComment string` to `domain.UpdateFeatureStageInput` and `database.UpdateFeatureStageInput`,
threaded from the handler's request body (new optional JSON field `reject_comment`) through
`WorkspaceService.UpdateFeatureStage` to `Reader.UpdateFeatureStage`. hermes-agent's
`update_feature_stage` (`workflow_backend_client.py`) gains an optional `reject_comment` kwarg,
included in the JSON body only when non-empty — additive to the existing call signature, no breaking
change for hermes-agent's other callers.

#### 6b. `ActivateReadyTasks` required-actor plumbing (resolves product spec open question for row #6)

- Handler (`WorkspaceHandler.ActivateReadyTasks`): request body gains a required `actor` field
  (`{"actor": "<user_id>"}`); missing/empty → `400` via the same `domain.ErrValidationMissingInput`
  pattern `UpdateFeatureStage` already uses for its own required fields.
- Service (`WorkspaceService.ActivateReadyTasks`): new `actor string` parameter, passed through to
  `Reader.ActivateReadyTasks`.
- **Caller update required in the same rollout**: hermes-agent's `activate_ready_tasks`
  (`src/services/workflow_backend_client.py`) is the only caller found in the codebase (invoked from
  the tasks-stage approve flow). It must be updated to pass `actor=user_id` (the same identity already
  threaded through `plugins/context.py`'s `get_user_id()` / the `user_id` parameter pattern every other
  function in that file already uses) in its request body. This is a coordinated two-repo change
  (`workflow-backend` + `hermes-agent`) landing together — `workflow-backend`'s validation must not go
  live before hermes-agent's caller is updated, or the tasks-stage approve flow breaks with a 400.

### 7. `clientAudienceAllowlist` update

Add to the map in `internal/service/workspace.go` (exact entries from product spec, unaffected by the
async-enrichment change):

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

### 8. `sequence` scoping — no change needed

The existing `(SELECT COALESCE(MAX(sequence), 0) + 1 FROM workspace_activity_events WHERE workspace_id
= $1 AND feature_id = $2 AND task_id = $3)` subquery already used by `UnblockTask`/`RecoverTask` is
reused verbatim for every new insert. **Verify at implementation time** whether this needs `task_id IS
NOT DISTINCT FROM $3` instead of `task_id = $3` for the three feature-scoped actions (task_id `NULL`),
since a plain `=` comparison against `NULL` never matches under Postgres's three-valued logic and would
always yield sequence `1`. Pre-existing subtlety, not introduced by this feature — `UnblockTask`/
`RecoverTask` are both task-scoped (`task_id` always non-null), so this feature's three feature-scoped
inserts are the first callers to exercise the `NULL` case.

## Dependency Analysis

- **New cross-service dependency**: `workflow-backend` → `user-service`, but now **only** from the
  background enrichment poller (§4), never from a request-handling path. `user-service` availability
  has zero effect on mutation success/latency. `user-service`'s `GET /internal/users` endpoint and
  `RequireServiceToken` middleware already exist and require no change.
- **`workflow-backend` ↔ `hermes-agent`**: the `ActivateReadyTasks` request-shape change is a
  coordinated breaking change — hermes-agent's `activate_ready_tasks` caller must be updated
  simultaneously (see §6b). The reject-comment addition (§6a) is additive/non-breaking for existing
  hermes-agent callers.
- **No dependency on `workflow-orchestrator`** — confirmed out of scope; no code there is touched, and
  the `enriched=true` default guarantees its existing writes are unaffected by the schema change.
- **No dependency on `workspace-github-adapter`** — its `owner IS NULL` sync scoping is unaffected;
  `owner='go'` rows remain outside its reconciliation regardless of this feature.
- **Schema migration**: additive only — two nullable/defaulted columns + one partial index, no data
  rewrite, no change to any existing row's queryable behavior.

## Parallelization / Blocking Analysis

- **T1 (workflow-backend): schema migration — `actor_id`, `enriched` columns + partial index** — no
  blockers, can start immediately.
- **T2 (workflow-backend): new `user-service` client package (enrichment-only) + config wiring** — no
  blockers, can run in parallel with T1.
- **T3 (workflow-backend): `CreateWorkspaceFeature` activity insert** — blocked on T1.
- **T4 (workflow-backend): `UpdateFeatureStage` activity insert + reject-comment plumbing (§6a)** —
  blocked on T1.
- **T5 (workflow-backend): `CreateWorkspaceTasks` per-task activity insert** — blocked on T1.
- **T6 (workflow-backend): `ActivateReadyTasks` required-actor + activity insert (§6b, backend half)**
  — blocked on T1.
- **T7 (workflow-backend): `UnblockTask`/`RecoverTask` migrate to `actor_id`/`enriched` + note-format
  fix** — blocked on T1. Independent of T3–T6 (different methods), can run in parallel with them.
- **T8 (workflow-backend): enrichment poller (§4)** — blocked on T1 (needs the new columns) and T2
  (needs the client). Independent of T3–T7 — the poller works over whatever rows already exist matching
  `enriched=false`, regardless of which write path produced them, so it can be built/tested
  concurrently with T3–T7 using synthetic rows.
- **T9 (workflow-backend): `clientAudienceAllowlist` update** — blocked on T3–T7 landing (needs the
  final agreed `action` string values; trivial one-file change, sequenced last to avoid churn if any
  action name changes during T3–T7 review).
- **T10 (hermes-agent): update `activate_ready_tasks` caller to pass `actor`** — must land in the same
  rollout as T6, coordinated so `workflow-backend`'s validation does not go live before this ships (see
  §6b). Can be developed in parallel with T6, but deployment must be sequenced: either deploy T10 first
  (harmless — extra field ignored by old backend) then T6, or deploy both atomically. Landing T6 alone
  first would break the tasks-stage approve flow.
- T3, T4, T5, T6, T7 all touch different methods/file-regions within `workflow-backend` and can be
  implemented and reviewed in parallel once T1 is done; T8 (poller) is independent of all of them; only
  T9 (allowlist) and the T6/T10 deployment order have real sequencing constraints.
