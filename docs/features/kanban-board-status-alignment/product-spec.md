# Product Specification

## Feature
- Feature ID: `kanban-board-status-alignment`
- Title: Kanban Board Status Alignment

## Problem
Task sidebar and kanban board status rendering is not aligned with the expected
workflow status contract.

Current issues:
- The task sidebar is missing the `In Review` label for status value
  `in_review`.
- The `In Reviewing` label must map to status value `reviewing`.
- Kanban board Feature Mode and Task Mode must render different status lists.
- The backend feature-list endpoint can return features whose included `tasks`
  array is empty after applying a task status filter. For example,
  `/api/workspaces/:workspaceId/features?include=tasks&status=...` may return a
  feature with `tasks: []`, which means the feature has no tasks matching the
  requested statuses and should not appear in that filtered response.

## Goals
- Add `In Review` as the display label for task status value `in_review`.
- Keep `In Reviewing` as the display label for task status value `reviewing`.
- Render Feature Mode kanban columns in this exact order:
  - `in_design`
  - `in_tdd`
  - `ready_for_implementation`
  - `in_implementation`
  - `in_handoff`
  - `done`
  - `blocked`
  - `cancelled`
- Render Task Mode kanban columns in this exact order:
  - `todo`
  - `ready`
  - `in_progress`
  - `blocked`
  - `in_review`
  - `reviewing`
  - `done`
  - `cancelled`
- Preserve existing sidebar and board behavior outside status visibility,
  status order, and display labels.
- Treat the Feature Mode and Task Mode status lists above as strict allowlists:
  if the current kanban board shows any status outside the supplied list for
  that mode, remove that old status from the mode.
- Apply the same strict allowlists to the status filters for both modes: Feature
  Mode filters must expose only the supplied Feature Mode statuses, and Task
  Mode filters must expose only the supplied Task Mode statuses.
- When the backend feature-list API is called with `include=tasks` and a
  task-status `status` filter, return only features that have at least one
  included task matching the requested statuses.
- After the backend filtering change lands, verify the Digital Factory UI
  consumes the updated response contract correctly in both board modes and does
  not surface filtered-out features or legacy status values.

## Non-goals
- No new status values.
- No workflow lifecycle changes outside the Digital Factory UI status display.
- No redesign of the task sidebar or kanban board.
- No changes to search UX, pagination controls, card click behavior, or detail
  navigation outside the status allowlist/filter corrections described in this
  spec.

## Success criteria
- Task sidebar displays `In Review` for `in_review`.
- Task sidebar displays `In Reviewing` for `reviewing`.
- Task Mode kanban board displays `In Review` and `In Reviewing` as separate
  columns/status groups.
- Feature Mode kanban board displays only:
  `in_design`, `in_tdd`, `ready_for_implementation`, `in_implementation`,
  `in_handoff`, `done`, `blocked`, `cancelled`.
- Task Mode kanban board displays only:
  `todo`, `ready`, `in_progress`, `blocked`, `in_review`, `reviewing`, `done`,
  `cancelled`.
- Feature Mode and Task Mode do not display any legacy/extra kanban status
  columns outside their supplied lists.
- Feature Mode and Task Mode filters do not display or submit any legacy/extra
  status values outside their supplied lists.
- `/api/workspaces/:workspaceId/features?include=tasks&status=...` does not
  return features with `tasks: []` when the empty task list is caused by the
  requested task-status filter.
- The Digital Factory UI, when exercised against the backend behavior above,
  does not render feature rows/cards whose tasks were fully filtered out by the
  requested task-mode statuses.
- The frontend does not use `in_reviewing` as a task status value for
  `In Reviewing`.

## User stories
- As a workflow user, I want `In Review` and `In Reviewing` to appear as
  separate task statuses so I can distinguish waiting-for-review work from
  actively-reviewing work.
- As a workflow user, I want Feature Mode and Task Mode to show the correct
  status sets so board columns match the workflow state I am viewing.
- As a workflow user, I want task-status filtered board data to stay aligned
  between backend responses and frontend rendering so I do not see features
  that have no matching tasks for the active filter.

## Architecture decisions

### D1. Keep label and value mapping explicit
Task status display labels must be mapped explicitly:
- `In Review` -> `in_review`
- `In Reviewing` -> `reviewing`

### D2. Keep board status lists mode-specific
Feature Mode must use the feature lifecycle status list. Task Mode must use the
task status list. The two modes must not share one combined status list.

### D3. Supplied kanban status lists are strict allowlists
Each kanban mode must render only the statuses supplied in this spec. Any
existing mode status that is not in the supplied list must be removed from that
mode rather than kept as an extra column.

### D4. Status filters follow the same allowlists
Feature Mode and Task Mode status filters must use the same supplied status
lists as their kanban columns. Filter options or submitted filter values outside
the supplied list must be removed.

### D5. Feature list task-status filtering excludes empty task matches
When `include=tasks` and `status=<task-status-list>` are both present, the
feature-list response must include only features with at least one returned task
after the status filter is applied. A feature with `tasks: []` for that request
does not match the filter and must be excluded from the response.

### D6. Backend filtering change must be verified through frontend integration
Backend correctness for `include=tasks&status=...` is not complete until the
Digital Factory UI is exercised against that response shape. The acceptance
check must confirm the frontend no longer renders empty-match feature rows and
still renders only the approved mode-specific statuses and filters.

## Open questions
- None.

## Dependencies and risks

### Dependencies
- `digital-factory-ui` task sidebar status label definitions.
- `digital-factory-ui` kanban board mode configuration.
- `digital-factory-ui` Feature Mode and Task Mode status filter configuration.
- `workflow-backend` feature-list endpoint filtering for
  `/api/workspaces/:workspaceId/features?include=tasks&status=...`.

### Risks
- Existing frontend code may contain a non-canonical `in_reviewing` task status
  value. Implementation must replace that mapping with `reviewing` for
  `In Reviewing`.
