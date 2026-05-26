# Technical Design

## Feature
- Feature ID: `df-ui-bugfix`
- Title: DF UI Bug Fix — scoped follow-up
- Implementation repo: `digital-factory-ui`

## Current State
The remaining `digital-factory-ui` defects in this scope are:
- Task/feature detail modal paths can still be active, but the desired UX is tab-first navigation with detail content in Feature and Task tabs only.
- Task creation must not remain coupled to task or feature detail modals; it needs a dedicated creation entry point and flow/dialog.
- Feature mode and Task mode list/search/filter behavior must be explicitly tied to separate backend collection endpoints.
- Pagination must be API-backed with `page` and `limit` on the same mode-specific endpoints.
- Task Docs must use the real feature detail document payload: select `documents` entry with `document_type: tasks_md`, fetch its `url`, and render the returned Markdown.
- Task-mode feature row status can show task lifecycle values; it must show only parent feature lifecycle status.
- Kanban/Feature mode feature status can show task-derived values; it must show only feature lifecycle status.
- Final QA must also verify Feature mode card title hierarchy and casing because those visual criteria remain part of the bugfix acceptance surface.
- The tasks sidebar needs a top-level blocked section and prominent current-status age indicators.
- Task activity timeline/log text needs regex-free URL detection and safe clickable link rendering.
- Task tab content must be reordered so Pull Request information appears before all other task metadata.

Relevant implementation points in `digital-factory-ui`:
- `src/services/workflow-backend/types.ts` defines paged list shapes such as `PagedFeatures` and `PagedTasks` with `items`, `total`, `page`, and `limit`.
- `src/services/workflow-backend/query-params.ts` supports list query params including `title`, `status`, `page`, `limit`, and `sort`.
- Board feature/task search hooks and backend list params are the likely request wiring points for endpoint/query correctness and pagination.
- Feature tab task documentation rendering lives around `src/features/board/components/FeatureTabView/FeatureTasksPanel.tsx`, `useDocumentContent()`, and `MarkdownBlock`.
- Feature and task card/row click handlers should route to tab-opening handlers instead of modal-selection state.
- Feature row/status adapters must normalize feature lifecycle statuses and reject task lifecycle values for feature status display.
- Feature mode card typography/casing is likely owned by `FeatureListRow.tsx` and related styles.

## Problem Framing
What needs to change:
- Add or expose a dedicated create-task UI flow/dialog independent from detail modals.
- Remove active task and feature detail modal render paths after tab-first navigation is in place.
- Feature mode list/search/filter requests must call `/api/workspaces/:workspaceId/features`.
- Task mode list/search/filter requests must call `/api/workspaces/:workspaceId/tasks`.
- Search text must serialize as `title`; status filters must serialize as `status`.
- Page changes must serialize as `page` and `limit` on the active endpoint, preserving `title`, `status`, and `sort`.
- Search, status filter, sort, and page size changes reset `page` to `1`; next/previous page changes do not reset unrelated query state.
- Board lists must use backend pagination metadata rather than local slicing.
- Task Docs must select the `tasks_md` document from feature details and fetch/render the document URL content as Markdown.
- Task-mode feature rows and Kanban/Feature mode feature status must only use feature lifecycle statuses from feature responses.
- Feature status display must not use task lifecycle statuses such as `todo`, `ready`, `in_progress`, or `in_review`.
- The tasks sidebar must include a collapsible/expandable "Blocked" section at the top and show current-status age/duration for every sidebar task.
- Timeline/log rendering must detect `http://` and `https://` links without regular expressions and render them as highlighted safe hyperlinks.
- The Task tab must render sections in the order: Pull Request, Details, Execution, Last Updated, Activity Timeline.

What must remain stable:
- Workspace selection and unrelated dashboard flows.
- Existing backend route ownership.
- Existing feature/task identity conventions.
- Existing backend schema; use current read endpoints and current task creation contract if available.
- Existing Markdown renderer and document content proxy/raw-content path where possible.

Fixed assumptions:
- The backend exposes separate collection endpoints for features and tasks.
- The existing paged response shape is `{ items, total, page, limit }`.
- Pagination `page` is 1-based and `limit` must be a positive bounded value.
- Feature detail payload includes `documents` entries like `{ document_type: "tasks_md", source_path: "docs/features/<feature>/tasks.md", url: "https://github.com/.../tasks.md" }`.
- Valid feature lifecycle statuses are `in_design`, `in_tdd`, `ready_for_implementation`, `in_implementation`, `in_handoff`, `done`, `blocked`, and `cancelled`.
- Task lifecycle values must never be rendered as feature lifecycle status.
- If no task creation write contract exists in the frontend, the implementation should document that dependency rather than fake local creation.

## Constraints
- The scoped follow-up is frontend-first; no backend API redesign is planned.
- Board lists must consume backend collection endpoints instead of deriving list/search/filter state from a workspace root payload.
- Task Docs must render fetched Markdown content, not a raw document URL.
- Feature status surfaces must only render feature lifecycle values.
- Task creation must not be nested in task or feature detail modals.
- Final regression must cover both behavior and visible Feature mode card typography/casing.

## Options Considered

### Option A — Patch individual visible defects while preserving existing list/detail flow
**Approach**
Keep the current modal/detail and list plumbing mostly intact, then patch only the most visible symptoms: Task Docs display, status labels, and card styling.

**Pros**
- Smallest initial implementation surface.
- Lower short-term risk of touching board list and tab navigation code.

**Cons**
- Leaves the detail-modal coupling that caused part of the bugfix scope.
- Does not lock Feature mode and Task mode to separate backend collection contracts.
- Makes pagination and status fixes fragile because local list derivation can continue to leak stale or wrong values.

**Impact**
- Repo impact: `digital-factory-ui` only.
- Dependency impact: low, but keeps hidden coupling with existing modal/list state.
- Release impact: faster to ship but likely to require another follow-up.

### Option B — Normalize the board around tab-first UX and mode-specific backend contracts
**Approach**
Make tab views the active detail surfaces, add a dedicated task creation flow, lock Feature mode and Task mode list/search/filter/pagination to their own backend endpoints, and fix Task Docs/status rendering from typed backend response fields.

**Pros**
- Directly matches the approved product scope.
- Makes endpoint, pagination, Task Docs, and status behavior testable through focused request/render assertions.
- Removes active modal detail paths from normal task/feature navigation.
- Keeps the implementation frontend-first and reuses existing backend contracts.

**Cons**
- Touches several board surfaces at once: navigation, list queries, pagination, docs, adapters, and QA.
- Requires careful regression coverage so tab behavior and list state do not drift.

**Impact**
- Repo impact: `digital-factory-ui` for implementation; `project-workspace` for planning artifacts.
- Dependency impact: depends on existing backend list/document/task creation contracts.
- Release impact: frontend-only rollout if the existing task creation write contract is available.

### Option C — Block frontend work until backend contracts are redesigned
**Approach**
Pause the UI fixes and first redesign backend feature/task list, document content, and task creation APIs.

**Pros**
- Could produce a more explicit long-term backend contract.
- May reduce ambiguity if any current endpoint behavior is missing.

**Cons**
- Out of scope for this follow-up.
- Delays fixes that can already be implemented against current endpoints.
- Adds backend coordination without evidence that list/document APIs need redesign.

**Impact**
- Repo impact: would expand to `workflow-backend`, which is not planned for this feature.
- Dependency impact: creates new backend blockers.
- Release impact: slower, higher coordination cost, and unnecessary unless implementation proves a contract is missing.

## Chosen Design
Choose Option B: normalize the board around tab-first UX and mode-specific backend contracts.

### Dedicated task creation and no active detail modals
- Keep tab views as the only active task/feature detail surfaces.
- Route feature primary clicks to the Feature tab and task primary clicks to the Task tab.
- Add a dedicated task creation entry point and dialog/flow.
- Reuse an existing create-task client/helper if present.
- If no creation write contract exists, surface a clear dependency instead of storing fake tasks locally.
- Remove or disable remaining active task/feature detail modal mounts so creation is not nested inside a detail surface.

### Mode-specific backend list contract
- Feature mode list/search/filter requests target `/api/workspaces/:workspaceId/features`.
- Task mode list/search/filter requests target `/api/workspaces/:workspaceId/tasks`.
- Search text is sent as `title`.
- Selected status is sent as `status`.
- Board list rendering must not search/filter from the workspace root payload.

### API-backed pagination
- Feature mode page changes call `/api/workspaces/:workspaceId/features?page=<page>&limit=<pageSize>`.
- Task mode page changes call `/api/workspaces/:workspaceId/tasks?page=<page>&limit=<pageSize>`.
- Active `title`, `status`, and `sort` params are preserved when changing page.
- Search/filter/sort/page-size changes reset `page` to `1`.
- Controls derive current page, total rows, and next/previous availability from backend `{ items, total, page, limit }` metadata.
- Do not implement pagination with local slicing, `limit=0`, or omitted `limit`.

### Task Docs source contract
- Select `FeatureDetail.documents.find(document.document_type === "tasks_md")`.
- Fetch the selected document `url` through the existing content proxy or raw-content path.
- Render the fetched Markdown string through the existing Markdown renderer.
- Show clear empty/error states for missing, empty, or failed document fetches.
- Never render the raw document URL as Task Docs body content.

### Feature lifecycle status mapping
- Task-mode feature rows read status from the parent feature response lifecycle field.
- Kanban/Feature mode feature status reads status from the feature response lifecycle field.
- Normalize display to the feature lifecycle enum only.
- Remove fallback behavior that maps task status values into feature status labels.
- Add regression tests for all allowed feature lifecycle statuses and for rejected task lifecycle statuses.

### Final visual regression checks
- Confirm Feature mode card title is the largest card text.
- Confirm feature ID is smaller secondary text.
- Confirm title/subtitle preserve mixed casing without CSS or JavaScript uppercase transforms.

### Sidebar blocked section and status-age indicators
- Extend the sidebar tracked status model to include `blocked`.
- Add a "Blocked" section at the top of the tracked task sections, initialized expanded and user-toggleable.
- Include `blocked` in the sidebar task query status params so blocked tasks are fetched alongside ready/in-progress/in-review work.
- Group blocked tasks into the new top bucket.
- Compute status age by scanning task logs in reverse for the latest transition matching the current status; fall back to last log or execution timestamp when needed.
- Render status age prominently on each sidebar task with readable duration text such as `2d`, `5h`, `10m`, or `30s`.

### Timeline link formatting
- Add a regex-free URL tokenization helper for timeline/log text.
- Treat `http://` and `https://` tokens as candidate URLs and validate with URL parsing or equivalent non-regex logic.
- Render detected links with distinct hyperlink styling and `target="_blank" rel="noopener noreferrer"`.
- Preserve surrounding plain text exactly so log notes remain readable.

### Task tab section order
- Move the Pull Request section/card to the top of the Task tab body.
- Render the remaining sections after it in this order: Details, Execution, Last Updated, Activity Timeline.
- Preserve existing spacing, empty states, and section semantics while changing order.

Compatibility and release considerations:
- Existing workspace selection, Feature tab, Task tab, Markdown renderer, and backend read endpoints remain the compatibility boundary.
- No data migration or persisted state format change is expected.
- The only unresolved release dependency is whether task creation already has a real backend/client write path.

## Dependency Analysis
Internal dependencies:
- Existing tab-opening handlers for Feature and Task tabs.
- Existing create-task helper/client if available.
- Board request/query serialization and search hooks.
- Backend paged response types and client helpers.
- Feature tab document loading path and Markdown renderer.
- Feature/task adapter code that maps API data to row/card view models.
- Feature mode card component and styles.
- Task tracking sidebar grouping, tracked status types, task query params, and task item rendering.
- Task timeline/log renderer and any shared log note formatting helpers.
- Task tab section composition in `TaskDetailSheet`.

External dependencies:
- `workflow-backend` feature list endpoint: `/api/workspaces/:workspaceId/features`.
- `workflow-backend` task list endpoint: `/api/workspaces/:workspaceId/tasks`.
- Backend support for `title`, `status`, `page`, `limit`, and `sort` query params.
- Backend feature detail `documents` payload with `document_type: tasks_md` and `url`.
- Existing task creation backend/client contract, if task creation is submitted from the UI.

Blocking decisions:
- Confirm whether a frontend task creation write path already exists. This does not block T1 investigation, but it decides whether T1 implements creation or documents the missing backend/client dependency.
- Confirm the current content proxy/raw-content helper can fetch the selected `tasks_md` document `url`. This does not block T3 investigation, but it decides whether T3 reuses an existing helper or adds a narrow frontend fetch path.
- Confirm multi-status query encoding only if the current UI supports multiple selected statuses. Single selected status uses `status=<value>`.

Configuration dependencies:
- The frontend must continue to use the existing workflow backend base URL configuration.
- No new environment variables are expected for this follow-up.

Release dependencies:
- T7 final regression must pass before the feature is ready for handoff.
- T8, T9, and T10 must complete before T7 final regression because T7 verifies the sidebar blocked/status-age, timeline link, and Task tab ordering additions.
- If T1 proves task creation lacks a real write contract, the handoff must call out that dependency instead of claiming local task creation is complete.

## Parallelization / Blocking Analysis
External decisions/dependencies:
- D1: Confirm task creation write contract — check during T1; if absent, document dependency instead of faking local writes.
- D2: Confirm document content fetch path for `tasks_md.url` — check during T3; reuse existing proxy/raw-content helper if available.
- D3: Confirm multi-status query encoding — only needed if the UI supports multi-select status filters; single status remains `status=<value>`.

T1: Dedicated task creation flow and detail-modal cleanup
  └── Can begin now — no blockers
  └── D1 determines implementation depth but does not block investigation or modal cleanup

T2: Mode-specific list search/filter endpoint contract
  └── Can begin now — no blockers

T3: Task Docs tasks.md document URL rendering
  └── Can begin now — no blockers
  └── D2 determines helper reuse vs narrow fetch-path adjustment

T5: Task-mode feature lifecycle status mapping
  └── Can begin now — no blockers

T6: Kanban feature lifecycle status mapping
  └── Can begin now — no blockers

T8: Sidebar blocked section and status-age indicators
  └── Can begin now — no blockers

T9: Timeline link formatting and click-handling
  └── Can begin now — no blockers

T10: Task tab layout reordering
  └── Can begin now — no blockers
  └── T1, T2, T3, T5, T6, T8, T9, and T10 run in parallel

T4: Feature/task pagination API wiring
  └── BLOCKED on T2 (pagination must use the finalized mode-specific endpoint/query contract)

T7: Post-change final regression and browser QA
  └── BLOCKED on T1 (task creation flow and modal cleanup must be implemented or dependency-documented)
  └── BLOCKED on T2 (endpoint/search/filter contract must be locked)
  └── BLOCKED on T3 (Task Docs source/fetch/render behavior must be implemented)
  └── BLOCKED on T4 (pagination API wiring must be implemented)
  └── BLOCKED on T5 (Task-mode feature lifecycle status mapping must be fixed)
  └── BLOCKED on T6 (Kanban/Feature mode lifecycle status mapping must be fixed)
  └── BLOCKED on T8 (sidebar blocked section and status-age indicator must be implemented)
  └── BLOCKED on T9 (timeline link formatting and click-handling must be implemented)
  └── BLOCKED on T10 (Task tab section ordering must be implemented)

Execution waves:
- Wave 1: T1, T2, T3, T5, T6, T8, T9, and T10 can start immediately and run in parallel.
- Wave 2: T4 starts after T2.
- Wave 3: T7 starts after T1 through T6 and T8 through T10 are complete.

## Repository Impact
Affected repositories:
- `digital-factory-ui` — implementation repo for UI behavior, data fetching, tests, and browser QA.
- `management-repo` — this planning repo, which owns `docs/features/df-ui-bugfix/` state and workflow artifacts.

No backend code change is planned. If implementation discovers the task creation write contract is missing, the relevant frontend task should document that dependency rather than silently inventing local behavior.

Task `repo` values must use the workspace repo ID `digital-factory-ui`.

## Validation Approach
Testing expectations:
- Verify task creation opens a dedicated flow/dialog and does not mount task/feature detail modals.
- Verify feature and task clicks open their corresponding tabs without mounting detail modals.
- Verify Feature mode search/filter calls `/api/workspaces/:workspaceId/features?title=...&status=...`.
- Verify Task mode search/filter calls `/api/workspaces/:workspaceId/tasks?title=...&status=...`.
- Verify Feature mode pagination calls `/api/workspaces/:workspaceId/features?page=...&limit=...` and preserves active `title`, `status`, and `sort`.
- Verify Task mode pagination calls `/api/workspaces/:workspaceId/tasks?page=...&limit=...` and preserves active `title`, `status`, and `sort`.
- Verify board pagination never uses local slicing, `limit=0`, or omitted `limit`.
- Verify Task Docs selects `document_type: tasks_md`, fetches `url`, renders Markdown, and handles missing/failing states.
- Verify Task Docs does not render the raw document URL as body content.
- Verify Task-mode feature rows and Kanban/Feature mode surfaces display only feature lifecycle statuses from feature responses.
- Verify task lifecycle statuses are not displayed as feature status.
- Verify Feature mode card title hierarchy and mixed-casing behavior.
- Verify the tasks sidebar renders blocked tasks at the top in a collapsible section.
- Verify each sidebar task shows a prominent status age/duration derived from current status history.
- Verify timeline/log URLs are detected without regex, highlighted, and opened in a new tab/window.
- Verify Task tab sections render in the required order: Pull Request, Details, Execution, Last Updated, Activity Timeline.
- Run focused unit/integration tests and browser UI checks for the affected views.

Backward compatibility constraints:
- Existing workspace selection and unrelated board/dashboard flows must continue to work.
- Existing Feature tab and Task tab entry points must remain the detail-navigation surfaces.
- Existing backend response parsing should remain compatible with `{ items, total, page, limit }`.

## Deployment / Handoff Impact
Release impact:
- Frontend-only rollout expected.
- No data migration.
- No persisted data format change.
- No deployment checklist is required at this planning stage.

Handoff impact:
- Handoff must include T7 evidence for endpoint URLs, pagination metadata, Task Docs Markdown rendering, modal cleanup, status mapping, card typography/casing, sidebar blocked/status-age behavior, timeline link formatting, and Task tab section ordering.
- If task creation cannot be fully implemented because no write contract exists, handoff must list that backend/client dependency explicitly.
