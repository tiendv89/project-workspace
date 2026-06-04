# Technical Design

## Feature

- Feature ID: `task-status-transition-timeline`
- Title: `Task Status Transition Timeline`
- Status: **awaiting_approval** — revised: DB trigger approach, no adapter changes

## Current state

Today the system stores only the latest task status.

### What exists

- `workspace_tasks.status` is the current persisted task status.
- The write path overwrites `workspace_tasks.status` with the newly synced value, without preserving the previous status.
- Task list and detail APIs return `TaskSummary.status` only.
- Backend can answer "what is the current status?", but not "when did this status begin?" or "when did the previous status end?".
- The frontend task sidebar computes a duration badge from task log timestamps, which is approximate and not backed by a persisted status interval model.

### Constraints and boundaries

- `workspace_tasks.status` is the only source of truth for current task status.
- `workspace_activity_events` and task log entries are audit data, not the source for this feature.
- The timeline must be created from observed changes to the persisted task status.
- Existing task status workflow and allowed status names remain unchanged.
- Existing task APIs and filters remain backward compatible.

## Problem framing

The product requirement is to track task status intervals:

```text
When a task status changes from A to B at time T:
- the open A interval ends at T
- a new B interval starts at T
```

The system must support:

- current active status interval with `ended_at = null`,
- closed intervals with both `started_at` and `ended_at`,
- repeated entry into the same status as separate intervals,
- API exposure through `GET /api/workspaces/:workspaceId/tasks`,
- frontend sidebar rendering for the current task status interval.

What must change:

- Add durable storage for task status intervals.
- Track every status change automatically.
- Expose intervals through task APIs.
- Render duration from the returned interval in the sidebar.

What remains stable:

- `workspace_tasks.status` remains the current status.
- Task status filters continue to use `workspace_tasks.status`.
- Sidebar grouping remains based on `task.status`.
- No timeline is inferred from logs or activity events.

Fixed assumptions:

- In v1, the transition timestamp is the database transaction time (`now()`).
- Historical transitions before deployment cannot be reconstructed.
- Existing tasks get one active current-status interval on first status update after deployment.

## Options considered

### Option A — DB trigger on `workspace_tasks.status` UPDATE

A PostgreSQL trigger fires on every `UPDATE OF status` and writes rows into a timeline table.

**Pros**: zero application-code change in the write path; captures every writer (adapter, scripts, manual fixes); atomic with the triggering transaction; simple to test and deploy.  
**Cons**: logic lives in the database, not in Go code.

### Option B — Adapter writes intervals in application code

The adapter would lock the row, compare old and new status, and write interval rows itself.

Rejected — it requires changes in `workspace-github-adapter` that add no value when a trigger can achieve the same result with zero adapter changes.

### Option C — JSONB array on `workspace_tasks`

Rejected — closing one interval and appending another inside a JSON array is fragile. Row-level intervals with a one-active-interval constraint are cleaner and safer.

**Decision**: Option A — DB trigger.

## Chosen design

Add a `workspace_task_status_timeline` table. A PostgreSQL trigger automatically writes a timeline row every time `workspace_tasks.status` changes. The backend reads the table and exposes `status_timeline` in task APIs. The frontend renders the current status interval from that field.

No changes to `workspace-github-adapter`.

### Schema

```sql
CREATE TABLE IF NOT EXISTS workspace_task_status_timeline (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id  UUID NOT NULL REFERENCES workspaces (id) ON DELETE CASCADE,
    feature_id    UUID NOT NULL REFERENCES workspace_features (id) ON DELETE CASCADE,
    task_id       UUID NOT NULL REFERENCES workspace_tasks (id) ON DELETE CASCADE,
    task_name     TEXT NOT NULL,
    status        TEXT NOT NULL,
    started_at    TIMESTAMPTZ NOT NULL,
    ended_at      TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT ck_timeline_time_order CHECK (ended_at IS NULL OR ended_at >= started_at)
);

CREATE UNIQUE INDEX IF NOT EXISTS uq_task_timeline_one_active
    ON workspace_task_status_timeline (task_id)
    WHERE ended_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_task_timeline_time
    ON workspace_task_status_timeline (task_id, started_at);
```

### Trigger

```sql
CREATE OR REPLACE FUNCTION fn_task_status_timeline_change()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.status IS DISTINCT FROM NEW.status THEN
        UPDATE workspace_task_status_timeline
        SET ended_at = now()
        WHERE task_id = NEW.id AND ended_at IS NULL;

        IF NEW.status IS NOT NULL AND NEW.status != '' THEN
            INSERT INTO workspace_task_status_timeline
                (workspace_id, feature_id, task_id, task_name, status, started_at)
            VALUES
                (NEW.workspace_id, NEW.feature_id, NEW.id, NEW.task_name, NEW.status, now());
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_task_status_timeline_change
    AFTER UPDATE OF status ON workspace_tasks
    FOR EACH ROW
    EXECUTE FUNCTION fn_task_status_timeline_change();
```

Behavior:

- Status unchanged → trigger does nothing.
- Status changed → trigger closes the previous open interval and opens a new active interval.
- Status changed to empty → trigger closes the previous interval without opening a new one.
- Upsert (INSERT with no previous row) → first `UPDATE OF status` produces the first timeline row.
- Same status entered again later → creates a new row; the unique index allows only one active interval.

### API exposure

Add `status_timeline` to task summary and detail responses.

Response shape — all existing fields kept, only `status_timeline` added:

```json
{
  "id": "task-row-uuid",
  "task_id": "task-row-uuid",
  "task_name": "T2",
  "feature_id": "feature-row-uuid",
  "feature_name": "task-status-transition-timeline",
  "title": "Render current status interval duration in sidebar",
  "status": "in_progress",
  "repo": "digital-factory-ui",
  "branch": "feature/task-status-transition-timeline-T2",
  "is_blocked": false,
  "pr": {"url": "", "status": "not_created"},
  "workspace_pr": {"url": "", "status": "not_created"},
  "updated_at": "2026-06-04T09:00:00Z",
  "status_timeline": [
    {
      "task_id": "task-row-uuid",
      "status": "todo",
      "started_at": "2026-06-04T08:00:00Z",
      "ended_at": "2026-06-04T08:20:00Z"
    },
    {
      "task_id": "task-row-uuid",
      "status": "ready",
      "started_at": "2026-06-04T08:20:00Z",
      "ended_at": "2026-06-04T09:00:00Z"
    },
    {
      "task_id": "task-row-uuid",
      "status": "in_progress",
      "started_at": "2026-06-04T09:00:00Z",
      "ended_at": null
    }
  ]
}
```

DTO:

```go
type TaskStatusTimelineEntry struct {
    TaskID    string     `json:"task_id"`
    Status    string     `json:"status"`
    StartedAt time.Time  `json:"started_at"`
    EndedAt   *time.Time `json:"ended_at"`
}
```

Backend read strategy:

1. Run the existing task query.
2. Collect task UUIDs from the result set.
3. Batch query `workspace_task_status_timeline` for those task UUIDs.
4. Group rows by task UUID.
5. Attach ordered intervals to each task response.

Affected endpoints:

- `GET /api/workspaces/:workspaceId/tasks`
- `GET /api/workspaces/:workspaceId/tasks/:taskId`
- `GET /api/workspaces/:workspaceId/features/:featureId/tasks`
- `GET /api/workspaces/:workspaceId/features/:featureId/tasks/:taskId`
- `GET /api/workspaces/:workspaceId/features?include=tasks`

API rules: `status_timeline` is always an array; active intervals use `ended_at = null`; duration is computed by the frontend from `started_at` / `ended_at`; task filters and grouping remain based on `workspace_tasks.status`.

### Frontend integration

`digital-factory-ui` consumes `status_timeline` and renders the current status interval in the task sidebar.

Type additions:

```ts
export type TaskStatusTimelineEntry = {
  task_id: string;
  status: string;
  started_at: string;
  ended_at: string | null;
};
```

Add to `TaskSummary`: `status_timeline?: TaskStatusTimelineEntry[]`.

Sidebar interval selection:

```ts
function findCurrentStatusInterval(task: ParsedTask) {
  const timeline = task.statusTimeline ?? [];
  for (let i = timeline.length - 1; i >= 0; i--) {
    const entry = timeline[i];
    if (entry.status === task.status && entry.ended_at === null) return entry;
  }
  for (let i = timeline.length - 1; i >= 0; i--) {
    const entry = timeline[i];
    if (entry.status === task.status) return entry;
  }
  return null;
}
```

Sidebar rendering:

- Keep grouping by `task.status`.
- Layout: status duration on the left, last-seen timestamp on the right, same row.
- Active interval (`ended_at = null`): display live `now - started_at`, update every second.
- Closed interval: display fixed `ended_at - started_at`.
- No matching interval: show existing empty state, do not infer from logs.

Time handling: all duration calculations must use browser time (`new Date()`, `Date.now()`). Timestamps from the API (`started_at`, `ended_at`) are UTC RFC3339 strings — parse them with `new Date(iso)` which converts to the browser's local time context. Never use server-computed durations or rely on clock sync between browser and server.

### Compatibility and rollout

- Existing clients ignore the additive `status_timeline` field.
- Existing tasks have no historical intervals; the first status update after deployment creates the current active interval.
- Past transitions are not reconstructed — the timeline is accurate going forward.

## Dependency analysis

### Internal dependencies

- `workflow-backend` migration and trigger must land before `status_timeline` appears in API responses.
- `digital-factory-ui` depends on the stable `status_timeline` API shape.

### External dependencies

None.

### Blocking decisions

- Transition timestamp: database transaction time (`now()`).
- Timeline source: `workspace_tasks.status` changes only.
- `workspace_activity_events` and task logs are out of scope.

### Release dependencies

1. Deploy `workflow-backend` migration + trigger + API changes.
2. Deploy `digital-factory-ui` sidebar rendering.

## Parallelization / blocking analysis

```text
T1: workflow-backend — schema, trigger, and API exposure for status_timeline
  └── Can begin now — no blockers
  │
T2: digital-factory-ui — render current status interval in task sidebar
  └── BLOCKED on T1 (needs stable status_timeline API shape)
  └── Can begin with mocked fixtures once T1 contract is defined
```

## Repository impact

| Repo ID | Impact |
|---|---|
| `workflow-backend` | Add `workspace_task_status_timeline` table and status-change trigger; add `status_timeline` DTO field; batch-read timeline rows and attach to task APIs. |
| `digital-factory-ui` | Add `status_timeline` types and mapping; render current status interval duration in task sidebar. |

## Validation and release impact

### Testing

`workflow-backend`:

- Migration creates and drops `workspace_task_status_timeline` and its trigger.
- `UPDATE workspace_tasks SET status = ...` fires the trigger correctly:
  - status unchanged → no new timeline row.
  - status changed → previous interval closed, new active interval opened.
  - status set to empty → previous interval closed, no new interval.
- Task APIs return `status_timeline` ordered by `started_at`.
- Active intervals return `ended_at = null`; closed intervals return `ended_at >= started_at`.
- Status filters and sorting still use `workspace_tasks.status`.

`digital-factory-ui`:

- `status_timeline` is mapped into the frontend task model.
- Sidebar selects the active interval matching `task.status`.
- Active duration updates every second; closed duration stays fixed.
- Missing timeline data renders empty state, does not crash, does not infer from logs.

### Rollout

- Deploy migration and trigger before API changes.
- Existing tasks get their first timeline row on the next status update after deployment.
- Frontend tolerates empty `status_timeline` during rollout.

### Backward compatibility

- `workspace_tasks.status` is unchanged.
- Existing filters and board grouping are unchanged.
- `status_timeline` is additive.
