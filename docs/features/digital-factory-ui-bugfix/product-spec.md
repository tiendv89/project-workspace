# Product Specification

## Feature
- Feature ID: `digital-factory-ui-bugfix`
- Title: Digital Factory UI Bug Fix
- Implementation repo: `digital-factory-ui`
- GitHub: https://github.com/tiendv89/digital-factory-ui

## Problem
The `digital-factory-ui` task and feature views have incorrect UI behavior around status display, backend list loading, pagination, repository display, feature/task click behavior, feature card metadata, and task documentation rendering.

Today, users can see misleading feature status in task mode, list data can come from the wrong source, long task/feature lists cannot be paged, repository metadata looks like an action link in task tab, single-clicking a feature or task opens a modal detail instead of the corresponding tab, feature cards carry an extra status tag and over-emphasize the feature ID, and the Feature tab task docs view does not reliably show `tasks.md` as formatted Markdown.

## Required Fixes and Additions
- Fix task-mode feature rows so they display the real feature lifecycle status from the feature response.
- Change feature mode and task mode list loading so each mode uses its own backend collection endpoint.
- Add pagination to feature mode and task mode lists. The current UI does not paginate these lists.
- Change single-click behavior so clicking a feature opens the Feature tab and clicking a task opens the Task tab, instead of opening modal detail surfaces.
- Fix task tab repository display so the repository is plain text, not a link.
- Remove the status tag from feature cards in feature mode.
- Adjust Feature mode cards so the feature ID is smaller than the title and the title gets as much visible space as possible.
- Fix the Feature tab Tasks panel so the nested tabs are `Tasks List` and `Task Docs`, and `Task Docs` loads `tasks.md` from the document URL/path and renders it as formatted Markdown.

## Goals
- Users see the correct feature lifecycle status in task mode.
- In feature mode, search, filter, sort, and pagination actions query the backend feature list endpoint with the current query params.
- In task mode, search, filter, sort, and pagination actions query the backend task list endpoint with the current query params.
- Users can move through task and feature list pages without losing the current search, status filter, or sort.
- Users can single-click a task or feature and continue in the corresponding tab view without passing through a modal detail.
- Users see repository values as task tab metadata text.
- Feature mode cards show only the intended feature metadata, with title prioritized over feature ID.
- Users can open Task Docs from the Feature tab and read the `tasks.md` content as formatted Markdown without leaving the app.

## Non-goals
- No backend API redesign beyond consuming the existing mode-specific list endpoints and their query params.
- No redesign of unrelated screens or visual systems.
- No workflow state write-path changes.
- No deployment checklist at this stage.

## Acceptance Criteria
- Task-mode feature rows render feature lifecycle statuses from the feature response.
- Feature mode initial and subsequent list requests use the backend feature list endpoint.
- Task mode initial and subsequent list requests use the backend task list endpoint.
- Feature and task list views support visible pagination controls.
- Feature mode search/filter/sort/page changes request the backend feature list endpoint, not local filtering from the workspace root payload.
- Task mode search/filter/sort/page changes request the backend task list endpoint, not local filtering from the workspace root payload.
- Pagination preserves the active search text, selected statuses, sort, and page size.
- Single-clicking a feature opens its Feature tab instead of a feature detail modal.
- Single-clicking a task opens its Task tab instead of a task detail modal.
- Task tab shows repository as plain text.
- Feature cards in feature mode no longer show a status tag.
- Feature cards in feature mode render feature ID smaller than title and prioritize title visibility.
- Feature tab Tasks panel shows `Tasks List` and `Task Docs`, and Task Docs renders the `tasks.md` content as formatted Markdown from the document URL/path.
- The fix is verified with focused regression coverage and browser/UI checks.
