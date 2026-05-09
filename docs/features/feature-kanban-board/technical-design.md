# Technical Design - Feature Kanban Board

## Feature

- Feature ID: `feature-kanban-board`
- Title: Feature Kanban Board
- Implementation repo: `digital-factory-ui`
- Management repo artifacts: `docs/features/feature-kanban-board/*`

## Current State

The board page in `digital-factory-ui` is a Next.js client page at
`src/app/board/page.tsx`. It loads a workspace from browser storage and renders
`BoardProvider`, `BoardHeader`, `TaskTrackingPanel`, `KanbanBoard`, and
`TaskDetailSheetMount`.

The board data path is already browser-only:

- `src/features/board/data/load-board-data.ts` reads `docs/features/*`.
- `status.yaml` is parsed into `ParsedFeature.featureStatus`.
- `tasks/T<n>.yaml` files are parsed into `ParsedTask[]`.
- open pull request task overrides can be merged into parsed tasks.

The current main board is task-oriented:

- `KanbanBoard.tsx` renders one status-column header per task status.
- `FeatureRow.tsx` expands each feature into task cards.
- `matchesSearch` searches feature title/id plus task title/id.
- `matchesStatusFilter` filters by task status.
- `status-filter-store.ts` persists one task-status filter key.
- `TaskDetailSheetMount` opens a task detail sheet from selected task state.

Useful feature-level primitives already exist:

- `ParsedFeature` includes `id`, `title`, `featureStatus`, and `tasks`.
- `status.ts` maps workflow feature statuses to labels and colors.
- `getFeatureLastModifiedAt` can derive a feature-level last modified value from
  task execution/log timestamps.

Current limitations:

- There is no explicit board mode state.
- Search and filter state are task-mode concepts only.
- Filtering by status uses task statuses, not feature lifecycle status.
- The existing feature row always exposes task progress, task counts, task
  segment bars, and task expansion.
- There is no feature detail sheet/modal.

## Problem Framing

Add a `Feature` mode to the existing board without changing `Task` mode behavior.
Feature mode must show one row per feature, filter by feature lifecycle status,
search only feature-level fields, and open feature-level detail on row click.

The implementation must keep these contracts stable:

- Task Mode behavior remains unchanged for task cards, task rows, task filters,
  task search, expansion, and `TaskDetailSheet`.
- Workspace import, GitHub access, and board-data loading
  remain unchanged.
- The parsed data model can be extended, but the repo and YAML source of truth
  remain unchanged.
- Feature Mode must not show task cards, task rows, task progress bars, done/total
  task counts, task status columns, task status filters, or task detail sheets.

Fixed assumptions:

- Feature lifecycle state comes from `status.yaml -> feature_status`.
- Supported feature statuses are `in_design`, `in_tdd`,
  `ready_for_implementation`, `in_implementation`, `in_handoff`, `done`,
  `blocked`, and `cancelled`.
- Default Feature Mode filters include every supported feature status except
  `done`.
- The implementation is limited to `digital-factory-ui`.

## Options Considered

### Option A - Add Feature Mode conditionals inside existing KanbanBoard and FeatureRow

What it is:

- Add a `mode` state to the current `KanbanBoard`.
- Keep the same `FeatureRow` component and branch internally for task vs feature
  display.

Pros:

- Smallest initial diff.
- Reuses current component tree directly.

Cons:

- Mixes two different board concepts in one row component.
- Makes it easier for task-only UI, such as task counts or segment bars, to leak
  into Feature Mode.
- Increases regression risk for Task Mode because core task rendering would carry
  more conditional behavior.

Implementation impact:

- Touches `KanbanBoard.tsx`, `FeatureRow.tsx`, `filter.ts`,
  `status-filter-store.ts`, context, and tests.

Dependency impact:

- Low setup cost, but every later Feature Mode change would be coupled to Task
  Mode row behavior.

### Option B - Add a mode-aware board shell with separate Task and Feature views

What it is:

- Add board mode state to `BoardProvider`.
- Keep the existing task board behavior behind a Task Mode view.
- Add a separate Feature Mode view with its own row component, filters, search,
  and feature detail sheet.

Pros:

- Preserves Task Mode as a stable path.
- Makes Feature Mode easier to reason about because it has feature-only
  components and helpers.
- Allows separate task-status and feature-status filter storage.
- Keeps row-click behavior explicit: Task Mode expands/tasks; Feature Mode opens
  feature detail.

Cons:

- Slightly larger refactor than Option A.
- Requires a clean interface between shared controls and active mode state.

Implementation impact:

- Adds board mode state, feature filter state, feature detail state, and feature
  view components.
- Refactors current `KanbanBoard` enough to render the active view.

Dependency impact:

- Creates a small foundation task before UI tasks can be integrated.

### Option C - Add a new `/features` page separate from the Kanban Board

What it is:

- Leave `/board` unchanged.
- Create a separate feature list page using existing board data.

Pros:

- Lowest risk to the task board.
- Avoids control-state collisions.

Cons:

- Does not satisfy the product requirement for a Board mode toggle.
- Splits a workflow that should stay inside the Kanban Board.
- Creates routing/navigation questions outside the requested scope.

Implementation impact:

- Adds a new page and likely duplicates board-loading behavior.

Dependency impact:

- Avoids some board internals but introduces a product mismatch.

## Chosen Design

Choose Option B: a mode-aware board shell with separate Task and Feature views.

### Board state and controls

Extend `BoardProvider` context with:

- `boardMode: "task" | "feature"`
- `setBoardMode`
- `taskSearchQuery` and `setTaskSearchQuery`
- `featureSearchQuery` and `setFeatureSearchQuery`
- `taskActiveFilters` and `setTaskActiveFilters`
- `featureActiveFilters` and `setFeatureActiveFilters`
- `selectedFeature` and `setSelectedFeature`

State persistence contract:

- The default board mode is always `task` when there is no valid saved mode.
- Persist the active board mode in browser storage, for example
  `dashboard:board-mode`, with only `task` and `feature` accepted values.
- A browser reload restores the saved board mode. If the saved value is missing
  or invalid, the board opens in Task Mode.
- Switching between Task Mode and Feature Mode must preserve each mode's own
  search and filter state for the current session.
- Task Mode filters persist across browser reload using the existing
  `dashboard:board-status-filter` key.
- Feature Mode filters persist across browser reload using a separate
  `dashboard:board-feature-status-filter` key.
- Switching modes must never copy task status filters into Feature Mode or
  feature lifecycle filters into Task Mode.

Compatibility rule:

- Existing consumers can temporarily keep aliases such as `searchQuery` and
  `activeFilters` only if they still refer to Task Mode behavior. New code should
  use mode-explicit names.

`BoardControls` becomes mode-aware:

- The left side gains a compact `Task` / `Feature` segmented control.
- Search input reads/writes the active mode search state.
- Filter menu uses task status options in Task Mode and feature status options in
  Feature Mode.
- Active filter count and checkbox state are derived from the active mode only.
- `Sync` behavior remains unchanged and reloads the same board data.

### Status and filter helpers

Create explicit feature status primitives in `status.ts`:

- `FEATURE_STATUS_OPTIONS`
- `FeatureStatus`
- `getFeatureStatusLabel`
- `getFeatureStatusColor`

Keep `STATUS_COLUMNS` as the task status source of truth.

Split filter helpers:

- `matchesTaskModeSearch(feature, query)`
- `matchesTaskModeStatusFilter(feature, taskStatuses)`
- `matchesFeatureModeSearch(feature, query)`
- `matchesFeatureModeStatusFilter(feature, featureStatuses)`

Feature Mode search only checks:

- `feature.title`
- `feature.id`

Feature Mode status filtering checks only:

- `feature.featureStatus`

An empty Feature Mode filter returns no features. This follows the product rule
that no selected feature statuses means no feature rows are shown. Existing Task
Mode empty-filter behavior remains unchanged unless a task-mode requirement says
otherwise.

Persist filters separately:

- existing key `dashboard:board-status-filter` remains Task Mode only.
- add `dashboard:board-feature-status-filter` for Feature Mode.
- both filter stores must survive browser reloads.

The Feature Mode default is all feature statuses except `done`.

### Task Mode view

Extract the current task-board rendering into a task-specific view, for example:

- `TaskBoardView`
- `TaskBoardColumnHeader`

This view continues to:

- use task status columns,
- calculate task counts from visible task statuses,
- render existing `FeatureRow`,
- preserve feature expansion,
- open `TaskDetailSheet` from task-card selection.

This keeps Task Mode behavior stable while the board shell becomes mode-aware.

### Feature Mode view

Add a Feature Mode list view, for example:

- `FeatureBoardView`
- `FeatureListRow`

The view renders one row per `ParsedFeature` and does not render task columns,
expanded task grids, task cards, task counts, or segment bars.

Each row shows:

- feature icon,
- feature title,
- feature id,
- feature status pill,
- last modified time if available.

Unknown feature statuses render with fallback label/color and do not crash the
board.

Click behavior:

- Row click sets `selectedFeature`.
- Feature detail sheet opens.
- Row click does not call `toggleFeature`.
- Row click does not set `selectedTask`.

### Feature detail sheet

Add a feature detail sheet/modal mounted alongside the existing task sheet.

The sheet should show feature-level information only:

- feature title,
- feature id,
- feature lifecycle status,
- last modified time if available,
- current stage/next action only if already available in parsed data later.

No task cards or task detail controls are shown. The first implementation can
avoid adding new GitHub reads for full `status.yaml` detail; it can use the
already parsed `ParsedFeature` data. If richer status details are needed later,
that should be a separate feature or follow-up task.

### Data model compatibility

No YAML format changes are required.

Optional parser extensions are allowed only if they support feature-level detail
without breaking existing tests. The initial Feature Mode can use the current
`ParsedFeature` fields.

### Operational and release implications

This is a frontend-only change. It ships in `digital-factory-ui` and does not
require database migrations, backend deployment, workflow runtime changes, or
new environment variables.

Because the board reads live workspace YAML from GitHub, QA must cover real
workspace-like data and not only isolated component markup.

## Dependency Analysis

Internal dependencies:

- `BoardProvider` is the state owner for mode, search, filters, and selected
  detail state.
- `KanbanBoard` currently owns controls and task board rendering, so it must be
  split carefully before Feature Mode is added.
- Existing tests around task filtering, status filter storage, and board QA must
  remain green.
- `TaskTrackingPanel` uses `trackedFeatures` and task status grouping. It is
  unaffected by Feature Mode and should not consume feature filters.

External dependencies:

- No new npm package is required.
- No Figma dependency is required for this planning scope.
- GitHub Contents API behavior remains unchanged.

Blocking decisions:

- None for the first implementation.

Configuration dependencies:

- Existing workspace storage and GitHub token behavior remain as-is.
- Add one new localStorage key for Feature Mode filters.

Release dependencies:

- Needs standard frontend validation: type-check, unit tests, and browser QA on
  `/board`.
- Rollout can be a normal frontend release because no data migration is needed.

## Parallelization / Blocking Analysis

External decisions/dependencies:

- None. The implementation can start after tasks-stage approval.

T1: Mode, status, and filter foundation
  └── Can begin now — no blockers
  │
  T2: Task Mode shell preservation
    └── BLOCKED on T1 (mode-explicit context and filter helpers must exist)
  │
  T3: Feature detail sheet
    └── BLOCKED on T1 (selected feature state and feature status helpers must exist)
  │
  T2 and T3 run in parallel after T1
  │
    T4: Feature Mode list view and controls integration
      └── BLOCKED on T2 (the board shell must switch between Task and Feature views)
      └── BLOCKED on T3 (row click must open the feature detail sheet, not task detail)
      │
      T5: Regression, responsive, and browser QA
        └── BLOCKED on T4 (the full Feature Mode workflow must be integrated)

## Repository Impact

Affected repo:

- `digital-factory-ui`

Why:

- The change is entirely in the Next.js frontend board experience.
- The management repo stores this feature plan and task state only.

Expected implementation areas:

- `src/features/board/components/KanbanBoard/*`
- `src/features/board/components/FeatureRow/*`
- new `src/features/board/components/FeatureBoardView/*` or equivalent
- new `src/features/board/components/FeatureDetailSheet/*` or equivalent
- `src/features/board/lib/status.ts`
- `src/features/board/lib/filter.ts`
- `src/features/board/lib/status-filter-store.ts`
- board-related tests under `src/__tests__`

Unaffected repos:

- `workflow-backend`
- `rag-service`
- `git-nexus`
- `workflow`
- `management-repo` outside this feature planning artifact

## Validation and Release Impact

Testing expectations:

- Unit tests for feature status defaults and filter storage.
- Unit tests for Task Mode search/filter behavior to prove no regression.
- Unit tests for Feature Mode search/filter behavior.
- Component/render tests for Feature Mode rows and detail sheet.
- Integration test for switching Task -> Feature -> Task while preserving mode
  specific search/filter state.
- Browser QA for `/board` with desktop and mobile-ish widths.

Migration/config impact:

- No migration.
- No new environment variables.
- One new browser `localStorage` key for Feature Mode filters.

Backward compatibility constraints:

- Existing Task Mode saved filter key must remain readable.
- Existing workspace storage must remain readable.
- Unknown feature statuses must render safely.

Deployment/handoff implications:

- Normal frontend deployment.
- Handoff should mention that Feature Mode intentionally hides task progress and
  task detail behavior.
