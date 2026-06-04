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

This feature also has a concrete product requirement on both system sides:

- The backend must extend `GET /workspaces/:workspaceId/tasks` so each task can
  return status timeline data for every recorded status interval.
- The frontend task sidebar must consume that timeline, detect the task's
  current status, and render the matching timeline entry for that current
  status.

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
- Extend `GET /workspaces/:workspaceId/tasks` to return the task status timeline
  in the API response.
- Integrate the returned timeline into the frontend task sidebar.
- In the task sidebar, identify the task's current status and render the
  timeline entry that corresponds to that current status.
- If the current status timeline entry has no `ended_at`, calculate the live
  duration as `now - started_at`.

## Non-goals

- No change to the allowed task statuses.
- No change to the existing status transition workflow itself.
- No analytics dashboard, SLA calculation, or reporting UI in v1.
- No guarantee of perfect backfill for historical transitions that were never
  recorded explicitly before this feature.
- No separate timeline endpoint in v1; the required timeline data is delivered
  through `GET /workspaces/:workspaceId/tasks`.
- No timeline rendering outside the task sidebar in v1.

## Success criteria

- A task that moves `todo -> ready -> in_progress` records two closed intervals
  and one active interval with exact transition timestamps.
- When a task leaves `ready`, the `ready` interval `ended_at` matches the
  `started_at` of the next status interval.
- If a task returns to `ready` later, that creates a new `ready` interval
  instead of overwriting the earlier one.
- The workflow can still read the current task status without ambiguity while
  also exposing the full status timeline.
- `GET /workspaces/:workspaceId/tasks` returns status timeline data for each
  task.
- The frontend task sidebar renders the timeline entry for the task's current
  status, not a stale or mismatched status.
- When the current status timeline entry has `ended_at = null`, the sidebar
  shows elapsed time computed from `now - started_at`.
- When the current status timeline entry has both `started_at` and `ended_at`,
  the sidebar shows the closed interval for that status instead of a live timer.
