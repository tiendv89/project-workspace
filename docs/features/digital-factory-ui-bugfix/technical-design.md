# Technical Design

## Feature
- Feature ID: `digital-factory-ui-bugfix`
- Title: Digital Factory UI Bug Fix
- Implementation repo: `digital-factory-ui`

## 1. Current State
The current `digital-factory-ui` behavior has several concrete UI problems:
- Task mode feature rows show the wrong status.
- Mode-level list loading still leans on the workspace root payload instead of mode-specific list endpoints.
- Feature and task lists do not have pagination behavior.
- Single-clicking features or tasks currently opens modal detail surfaces; the desired primary action is to open the matching Feature tab or Task tab.
- Task repository metadata in the Task tab must be plain text, not a link. Modal-detail repository behavior is no longer part of this bugfix because modal detail is being removed from the single-click flow.
- Feature cards in feature mode do not yet have the intended copy hierarchy: feature ID should be secondary and smaller than the title, while the title should get as much visible width as possible.
- Feature cards in feature mode must not show a status tag.
- The Feature tab Tasks panel must expose nested tabs as `Tasks List` and `Task Docs`; `Task Docs` must load `tasks.md` from the document URL/path and render it as formatted Markdown.
- The tasks sidebar displays "In Progress", "In Review", and "Ready" sections, but lacks a dedicated section for "Blocked" tasks. Blocked tasks are mixed within other lists or omitted.
- The tasks sidebar sections cannot be collapsed/expanded to focus on specific work states, and there are no status duration indicators showing how long a task has been in its current state.

Relevant implementation points in `digital-factory-ui`:
- `src/services/workflow-backend/types.ts` already defines `PagedFeatures` and `PagedTasks` with `items`, `total`, `page`, and `limit`.
- `src/services/workflow-backend/client.ts` currently unwraps paged responses to arrays via `unwrapItems()`, which discards pagination metadata.
- `src/services/workflow-backend/query-params.ts` already supports `title`, `status`, `page`, `limit`, and `sort` for features, and also supports `task_id` and `repo` for task routes.
- `src/features/board/lib/backend-list-params.ts` currently applies `limit=100` but does not consistently set `page=1` or a default sort for board list requests.
- `src/features/board/hooks/useBackendFeatureSearch.ts` and `src/features/board/hooks/useBackendTaskSearch.ts` return only result rows and loading/error state, not pagination metadata.
- `src/features/board/components/FeatureBoardView/FeatureListRow.tsx` is the Feature mode card surface. It should render the feature ID as compact secondary metadata and let the title occupy the primary text block.
- `src/features/board/components/FeatureBoardView/FeatureBoardView.tsx` currently wires Feature mode card single-click to selection/modal state and double-click to tab opening. The primary click should open the Feature tab.
- `src/features/board/components/TaskBoardView/TaskBoardView.tsx`, `src/features/board/components/FeatureRow/FeatureRow.tsx`, and task card wiring currently route task selection through modal state. The primary task click should open the Task tab.
- `src/features/board/components/FeatureTabView/FeatureTasksPanel.tsx` already has the document-content path through `useDocumentContent()` and `MarkdownBlock`, but the visible tab label and fallback copy still need to match `Task Docs`.
- `src/features/board/components/TaskTrackingPanel/TaskTrackingPanel.tsx` groups and lists tracked sidebar tasks. It uses `groupTrackedTasks()` from `groupTasks.ts` and renders sections via `TaskTrackingSection` and tasks via `TaskTrackingItem`.
- `src/features/board/components/TaskTrackingPanel/TaskTrackingPanel.types.ts` defines `TrackedStatus` as `"in_progress" | "ready" | "in_review"`, missing the `"blocked"` status.

Current repo boundaries:
- `project-workspace` owns the planning artifacts.
- `digital-factory-ui` owns the implementation.
- `workflow-backend` is the read-only backend dependency for list/search data.

Current constraints:
- The frontend must keep the backend as the source of truth for feature/task lists.
- The frontend must preserve the current query state when the user pages, filters, or searches.
- Browser verification is required because the defects are visible in the UI.
- Existing `workflow-backend` client behavior should remain backward compatible for call sites that only need arrays; pagination-aware code can use an additive API.
- Feature mode card layout must stay compact enough for the kanban-style table while prioritizing title readability over metadata decoration.

## 2. Problem Framing
What needs to change:
- Feature mode must query the feature list endpoint.
- Task mode must query the task list endpoint.
- Search, filter, sort, and pagination must all be backend-driven per mode.
- The UI needs explicit pagination state and controls instead of only `limit`.
- The frontend must preserve pagination metadata from backend list responses instead of unwrapping everything to arrays.
- Single-clicking a feature must open the Feature tab, not a feature detail modal.
- Single-clicking a task must open the Task tab, not a task detail modal.
- Task tab must show repository as text only.
- Feature cards in feature mode must stop rendering a status tag.
- Feature mode cards must show `feature.id` as smaller, secondary metadata and allocate the primary card width to the title so the title is visible as fully as possible.
- Task-mode feature rows must render the feature lifecycle status from the feature response, not a task-derived proxy.
- Feature tab Tasks panel must show `Tasks List` and `Task Docs`, and `Task Docs` must render `tasks.md` Markdown from the backend document content or document URL.
- The tasks sidebar must include a collapsible/expandable section for "Blocked" tasks, positioned at the very top.
- Task items in the sidebar must show prominent status duration indicators representing the elapsed time since they entered their current status, computed from the task's log or execution metadata.

What must remain stable:
- Workspace selection and other unrelated dashboard flows.
- Existing backend route ownership.
- Existing feature/task identity conventions.
- No backend schema or write-path change for this bugfix.

Assumptions already fixed:
- The workspace ID for the bug report is `e2a00270-3358-4264-8aa6-785279feb5e4`.
- The backend exposes separate collection endpoints for features and tasks.
- The UI is allowed to keep the current backend contract and only change how it queries and renders it.
- The existing paged response shape is `{ items, total, page, limit }`.
- Feature card title text is more important than showing the ID prominently; ID remains useful for scanning and copy context, but it must not steal title space.
- Modal detail surfaces are not part of the target single-click interaction path for this bugfix.

## 3. Options Considered

### Option A: Keep loading the workspace root payload and filter locally
- Pros:
  - Lowest immediate code churn.
  - No new query-state plumbing.
- Cons:
  - Cannot satisfy mode-specific query requirements.
  - Cannot add real pagination.
  - Keeps the status mapping bug alive.
  - Ties list rendering to stale or oversized root payloads.
- Implementation impact:
  - Small code change, but it would not fix the reported defects.
- Dependency impact:
  - No backend dependency change, but the UI would still be incorrect.

### Option B: Use existing mode-specific list endpoints with shared query state
- Pros:
  - Matches the required backend contract.
  - Makes search, filter, sort, and pagination consistent per mode.
  - Keeps backend as source of truth.
  - Fixes the status and repository rendering bugs in the same data flow.
- Cons:
  - More frontend state and request wiring.
  - Requires a clear pagination metadata contract.
- Implementation impact:
  - Moderate refactor in the data layer and list components.
- Dependency impact:
  - Depends on the existing list endpoints and their pagination shape.

### Option D: Render Feature mode card ID as secondary metadata and prioritize title width
- Pros:
  - Matches the requested visual hierarchy: title first, ID second.
  - Keeps feature identity visible without making the card feel like an ID-first row.
  - Gives long titles the best chance to render fully by putting title in the primary text block and avoiding large ID/status chips beside it.
- Cons:
  - May slightly increase card height if the title wraps.
  - Requires regression coverage so future compact-card tweaks do not hide the ID or compress the title again.
- Implementation impact:
  - Update `FeatureListRow` card layout, typography, and truncation/wrapping behavior.
  - Keep the feature status tag suppressed in Feature mode cards.
- Dependency impact:
  - No backend dependency; this is a frontend rendering-only change.

### Option E: Keep ID and title on one line with equal visual weight
- Pros:
  - Minimal markup change.
  - Keeps cards very compact.
- Cons:
  - Does not satisfy the requirement that ID be smaller than title.
  - Long IDs or badge styling can consume the title width and make titles harder to read.
- Implementation impact:
  - Small change, but weak UX outcome.
- Dependency impact:
  - No backend dependency.

### Option F: Make single-click open tabs and remove modal detail from the primary flow
- Pros:
  - Matches the requested interaction model.
  - Reduces duplicate detail surfaces for the same task/feature content.
  - Makes single-click behavior consistent with tab-based navigation.
- Cons:
  - Requires updating tests that expect modal state on single-click.
  - Existing modal components may become unused until a separate cleanup removes them.
- Implementation impact:
  - Rewire Feature mode card primary click to `openFeatureTab(...)`.
  - Rewire task card/row primary click to `openTaskTab(...)`.
  - Remove modal-detail-specific acceptance checks from this bugfix.
- Dependency impact:
  - No backend dependency; this is frontend interaction wiring.

### Option G: Keep modal on single-click and open tab only through double-click
- Pros:
  - Minimal behavior change.
  - Preserves the existing modal detail path.
- Cons:
  - Does not satisfy the requested tab-first behavior.
  - Keeps two competing detail surfaces active.
  - Keeps modal-detail repository rendering in scope even though the modal path is no longer desired.
- Implementation impact:
  - Small code change, but it leaves the reported behavior in place.
- Dependency impact:
  - No backend dependency.

### Option C: Add a new backend endpoint tailored to the UI
- Pros:
  - Could normalize response shape and pagination metadata.
- Cons:
  - Unnecessary backend churn.
  - Slower release path.
  - Expands scope beyond a frontend bugfix.
- Implementation impact:
  - Frontend and backend work.
- Dependency impact:
  - Adds a backend release dependency the current bug does not need.

## 4. Chosen Design
Selected approach: **Option B - Use existing mode-specific list endpoints with shared query state**, plus **Option D - Feature mode card ID as secondary metadata with title width prioritized**, plus **Option F - single-click opens tabs and modal detail is removed from the primary flow**.

Option B keeps the existing backend contract, makes mode behavior explicit, and keeps implementation scoped to `digital-factory-ui`.

The chosen implementation uses a shared frontend list-query layer that resolves the active endpoint by mode:
- Feature mode -> `/api/workspaces/:workspaceId/features`
- Task mode -> `/api/workspaces/:workspaceId/tasks`

The list-query layer should own:
- active mode
- `title`
- `status`
- `page`
- `limit`
- `sort`
- request execution
- pagination metadata normalization

The workflow-backend client should expose pagination-aware list helpers without breaking existing array-returning helpers. The implementation can either:
- add new helpers such as `searchFeaturesPage()` and `searchWorkspaceTasksPage()`, or
- change the board-specific hooks to call a lower-level request path that returns `{ items, total, page, limit }`.

Do not rely on `unwrapItems()` for the paginated board/search surfaces because it drops the metadata needed by pagination controls.

The render layer should own:
- feature lifecycle status display
- task repository text rendering
- tab-first feature/task click behavior
- feature card status-tag suppression
- feature card ID/title hierarchy
- Feature tab `Task Docs` label and Markdown rendering
- task activity timeline/logs regex-free link detection and click handling
- Task tab section reordering (Pull Request first, followed by Details, Execution, Last Updated, and Activity Timeline)

Behavior rules:
- Initial board list requests use `page=1&limit=100`.
- Search, filter, and sort changes reset `page` to `1`.
- Page changes preserve `title`, `status`, `limit`, and `sort`.
- The active mode always determines the endpoint.
- Feature mode and task mode never share a local filtered list derived from the workspace root payload.
- Task route helpers may continue supporting `task_id` and `repo` for existing call sites, but this bugfix only requires task mode board search/filter to drive `title`, `status`, `page`, `limit`, and `sort`.
- Feature mode card single-click opens the Feature tab. It must not open the feature modal detail.
- Task card single-click opens the Task tab. It must not open the task modal detail.
- Feature mode cards render the feature ID in a smaller secondary style than the title.
- Feature mode card title uses the primary text area, can wrap within the card, and should only truncate after consuming the available title area.
- Feature mode cards keep the status tag suppressed; status remains represented by the kanban-style status column/cell, not by an extra card badge.
- Feature tab nested tasks view uses the visible labels `Tasks List` and `Task Docs`; `Task Docs` fetches or uses inline `tasks.md` content and renders it through the Markdown renderer.
- The tasks sidebar displays the "Blocked" tasks section at the very top, followed by "In Progress", "In Review", and "Ready".
- The "Blocked" section is collapsible/expandable, initialized as expanded, and can be toggled by the user.
- To retrieve blocked tasks for the sidebar from the backend, the constant `SIDEBAR_TASK_PARAMS` in `src/services/workflow-backend/query-params.ts` must be updated to include `"blocked"` in its `status` array, resulting in the query parameter string `status=in_progress,in_review,ready,blocked` (adding `blocked` to the 3 existing statuses).
- Status duration (age) is calculated by scanning the task's log in reverse to find the latest transition timestamp matching the current status (or falling back to the last log timestamp or `execution.last_updated_at`).
- The status duration is displayed prominently on the task item in the sidebar (e.g., using a high-visibility badge, highlighted text, or color-coded status age indicators like "in progress 2d", "blocked 5h").
- Web links (e.g., `https://github.com/tiendv89/digital-factory-ui/pull/57`) within task activity timeline and logs are detected without using regular expressions (regex).
- Detected web links in timeline/logs are formatted/highlighted as hyperlinks, and clicking them opens the URL in a new tab/window.
- The Task tab (rendered in `TaskDetailSheet`) reorders its sections so that the "Pull Request" (PR) section is rendered first at the very top, followed by the "Details" metadata, "Execution" info, "Last Updated" timestamp, and finally the "Activity Timeline" logs.

Compatibility considerations:
- If the backend returns explicit pagination metadata, the UI should use it directly.
- If metadata is incomplete, the UI should fall back conservatively and avoid inventing page counts.
- The UI should tolerate backend-supported multi-value `status` encoding without hardcoding a single serialization scheme unless the contract already fixes it.
- Existing tests that assert array-returning helpers should remain valid unless their call site is intentionally migrated to a paged helper.
- Card layout changes should not alter feature identity or explicit new-tab/session behavior.

Operational / release implications:
- No migration.
- No config change expected.
- Frontend-only rollout, but it depends on the existing backend read contract staying stable.

## 5. Dependency Analysis

Internal dependencies:
- Mode switch state in `digital-factory-ui`.
- Existing feature/task list rendering components.
- Shared request/query serialization code.
- `workflow-backend` client handling of paged responses.
- Status/repository/card rendering components.
- Feature/task click wiring and tab-opening handlers.
- `FeatureListRow` typography and layout behavior.
- Feature tab document loading and Markdown rendering path.
- Task list grouping logic and sidebar components (`TaskTrackingPanel`, `groupTrackedTasks`, `TaskTrackingItem`).
- Status duration calculations and formatting helpers.

External dependencies:
- `workflow-backend` list endpoints for features and tasks.
- Backend pagination metadata shape.
- Backend-supported query params for `title`, `status`, `page`, `limit`, and `sort`.
- Browser QA against the live UI.

Blocking decisions:
- Confirm whether the backend list responses expose `total`, `page`, `limit`, `hasNext`, or similar pagination metadata.
- Confirm the backend's multi-status encoding convention if it is not already standardized by the current list routes.

Unresolved dependency:
- Exact pagination metadata beyond `{ items, total, page, limit }` is not required. If the backend omits additional fields such as `hasNext`, the frontend should derive only conservative next/previous availability from `total`, `page`, and `limit`.

## 6. Parallelization / Blocking Analysis

D1: Confirm backend pagination metadata shape and multi-status encoding
  └── Unblocks pagination control enablement and exact query serialization before T5

T1: Frontend list-query layer - mode-scoped requests and query-state model
  └── Can begin now — no blockers

T2: Tab-first feature/task click behavior
  └── Can begin now — no blockers

T3: Feature/card/status rendering fixes
  └── Can begin now — no blockers

T4: Feature Task Docs markdown panel
  └── Can begin now — no blockers

T8: Sidebar blocked section and status-age indicators
  └── Can begin now — no blockers

T9: Timeline link formatting and click-handling
  └── Can begin now — no blockers

T10: Task tab section reordering
  └── Can begin now — no blockers

T2, T3, T4, T8, T9, and T10 run in parallel.

T5: Pagination controls and page-state wiring
  └── BLOCKED on D1 (pagination controls need the response metadata and query serialization confirmed)
  └── BLOCKED on T1 (shared query-state layer must preserve page metadata before controls can drive it)

T1, T2, T3, and T4 can start in parallel after task approval.
T5 starts after T1 is in place and the pagination contract is confirmed.

T6: Regression tests and browser QA
  └── BLOCKED on T1 (endpoint/query contract must be stable before assertions are meaningful)
  └── BLOCKED on T2 (tab-first click behavior must be implemented)
  └── BLOCKED on T3 (status, repository, and feature card hierarchy must be implemented)
  └── BLOCKED on T4 (Task Docs rendering must be implemented)
  └── BLOCKED on T5 (pagination controls and page-state behavior must exist before browser QA)

T7: Post-change final regression and browser QA
  └── BLOCKED on T1, T2, T3, T4, T5, T6, T9, T10 (original features regression must be stable)
  └── BLOCKED on T8 (sidebar blocked section and status-age indicator must be implemented)

## 7. Repository Impact
Affected repositories:
- `digital-factory-ui` - implementation repo where the bugfix lands.
- `project-workspace` - planning repo where this technical design lives.

No other repo needs a code change for this bugfix.

## 8. Validation and Release Impact
Testing expectations:
- Verify the feature endpoint is queried in feature mode with `page`, `limit`, `title`, `status`, and `sort`.
- Verify the task endpoint is queried in task mode with `page`, `limit`, `title`, `status`, and `sort`.
- Verify paged response metadata is preserved for board/search pagination controls.
- Verify search/filter/sort/page actions preserve the active query state and reset `page` only when appropriate.
- Verify task-mode feature rows render lifecycle status from the feature response.
- Verify feature single-click opens the Feature tab and does not open the feature modal detail.
- Verify task single-click opens the Task tab and does not open the task modal detail.
- Verify task repository is plain text in the Task tab.
- Verify feature cards in feature mode no longer render a status tag.
- Verify feature cards render feature ID smaller than the title and let the title use the primary available width.
- Verify Feature tab nested tasks view labels are `Tasks List` and `Task Docs`.
- Verify `Task Docs` loads `tasks.md` content from inline backend content or the document URL and renders formatted Markdown.
- Verify the tasks sidebar displays a collapsible/expandable "Blocked" tasks panel at the very top.
- Verify that every task item in the sidebar displays a prominent, highly visible indicator showing how long it has been in its current status.
- Verify that web links (e.g., `https://github.com/tiendv89/digital-factory-ui/pull/57`) in the task activity timeline and logs are detected without regex, highlighted as hyperlinks, and open correctly in a new tab/window when clicked.
- Verify that the Task tab layout displays its sections in the following specific top-to-bottom order: Pull Request, Details, Execution, Last Updated, and Activity Timeline.

Release impact:
- Frontend-only rollout.
- No migration.
- No persisted data change.
- Backward compatibility depends on the backend continuing to accept the documented query params and returning usable pagination data.

Handoff impact:
- The implementation handoff should include the exact query contract used by the UI, the pagination behavior, and screenshots or browser QA notes for the affected views.
