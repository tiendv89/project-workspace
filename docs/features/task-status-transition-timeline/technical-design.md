# Technical Design

## Feature

- Feature ID: `task-status-transition-timeline`
- Title: `Task Status Transition Timeline`
- Status: **awaiting_approval** — revised: LEFT JOIN 1:1 for sidebar, full timeline for task detail

## Current state

Today the system stores only the latest task status.

### What exists

- `workspace_tasks.status` is the current persisted task status.
- The write path overwrites `workspace_tasks.status` with the newly synced value, without preserving the previous status.
- Task list and detail APIs return `TaskSummary.status` only.
- Backend can answer "what is the current status?", but not "when did this status begin?" or "when did the previous status end?".
- The frontend task sidebar has no duration display. `lib/time.ts` computes elapsed time from task log entries (`findStatusLogEntry`, `getElapsedSinceStatus`) which is approximate and not backed by a persisted status interval model.

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
                (NEW.workspace_id, NEW.feature_id, NEW.id, NEW.title, NEW.status, now());
        END IF;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_task_status_timeline_change
    AFTER UPDATE OF status ON workspace_tasks
    FOR EACH ROW
    EXECUTE FUNCTION fn_task_status_timeline_change();

CREATE OR REPLACE FUNCTION fn_task_status_timeline_insert()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status IS NOT NULL AND NEW.status != '' THEN
        INSERT INTO workspace_task_status_timeline
            (workspace_id, feature_id, task_id, task_name, status, started_at)
        VALUES
            (NEW.workspace_id, NEW.feature_id, NEW.id, NEW.title, NEW.status, now());
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_task_status_timeline_insert
    AFTER INSERT ON workspace_tasks
    FOR EACH ROW
    EXECUTE FUNCTION fn_task_status_timeline_insert();
```

Behavior:

- Status unchanged → trigger does nothing.
- Status changed → trigger closes the previous open interval and opens a new active interval.
- Status changed to empty → trigger closes the previous interval without opening a new one.
- Task inserted with non-empty status → `AFTER INSERT` trigger opens the first active interval immediately.
- Task inserted with empty/null status → no interval created; first `UPDATE OF status` produces the first timeline row.
- Same status entered again later → creates a new row; the unique index allows only one active interval.

### API exposure

Two distinct response shapes depending on the endpoint's purpose:

#### Sidebar — `GET /api/workspaces/:workspaceId/features?include=tasks`

Sidebar only needs the current interval for each task. Uses a **LEFT JOIN 1:1** directly in the query instead of returning the full `status_timeline[]`:

```sql
SELECT 
    t.id, t.task_id, t.title, t.status, t.feature_id,
    t.repo, t.depends_on, t.blocked_reason, t.pr,
    tl.started_at,
    tl.ended_at
FROM workspace_tasks t
LEFT JOIN workspace_task_status_timeline tl 
    ON tl.task_id = t.id 
    AND tl.ended_at IS NULL           -- active interval only
    AND tl.status = t.status          -- matches task current status
WHERE t.workspace_id = $1
    AND t.feature_id = ANY($2);
```

Partial unique index `(task_id) WHERE ended_at IS NULL` guarantees at most 1 matching row.

Response shape — each task has 2 new top-level fields, no `status_timeline[]`:

```json
{
  "features": [{
    "id": "feature-uuid",
    "feature_id": "task-status-transition-timeline",
    "tasks": [{
      "id": "task-row-uuid",
      "task_id": "T2",
      "title": "Render current status interval duration in sidebar",
      "status": "in_progress",
      "repo": "digital-factory-ui",
      "started_at": "2026-06-05T09:00:00Z",
      "ended_at": null
    }]
  }]
}
```

- `started_at` = `NULL` when task has no timeline data yet (task created before trigger was installed).
- `ended_at` is always `NULL` in this response due to JOIN condition `tl.ended_at IS NULL`.

#### Task detail — `GET /api/workspaces/:workspaceId/tasks/:taskId`

Returns the **full history** `status_timeline[]`:

```json
{
  "id": "task-row-uuid",
  "task_id": "T2",
  "status": "in_progress",
  "status_timeline": [
    { "status": "todo",       "started_at": "...", "ended_at": "..." },
    { "status": "ready",      "started_at": "...", "ended_at": "..." },
    { "status": "in_progress","started_at": "...", "ended_at": null }
  ]
}
```

Backend read strategy for task detail:

1. Run the existing task query.
2. Batch query `workspace_task_status_timeline WHERE task_id = $1 ORDER BY started_at`.
3. Attach ordered intervals as `status_timeline[]`.

DTO:

```go
type TaskStatusTimelineEntry struct {
    Status    string     `json:"status"`
    StartedAt time.Time  `json:"started_at"`
    EndedAt   *time.Time `json:"ended_at"`
}
```

Affected endpoints:

| Endpoint | Pattern |
|---|---|
| `GET /.../features?include=tasks` | LEFT JOIN 1:1 → `started_at` + `ended_at` top-level |
| `GET /.../tasks/:taskId` | Batch query → full `status_timeline[]` |
| `GET /.../features/:featureId/tasks` | Batch query → full `status_timeline[]` (same as task detail) |

API rules:
- Sidebar endpoint (`features?include=tasks`): `started_at` / `ended_at` are 2 top-level fields, no `status_timeline[]`.
- Task detail + feature tasks endpoints: `status_timeline[]` is the full array, ordered by `started_at`.
- Task filters and grouping remain based on `workspace_tasks.status`.

### Frontend integration — detailed UX spec

`digital-factory-ui` consumes timeline data with 2 patterns from backend.

#### Sidebar — TaskTrackingItem

Time format uses browser time. Update every **1000ms** via `setInterval`.

Duration format: `Time spent in: 3h 30m`. Use `date-fns` `intervalToDuration` (`pnpm add date-fns`):

```ts
import { intervalToDuration } from "date-fns";

function formatDuration(ms: number): string {
  const d = intervalToDuration({ start: 0, end: ms });
  const parts: string[] = [];
  if (d.days)    parts.push(`${d.days}d`);
  if (d.hours)   parts.push(`${d.hours}h`);
  if (d.minutes) parts.push(`${d.minutes}m`);
  return parts.join(" ") || "0m";
}
```

Display rules:
- `started_at` has value: show live `now - started_at` as `Time spent in: Xh Xm`, update 1000ms
- `started_at = null`: show `—`

Layout: label left, feature name right, same row. Grouping by `task.status` unchanged.

---

#### Task detail — Activities (2 tabs)

Task detail sheet has an **Activities** section with 2 switchable tabs inside:

| Tab | Data source |
|---|---|
| **Logs** | Task `activity` field from API response |
| **Timeline** | `status_timeline[]` from API |

##### Tab: Logs

Each entry: timestamp + action label + actor + note (if present).
Timestamp: uses existing `TIMESTAMP_FORMATTER` from `lib/time.ts` (browser-native `Intl.DateTimeFormat`). Output: `"Jun 4 14:30"`.
Empty state: `"No activity logs yet."`

##### Tab: Timeline

Displays `status_timeline[]` as a flow. Timestamps use a new `TIMELINE_FORMATTER`:

```ts
const TIMELINE_FORMATTER = new Intl.DateTimeFormat("en-US", {
  year: "numeric", month: "short", day: "numeric",
  hour: "2-digit", minute: "2-digit", hour12: true,
});
// Output: "Jun 4, 2026, 2:30 PM"
```

First interval:
```
Entered todo at Jun 4, 2026, 5:48 PM
```

Middle intervals (has `ended_at`):
```
Moved from todo to ready after 30m.
Jun 4, 2026, 6:18 PM
```
`after Xh Xm` = `formatDuration(ended_at - started_at)` of the previous interval.

Current interval (`ended_at = null`):
```
Moved from in_progress to in_review · Active now
Jun 4, 2026, 8:15 PM
```

**Status label colors** — reuse existing `STATUS_STYLES` from `src/features/tasks/lib/status.ts`, add `reviewing` entry:

| Status | Tailwind bg | Tailwind text | Tailwind dot |
|---|---|---|---|
| `todo` | `bg-muted-bg` | `text-text-secondary` | `bg-text-muted` |
| `ready` | `bg-ready-bg` | `text-ready` | `bg-ready` |
| `in_progress` | `bg-warning-bg` | `text-warning` | `bg-warning` |
| `blocked` | `bg-danger-bg` | `text-danger` | `bg-danger` |
| `in_review` | `bg-purple-bg` | `text-purple` | `bg-purple` |
| `reviewing` | `bg-purple-bg` | `text-purple` | `bg-purple` |
| `done` | `bg-success-bg` | `text-success` | `bg-success` |
| `cancelled` | `bg-muted-bg` | `text-text-muted` | `bg-text-muted` |

Note: `reviewing` reuses the same purple palette as `in_review`.

Compute helper:
```ts
type TimelineDisplayItem = {
  fromStatus: string | null;
  toStatus: string;
  startedAt: string;
  isActive: boolean;
  timeInPrevStatusMs: number | null;
};

function buildTimelineDisplay(timeline: TaskStatusTimelineEntry[]): TimelineDisplayItem[] {
  return timeline.map((entry, i) => {
    const prev = i > 0 ? timeline[i - 1] : null;
    const timeInPrevStatus = prev
      ? (prev.ended_at
          ? new Date(prev.ended_at).getTime() - new Date(prev.started_at).getTime()
          : new Date(entry.started_at).getTime() - new Date(prev.started_at).getTime())
      : null;
    return {
      fromStatus: prev?.status ?? null,
      toStatus: entry.status,
      startedAt: entry.started_at,
      isActive: entry.ended_at === null,
      timeInPrevStatusMs: timeInPrevStatus,
    };
  });
}
```

#### Component targets

Apply to both task detail UIs in the codebase:
- `TaskDetailSheet.tsx` (sidebar sheet) — replace existing `TimelineSection` with Activities tabs
- `TaskTabView.tsx` (full-page tab view) — replace existing `TaskActivityTimelineSection` with Activities tabs

### Compatibility and rollout

- Existing clients ignore the additive `status_timeline` field.
- New tasks inserted with a non-empty status get their first active interval immediately via the `AFTER INSERT` trigger — no blank sidebar states for newly created tasks.
- Existing tasks without timeline rows (from before deployment) get their first interval on the next status update after deployment.
- Past transitions are not reconstructed — the timeline is accurate going forward.

### Reconciliation path constraint

- `workspace_task_status_timeline.task_id` references `workspace_tasks.id` with `ON DELETE CASCADE`. The adapter's `full_reconciliation` path **must** use `INSERT ... ON CONFLICT (workspace_id, feature_id, task_id) DO UPDATE` (upsert in place) and **must never** delete-then-reinsert task rows. A delete+reinsert cycle would cascade-wipe all timeline history for those tasks and the fresh rows would start with no timeline intervals.
- This constraint must be verified against the existing `workspace-github-adapter` reconciliation logic before T1 implementation begins. If the adapter currently deletes and reinserts, it must be refactored to upsert as a prerequisite or parallel task.

### Retention / partitioning (follow-up)

- The `workspace_task_status_timeline` table grows one row per status transition, per task, forever. Platform-scale multi-tenant use requires a retention strategy.
- **Decision**: out of scope for this feature. Tracked as follow-up work:
  - Add RANGE partitioning on `started_at` (monthly).
  - Define retention policy (e.g. archive rows older than 12 months to cold storage).
  - Add `(workspace_id, status, started_at)` index for per-workspace analytics queries once needed.
- Until partitioning is in place, the table's growth rate is bounded by task count × status transition frequency, which is well within PostgreSQL's single-table capacity for the current deployment scale.

## Dependency analysis

### Internal dependencies

- `workflow-backend` migration and trigger must land before `status_timeline` appears in API responses.
- `digital-factory-ui` depends on the stable `status_timeline` API shape.

### External dependencies

None.

### Blocking decisions

- Transition timestamp: database transaction time (`now()`).
- Timeline source: `workspace_tasks.status` changes only (trigger-based).
- INSERT trigger: new tasks with non-empty status get their first interval immediately via `AFTER INSERT` (not blank-until-first-update).
- Reconciliation path: adapter must use upsert (`ON CONFLICT DO UPDATE`), never delete+reinsert. Delete+reinsert cascade-wipes timeline history.
- Retention: out of scope — tracked as follow-up (RANGE partitioning on `started_at` + archive policy).
- `workspace_activity_events` and task logs are not used as timeline source — they remain the data source for the Logs tab in the frontend.

### Release dependencies

1. Deploy `workflow-backend` migration + trigger + API changes.
2. Deploy `digital-factory-ui` sidebar rendering.

## Parallelization / blocking analysis

```text
T1: workflow-backend — schema, trigger, LEFT JOIN 1:1 for sidebar, full timeline for detail
  └── Can begin now — no blockers
  │
T2: digital-factory-ui — consume started_at/ended_at in sidebar, status_timeline[] in detail
  └── BLOCKED on T1 (needs stable API contract: started_at/ended_at top-level + status_timeline[])
  └── Can begin with mocked fixtures once T1 contract is defined
  │
T3: digital-factory-ui — regression and integration validation
  └── BLOCKED on T1, T2 (needs both backend and frontend deployed)
```

## Repository impact

| Repo ID | Impact |
|---|---|
| `workflow-backend` | Add `workspace_task_status_timeline` table and status-change trigger; add `started_at`/`ended_at` to feature-list responses via LEFT JOIN; add `status_timeline[]` to task-detail responses. |
| `digital-factory-ui` | Add timeline types and mapping; render sidebar duration with `Time spent in: Xh Xm` label; add Activity Timeline section with Logs & Timeline tabs. |

## Validation and release impact

### Testing

`workflow-backend`:

- Migration creates and drops `workspace_task_status_timeline` and both triggers (`UPDATE OF status` + `INSERT`).
- `INSERT INTO workspace_tasks (...)` with non-empty status fires the `AFTER INSERT` trigger:
  - first active interval created immediately.
  - `started_at` set to `now()`, `ended_at` remains `NULL`.
- `INSERT INTO workspace_tasks (...)` with empty/null status → no timeline row created.
- `UPDATE workspace_tasks SET status = ...` fires the `AFTER UPDATE OF status` trigger correctly:
  - status unchanged → no new timeline row.
  - status changed → previous interval closed, new active interval opened.
  - status set to empty → previous interval closed, no new interval.
- `features?include=tasks` endpoint: verifies LEFT JOIN returns `started_at` / `ended_at` top-level, correct 1:1.
- `features?include=tasks` endpoint: task without timeline → `started_at = null`, still present in response.
- `tasks/:taskId` endpoint: `status_timeline[]` ordered by `started_at`, active interval `ended_at = null`.
- Status filters and sorting still use `workspace_tasks.status`.

`digital-factory-ui`:

- Sidebar renders live `now - started_at` from top-level field, updates every 1000ms.
- Sidebar renders `—` when `started_at = null` (no crash, no log inference).
- Task detail Activity Timeline has 2 tabs: Logs and Timeline.
- Logs tab renders log entries with browser locale timestamps.
- Timeline tab renders flow with colored status labels and correct duration.
- Grouping by `task.status` is not affected.

### Rollout

- Deploy migration and both triggers (`INSERT` + `UPDATE OF status`) before API changes.
- New tasks created after deployment get their first timeline row immediately via `AFTER INSERT`.
- Existing tasks get their first timeline row on the next status update after deployment.
- Frontend tolerates `started_at = null` in sidebar response during rollout.

### Backward compatibility

- `workspace_tasks.status` is unchanged.
- Existing filters and board grouping are unchanged.
- New fields (`started_at`, `ended_at`, `status_timeline`) are additive — old clients ignore them.
