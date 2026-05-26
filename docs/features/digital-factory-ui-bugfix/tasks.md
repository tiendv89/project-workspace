# Tasks - digital-factory-ui-bugfix

> Feature status: `in_tdd` - stage status: `technical_design` (`awaiting_approval`). Machine state lives in `tasks/T<n>.yaml`; this file is the narrative task breakdown only.

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | Mode-scoped paged query layer | none |
| T2 | 1 | Tab-first click behavior | none |
| T3 | 1 | Feature/card/status rendering fixes | none |
| T4 | 1 | Feature Task Docs markdown panel | none |
| T8 | 1 | Sidebar blocked section and status-age indicators | none |
| T5 | 2 | Pagination controls and metadata wiring | T1 |
| T6 | 3 | Regression tests and browser QA | T1, T2, T3, T4, T5 |
| T9 | 1 | Timeline link formatting and click-handling | none |
| T10 | 1 | Task tab layout reordering | none |
| T7 | 4 | Post-change final regression and browser QA | T1, T2, T3, T4, T5, T6, T8, T9, T10 |

## T1 — Mode-scoped paged query layer

### Description
Extend the board query path so Feature mode and Task mode send search, filter, sort, page, and limit to the correct backend collection route while preserving paged response metadata. This task is the data-flow foundation for pagination but does not need to implement visible pagination controls.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Add or expose pagination-aware request paths for workspace features and workspace tasks.
- [ ] Preserve `{ items, total, page, limit }` metadata instead of unwrapping paged responses to arrays in board/search surfaces.
- [ ] Serialize `title`, `status`, `page`, `limit`, and `sort` into the active mode-specific request.
- [ ] Ensure Feature mode uses the features endpoint and Task mode uses the tasks endpoint.
- [ ] Reset page to `1` when search, filter, or sort changes.
- [ ] Keep query state and pagination metadata in one shared source of truth for board views.

## T2 — Tab-first click behavior

### Description
Change primary feature/task interactions so single-clicking a Feature mode card opens the Feature tab and single-clicking a task opens the Task tab. Modal detail surfaces should no longer be part of the single-click path.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Rewire Feature mode card single-click from selection/modal state to `openFeatureTab(...)`.
- [ ] Rewire task card single-click from selection/modal state to `openTaskTab(...)`.
- [ ] Preserve explicit new-tab/new-session behavior where it already exists.
- [ ] Remove or update tests that assert modal detail opens on single-click.
- [ ] Add interaction coverage proving single-click opens the matching tab and does not open modal detail.

## T3 — Feature/card/status rendering fixes

### Description
Fix the non-pagination rendering regressions in board surfaces: task-mode feature rows must use the real feature lifecycle status, Feature mode cards must suppress the status tag, feature ID must be smaller secondary text, title visibility must be prioritized, and Task tab repository metadata must stay plain text.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Map task-mode feature lifecycle status directly from feature response data.
- [ ] Verify task-mode rows do not fall back to task-derived feature status when feature data is available.
- [ ] Preserve Feature mode card status-pill suppression.
- [ ] Render Feature mode card ID as smaller secondary text than the title.
- [ ] Give Feature mode card title the primary text area, allowing it to wrap or consume available width before truncation.
- [ ] Preserve repository as plain text in the Task tab.
- [ ] Add focused render tests for lifecycle status, feature card hierarchy, status-pill suppression, and Task tab repository text.

## T4 — Feature Task Docs markdown panel

### Description
Fix the Feature tab Tasks panel so the nested tabs are `Tasks List` and `Task Docs`, and the `Task Docs` subview loads the feature `tasks.md` document from inline backend content or document URL and renders it as formatted Markdown.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Rename the Feature tab nested docs tab from `tasks.md` to `Task Docs`.
- [ ] Load Task Docs content from `FeatureDetail.documents` inline content when present.
- [ ] Fetch Task Docs content from the document URL through the existing content proxy when inline content is absent.
- [ ] Render Task Docs through the existing Markdown renderer.
- [ ] Keep the `Tasks List` subview behavior unchanged.
- [ ] Add focused tests for the tab labels, loading path, empty fallback, and formatted Markdown rendering.

## T5 — Pagination controls and metadata wiring

### Description
Add visible pagination controls to Feature mode and Task mode and wire page transitions into the shared query-state layer from T1. The controls must preserve the current search, filter, sort, and page size while moving between pages.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Confirm backend pagination metadata and multi-status query encoding before finalizing control behavior.
- [ ] Add visible pagination controls to Feature mode and Task mode.
- [ ] Wire next/previous or page selection to the shared query state.
- [ ] Preserve active query params when changing page.
- [ ] Use backend pagination metadata when available and handle missing metadata conservatively.
- [ ] Reset page to `1` only for search/filter/sort changes, not for next/previous page changes.

## T6 — Regression tests and browser QA

### Description
Cover the data contract, click behavior, rendering fixes, Task Docs, and pagination behavior with focused tests, then verify the affected Feature mode and Task mode screens in the browser.

### Required skills
- browser-qa-frontend
- typescript-best-practices

### Subtasks
- [ ] Assert Feature mode queries the features endpoint with active params.
- [ ] Assert Task mode queries the tasks endpoint with active params.
- [ ] Assert paged response metadata is preserved for pagination controls.
- [ ] Assert page changes preserve query params and search/filter/sort changes reset page to `1`.
- [ ] Assert feature/task single-click opens the matching tab and does not open modal detail.
- [ ] Assert Feature mode cards render ID smaller than title and prioritize title width.
- [ ] Assert Task Docs renders `tasks.md` Markdown from inline content or document URL.
- [ ] Verify the status, repository, Task Docs, pagination, and feature-card regression cases in-browser.

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
