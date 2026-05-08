# Tasks - UI Interaction Updates

Feature status reference: `in_tdd`; stage status: `technical_design/awaiting_approval`. Machine state lives in `tasks/T<n>.yaml`; this file is narrative only.

## Index

| ID | Wave | Title | Depends on |
|---|---:|---|---|
| T1 | 1 | Board refresh and filter persistence foundation | [] |
| T2 | 1 | Sidebar companion panel and 15/85 board layout | [] |
| T3 | 1 | Feature row summary refinements | [] |
| T4 | 2 | Integration tests and browser QA | [T1, T2, T3] |

---

## T1 — Board refresh and filter persistence foundation

### Description

Implement the shared board-state changes that support the sidebar and default filter requirements.

This task owns the 60 second automatic refresh behavior and persisted status filter state. It should reuse the same reload path used by manual sync so the board and sidebar stay consistent.

Deliverables:

- Add a 60 second refresh interval for board data and tracked sidebar data.
- Ensure the interval is cleaned up on unmount.
- Ensure interval refresh does not reset search text, active filters, selected task modal, expanded/collapsed state, or board scroll state.
- Add status filter persistence in `localStorage`.
- Default the status filter to all statuses except `done` when no saved filter exists.
- Preserve manual sync as an immediate reload action.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Identify the existing reload paths in `BoardProvider`, `useBoardData`, and `usePullRequestTaskData`.
- [ ] Add the 60 second interval using React effects and cleanup.
- [ ] Keep manual sync wired to the same reload path.
- [ ] Add a status filter storage helper under `src/features/board/lib/`.
- [ ] Initialize filters from storage, or default to all statuses except `done`.
- [ ] Save filter changes after user updates the filter.
- [ ] Add Vitest coverage for interval reload with fake timers.
- [ ] Add Vitest coverage for default and persisted filter behavior.
- [ ] Typecheck passes.

---

## T2 — Sidebar companion panel and 15/85 board layout

### Description

Convert the current left navigation/sidebar into the product-specified companion panel.

The board must remain visible on the right while users expand/collapse sidebar rows and click task cards. The main area below the header should target approximately 15% sidebar width and 85% Kanban Board width on desktop, with practical min/max constraints for usability.

Deliverables:

- Update `/board` layout so the sidebar and Kanban Board remain visible together.
- Target a 15% / 85% content split on desktop.
- Remove the primary flow where selecting a sidebar status replaces the Kanban Board with `TaskTrackingDetailPanel`.
- Render 3 collapsible sidebar sections in this order: `IN PROGRESS`, `IN REVIEW`, `READY`.
- Expand all 3 sections by default.
- Preserve per-section collapse/expand state during the current session.
- Render task cards directly inside each section.
- Task cards show task name, feature/project name, actor type if available, priority if available, and next action or blocked reason if available.
- Empty expanded sections show `No tasks.`
- Clicking a task card calls `setSelectedTask` and opens the existing task detail modal.
- Sidebar list scrolls independently when it contains many tasks.
- Search and active status filter update sidebar results.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Update `src/app/board/page.tsx` to keep sidebar and Kanban Board visible together.
- [ ] Replace fixed sidebar-only navigation behavior with companion panel behavior.
- [ ] Implement 15% / 85% layout with readable min/max constraints.
- [ ] Update `TaskTrackingPanel` to render collapsible task sections.
- [ ] Set default expanded state for all 3 sections.
- [ ] Apply product order: `IN PROGRESS`, `IN REVIEW`, `READY`.
- [ ] Render sidebar task cards directly in the section body.
- [ ] Wire card click to `setSelectedTask`.
- [ ] Apply search and status filter to sidebar grouping.
- [ ] Add empty state text `No tasks.` for empty expanded sections.
- [ ] Add or update component tests for section order, default expansion, collapse, empty states, and click-to-open behavior.
- [ ] Typecheck passes.

---

## T3 — Feature row summary refinements

### Description

Finish the Kanban feature row behavior described in the product spec.

The existing `FeatureRow` already has partial support for status pill, done/total, segment bar, last modified time, and collapsed rows. This task tightens the remaining behavior so it matches the current spec exactly.

Deliverables:

- Feature rows remain collapsed by default.
- Feature row primary label displays `feature_id`, not feature title.
- Right-side summary group displays feature status pill, done/total count, status segment bar, and last modified time when available.
- Status segment bar renders one equal-width segment per task.
- Segment hover/focus shows the corresponding task status tooltip.
- Last modified time is calculated from `task.execution.last_updated_at` and `task.log[].at`.
- If no valid timestamp exists, last modified text is hidden.
- Expanded rows continue placing tasks in the correct status columns.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Update `FeatureRow` to render `feature.id` as the primary row label.
- [ ] Ensure feature status pill, done/total count, segment bar, and modified time stay grouped on the right.
- [ ] Update segment bar to render one equal-width segment per task.
- [ ] Preserve tooltip behavior for every task segment.
- [ ] Verify last modified time uses latest valid task execution/log timestamp.
- [ ] Keep no-timestamp behavior hidden.
- [ ] Add or update tests for feature label, segment count/width behavior, and modified timestamp behavior.
- [ ] Typecheck passes.

---

## T4 — Integration tests and browser QA

### Description

Run final integration and browser QA after the foundation, sidebar, and feature row tasks are complete.

This task owns end-to-end confidence rather than broad implementation. It should fix regressions discovered during QA if they are directly caused by this feature.

### Required skills

- frontend-engineer
- browser-qa-frontend

### Subtasks

- [ ] Run the unit test suite.
- [ ] Run TypeScript type-check.
- [ ] Run production build.
- [ ] Start the local app and open `/board` with an imported workspace.
- [ ] Verify header, sidebar, and Kanban Board layout.
- [ ] Verify sidebar target split is approximately 15% and board is approximately 85% on desktop.
- [ ] Verify all 3 sidebar sections are expanded by default.
- [ ] Verify collapse/expand state for each sidebar section.
- [ ] Verify task cards render in `IN PROGRESS`, `IN REVIEW`, and `READY`.
- [ ] Verify clicking a sidebar task opens the task detail modal and keeps the Kanban Board visible.
- [ ] Verify search and status filter update sidebar and board results.
- [ ] Verify default filter excludes `Done` on first visit.
- [ ] Verify changed filter preferences survive reload.
- [ ] Verify automatic refresh runs every 60 seconds without resetting UI state.
- [ ] Verify manual sync refreshes immediately.
- [ ] Verify feature rows are collapsed by default and display the required summary fields.
- [ ] Fix feature-owned regressions found during QA.
