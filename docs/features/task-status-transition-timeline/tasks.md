# Task Breakdown — task-status-transition-timeline

Feature status: `ready_for_implementation`. Stage: `tasks` (`approved`). Machine state lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Add status timeline table, trigger, and API exposure | — |
| T2 | 2 | Render current status interval duration in sidebar | T1 |
| T3 | 3 | Regression and integration validation | T1, T2 |

## T1 — Add status timeline table, trigger, and API exposure

### Description

Add the `workspace_task_status_timeline` table and a PostgreSQL trigger that fires on `UPDATE OF status` on `workspace_tasks`. The trigger automatically closes the previous open interval and opens a new active interval on every status change. Then expose `status_timeline` in all task list and detail API responses.

This task covers the full backend: migration, trigger, database reader query, DTO type, service batch-mapping logic, and handler responses across all affected endpoints. No changes to `workspace-github-adapter`.

### Required skills

- go-best-practices
- postgres-best-practices

### Subtasks

- [ ] Add migration: `CREATE TABLE workspace_task_status_timeline` with unique partial index on active intervals
- [ ] Add migration: `CREATE TRIGGER trg_task_status_timeline_change` firing on `UPDATE OF status`
- [ ] Add migration: down scripts for table and trigger
- [ ] Add database model and batch-read query for timeline rows by task UUIDs
- [ ] Add `TaskStatusTimelineEntry` DTO in `internal/domain/dto.go`
- [ ] Add `StatusTimeline` field to `TaskSummary`
- [ ] Update service layer: collect task UUIDs, batch-fetch timeline rows, attach to each task response
- [ ] Verify all affected endpoints return `status_timeline`
- [ ] Verify status filters and sorting still use `workspace_tasks.status`, not timeline rows
- [ ] Add trigger behavior tests: status unchanged, status changed, status set to empty
- [ ] Add API tests: `status_timeline` ordered by `started_at`, active interval `ended_at = null`, closed interval `ended_at >= started_at`
- [ ] Run `golangci-lint run` and full test suite before PR

---

## T2 — Render current status interval duration in sidebar

### Description

Consume `status_timeline` from the backend API and render the current status interval duration in the task tracking sidebar. Add types, map the field into the frontend task model, implement `findCurrentStatusInterval`, and update `TaskTrackingItem` rendering.

Layout: status duration on the left, last-seen timestamp on the right, same row. All time calculations use browser time. Keep sidebar grouping by `task.status` unchanged. Do not infer timeline from task logs.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Add `TaskStatusTimelineEntry` type in `src/services/workflow-backend/types.ts`
- [ ] Add `status_timeline?` to `TaskSummary` type
- [ ] Add `statusTimeline?` to `ParsedTask` in `src/services/yaml-parser.ts`
- [ ] Map `status_timeline` → `statusTimeline` in `workspaceAdapter.ts`
- [ ] Implement `findCurrentStatusInterval` helper in `src/lib/time.ts`
- [ ] Update `TaskTrackingItem` to replace status-age badge with timeline-based duration
- [ ] Layout: duration on left, last-seen time on right, same row
- [ ] Active interval: live `Date.now() - started_at`, update every second
- [ ] Closed interval: fixed `ended_at - started_at`
- [ ] Empty timeline: show existing empty state, do not infer from logs
- [ ] Add tests: `findCurrentStatusInterval` with active, closed, repeated, and missing intervals
- [ ] Add tests: `TaskTrackingItem` renders timeline duration correctly
- [ ] Run frontend test suite and lint before PR

---

## T3 — Regression and integration validation

### Description

Verify that the backend timeline trigger, API response contract, and frontend sidebar rendering work together correctly. This task covers cross-component integration tests and regression validation to ensure existing board and sidebar behavior is not broken by the new `status_timeline` field.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Verify `status_timeline` response field is present and correct in all task API endpoints
- [ ] Verify trigger produces correct interval rows for status change scenarios
- [ ] Verify sidebar renders live duration from active timeline interval
- [ ] Verify sidebar renders fixed duration from closed timeline interval
- [ ] Verify repeated statuses produce separate timeline intervals
- [ ] Verify missing timeline data does not break sidebar rendering
- [ ] Regression test: status filters, board grouping, and sidebar sections unchanged
- [ ] Regression test: existing task cards and feature rows unaffected
- [ ] Run full test suite and lint before PR
