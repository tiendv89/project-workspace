# Product Specification

## Feature
- Feature ID: `df-ui-bugfix`
- Title: DF UI Bug Fix — scoped follow-up
- Implementation repo: `digital-factory-ui`
- GitHub: https://github.com/tiendv89/digital-factory-ui

## Scope
This specification keeps only the scoped follow-up work for task creation, endpoint contracts, Task Docs rendering, pagination, feature lifecycle status mapping, sidebar blocked/status-age visibility, timeline link formatting, Task tab section ordering, workspace switching tab and state reset, and final regression QA.

## Problem
The follow-up bugfix scope addresses remaining UI defects in `digital-factory-ui` after the earlier base tasks:

- Task and feature detail modal paths still need to be removed from active flows, while task creation must remain available through a dedicated creation flow.
- Feature mode and Task mode list/search/filter requests must be locked to their own backend collection endpoints.
- Task Docs must render the actual `tasks.md` Markdown by selecting the feature document with `document_type: tasks_md` and fetching content from its `url`.
- Feature and task pagination must use backend `page` and `limit` API params, not local slicing or unbounded list loading.
- Task-mode feature rows must show only parent feature lifecycle statuses from the feature response.
- Kanban/Feature mode feature status must also show only parent feature lifecycle statuses from the feature response.
- Final regression coverage must verify the above behavior plus Feature mode card typography/casing acceptance criteria that remain part of the visible UI bugfix.
- The tasks sidebar lacks dedicated top-level sections for blocked and in_reviewing tasks, and does not prominently show how long each task has been in its current status.
- Task activity timeline/log entries can contain URLs such as GitHub PR links, but these links must be detected without regular expressions, highlighted, and opened safely in a new tab/window.
- Task tab users need Pull Request information at the very top of the tab before details, execution metadata, last-updated information, and timeline logs.
- When a user opens a task or feature tab, and then switches workspaces, the open tab still displays components and data from the previous workspace. This is incorrect because the active tab does not belong to the newly selected workspace. When switching workspaces, the active tabs must be closed, and the workspace UI state must be completely reset.

## Required Fixes and Additions
- Add a dedicated task creation entry point and flow/dialog that is independent of task and feature detail modals.
- Remove or disable all remaining active task/feature detail modal render paths. Feature and task detail content should be reached through Feature tab and Task tab views only.
- Ensure Feature mode list, search, and status filtering call `/api/workspaces/:workspaceId/features`.
- Ensure Task mode list, search, and status filtering call `/api/workspaces/:workspaceId/tasks`.
- Serialize search text as `title` and selected status as `status` for both endpoints.
- Ensure Feature mode pagination calls `/api/workspaces/:workspaceId/features?page=...&limit=...` while preserving active `title`, `status`, and `sort` params.
- Ensure Task mode pagination calls `/api/workspaces/:workspaceId/tasks?page=...&limit=...` while preserving active `title`, `status`, and `sort` params.
- Use backend `{ items, total, page, limit }` metadata for pagination controls and avoid local slicing, `limit=0`, or omitted `limit` for paginated board lists.
- Fix Task Docs so it selects `FeatureDetail.documents` item where `document_type` is `tasks_md`, fetches that document `url`, and renders the returned Markdown through the existing Markdown renderer.
- Fix Task mode feature row status so it reads from the parent feature lifecycle response and never displays task lifecycle statuses.
- Fix Kanban/Feature mode feature status so it reads from the feature lifecycle response and never displays task lifecycle statuses.
- Verify Feature mode card title remains the largest card text, feature ID is smaller secondary text, and title/subtitle preserve mixed casing.
- Add a collapsible/expandable "Blocked" tasks section at the top of the tasks sidebar, with blocked tasks grouped first.
- Add a collapsible/expandable "In Reviewing" tasks section in the tasks sidebar to display the list of tasks with status `in_reviewing`.
- Show prominent status age/duration indicators for each task in the sidebar based on its current status transition log.
- Detect and format web links inside task activity timeline/log text without using regular expressions; detected links must be highlighted and open in a new tab/window.
- Reorder Task tab sections so the top-to-bottom order is Pull Request, Details, Execution, Last Updated, and Activity Timeline.
- Reset the active feature and task tabs, and completely clear/reset all workspace UI state (such as active detail panels, open tabs, search queries, filters, and pagination) when switching workspaces to prevent stale information from persisting.

## Goals
- Users create tasks through a dedicated task creation flow, not through task or feature detail modals.
- Users single-click features/tasks and continue through tab views without mounting task/feature detail modals.
- Feature mode search/filter/pagination always uses the backend feature list endpoint with current query params.
- Task mode search/filter/pagination always uses the backend task list endpoint with current query params.
- Users can move through feature and task pages without losing current search text, status filter, sort, or page size.
- Users can open Task Docs from the Feature tab and read fetched `tasks.md` Markdown content, not a raw document URL.
- Task mode and Kanban/Feature mode show only valid feature lifecycle statuses: `in_design`, `in_tdd`, `ready_for_implementation`, `in_implementation`, `in_handoff`, `done`, `blocked`, and `cancelled`.
- Feature status surfaces never display task lifecycle statuses such as `todo`, `ready`, `in_progress`, or `in_review`.
- Final QA confirms the endpoint, pagination, modal removal, Task Docs, status mapping, Feature card typography/casing, sidebar blocked/status-age, timeline link formatting, and Task tab ordering requirements.
- Users can quickly find blocked tasks in a dedicated top-level sidebar section, as well as tasks with status `in_reviewing` in their own dedicated collapsible section.
- Users can monitor task bottlenecks through visible duration/age indicators for the current status.
- Users can click timeline/log URLs and have them open safely in a new tab/window.
- Users see Pull Request information first when opening the Task tab.
- Users see a completely clean, reset workspace UI state upon switching workspaces, with any previously open feature or task tab closed.

## Non-goals
- No backend API redesign beyond consuming existing mode-specific list endpoints and query params.
- No redesign of unrelated screens or visual systems.
- No workflow state write-path changes.
- No deployment checklist at this stage.
- No local fake task creation if no task creation write contract exists; document the backend dependency instead.

## Acceptance Criteria
- Creating a new task opens a separate dedicated task creation flow/dialog, independent of any task/feature detail modal.
- Single-clicking a feature opens its Feature tab and no feature detail modal is mounted.
- Single-clicking a task opens its Task tab and no task detail modal is mounted.
- Feature mode search/filter requests call `/api/workspaces/:workspaceId/features` with `title` and `status` when present.
- Task mode search/filter requests call `/api/workspaces/:workspaceId/tasks` with `title` and `status` when present.
- Board list search/filter behavior does not locally filter from the workspace root payload.
- Feature mode pagination calls `/api/workspaces/:workspaceId/features?page=...&limit=...`, preserving `title`, `status`, and `sort` when present.
- Task mode pagination calls `/api/workspaces/:workspaceId/tasks?page=...&limit=...`, preserving `title`, `status`, and `sort` when present.
- Paginated board lists never use local slicing, `limit=0`, or omitted `limit`.
- Pagination controls use backend `{ items, total, page, limit }` metadata for current page, total rows, and next/previous availability.
- Task Docs selects the feature document whose `document_type` is `tasks_md`.
- Task Docs fetches content from the selected document `url` and renders the fetched Markdown as formatted content.
- Task Docs does not display the raw GitHub/document URL as the body content.
- Missing, empty, or failing `tasks_md` document states show a clear empty/error state.
- Task-mode feature rows render feature lifecycle statuses from the parent feature response only.
- Kanban/Feature mode feature status renders feature lifecycle statuses from the feature response only.
- Both feature status surfaces support `in_design`, `in_tdd`, `ready_for_implementation`, `in_implementation`, `in_handoff`, `done`, `blocked`, and `cancelled`.
- Both feature status surfaces never display task lifecycle statuses such as `todo`, `ready`, `in_progress`, or `in_review`.
- Feature mode card title is the largest card text, feature ID is smaller secondary text, and title/subtitle preserve mixed casing without uppercase transforms.
- The task sidebar displays a collapsible/expandable section for blocked tasks positioned at the very top.
- The task sidebar displays a collapsible/expandable section for tasks with status `in_reviewing` to display the list of tasks currently in review.
- Every task in the sidebar displays a prominent, easily readable duration/age indicator showing how long it has been in its current status.
- Web links such as `https://github.com/tiendv89/digital-factory-ui/pull/57` within the task activity timeline/logs are detected without using regular expressions, highlighted as clickable hyperlinks, and open in a new tab/window.
- In the Task tab, sections render in this top-to-bottom order: Pull Request, Details, Execution, Last Updated, and Activity Timeline.
- Switching workspaces automatically closes any active Feature tab and Task tab (e.g., active detail sheets or panels).
- Switching workspaces completely resets search queries, selected status filters, sorting state, and pagination back to their default values for the new workspace.
- Switching workspaces triggers a full state reset in all workspace-scoped components and state managers (such as Zustand/Redux stores or Contexts), ensuring no data leaks from the previous workspace.
- The scoped follow-up is verified with focused regression coverage and browser/UI checks.
