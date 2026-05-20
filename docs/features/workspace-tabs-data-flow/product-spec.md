# Product Specification

## Feature

- Feature ID: `workspace-tabs-data-flow`
- Title: `Workspace Tabs and Backend API Data Flow`

## References

Visual references are stored in `docs/features/workspace-tabs-data-flow/references/`. The workspace, feature, and task tab references remain the visual source for the user-facing surfaces.

### Workspace dropdown

Figma: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=110-2&m=dev

![Workspace dropdown](<references/workspace dropdown.png>)

### Import workspace modal

Figma: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=110-517&m=dev

![Import workspace modal](<references/import workspace modal.png>)

### Feature tab - product spec default

Figma: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=110-733&m=dev

![Feature tab - product spec default](<references/feature tab -  product spec (default).png>)

### Feature tab - technical design

Figma: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=110-1418&m=dev

![Feature tab - technical design](<references/feature tab - technical design.png>)

### Feature tab - tasks

Figma: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=110-1660&m=dev

![Feature tab - tasks](<references/feature tab - tasks.png>)

### Feature tab - tasks.md mode

Figma: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=110-1898&m=dev

![Feature tab - tasks.md mode](<references/feature tab - tasks - tasks.md mode.png>)

### Feature tab - logs

Figma: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=110-2464&m=dev

![Feature tab - logs](<references/feature tab - logs.png>)

This reference remains for later activity/log work. Activity timelines and the `/api/workspaces/:workspaceId/activity` route are deferred and not integrated in this feature phase.

### Task tab

Figma: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=110-2689&m=dev

![Task tab](<references/task tab.png>)

## Dependencies

- **`workspace-data-backend`** delivers the `workflow-backend` frontend API contract consumed by this feature.
- **`workflow-backend` `api-service`** is the HTTP source of truth. Local default base URL is `http://localhost:8081`; public routes are under `/api`.
- **`digital-factory-ui`** owns the workspace switcher, import modal, board, task tabs, feature tabs, frontend API client, and browser QA.

## Problem

The dashboard needs persistent workspace, feature, and task navigation without parsing workflow repository files in the browser. The backend now exposes workspace detail, import, sync, feature detail, task detail, and search/filter routes. The frontend must use that contract directly so the UI displays the same normalized workspace state that `workflow-backend` serves.

Users need to switch workspaces, import repositories, refresh source data, open persistent task and feature tabs, and keep active board/sidebar data refreshed while preserving context. Workspace choices shown to the user must come from a browser-local saved workspace list so a workspace imported by user A in one browser profile is not exposed to user B through an unscoped backend workspace list. Workspace details, features, tasks, sync results, stale-cache states, and structured errors still come from backend payloads instead of frontend-only fixtures, direct GitHub reads, or raw YAML parsing.

## Goals

- Redesign the workspace dropdown, import modal, backend-backed board data, task tabs, and feature tabs according to the visual references in this spec.
- Integrate all backend APIs to replace the current frontend data flows, covering workspace load/import/sync, board polling, feature/task list and detail routes, sidebar active-task polling, stale-cache handling, and structured error states.
- Load saved workspace choices from browser-local workspace summaries, not from a global `GET /api/workspaces` response.
- Import a workspace with `POST /api/workspaces/import`, persist the workspace in the backend database, save a short browser-local workspace summary, and navigate to the returned `WorkspaceDetail`.
- Keep browser-local workspace summaries private to the current browser/user profile and limited to picker metadata such as `workspaceId`, display name, repository URL, default branch, and last-opened timestamp.
- Render the workspace dashboard from `GET /api/workspaces/:workspaceId`.
- Refresh workspace data with `POST /api/workspaces/:workspaceId/sync`.
- Poll the Kanban board data from `GET /api/workspaces/:workspaceId` while the board is active.
- Render workspace feature and task lists through the backend list/search routes.
- Render the board sidebar from its own active-task query: `GET /api/workspaces/:workspaceId/tasks?status=in_progress,in_review,ready&sort=task_id_asc&page=1&limit=50`.
- Poll the sidebar active-task query independently from the board/detail payloads.
- Open quick task detail and task tabs through `GET /api/workspaces/:workspaceId/tasks/:taskId`.
- Open feature tabs through `GET /api/workspaces/:workspaceId/features/:featureId`.
- Render feature-scoped tasks and task detail through the feature-scoped task routes where the UI is already inside a feature.
- Use backend identifier rules consistently:
  - `workspaceId` is a workspace UUID.
  - `featureId` is the public feature UUID from `feature_id`.
  - `taskId` is the public task UUID from `task_id`.
  - `feature_name` and `task_name` are display/source labels, not route ids.
- Preserve the current workspace board when switching between board, task tab, and feature tab surfaces.
- Keep stale cached data visible when backend responses mark `source_state.stale=true`.
- Show backend error source and retryability in user-facing loading, empty, stale, and error states.

## Non-goals

- No direct GitHub file fetching or raw YAML/markdown parsing inside frontend UI components.
- No user-visible workspace switcher populated from an unscoped/global `GET /api/workspaces` response.
- No workflow state write-path changes for claims, approvals, branch updates, or task transitions.
- No activity timeline or `/api/workspaces/:workspaceId/activity` integration in this phase.
- No redesign of unrelated dashboard modules outside the referenced workspace and tab surfaces.
- No `deployment-checklist.md` at this stage.

## User Journeys

| ID | Title |
|---|---|
| [J01](journeys/J01-return-to-workspace-board.md) | Return to the workspace board |
| [J02](journeys/J02-load-saved-workspaces.md) | Load saved workspaces |
| [J03](journeys/J03-open-workspace-switcher.md) | Open the workspace switcher |
| [J04](journeys/J04-search-and-select-workspace.md) | Search and select a saved workspace |
| [J05](journeys/J05-start-importing-workspace.md) | Start importing a workspace |
| [J06](journeys/J06-submit-import.md) | Submit an imported workspace |
| [J07](journeys/J07-handle-import-sync-failure.md) | Handle import or sync failure |
| [J08](journeys/J08-cancel-workspace-import.md) | Cancel workspace import |
| [J09](journeys/J09-refresh-workspace-data.md) | Refresh workspace data |
| [J10](journeys/J10-inspect-task-quickly.md) | Inspect a task quickly from the board |
| [J11](journeys/J11-open-task-tab-from-board.md) | Open a task tab from the board |
| [J12](journeys/J12-open-task-tab-from-context-menu.md) | Open a task tab from a context menu |
| [J13](journeys/J13-use-sidebar-task-items.md) | Use task items from the sidebar |
| [J14](journeys/J14-inspect-feature-quickly.md) | Inspect a feature quickly in Task Mode |
| [J15](journeys/J15-switch-to-feature-mode.md) | Switch to Feature Mode |
| [J16](journeys/J16-open-feature-tab-feature-mode.md) | Open a feature tab in Feature Mode |
| [J17](journeys/J17-activate-task-tab.md) | Activate an existing task tab |
| [J18](journeys/J18-read-task-tab-content.md) | Read task tab content |
| [J19](journeys/J19-copy-task-identity.md) | Copy task identity |
| [J20](journeys/J20-leave-task-tab.md) | Leave a task tab |
| [J21](journeys/J21-activate-feature-tab.md) | Activate an existing feature tab |
| [J22](journeys/J22-read-feature-tab-content.md) | Read feature tab content |
| [J23](journeys/J23-understand-feature-stage.md) | Understand feature stage state |
| [J24](journeys/J24-open-task-from-feature-tab.md) | Open a task from a feature tab |
| [J25](journeys/J25-copy-feature-identity.md) | Copy feature identity |
| [J26](journeys/J26-close-feature-tab.md) | Close a feature tab |

## Acceptance Criteria

- First app load lists saved workspace choices from browser-local workspace summaries.
- The user-visible workspace switcher does not call or depend on `GET /api/workspaces` unless that backend route is explicitly user-scoped in a later contract.
- Selecting a browser-saved workspace loads `GET /api/workspaces/:workspaceId` and renders board data from the returned `WorkspaceDetail`.
- Workspace import sends `repo_url`, optional `default_branch` defaulting to `main`, and optional `name` to `POST /api/workspaces/import`; `200 OK` persists the workspace in the backend database, saves or updates the browser-local workspace summary, and navigates to the returned workspace detail.
- Browser-local workspace summaries contain only short picker metadata and do not store features, tasks, source documents, raw workflow files, access tokens, or full `WorkspaceDetail` payloads.
- A workspace imported in one browser/user profile is not shown in another browser/user profile solely because it exists in the backend database.
- Manual sync calls `POST /api/workspaces/:workspaceId/sync` and replaces the active workspace detail/view cache with the returned `WorkspaceDetail`; browser-local workspace summaries remain limited to picker metadata.
- Kanban board polling refreshes `GET /api/workspaces/:workspaceId` while the workspace board is active and does not run from task or feature tabs.
- Sync failure with stale backend data keeps the current workspace visible and clearly marks `source_state.stale=true` and `source_state.error_code`.
- Feature Mode fetches or refreshes feature data through `GET /api/workspaces/:workspaceId/features` with supported query params.
- Task Mode fetches or refreshes task data through `GET /api/workspaces/:workspaceId/tasks` with supported query params.
- The board sidebar fetches and polls active tasks independently through `GET /api/workspaces/:workspaceId/tasks?status=in_progress,in_review,ready&sort=task_id_asc&page=1&limit=50`; it does not derive from workspace detail, Task Mode search, feature detail, or task detail data.
- Search and filter controls map to backend query params exactly: feature title uses `title`, task name uses `task_id`, task title uses `title`, statuses use comma-separated `status`, and natural task order uses `sort=task_id_asc`.
- Single-clicking a task or feature opens quick inspection rather than a persistent tab.
- Double-clicking a task opens or focuses a task tab backed by `TaskDetail`.
- Double-clicking a feature opens or focuses a feature tab only in Feature Mode and backs it with `FeatureDetail`.
- Task and feature context menus provide a clear path to open work item tabs where supported.
- Sidebar task items follow the same task inspection and task tab behavior as board task cards while using their own active-task API source.
- Task tabs and feature tabs preserve work sessions, can be activated and closed, and do not show the workspace board sidebar.
- Task tabs show task identity, status, repository, branch, dependencies, execution metadata, and PR refs from backend data.
- Feature tabs show feature identity, current stage, source documents, feature-scoped task list, task counts, and source state from backend data.
- Opening a task from a feature tab preserves originating feature context and can use the feature-scoped task detail route.
- Structured backend errors render source-specific messages and retry affordances based on `retryable`.
- Empty arrays from backend list/search routes render empty states rather than errors.
