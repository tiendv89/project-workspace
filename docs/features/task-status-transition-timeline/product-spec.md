# Product Specification

## Feature
- Feature ID: `task-status-transition-timeline`
- Title: `Task Status Transition Timeline`

## Problem

Today the workflow only tells us the current status of a task. It does not keep
an explicit timeline for when a status started and when it ended.

Because of that, we cannot answer basic questions reliably:

- When did a task enter `ready`?
- When did `ready` end because the task moved to another status?
- How long did the task stay in each status?
- If a task returns to the same status later, what were the separate time
  ranges?

The requested behavior is: when a task changes from one status to another at
time `T`, the previous status interval ends at `T` and the new status interval
starts at `T`.

This feature has concrete product requirements on both system sides:

- The backend must extend `GET /.../features?include=tasks` so each task returns
  `started_at` / `ended_at` for its current status interval (sidebar pattern),
  and `GET /.../tasks/:taskId` so each task returns the full `status_timeline[]`
  for every recorded status interval (detail pattern).
- The frontend task sidebar must consume the current interval, detect the task's
  current status, and render the matching timeline entry with live elapsed time.
- The frontend task detail must surface an **Activities** section with two
  switchable tabs: **Logs** (activity log entries from API / YAML) and
  **Timeline** (flow view of all status transitions from `status_timeline[]`).

## Goals

- Track a timeline of task status intervals, not only the latest status value.
- When a task changes status at time `T`, close the previous interval with
  `ended_at = T`.
- Open the new interval at the same transition time with `started_at = T`.
- Keep the current active status interval open until the next status change.
- Support repeated entry into the same status as separate timeline intervals.
- Preserve the existing workflow status names and transition rules.
- Make the status timeline available for later audit, duration reporting, and UI
  display.
- Expose current status interval (`started_at` / `ended_at`) and full
  `status_timeline[]` through existing task API endpoints.
- Integrate the current interval into the frontend task sidebar as a live
  `Time spent in: Xh Xm` label updated at 1000ms.
- In the task detail, surface an Activities section with Logs and Timeline
  tabs — Timeline renders status transitions as a flow from `status_timeline[]`.
- If the current status timeline entry has no `ended_at`, calculate the live
  duration as `now - started_at`.

## Non-goals

- No change to the allowed task statuses.
- No change to the existing status transition workflow itself.
- No analytics dashboard, SLA calculation, or reporting UI in v1.
- No guarantee of perfect backfill for historical transitions that were never
  recorded explicitly before this feature.
- No separate timeline endpoint in v1; timeline data is delivered through
  existing endpoints (`features?include=tasks` for sidebar, `tasks/:taskId`
  for detail).
- Timeline is surfaced in the task sidebar (live interval) and task detail
  Activities tab (full history); no timeline rendering on the feature board
  or dashboard in v1.

## Success criteria

- A task that moves `todo -> ready -> in_progress` records two closed intervals
  and one active interval with exact transition timestamps.
- When a task leaves `ready`, the `ready` interval `ended_at` matches the
  `started_at` of the next status interval.
- If a task returns to `ready` later, that creates a new `ready` interval
  instead of overwriting the earlier one.
- The workflow can still read the current task status without ambiguity while
  also exposing the full status timeline.
- `GET /.../features?include=tasks` returns `started_at` / `ended_at` for the
  current status interval of each task.
- `GET /.../tasks/:taskId` returns the full `status_timeline[]` ordered by
  `started_at`.
- The frontend task sidebar renders the timeline entry for the task's current
  status, not a stale or mismatched status.
- When the current status timeline entry has `ended_at = null`, the sidebar
  shows elapsed time computed from `now - started_at`.
- When the current status timeline entry has both `started_at` and `ended_at`,
  the sidebar shows the closed interval for that status instead of a live timer.
- The task detail Activities section renders the full status transition flow
  from `status_timeline[]` with correct status labels and colors.
