# Product Specification

## Feature

- Feature ID: `workspace-tabs-data-flow`
- Title: `Workspace Tabs and End-to-End Workspace Data Flow`

## References

Visual references are stored in `docs/features/workspace-tabs-data-flow/references/`. The workspace, feature, and task tab references are the visual source for the user-facing surfaces.

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

### Task tab

Figma: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=110-2689&m=dev

![Task tab](<references/task tab.png>)

## Problem

Today the dashboard reads workspace, feature, and task data directly from GitHub on every page load. As more features and tasks are added, this becomes too slow and too fragile — a single GitHub API failure breaks the entire board, and nothing persists when the browser session ends.

GitHub still owns the canonical record for task state changes. Task claims, status transitions, and approvals are written to the repository, and that will not change. The gap is on the read side: there is no server-backed store that mirrors those records and serves them reliably to the UI.

Users need the dashboard to load workspace data across sessions and devices without re-entering repository credentials every time. When a GitHub sync fails, users should still see the last known state rather than a blank screen. When GitHub data is available, it should update in the background without blocking the UI.

## Goals

- Keep the workspace tab as the way back to the current workspace board.
- Let users switch between saved workspaces loaded from backend data.
- Let users import or sync a workspace from a GitHub repository.
- Normalize GitHub and database-backed workspace data through adapters before it reaches UI components.
- Let the backend expose stable workspace, feature, task, document, and activity APIs.
- Let the UI render workspace board, feature tabs, and task tabs from backend payloads only.
- Let users inspect tasks and features quickly without opening persistent sessions.
- Let users open persistent task and feature tabs when they want deeper work context.
- Keep task and feature tab behavior predictable across single click, double click, and context menu actions.
- Keep the board sidebar limited to the workspace board, not task or feature tabs.
- Show loading, empty, stale, and source-error states clearly when GitHub, database, or adapter reads fail.

## Non-goals

- No agent, chat, model selector, composer, skill mention, image attachment, conversation persistence, or LLM surface.
- No workflow lifecycle, approval gate, task status, or task YAML ownership changes.
- No direct GitHub file parsing inside frontend UI components.
- No frontend-only source of truth for imported workspace data.
- No broad dashboard redesign outside workspace switching, work item tabs, source-backed detail views, and end-to-end data loading.
- No `deployment-checklist.md` at this stage.

## Source Model

### GitHub source

The GitHub source is an imported workflow repository. It contains feature folders, `status.yaml`, `product-spec.md`, `technical-design.md`, `tasks.md`, and `tasks/T*.yaml` files.

GitHub reads are used for import, manual refresh, and source resync. The user should see clear errors for inaccessible repositories, invalid repository URLs, missing required files, invalid YAML, rate limits, and network failures.

### Database source

The database source stores saved workspaces and backend-owned cached workspace snapshots. It lets returning users open known workspaces without re-entering repository data every time.

Database reads are used for workspace list, workspace detail, cached feature/task state, and fallback display when a fresh GitHub sync is not available.

### Source adapters

Adapters normalize GitHub and database data into the same backend DTOs. Source-specific parsing, fallback, freshness, and validation should stay behind this boundary.

Adapter output must include enough source status for the UI to explain where data came from, whether it is fresh, stale, partially loaded, or unavailable.

### Backend API

The backend owns import, sync, cache reads, source normalization, and error mapping. It exposes the only data contract used by the UI.

### UI

The UI renders workspace, feature, and task surfaces from backend payloads. It should not parse GitHub archives, raw YAML, or database-specific records directly.

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

- The workspace tab returns the user from any task or feature tab to the current workspace board.
- The workspace switcher loads saved workspaces from the backend and supports search, switch, and cancel.
- Workspace import sends repository input to the backend and does not parse GitHub files in the UI.
- GitHub data and database data are normalized through source adapters before the backend returns UI payloads.
- Backend APIs expose stable workspace list, workspace detail, feature detail, task detail, source document, task list, activity, and refresh/sync payloads.
- The database cache supports reopening saved workspaces without a fresh GitHub import every time.
- Sync failures keep cached data visible when available and mark the source state clearly.
- Single-clicking a task or feature opens quick inspection rather than a persistent tab.
- Double-clicking a task opens or focuses a task tab.
- Double-clicking a feature opens or focuses a feature tab only in Feature Mode.
- Task and feature context menus provide a clear path to open work item tabs where supported.
- Sidebar task items follow the same task inspection and task tab behavior as board task cards.
- Task tabs and feature tabs preserve work sessions and can be activated, closed, and navigated predictably.
- The sidebar is visible on the workspace board and hidden in task and feature tabs.
- Task tabs let the user understand task identity, state, related work, and history from backend data.
- Feature tabs let the user understand feature identity, stage state, source documents, tasks, and history from backend data.
- Opening a task from a feature tab lets the user return to the originating feature tab when possible.
- Agent, chat, model, composer, and conversation controls are absent from this feature.
