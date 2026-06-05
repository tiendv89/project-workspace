# Task Breakdown — task-status-transition-timeline

Feature status: `in_design`. Stage: `tasks` (`awaiting_approval`). Machine state lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Add status timeline table, trigger, and API exposure | — |
| T2 | 2 | Render sidebar duration + task detail Activities (Logs & Timeline tabs) | T1 |
| T3 | 3 | Regression and integration validation | T1, T2 |

## T1 — Add status timeline table, trigger, and API exposure

### Description

Add the `workspace_task_status_timeline` table and a PostgreSQL trigger that fires on `UPDATE OF status` on `workspace_tasks`. The trigger automatically closes the previous open interval and opens a new active interval on every status change.

API exposure uses 2 patterns:
- **Sidebar** (`features?include=tasks`, `features/:fid/tasks`): LEFT JOIN 1:1 → `started_at` + `ended_at` top-level.
- **Task detail** (`tasks/:taskId`): batch query → full `status_timeline[]`.

This task covers the full backend: migration, trigger, database reader queries, DTO type, and handler responses. No changes to `workspace-github-adapter`.

### Required skills

- go-best-practices
- postgres-best-practices

### Subtasks

- [ ] Add migration: `CREATE TABLE workspace_task_status_timeline` with unique partial index on active intervals
- [ ] Add migration: `CREATE TRIGGER trg_task_status_timeline_change` firing on `UPDATE OF status`
- [ ] Add migration: down scripts for table and trigger
- [ ] Add database reader: LEFT JOIN query for `features?include=tasks` (1:1, active interval only)
- [ ] Add database reader: batch query for `tasks/:taskId` (full `status_timeline[]` ordered by `started_at`)
- [ ] Add `TaskStatusTimelineEntry` DTO in `internal/domain/dto.go`
- [ ] Add `StartedAt` / `EndedAt` fields to task struct in feature-list response
- [ ] Add `StatusTimeline` field to task struct in task-detail response
- [ ] Update service layer: LEFT JOIN for feature-list handler, batch query for task-detail handler
- [ ] Verify status filters and sorting still use `workspace_tasks.status`, not timeline rows
- [ ] Add trigger behavior tests: status unchanged, status changed, status set to empty
- [ ] Add API tests: `features?include=tasks` returns `started_at` / `ended_at` top-level, task without timeline → `started_at = null`
- [ ] Add API tests: `tasks/:taskId` returns `status_timeline[]` ordered, active interval `ended_at = null`
- [ ] Run `golangci-lint run` and full test suite before PR

---

## T2 — Render sidebar duration + task detail Activities (Logs & Timeline tabs)

### Description

Consume timeline data with 2 patterns from backend:

**Sidebar:** map `started_at` / `ended_at` directly from response top-level. Display label `Time spent in: Xh Xm`, update every 1000ms via `setInterval`. Use `formatDuration(ms)` helper.

**Task detail — Activities:** new section with 2 switchable tabs:
- **Logs tab**: read task `activity` field from API response (or `log` from yaml-parser tasks), display timestamp + action + actor + note. Browser locale date format.
- **Timeline tab**: read `status_timeline[]`, display as flow `Moved from X to Y after Zh Zm`. Status labels colored per mapping. Current interval shows `Active now`.

Sidebar layout: `Time spent in: Xh Xm` on the left, feature name on the right, same row. Keep grouping by `task.status`. Do not infer timeline from task logs.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Add `started_at` / `ended_at` fields to sidebar task type (`features?include=tasks` response)
- [ ] Add `TaskStatusTimelineEntry` type and `status_timeline?` to task detail type
- [ ] Install `date-fns` (`pnpm add date-fns`)
- [ ] Implement `formatDuration(ms)` helper using `intervalToDuration` → output `Xh Xm` / `Xd Yh` / `Xm`
- [ ] Map `started_at` / `ended_at` in sidebar adapter (map directly, no filtering)
- [ ] Map `status_timeline` in task detail adapter
- [ ] Update `TaskTrackingItem`: label `Time spent in: Xh Xm`, live counter at 1000ms
- [ ] Update `TaskTrackingItem`: render `—` when `started_at = null`
- [ ] Sidebar layout: `Time spent in:` on left, feature name on right, same row
- [ ] Task detail: add **Activities** section with 2 switchable tabs (Logs | Timeline)
- [ ] Tab **Logs**: read `task.activity[]` (API) or `task.log[]` (yaml-parser), render timestamp + action + actor + note
- [ ] Tab **Logs**: empty state "No activity logs yet."
- [ ] Tab **Timeline**: implement `buildTimelineDisplay()` helper
- [ ] Tab **Timeline**: render flow — first "Entered X at ...", middle "Moved from X to Y after Zh Zm", current "Active now"
- [ ] Tab **Timeline**: status labels colored per mapping (todo=gray, ready=blue, in_progress=amber, blocked=red, in_review=reviewing=violet, done=emerald, cancelled=gray)
- [ ] Tab **Timeline**: timestamp format browser locale `Mmm DD, YYYY, HH:MM AM/PM`
- [ ] Add tests: `formatDuration` with various inputs
- [ ] Add tests: `buildTimelineDisplay` with active, closed, single-entry timeline
- [ ] Add tests: `TaskTrackingItem` renders live duration + label
- [ ] Add tests: Activities tabs render correct content
- [ ] Run frontend test suite and lint before PR

---

## T3 — Regression and integration validation

### Description

Verify that the backend timeline trigger, API response contract, and frontend sidebar + task detail Activities work together correctly. This task covers cross-component integration tests and regression validation to ensure existing board and sidebar behavior is not broken.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Verify `features?include=tasks` returns `started_at` / `ended_at` top-level, correct 1:1
- [ ] Verify `tasks/:taskId` returns `status_timeline[]` ordered by `started_at`, active interval `ended_at = null`
- [ ] Verify trigger produces correct interval rows for status change scenarios
- [ ] Verify sidebar renders `Time spent in: Xh Xm` label, counter updates at 1000ms
- [ ] Verify sidebar renders `—` when `started_at = null`
- [ ] Verify task detail Activities has 2 switchable tabs: Logs and Timeline
- [ ] Verify Logs tab renders log entries with correct timestamp format
- [ ] Verify Timeline tab renders flow: "Entered X at ..." → "Moved from X to Y after Zh Zm" → "Active now"
- [ ] Verify Timeline tab status labels have correct colors
- [ ] Verify repeated statuses produce separate timeline intervals
- [ ] Verify missing timeline data does not break sidebar or detail rendering
- [ ] Regression test: status filters, board grouping, and sidebar sections unchanged
- [ ] Regression test: existing task cards and feature rows unaffected
- [ ] Run full test suite and lint before PR
