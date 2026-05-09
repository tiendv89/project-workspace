# Tasks - Feature Kanban Board

Feature status reference: `ready_for_implementation`; stage status: `tasks/approved`. Machine state lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | Mode, status, and filter foundation | none |
| T2 | 2 | Task Mode shell preservation | T1 |
| T3 | 2 | Feature detail sheet | T1 |
| T4 | 3 | Feature Mode list view and controls integration | T2, T3 |
| T5 | 4 | Regression, responsive, and browser QA | T4 |

## T1 - Mode, status, and filter foundation

### Description

Add the non-visual foundation for Feature Mode. This task introduces explicit board mode state, separate Task Mode and Feature Mode search/filter state, feature status options, Feature Mode default filters, persistent filter storage, and split filter helpers. It must keep the existing task-status storage key and Task Mode filter behavior compatible.

### Required skills

- frontend-engineer
- typescript-best-practices
- nextjs-best-practices

### Subtasks

- [ ] Extend board context types with `boardMode`, mode setter, mode-specific search state, mode-specific filter state, and selected feature state.
- [ ] Default the board to Task Mode when no valid saved board mode exists.
- [ ] Persist active board mode with a constrained `dashboard:board-mode` value and safely fall back to Task Mode for missing or invalid stored values.
- [ ] Add feature status option metadata and ensure `in_handoff` displays as the product-facing `Handoff` label in Feature Mode.
- [ ] Split search/filter helpers into Task Mode and Feature Mode variants.
- [ ] Add separate Feature Mode filter storage with all feature statuses except `done` selected by default.
- [ ] Ensure Task Mode and Feature Mode each keep their own filter state when the user switches modes.
- [ ] Ensure Task Mode and Feature Mode filters both survive browser reload.
- [ ] Add or update unit tests for feature status defaults, Feature Mode filtering, Task Mode filtering, invalid stored filter recovery, filter persistence, and board-mode fallback.
- [ ] Confirm existing Task Mode filter persistence still reads `dashboard:board-status-filter`.

## T2 - Task Mode shell preservation

### Description

Refactor the existing board into a mode-aware shell while preserving the current Task Mode UI and behavior. This task should make the `Task` mode the default mode, keep existing task columns and feature expansion intact, and add the `Task` / `Feature` segmented control without yet completing the Feature Mode list.

### Required skills

- frontend-engineer
- typescript-best-practices
- heroui-react

### Subtasks

- [ ] Extract the current task-oriented board body into a Task Mode view or equivalent internal component.
- [ ] Add the board mode segmented control to board controls.
- [ ] Wire controls so Task Mode uses task search and task status filters.
- [ ] Ensure switching between Task Mode and Feature Mode does not copy search/filter state across modes.
- [ ] Keep existing `FeatureRow`, task column headers, expansion, `TaskCard`, and `TaskDetailSheet` behavior unchanged in Task Mode.
- [ ] Add regression tests for Task Mode search, filters, expansion, and task detail selection after the shell refactor.
- [ ] Ensure switching away from Task Mode does not clear Task Mode search/filter state.

## T3 - Feature detail sheet

### Description

Create the feature-level detail sheet/modal used by Feature Mode row clicks. The sheet must display only feature-level information and must not expose task cards, task actions, or task detail behavior.

### Required skills

- frontend-engineer
- typescript-best-practices
- heroui-react

### Subtasks

- [ ] Add a feature detail component and mount point that reads `selectedFeature` from board context.
- [ ] Display feature title, feature id, feature status pill, and last modified time when available.
- [ ] Add accessible dialog behavior consistent with the existing task detail sheet, including close button, overlay click, and Escape handling.
- [ ] Ensure closing the feature detail sheet clears only selected feature state.
- [ ] Add render tests for open, closed, and unknown-status feature detail states.

## T4 - Feature Mode list view and controls integration

### Description

Implement the actual Feature Mode experience. This task adds the feature-only list view, row component, feature search/filter behavior, Feature Mode empty/loading/error states, and row click behavior that opens the feature detail sheet.

### Required skills

- frontend-engineer
- typescript-best-practices
- heroui-react

### Subtasks

- [ ] Add a Feature Mode view that renders one row per visible feature.
- [ ] Add a feature row component that shows feature icon, title, id, feature status pill, and last modified metadata.
- [ ] Ensure Feature Mode rows do not render task cards, task rows, task status columns, task progress bars, or done/total task counts.
- [ ] Wire Feature Mode search to feature title/id only.
- [ ] Wire Feature Mode filters to feature lifecycle status only, with `done` excluded by default.
- [ ] Ensure Feature Mode row click opens feature detail and never opens task detail.
- [ ] Add tests for mode switching, separate search/filter state, empty filtered results, and unknown feature statuses.

## T5 - Regression, responsive, and browser QA

### Description

Verify the finished board behavior across Task Mode and Feature Mode. This task should focus on confidence that Task Mode did not regress and Feature Mode satisfies the product spec in the rendered app.

### Required skills

- browser-qa-frontend
- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Run type-check and the board-related Vitest suite.
- [ ] Run the full test command if practical for the branch.
- [ ] Start the Next.js app and verify `/board` in a browser with seeded workspace data.
- [ ] Verify Task Mode default behavior still shows task columns, feature expansion, task cards, and task detail sheets.
- [ ] Verify first visit opens Task Mode by default when no valid board mode is saved.
- [ ] Verify browser reload preserves saved filter state for both Task Mode and Feature Mode.
- [ ] Verify switching Task Mode to Feature Mode and back preserves each mode's own search/filter state.
- [ ] Verify Feature Mode default filter hides `done` features and shows active/blocked/cancelled lifecycle states.
- [ ] Verify Feature Mode search only matches feature title/id and not task title/id.
- [ ] Verify Feature Mode row click opens feature detail and does not open task detail.
- [ ] Check desktop and narrow viewport layouts for clipping, overflow, and overlapping controls.
