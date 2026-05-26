# Tasks - df-ui-bugfix

> Feature status: `ready_for_implementation` - stage status: `tasks` (`approved`; T1, T2, T3, T5, and T6 are ready). Machine state lives in `tasks/T<n>.yaml`; this file is the narrative task breakdown only.

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | Dedicated task creation flow and detail-modal cleanup | none |
| T2 | 1 | Mode-specific list search/filter endpoint contract | none |
| T3 | 1 | Task Docs tasks.md document URL rendering | none |
| T4 | 2 | Feature/task pagination API wiring | T2 |
| T5 | 1 | Task-mode feature lifecycle status mapping | none |
| T6 | 1 | Kanban feature lifecycle status mapping | none |
| T8 | 1 | Sidebar blocked section and status-age indicators | none |
| T9 | 1 | Timeline link formatting and click-handling | none |
| T10 | 1 | Task tab layout reordering | none |
| T7 | 4 | Post-change final regression and browser QA | T1, T2, T3, T4, T5, T6, T8, T9, T10 |

## T1 — Dedicated task creation flow and detail-modal cleanup

### Description
Add a dedicated task creation entry point and flow/dialog that is independent from task and feature detail modals. Remove remaining active task/feature detail modal render paths and ensure task creation is not nested inside any detail surface.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Locate any existing create-task action, client helper, or UI entry point and reuse it for the dedicated creation flow when available.
- [ ] Add a dedicated task creation entry point in the board/workspace UI that opens a create-task flow/dialog without selecting a task or feature detail modal.
- [ ] Remove or disable remaining active task/feature detail modal render paths after tab-first navigation is in place.
- [ ] Keep feature and task detail content reachable through Feature tab and Task tab views only.
- [ ] Add focused tests proving feature/task clicks open tabs, task creation opens the dedicated flow, and detail modals are not mounted.
- [ ] If no task creation write contract exists in the frontend, document the backend dependency instead of faking creation locally.

## T2 — Mode-specific list search/filter endpoint contract

### Description
Lock the board list contract so Feature mode and Task mode each use their own backend collection endpoint for list, search, and status filtering. Feature mode must call `/api/workspaces/:workspaceId/features` and Task mode must call `/api/workspaces/:workspaceId/tasks`; search text is serialized as `title` and selected status is serialized as `status` for both endpoints.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Ensure Feature mode list/search/filter requests use `/api/workspaces/:workspaceId/features`.
- [ ] Ensure Task mode list/search/filter requests use `/api/workspaces/:workspaceId/tasks`.
- [ ] Serialize search text as `title` for both feature and task list requests.
- [ ] Serialize status filtering as `status` for both feature and task list requests.
- [ ] Remove or bypass any board list path that searches or filters locally from the workspace root payload.
- [ ] Add focused tests for `/features?title=...&status=...` and `/tasks?title=...&status=...` request URLs.

## T3 — Task Docs tasks.md document URL rendering

### Description
Lock the Feature tab Task Docs source contract against the real feature detail payload. The Task Docs subview must select the document whose `document_type` is `tasks_md`, fetch content from that document's `url`, and render the fetched Markdown through the existing Markdown renderer.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Select the Task Docs source from `FeatureDetail.documents` by `document_type: tasks_md`.
- [ ] Fetch the selected document `url` through the existing content proxy or raw-content path so the UI receives Markdown text.
- [ ] Render the fetched `tasks.md` Markdown content through the Markdown renderer.
- [ ] Show a clear empty or error state when the `tasks_md` document is missing, empty, or cannot be fetched.
- [ ] Add focused tests for `tasks_md` document selection, URL fetch behavior, formatted Markdown rendering, and missing/failing document states.
- [ ] Verify the Feature tab does not display the raw GitHub URL as Task Docs content.

## T4 — Feature/task pagination API wiring

### Description
Implement real pagination for Feature mode and Task mode using the backend list APIs. Feature mode must request `/api/workspaces/:workspaceId/features?page=<page>&limit=<pageSize>` and Task mode must request `/api/workspaces/:workspaceId/tasks?page=<page>&limit=<pageSize>`, preserving active `title`, `status`, and `sort` query params when the user changes page.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Add visible pagination controls for Feature mode and Task mode if they are missing from the current UI.
- [ ] Serialize Feature mode page changes as `/api/workspaces/:workspaceId/features?page=<page>&limit=<pageSize>`.
- [ ] Serialize Task mode page changes as `/api/workspaces/:workspaceId/tasks?page=<page>&limit=<pageSize>`.
- [ ] Preserve active `title`, `status`, and `sort` query params when changing page.
- [ ] Reset page to `1` when search text, status filter, sort, or page size changes.
- [ ] Use backend `{ items, total, page, limit }` metadata to render current page, total rows, and next/previous availability.
- [ ] Do not use local slicing, `limit=0`, or omitted `limit` for paginated board lists.
- [ ] Add focused tests for Feature and Task mode pagination request URLs and metadata-driven control state.

## T5 — Task-mode feature lifecycle status mapping

### Description
Fix the Task mode feature row status display so each feature row shows the parent feature lifecycle status from the feature response. The row must support only the feature lifecycle statuses `in_design`, `in_tdd`, `ready_for_implementation`, `in_implementation`, `in_handoff`, `done`, `blocked`, and `cancelled`, and must not show child task lifecycle values as feature status.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Locate the Task mode feature row adapter/component that currently derives or displays the wrong status.
- [ ] Read the feature row status from the parent feature response lifecycle field.
- [ ] Normalize and render only `in_design`, `in_tdd`, `ready_for_implementation`, `in_implementation`, `in_handoff`, `done`, `blocked`, and `cancelled`.
- [ ] Remove fallback behavior that maps task status values into the feature row status label.
- [ ] Add focused render/adapter tests for all allowed feature lifecycle statuses.
- [ ] Add a regression test proving task statuses such as `todo`, `ready`, `in_progress`, and `in_review` are not shown as feature row status.

## T6 — Kanban feature lifecycle status mapping

### Description
Fix the Kanban/Feature mode feature status display so each feature surface shows the feature lifecycle status from the feature response. The surface must support only `in_design`, `in_tdd`, `ready_for_implementation`, `in_implementation`, `in_handoff`, `done`, `blocked`, and `cancelled`, and must not show child task lifecycle values as feature status.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Locate the Kanban/Feature mode feature adapter/component that currently derives or displays the wrong status.
- [ ] Read the Kanban/Feature mode feature status from the feature response lifecycle field.
- [ ] Normalize and render only `in_design`, `in_tdd`, `ready_for_implementation`, `in_implementation`, `in_handoff`, `done`, `blocked`, and `cancelled`.
- [ ] Remove fallback behavior that maps task status values into the Kanban/Feature mode feature status.
- [ ] Add focused render/adapter tests for all allowed feature lifecycle statuses on the Kanban/Feature mode surface.
- [ ] Add a regression test proving task statuses such as `todo`, `ready`, `in_progress`, and `in_review` are not shown as Kanban/Feature mode feature status.

## T8 — Sidebar blocked section and status-age indicators

### Description
Add a collapsible/expandable "Blocked" tasks section at the very top of the tasks sidebar, pushing blocked tasks to the top of the sidebar. For every task in the sidebar, calculate and display a prominent status age/duration indicator (e.g. "ready 2d", "in progress 5h", "blocked 1h") based on its current status transition log.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Extend `TrackedStatus` type to include `"blocked"`.
- [ ] Add the "Blocked" section to the top of the `TRACKED_SECTIONS` list.
- [ ] Configure the "Blocked" section to be collapsible/expandable, initialized as expanded.
- [ ] Update `SIDEBAR_TASK_PARAMS` in `query-params.ts` to include `"blocked"` in the status parameter list.
- [ ] Update task grouping logic in `groupTasks.ts` to populate the "Blocked" bucket with blocked tasks.
- [ ] Implement a utility function to compute status age/duration based on the latest matching log transition timestamp or fallback values.
- [ ] Implement duration formatting (e.g., converting milliseconds to "Xd", "Xh", "Xm", "Xs" formats).
- [ ] Add status age indicators to `TaskTrackingItem` and render them prominently (e.g., clear colored badges or highly readable duration copy).
- [ ] Add unit tests for the duration computing utility and task grouping changes.

## T9 — Timeline link formatting and click-handling

### Description
Enhance the task activity timeline and log entries (typically rendered in `TaskDetailSheet`) to automatically detect, highlight, and format web links (e.g., `https://github.com/tiendv89/digital-factory-ui/pull/57`) without using regular expressions (regex). Clicking on any detected web link must open the link in a new tab/window.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Implement a regex-free URL extraction/detection helper (e.g., checking if words start with `http://` or `https://` or parsing with a non-regex URL scheme).
- [ ] Update `TaskDetailSheet` log-timeline rendering to split log notes/activity text into text and link tokens using the helper.
- [ ] Format detected links with distinct hyperlink styling (highlighting) to make them visually recognizable as links.
- [ ] Add click handling to detected links to open them in a new tab/window using `target="_blank" rel="noopener noreferrer"`.
- [ ] Add focused unit tests for the regex-free link detection and tokenization helper.

## T10 — Task tab layout reordering

### Description
Reorder the layout sections within the Task tab (rendered in `TaskDetailSheet`) so that the "Pull Request" (PR) section is displayed first at the very top. It must be followed in specific order by: "Details" metadata, "Execution" actor/details, "Last Updated" timestamp, and finally the "Activity Timeline" logs.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Relocate the "Pull Request" section/card render path to the top of the Task tab body.
- [ ] Rearrange the remaining sections to follow the specific order: Details (Metadata Grid), Execution, Last Updated, and Activity Timeline.
- [ ] Ensure all visual spacing, margins, divider lines, and empty states of the Task tab match the reordered flow in Figma.
- [ ] Add or update render tests verifying the correct rendering order of the Task tab sections.

## T7 — Post-change final regression and browser QA

### Description
Perform final verification of the sidebar blocked panel, collapsible toggles, status-age indicators, timeline link formatting, Task tab section reordering, and run comprehensive regression tests across the entire workspace UI, ensuring zero broken flows after T8, T9, and T10 are implemented.

### Required skills
- browser-qa-frontend
- typescript-best-practices

### Subtasks
- [ ] Assert the "Blocked" section is rendered at the top of the tasks sidebar.
- [ ] Assert the "Blocked" section collapsible toggles correctly.
- [ ] Assert status duration values are formatted and displayed correctly on each task.
- [ ] Perform cross-browser testing for the status age indicators' styles and alignment.
- [ ] Verify that adding a log transition dynamically updates the status age on the sidebar.
- [ ] Assert that web links (e.g., `https://github.com/tiendv89/digital-factory-ui/pull/57`) are correctly highlighted and clickable in the timeline and logs, opening in a new tab/window.
- [ ] Assert that the Task tab sections are rendered in the correct specific top-to-bottom order: Pull Request, Details, Execution, Last Updated, and Activity Timeline.
- [ ] Run full regression suite on digital-factory-ui to ensure all features (T1-T6, T8, T9, T10) are functioning.
