# Tasks - Workspace Tabs and Backend API Data Flow

Feature status reference: `in_tdd`; stage status: `technical_design/awaiting_approval`, `tasks/draft`. Machine state lives in `tasks/T<n>.yaml`; this file is narrative only.

## Index

| ID | Wave | Title | Depends on |
|---|---:|---|---|
| T1 | 1 | Frontend API client and shared workflow DTOs | [] |
| T2 | 2 | Workspace switcher, import modal, and board bootstrap integration | [T1] |
| T3 | 2 | Workspace search, filters, refresh, and stale-source UX | [T1, T2] |
| T4 | 3 | Task quick views, workspace-scoped task drawer, and task tab | [T1, T2, T3] |
| T5 | 4 | Feature mode, feature tab, and feature-scoped task drilldown | [T1, T2, T3] |
| T6 | 5 | Document rendering, source state, and copy affordances | [T4, T5] |
| T7 | 6 | End-to-end browser QA and regression coverage | [T1, T2, T3, T4, T5, T6] |

---

## T1 - Frontend API client and shared workflow DTOs

### Description

Define the typed frontend boundary to `workflow-backend` and the shared DTOs the workspace shell will consume.

This task owns the API client, request helper, normalized error type, and the frontend TypeScript types that mirror the backend contract. It does not own any UI rendering beyond minimal smoke usage in tests.

Deliverables:

- Define typed client methods for import, detail, sync, feature detail, feature tasks, task detail, workspace tasks, Kanban board polling, and sidebar active-task polling.
- Define shared frontend DTOs for browser-local workspace summaries, workspace detail, feature summaries, feature detail, task summaries, task detail, pull request refs, source state, and error payloads.
- Define `ApiError` parsing and retryability handling.
- Define backend identifier helpers for `workspaceId`, `featureId`, `taskId`, `feature_name`, and `task_name`.
- Define query-param helpers for feature/task search and pagination.
- Add unit tests for request building and error parsing.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Inspect the current frontend service/query conventions and identify the right home for the new client.
- [ ] Add the `workflow-backend` API client.
- [ ] Add shared DTO and error types.
- [ ] Add request helper and environment base URL handling.
- [ ] Add query-param builders for feature and task search.
- [ ] Add tests for success and structured-error parsing.
- [ ] Typecheck passes.

---

## T2 - Workspace switcher, import modal, and board bootstrap integration

### Description

Wire the workspace shell to browser-local workspace summaries, the import route, and the workspace detail route.

This task depends on T1 because the workspace shell should only consume typed backend payloads.

Deliverables:

- Load saved workspace summaries and the current selected workspace id from browser-local storage on first app load.
- Use backend workspace detail data to bootstrap the active workspace board.
- Workspace tab returns to the current workspace board.
- Workspace switcher opens from the workspace tab control.
- Workspace selection updates browser-local current selection, loads the selected workspace detail, and clears or hides tabs from the previous workspace.
- Import modal submits to `POST /api/workspaces/import`.
- Import success saves or updates the short browser-local workspace summary, sets the current selected workspace id locally, and navigates to the returned workspace detail.
- Import validation and backend errors render inline without losing modal state.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Inspect the current workspace shell and routing/state entry points.
- [ ] Load saved workspace summaries and current selection from browser-local storage on app start.
- [ ] Wire the workspace tab to return to the board surface.
- [ ] Build or update the workspace switcher against browser-local workspace summaries.
- [ ] Wire the import modal to the backend import route.
- [ ] Handle import success by saving the local summary/current selection and rendering structured error states on failure.
- [ ] Clear or hide previous-workspace tabs when the active workspace changes.
- [ ] Add tests for first load, workspace switching, and import behavior.
- [ ] Typecheck passes.

---

## T3 - Workspace search, filters, refresh, and stale-source UX

### Description

Make the board data refreshable and searchable through the backend task and feature list routes while keeping stale cached data visible.

This task depends on T1 and T2 because the workspace shell and API client must already exist.

Deliverables:

- Feature search against `GET /api/workspaces/:workspaceId/features`.
- Workspace task search against `GET /api/workspaces/:workspaceId/tasks`.
- Sidebar active-task list against `GET /api/workspaces/:workspaceId/tasks?status=in_progress,in_review,ready&sort=task_id_asc&page=1&limit=50`.
- Search param mapping for `title`, `task_id`, `status`, `repo`, `page`, `limit`, and `sort`.
- Manual refresh button wired to `POST /api/workspaces/:workspaceId/sync`.
- Stale-data banner and source-state warning handling.
- Empty-state handling for empty local workspace summaries, feature lists, task lists, and search results.
- Retry affordances for retryable backend errors.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Add feature search and filter wiring.
- [ ] Add workspace task search and filter wiring.
- [ ] Add the board sidebar active-task query and keep it separate from Task Mode data.
- [ ] Map UI search controls to backend query params exactly.
- [ ] Add the manual sync action.
- [ ] Render stale-data and source-state warnings from backend payloads.
- [ ] Render empty states for no data and no matches.
- [ ] Add retry handling for retryable backend errors.
- [ ] Add tests for query serialization, stale state, and empty-state rendering.
- [ ] Typecheck passes.

---

## T4 - Task quick views, workspace-scoped task drawer, and task tab

### Description

Build the task experience from backend `TaskSummary` and `TaskDetail` payloads.

This task depends on T1, T2, and T3 because the task surfaces rely on the shared client, workspace shell, and board data.

Deliverables:

- Single-click task quick inspection from board and sidebar rows, where sidebar rows come from the independent active-task query.
- Double-click task tab open/focus behavior.
- Workspace-scoped task drawer and task tab backed by `GET /api/workspaces/:workspaceId/tasks/:taskId`.
- Task header with copy-id affordance, status, repo, branch, and updated metadata.
- Task detail sections for dependencies, execution metadata, and PR refs.
- Back behavior to the originating feature tab when present.
- No sidebar inside the task tab surface.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Build the task quick-inspection surface.
- [ ] Wire task tab open/focus behavior from board and sidebar entries.
- [ ] Fetch workspace-scoped task detail.
- [ ] Render task metadata, dependencies, and PR refs.
- [ ] Implement copy-id feedback and back behavior.
- [ ] Keep the task tab surface free of the board sidebar.
- [ ] Add tests for click behavior, task tab rendering, metadata fallbacks, and back navigation.
- [ ] Typecheck passes.

---

## T5 - Feature mode, feature tab, and feature-scoped task drilldown

### Description

Build the feature experience from backend `FeatureSummary`, `FeatureDetail`, and feature-scoped task routes.

This task depends on T1, T2, and T3 because the feature surfaces rely on the shared client, workspace shell, and board data.

Deliverables:

- Task Mode feature quick inspection from board and sidebar rows.
- Feature Mode feature tab open/focus behavior.
- Feature tab backed by `GET /api/workspaces/:workspaceId/features/:featureId`.
- Feature header with copy-id affordance, current stage, status, updated time, and task counts.
- Product Spec, Technical Design, and Tasks views driven by backend data.
- Feature-scoped task drilldown through `GET /api/workspaces/:workspaceId/features/:featureId/tasks/:taskId` when the UI already knows the feature.
- No sidebar inside the feature tab surface.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Build the feature quick-inspection surface.
- [ ] Gate feature tab open/focus behavior by Feature Mode.
- [ ] Fetch feature detail payloads from the backend.
- [ ] Render the feature header, status, stage, task counts, and copy feedback.
- [ ] Wire the Product Spec, Technical Design, and Tasks views.
- [ ] Add feature-scoped task drilldown.
- [ ] Keep the feature tab surface free of the board sidebar.
- [ ] Add tests for Feature Mode gating, feature tab rendering, drilldown, and back behavior.
- [ ] Typecheck passes.

---

## T6 - Document rendering, source state, and copy affordances

### Description

Render backend-provided documents, source state, and copy affordances cleanly across task and feature tabs.

This task depends on T4 and T5 because it builds on the task and feature detail surfaces.

Deliverables:

- Feature document rendering for product spec and technical design markdown.
- Empty-state handling for missing optional documents and missing PR refs.
- Copy affordances for `task_id` and `feature_id`.
- Source-state and updated-time presentation where the backend includes those fields.
- Activity timeline rendering and `/api/workspaces/:workspaceId/activity` integration are deferred.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Render product spec and technical design markdown from backend content.
- [ ] Handle empty and missing document states cleanly.
- [ ] Add copy affordances for task and feature identifiers.
- [ ] Add source-state and freshness presentation where needed.
- [ ] Add tests for markdown rendering, source-state display, and copy feedback.
- [ ] Typecheck passes.

---

## T7 - End-to-end browser QA and regression coverage

### Description

Verify the full frontend path against the backend API contract and fix regressions discovered during browser QA.

This task depends on all implementation tasks because it validates the integrated workspace flow end to end.

Deliverables:

- Workspace list, switcher, import, and sync flows verified in the browser.
- Task single-click, double-click, context menu, sidebar, and tab flows verified.
- Sidebar active-task query verified separately from workspace detail and Task Mode search.
- Feature single-click, Feature Mode gating, double-click, context menu, and tab flows verified.
- Stale-source, retryable-error, loading, and empty-state behavior verified.
- No direct GitHub workspace-data network access from the browser.
- No agent, chat, model selector, composer, or conversation controls in the feature surfaces.

### Required skills

- frontend-engineer
- frontend-testing
- browser-qa-frontend

### Subtasks

- [ ] Run frontend unit/component tests.
- [ ] Run TypeScript typecheck.
- [ ] Run production build where applicable.
- [ ] Verify browser-local workspace summary, current selection, and import flows in the browser.
- [ ] Verify manual sync and stale-source handling in the browser.
- [ ] Verify task and feature click, double-click, and context-menu behavior.
- [ ] Verify task tab and feature tab rendering, back behavior, and no-sidebar layout.
- [ ] Verify the board sidebar uses the active-task query and not another list payload.
- [ ] Verify no direct GitHub reads remain in browser workspace flows.
- [ ] Capture browser QA notes or screenshots for the key surfaces.
- [ ] Fix regressions found during QA.
