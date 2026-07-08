## Dependency Diagram

```
T1 (schema migration)         T2 (user-service client)
        │                              │
        ├──────────────┬───────────────┤
        ▼               ▼               │
       T3          (T4 also needs T2)   │
 (activity inserts:                     │
  5 write paths)                        ▼
        │                              T4
        │                        (enrichment poller)
        ▼
       T5
 (clientAudienceAllowlist)

T3 ──(coordinated deploy, not a hard build dependency)──> T6 (hermes-agent caller update)
```

Wave 1 (no blockers, parallel): T1, T2
Wave 2: T3 (after T1), T4 (after T1 + T2) — independent of each other
Wave 3: T5 (after T3), T6 (after T3 — coordinated rollout, see T6 description)

## Index

| ID | Title | Repo | Depends On | Actor |
|---|---|---|---|---|
| T1 | Schema migration — `actor_id` + `enriched` columns on `workspace_activity_events` | workflow-backend | | agent |
| T2 | New `user-service` client package (enrichment-only) + config wiring | workflow-backend | | agent |
| T3 | Activity-event logging for all five write paths (create feature, stage decisions, create tasks, activate-ready, unblock/recover) | workflow-backend | T1 | agent |
| T4 | Async enrichment poller — resolve `actor_id` → display name via `user-service` | workflow-backend | T1, T2 | agent |
| T5 | `clientAudienceAllowlist` update for new activity actions | workflow-backend | T3 | agent |
| T6 | Update `activate_ready_tasks` caller to pass required `actor` | hermes-agent | T3 | agent |

---

## T1 — Schema migration — `actor_id` + `enriched` columns on `workspace_activity_events`

### Description
Add two new columns to `workspace_activity_events` via a new goose migration, matching the existing
migration numbering convention in `workflow-backend`'s `internal/database/migrations/` (or
`migrations/`, per the existing `00006_workspace_activity_events.sql` — follow the exact directory the
repo already uses):

- `actor_id TEXT NULL` — typed, stable reference to who/what acted (e.g. `user:3f9ab21e-...`). No
  foreign key — this is a soft reference to an identity that may live in `user-service`, not in this
  database.
- `enriched BOOLEAN NOT NULL DEFAULT true` — `false` marks a row as an enrichment-poller candidate;
  `true` (the default) means "already display-ready, or enrichment does not apply." **The `true`
  default is what makes this migration fully backward-compatible** — every row the Go orchestrator's
  own `AppendLogTx` already writes (via `workflow-orchestrator`, untouched by this feature), and every
  pre-migration row, defaults to `true` and is therefore never picked up by the new poller (T4). Do not
  backfill or recompute `enriched` for existing rows — the default handles it.

**Add a DB-level column comment on `enriched`** explaining this default-`true` rationale directly in
the schema, so anyone inspecting the table later (`\d+ workspace_activity_events` in psql, a DB GUI,
`information_schema.columns`, etc.) sees the "why" without needing to find this task or the technical
design doc:

```sql
COMMENT ON COLUMN workspace_activity_events.enriched IS
    'Whether actor has been display-name-resolved (true) or is pending async enrichment (false). '
    'Defaults to true so that all pre-existing rows and all rows written by workflow-orchestrator''s '
    'own AppendLogTx (a separate writer this column does not apply to) are never picked up by the '
    'enrichment poller. Only rows explicitly written with enriched=false by workflow-backend''s own '
    'write paths are enrichment candidates.';
```

(Escape the embedded apostrophe in `AppendLogTx's`/`writer's` as `''` per standard SQL string-literal
escaping, as shown above — verify the exact wording compiles cleanly in the target Postgres version
during implementation.)

Add a partial index so poller scans (T4) stay cheap regardless of table growth:
```sql
CREATE INDEX idx_workspace_activity_events_unenriched
    ON workspace_activity_events (id)
    WHERE enriched = false;
```

Update the corresponding Go struct(s) that scan `workspace_activity_events` rows
(`WorkspaceActivityEvent` in `internal/database/`, and `domain.ActivityEvent` in
`internal/domain/`/wherever it's defined) to include the two new fields — `ActorID *string`,
`Enriched bool` — and update `toActivityEvent` (`internal/service/workspace.go`) to map them through so
they are available to later tasks (T3, T4, T5) without further struct changes.

Do **not** change `ListActivityEvents`'s SELECT column list beyond adding the two new columns, and do
not change `ListActivity`'s response shape/behavior in this task — that's read-path plumbing only,
consumed by T3/T4; no new endpoint or filtering logic is introduced here.

### Required skills
(Standard Go/Postgres/goose conventions already used throughout `workflow-backend` — no additional
technical skill beyond the repo's existing patterns.)

### Subtasks
- [ ] Add new goose migration file (`000XX_activity_events_actor_enrichment.sql` — pick the next
      sequential number after the highest existing migration file) with the `actor_id`/`enriched`
      columns, the `COMMENT ON COLUMN workspace_activity_events.enriched IS ...` statement explaining
      the default-`true` rationale, and the partial index, following the exact style of migration
      `00006_workspace_activity_events.sql` (up/down blocks, goose annotations).
- [ ] Add a corresponding **down** migration that drops the index and both columns cleanly (column
      comments are dropped automatically when their column is dropped — no separate cleanup needed).
- [ ] Update the Go struct(s) that scan/represent `workspace_activity_events` rows to add `ActorID
      *string` and `Enriched bool` fields, matching the existing nullable-string handling pattern
      already used for other nullable columns in the same struct (e.g. how `BlockedReason *string` is
      handled elsewhere in `WorkspaceTask`).
- [ ] Update `toActivityEvent` (`internal/service/workspace.go`) to populate the new fields on
      `domain.ActivityEvent` from the scanned row.
- [ ] Update `ListActivityEvents`'s SELECT statement to include the two new columns.
- [ ] Write/extend a migration test (mirroring existing `TestMigrationFSContainsExpectedFiles`-style
      tests in `internal/database/migrate_test.go`) asserting the new migration file is present and the
      expected file count is updated.
- [ ] Run `go build ./...`, `go vet ./...`, `go test ./...`, `golangci-lint run` — all clean.
- [ ] If a live Postgres instance is available in CI/local, run `goose up` / `goose down` / `goose up`
      to verify both directions apply cleanly, and confirm the column comment is present via
      `\d+ workspace_activity_events` or `SELECT col_description(...)`; otherwise note this as a manual
      verification step in the PR description (matching the precedent set by migration
      `00015_20260607_owner.sql`'s PR, which documented the same limitation).

---

## T2 — New `user-service` client package (enrichment-only) + config wiring

### Description
Add a new package `internal/adapter/userservice/` in `workflow-backend`, a plain `net/http` +
bearer-token client mirroring `workflow-bff`'s existing
`internal/pkg/serviceclient/userservice/client.go` shape (same repo family, same pattern — reuse it as
the reference implementation, adapted to `workflow-backend`'s package conventions):

```go
package userservice

type Client struct {
    baseURL    string
    token      string
    httpClient *http.Client
}

func New(baseURL, token string) *Client { ... }

// ResolveDisplayNames calls GET /internal/users?ids=<uuid,uuid,...> on user-service and
// returns a map[user_id]display_name for every id user-service resolved. IDs absent from
// user-service's response (unknown, malformed, or omitted because the whole batch failed)
// are simply absent from the returned map — this is not an error condition for the caller
// to handle specially, just a partial result.
func (c *Client) ResolveDisplayNames(ctx context.Context, userIDs []string) (map[string]string, error)
```

`user-service`'s `GET /internal/users?ids=...` endpoint (`Handler.ListUsersByIDs`,
`internal/handler/workspace.go` in the `user-service` repo) and its `RequireServiceToken` middleware
already exist and require **no change** — this task only builds the calling client in
`workflow-backend`.

New config values (env-driven, following the exact naming precedent of `WORKFLOW_BACKEND_URL` /
`WORKFLOW_BACKEND_SERVICE_TOKEN` already used by hermes-agent → workflow-backend):
- `USER_SERVICE_URL` — base URL of `user-service`.
- `USER_SERVICE_TOKEN` — bearer token accepted by `user-service`'s `RequireServiceToken` middleware.

Both are optional at the config level — if either is unset, the client should not be constructed (or
`New` should be skippable), and T4's poller must handle "no client configured" by no-op'ing (logging
once) rather than panicking. This task should expose a simple `Configured() bool`-style check (or
equivalent) that T4 can use, mirroring hermes-agent's `check_workflow_available()` pattern referenced in
the technical design.

This client is **only ever called from the T4 poller** — never from a request-handling goroutine. This
task does not wire the client into any HTTP handler.

### Required skills
(Standard Go/HTTP client conventions already used throughout `workflow-backend` — no additional
technical skill beyond the repo's existing patterns.)

### Subtasks
- [ ] Add `internal/adapter/userservice/client.go` with `Client`, `New`, `ResolveDisplayNames`.
- [ ] Add config fields `USER_SERVICE_URL` / `USER_SERVICE_TOKEN` to `workflow-backend`'s config
      loading (wherever `WORKFLOW_BACKEND_URL`-equivalent server-side config lives, if applicable, or
      the service's own `.env`/config struct — follow the existing config-loading pattern in this repo).
- [ ] Add a `Configured() bool` (or equivalent) helper so callers (T4) can detect "not set up" and no-op
      safely.
- [ ] Unit tests: successful batch resolve (mock HTTP server), partial resolve (some ids missing from
      response), full failure (non-2xx), malformed response body, empty `userIDs` input (should not
      call out to the network at all).
- [ ] Run `go build ./...`, `go vet ./...`, `go test ./...`, `golangci-lint run` — all clean.
- [ ] Document the two new env vars in `workflow-backend`'s `.env.example`/README, matching existing
      documentation conventions for `WORKFLOW_BACKEND_URL`-style vars elsewhere in the workspace.

---

## T3 — Activity-event logging for all five write paths

### Description
Add a savepoint-wrapped `workspace_activity_events` insert to each of the five write paths below, in
`internal/database/queries.go` (and `internal/service/workspace.go` / `internal/handler/workspace.go`
where request-shape changes are needed). This is deliberately one task covering all five call sites —
they share the identical insert pattern and are small enough individually that reviewing them together
catches cross-call-site inconsistency more reliably than five separate PRs would.

**Shared pattern for every insert in this task** (per approved technical design §2–3):
- `actor_id = "user:" + <the resolved caller user_id, already available via `authmw.FromContext(ctx).UserID`
  or the per-action input field — see the table below>`.
- `actor = NULL` at write time (**not** the raw user id — this is a deliberate change from today's
  `UnblockTask`/`RecoverTask` behavior, which currently writes the raw UUID into `actor` directly; this
  task removes that behavior too, per the two existing-row-changes below).
- `enriched = false`.
- The insert is wrapped in a **savepoint** (nested `tx.Begin`/`tx.Commit`/`tx.Rollback` inside the
  mutation's existing transaction) so that an insert failure can never roll back the primary mutation —
  see the technical design's exact code sketch (§3). Log a warning on savepoint-open or insert failure;
  never propagate the error to the caller of the primary mutation.
- No call to the T2 `user-service` client anywhere in this task — actor display-name resolution is
  entirely deferred to T4.

**Per-action detail** (`action` values, `note` content, and any request-shape changes — see the approved
product spec's field-mapping table and worked examples for exact wording, and the technical design §6
for the full per-method breakdown):

| Method | `action` | `note` | Notes |
|---|---|---|---|
| `Reader.CreateWorkspaceFeature` | `feature_created` | feature `title` | Wrap the existing bare `QueryRow` insert in an explicit `tx.Begin`/`tx.Commit` (it isn't transactional today) before adding the savepoint-wrapped activity insert. |
| `Reader.UpdateFeatureStage` | `stage_approved` / `stage_rejected` / `stage_reopened`, derived 1:1 from `input.ReviewStatus` (`approved`/`rejected`/`draft` respectively) | `input.Stage`, `+ input.RejectComment` appended when present and `ReviewStatus=="rejected"` | Requires the reject-comment plumbing below. |
| `Reader.CreateWorkspaceTasks` | `task_created` (one row per created task) | created task's `title` | Insert once per task inside the existing `insertGoTask` loop, using each task's returned `TaskID`. |
| `Reader.ActivateReadyTasks` | `activate` (one row per task transitioned) | `"Activated by " + actorUserID` (the raw user id — `actor` itself is `NULL` until enrichment; this is a known, accepted trade-off, not a bug) | Requires the required-`actor` request-shape change below. |
| `Reader.UnblockTask` | `unblocked` (existing action, unchanged) | `"Unblocked from status blocked → {toStatus}. Blocked reason: {blocked_reason}. Blocked details: {blocked_details}"` (omit the "Blocked details" sentence when empty), then the caller's `input.Note` appended as a final sentence if present | Stop writing the raw `input.Actor` UUID into `actor` (today's behavior) — switch to `actor_id`/`actor=NULL`/`enriched=false`. Convert the existing plain insert to the savepoint pattern. |
| `Reader.RecoverTask` | `recovered` (existing action, unchanged) | Branch-dependent: `"Recovered from {from} → {to}"` for the two `status`-based branches (no suffix, no caller-note append); `"Recovered from {from} → {to}. Current status: {status}"` for the `conflict_state`-based branch only | Same `actor_id`/`actor=NULL`/`enriched=false` migration and savepoint conversion as `UnblockTask`. |

**Reject-comment plumbing** (for `UpdateFeatureStage`): add `RejectComment string` to
`domain.UpdateFeatureStageInput` and `database.UpdateFeatureStageInput`, threaded from a new optional
JSON request field `reject_comment` through `WorkspaceHandler.UpdateFeatureStage` →
`WorkspaceService.UpdateFeatureStage` → `Reader.UpdateFeatureStage`. This is additive — do not change
any existing required field or break any existing caller that omits `reject_comment`.

**`ActivateReadyTasks` required-`actor` plumbing**: add a required `actor` field to the request body
(`{"actor": "<user_id>"}`) on `WorkspaceHandler.ActivateReadyTasks`; missing/empty → `400` via the same
`domain.ErrValidationMissingInput` pattern `UpdateFeatureStage` already uses for its own required
fields. Thread this new `actor string` parameter through `WorkspaceService.ActivateReadyTasks` →
`Reader.ActivateReadyTasks(ctx, workspaceID, featureID, actorUserID string)`. **This is a breaking
change** to an existing endpoint — coordinate with T6 before/at deploy time (see T6's description); do
not merge this task's PR and deploy it to production before T6 has shipped its caller-side update, or
the tasks-stage approve flow in hermes-agent will start failing with `400`.

**`clientAudienceAllowlist` note**: do NOT touch `clientAudienceAllowlist` in this task — that is T5,
sequenced after this task lands so the final agreed `action` string values are known first.

**`sequence` scoping**: reuse the existing `(SELECT COALESCE(MAX(sequence), 0) + 1 FROM
workspace_activity_events WHERE workspace_id = $1 AND feature_id = $2 AND task_id = $3)` subquery
pattern for every new insert. **Verify at implementation time** whether this needs `task_id IS NOT
DISTINCT FROM $3` instead of `task_id = $3` for the three feature-scoped actions in this task
(`feature_created`, `stage_approved`/`rejected`/`reopened`) where `task_id` is `NULL` — a plain `=`
comparison against `NULL` never matches under Postgres's three-valued logic and would always yield
sequence `1`. Write a test that specifically exercises two feature-scoped events on the same feature
and asserts the second gets `sequence=2`, not `sequence=1` again, to catch this if it's wrong.

### Required skills
(Standard Go/Postgres/pgx transaction-handling conventions already used throughout `workflow-backend`
— no additional technical skill beyond the repo's existing patterns, particularly the
`UnblockTask`/`RecoverTask` transaction+insert pattern already in `internal/database/queries.go` as the
direct precedent to extend.)

### Subtasks
- [ ] `CreateWorkspaceFeature`: wrap in an explicit transaction; add the savepoint-wrapped
      `feature_created` activity insert.
- [ ] `UpdateFeatureStage`: add `reject_comment` plumbing (domain/database input structs, handler
      request field, service/reader threading); add the savepoint-wrapped activity insert with
      `stage_approved`/`stage_rejected`/`stage_reopened` derived from `ReviewStatus`.
- [ ] `CreateWorkspaceTasks`: add one savepoint-wrapped `task_created` insert per task inside the
      existing `insertGoTask` loop.
- [ ] `ActivateReadyTasks`: add the required `actor` request field + 400 validation; thread `actor`
      through service/reader; add one savepoint-wrapped `activate` insert per activated task inside the
      existing loop.
- [ ] `UnblockTask`: switch from writing raw `input.Actor` into `actor` to
      `actor_id`/`actor=NULL`/`enriched=false`; convert the existing plain insert to the savepoint
      pattern; update `note` to the new transition-summary format.
- [ ] `RecoverTask`: same actor/enriched migration and savepoint conversion; update `note` per the
      branch-dependent format above.
- [ ] Unit/integration tests per call site: activity row is inserted with correct `action`/`actor_id`/
      `actor=NULL`/`enriched=false`/`note`/`sequence`; primary mutation still succeeds even when the
      activity insert is forced to fail (e.g. inject a constraint violation in a test double) — assert
      the savepoint isolates it; `ActivateReadyTasks` returns `400` when `actor` is missing/empty;
      `UpdateFeatureStage` accepts and threads `reject_comment` when present and behaves identically to
      today when it's absent.
- [ ] Update any existing tests for `UnblockTask`/`RecoverTask` that currently assert `actor` equals the
      raw UUID — these must be updated to assert `actor_id` instead, since `actor` is now `NULL` at
      insert time.
- [ ] Run `go build ./...`, `go vet ./...`, `go test ./...`, `golangci-lint run` — all clean.

---

## T4 — Async enrichment poller

### Description
Add a single background goroutine in `workflow-backend`, started at process boot alongside the HTTP
server, on a ticker interval configurable via `ACTIVITY_ENRICH_POLL_INTERVAL` (a Go duration string,
e.g. `1m`, `30s`), **defaulting to `30s`** when unset.

Each tick:
1. `SELECT id, actor_id FROM workspace_activity_events WHERE enriched = false AND actor_id IS NOT NULL
   ORDER BY id LIMIT 200 FOR UPDATE SKIP LOCKED` — `SKIP LOCKED` makes this safe to run concurrently
   across multiple `workflow-backend` replicas with no distributed coordination; each replica's poller
   just picks up whatever rows aren't already locked by another replica's in-flight batch.
2. Strip the `user:` prefix from each `actor_id` to get the raw `user_id`, dedupe, and call the T2
   client's `ResolveDisplayNames` once for the whole batch.
3. For each row whose `user_id` **was** resolved: `UPDATE workspace_activity_events SET actor =
   <resolved display_name, or email if no display_name>, enriched = true WHERE id = ...`.
4. For each row whose `user_id` was **not** resolved (unknown/malformed id, or the whole
   `user-service` call failed): leave `actor = NULL, enriched = false` — it is retried on the next
   tick. No retry-count/backoff mechanism in this task — simple unbounded retry is acceptable at this
   scale; a permanently-unknown `user_id` just keeps being re-selected each poll at negligible cost, and
   keeps showing as `actor = NULL` in `ListActivity` responses (which is the expected "unresolved
   actor" representation, not an error state).

If T2's client reports "not configured" (`USER_SERVICE_URL`/`USER_SERVICE_TOKEN` unset), the poller
must no-op each tick (log a warning once, not once per tick) rather than erroring — rows simply stay
`enriched=false` indefinitely, and the write path (T3) is completely unaffected either way.

This is the **only** place in `workflow-backend` that calls `user-service` — never from a
request-handling goroutine. No HTTP endpoint or handler change in this task.

This task is independent of T3 — the poller operates purely over whatever rows already exist matching
`enriched=false`, regardless of which write path produced them, so it can be developed and tested
using synthetic/seeded rows without waiting on T3 to land.

### Required skills
(Standard Go background-worker / ticker-loop conventions and Postgres `FOR UPDATE SKIP LOCKED` batch
-processing pattern — no additional technical skill beyond conventions already used elsewhere in this
codebase for polling loops, e.g. the sync-run polling patterns in `workspace-github-adapter`'s
equivalent worker code, if useful as a style reference.)

### Subtasks
- [ ] Add the ticker-driven background goroutine, wired into process startup (`cmd/api/` or wherever
      `workflow-backend`'s main entrypoint starts other background work).
- [ ] Add `ACTIVITY_ENRICH_POLL_INTERVAL` config (duration string, default `30s`).
- [ ] Implement the `SELECT ... FOR UPDATE SKIP LOCKED` batch selection query.
- [ ] Implement the `user:` prefix-stripping + dedupe + batch `ResolveDisplayNames` call (using the T2
      client; must check `Configured()` first and no-op with a single warning log if false).
- [ ] Implement the per-row `UPDATE` for resolved rows (`actor`, `enriched=true`) and leave-as-is
      behavior for unresolved rows.
- [ ] Unit tests: batch of all-resolved rows all get updated; batch with some unresolved rows only
      updates the resolved ones and leaves the rest `enriched=false`; empty batch (nothing to do) is a
      safe no-op; "not configured" case no-ops without erroring and logs exactly once (not once per
      tick — verify across multiple simulated ticks in the test).
- [ ] Integration test (if a live Postgres is available) seeding rows directly with `enriched=false`
      and asserting a poll cycle correctly enriches them, using a mock/fake `user-service` HTTP server.
- [ ] Verify graceful shutdown: the poller goroutine must respect context cancellation / process
      shutdown signals consistently with how other background work in this process already shuts down.
- [ ] Run `go build ./...`, `go vet ./...`, `go test ./...`, `golangci-lint run` — all clean.

---

## T5 — `clientAudienceAllowlist` update for new activity actions

### Description
Add the following entries to `clientAudienceAllowlist` in `internal/service/workspace.go` (existing
entries are unchanged):

```go
var clientAudienceAllowlist = map[string]string{
    // ... existing entries unchanged ...
    "feature_created": "Created",
    "stage_approved":  "Approved",
    "stage_rejected":  "Rejected",
    "stage_reopened":  "Reopened",
    "task_created":    "Created",
    "activate":        "Ready",
    "unblocked":        "Unblocked", // newly added — was internal-only before this feature
    "recovered":        "Recovered", // newly added — was internal-only before this feature
}
```

Without this change, every new action this feature introduces (and the two existing ones,
`unblocked`/`recovered`, which were never in the allowlist before) would be logged to the database but
silently dropped from any `audience=client` `ListActivity` response — this task is what makes them
visible to client-facing consumers.

This task is intentionally sequenced after T3 lands, so the exact final `action` string values are
confirmed (no risk of updating the allowlist with a name that changes during T3's review).

### Required skills
(Trivial one-file map update — no additional technical skill beyond the repo's existing conventions.)

### Subtasks
- [ ] Add the eight map entries above to `clientAudienceAllowlist`.
- [ ] Add/extend a test in the style of the existing `TestListActivity_ClientAudience_FiltersAllowlist`
      / `TestListActivity_ClientAudience_RelabelsActions` tests (`internal/service/workspace_test.go`)
      asserting each new action is present in `audience=client` responses with the correct relabeled
      value, and that `audience=internal` responses still show the raw action string unchanged.
- [ ] Run `go build ./...`, `go vet ./...`, `go test ./...`, `golangci-lint run` — all clean.

---

## T6 — Update `activate_ready_tasks` caller to pass required `actor`

### Description
`workflow-backend`'s `ActivateReadyTasks` endpoint (updated in T3) now requires an `actor` field in its
request body. hermes-agent's `activate_ready_tasks` (`src/services/workflow_backend_client.py`) is the
only caller of this endpoint found in the codebase, invoked from the tasks-stage approve flow. Update
it to pass `actor=user_id` in the request body, using the same identity already threaded through
`plugins/context.py`'s `get_user_id()` (or the explicit `user_id` parameter, matching the pattern every
other function in `workflow_backend_client.py` already uses for `X-User-Id`).

```python
async def activate_ready_tasks(
    workspace_id: str,
    feature_id: str,
    *,
    user_id: str | None = None,
    org_id: str | None = None,
) -> List[str]:
    ...
    data = await _call(
        "POST",
        f"/api/workspaces/{workspace_id}/features/{feature_id}/tasks/activate-ready",
        user_id=user_id,
        org_id=org_id,
        json_body={"actor": user_id or get_user_id()},  # NEW — required by workflow-backend
        not_found_message=f"Feature {feature_id!r} not found in workspace {workspace_id!r}",
    )
    return data.get("activated") or []
```

**Deployment coordination (critical — not just a code dependency)**: this task's change is harmless to
deploy *before* T3 ships (an extra `actor` field in the request body is silently accepted/ignored by
the current `workflow-backend` deployment, which doesn't yet require it). Deploying T3 to production
*before* this task's change is live would break the tasks-stage approve flow immediately, since
`workflow-backend` would start requiring a field this caller doesn't yet send. Sequence the rollout as:
deploy this task first (or atomically with T3), never T3 alone first.

### Required skills
(Standard Python/async HTTP client conventions already used throughout
`src/services/workflow_backend_client.py` — no additional technical skill beyond the file's existing
patterns.)

### Subtasks
- [ ] Update `activate_ready_tasks` to include `json_body={"actor": ...}` in its `_call` invocation,
      resolving the actor value the same way other functions in this file resolve `user_id` (explicit
      parameter falling back to `plugins.context.get_user_id()`).
- [ ] Update/add a unit test asserting the request body sent to `workflow-backend` includes the
      `actor` field with the expected resolved value.
- [ ] Verify no other caller of `activate_ready_tasks` in the `hermes-agent` codebase needs a
      corresponding update (grep for all call sites of `activate_ready_tasks` and confirm each already
      has a resolvable `user_id` in scope — e.g. the tasks-stage approve flow in `plugins/tools/approve.py`).
- [ ] Run the existing Python test suite for this module; ensure no regressions.
- [ ] Note in the PR description the deployment-sequencing requirement (this task must ship
      before/atomically with `workflow-backend`'s T3, never after).
