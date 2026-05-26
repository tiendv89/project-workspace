# Product Specification

## Feature
- Feature ID: `df-ui-bugfix`
- Title: DF UI Bug Fix — scoped follow-up
- Implementation repo: `digital-factory-ui`
- GitHub: https://github.com/tiendv89/digital-factory-ui

## Scope
This specification keeps only the scoped follow-up work for task creation, endpoint contracts, Task Docs rendering, pagination, feature lifecycle status mapping, and final regression QA.

## Problem
The follow-up bugfix scope addresses remaining UI defects in `digital-factory-ui` after the earlier base tasks:

- Task and feature detail modal paths still need to be removed from active flows, while task creation must remain available through a dedicated creation flow.
- Feature mode and Task mode list/search/filter requests must be locked to their own backend collection endpoints.
- Task Docs must render the actual `tasks.md` Markdown by selecting the feature document with `document_type: tasks_md` and fetching content from its `url`.
- Feature and task pagination must use backend `page` and `limit` API params, not local slicing or unbounded list loading.
- Task-mode feature rows must show only parent feature lifecycle statuses from the feature response.
- Kanban/Feature mode feature status must also show only parent feature lifecycle statuses from the feature response.
- Final regression coverage must verify the above behavior plus Feature mode card typography/casing acceptance criteria that remain part of the visible UI bugfix.

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

## Goals
- Users create tasks through a dedicated task creation flow, not through task or feature detail modals.
- Users single-click features/tasks and continue through tab views without mounting task/feature detail modals.
- Feature mode search/filter/pagination always uses the backend feature list endpoint with current query params.
- Task mode search/filter/pagination always uses the backend task list endpoint with current query params.
- Users can move through feature and task pages without losing current search text, status filter, sort, or page size.
- Users can open Task Docs from the Feature tab and read fetched `tasks.md` Markdown content, not a raw document URL.
- Task mode and Kanban/Feature mode show only valid feature lifecycle statuses: `in_design`, `in_tdd`, `ready_for_implementation`, `in_implementation`, `in_handoff`, `done`, `blocked`, and `cancelled`.
- Feature status surfaces never display task lifecycle statuses such as `todo`, `ready`, `in_progress`, or `in_review`.
- Final QA confirms the endpoint, pagination, modal removal, Task Docs, status mapping, and Feature card typography/casing requirements.

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
- The scoped follow-up is verified with focused regression coverage and browser/UI checks.
