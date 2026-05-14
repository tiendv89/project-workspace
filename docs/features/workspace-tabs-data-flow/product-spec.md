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

Users need workspace, feature, and task tabs to show real workflow state without reading raw repository files.

The current system has no backend layer. The UI calls the GitHub API directly from the browser, parses YAML in the browser, and saves workspace configuration only in `localStorage`. There is no database, no server-side cache, and no multi-workspace support.

```text
Current state (the problem):

  UI (browser)
    → api.github.com (direct fetch)
      → YAML parsed in browser
        → localStorage (ephemeral, single workspace)
```

This feature adds a backend-mediated path. GitHub is used only for import and sync; all UI reads come from a backend-managed Supabase database. When a sync fails, the backend returns the last cached snapshot with a stale marker.

```text
Target state (what this feature builds):

  Import / sync:
    GitHub repo
      → GitHubWorkspaceAdapter (backend)
        → WorkspaceSourceService
          → Supabase Postgres (workspace snapshots)

  Read (normal):
    Supabase Postgres
      → DbWorkspaceAdapter (backend)
        → WorkspaceSourceService
          → NestJS API routes
            → Frontend API client
              → workspace shell / board / task tabs / feature tabs

  Read (stale fallback — sync failed, cache exists):
    Supabase Postgres (active snapshot)
      → DbWorkspaceAdapter
        → WorkspaceSourceService (SourceState.stale = true)
          → NestJS API routes
            → UI (stale banner, cached data still visible)
```

GitHub and database records have different shapes, freshness, and failure modes. The UI should not know those source-specific details. It should consume a stable backend contract that normalizes workspace, feature, task, document, pull request, and activity data.

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

## User Journey

### Journey 1 - Return to the workspace board

1. The user is viewing a task tab or feature tab.
2. The user clicks the workspace tab.
3. The app returns to the board for the current workspace.
4. The workspace tab becomes active.
5. The task and feature tabs remain available so the user can return to them later.

Expected result: the user can get back to the board quickly without closing open work item tabs.

### Journey 2 - Load saved workspaces

1. The user opens the dashboard.
2. The UI asks the backend for saved workspaces.
3. The backend reads database-backed workspace records through the database adapter.
4. The UI shows the saved workspace list and marks the active workspace when one exists.

Expected result: saved workspaces load from backend state, not hardcoded frontend fixtures.

### Journey 3 - Open the workspace switcher

1. The user is on the dashboard with a workspace selected.
2. The user opens the workspace switcher from the workspace tab control.
3. The app shows saved workspaces and a way to search them.
4. The active workspace is clearly marked.
5. The user can choose a saved workspace or start importing a new one.

Expected result: the user understands where they are and can move to another workspace from the same header area.

### Journey 4 - Search and select a saved workspace

1. The user opens the workspace switcher.
2. The user searches for a workspace.
3. The app filters the saved workspace list.
4. If there is no match, the app shows an empty state.
5. The user selects a workspace from the results.
6. The app asks the backend for that workspace detail.
7. The app switches to that workspace and returns to the board view.
8. Task and feature tabs from the previous workspace are not shown in the newly selected workspace.

Expected result: workspace switching is fast and does not leak tabs or context from another workspace.

### Journey 5 - Start importing a workspace

1. The user opens the workspace switcher.
2. The user chooses the import workspace action.
3. The switcher closes.
4. The import workspace modal opens directly to the import form.

Expected result: importing a workspace is reachable from the same place users manage workspace switching.

### Journey 6 - Submit an imported workspace

1. The user provides repository information needed to import a workspace.
2. The user provides access credentials when needed.
3. The user submits the form.
4. The UI sends the import request to the backend.
5. The backend reads GitHub through the GitHub adapter.
6. The adapter normalizes feature, task, document, pull request, and activity data.
7. The backend stores a database snapshot for later reuse.
8. The app adds the workspace to the saved workspace list and opens it.

Expected result: GitHub import creates a usable backend-backed workspace without requiring the UI to parse repository files.

### Journey 7 - Handle import or sync failure

1. The user submits import or refresh.
2. GitHub, database, or adapter validation fails.
3. The UI keeps the current page stable.
4. The app shows a source-specific but user-readable error.
5. The user edits the input or retries.

Expected result: users can recover from source failures without losing the current workspace state.

### Journey 8 - Cancel workspace import

1. The import modal is open.
2. The user closes the modal.
3. The modal state resets.
4. The active workspace remains unchanged.

Expected result: cancelling import does not change the current workspace.

### Journey 9 - Refresh workspace data

1. The user is viewing a workspace.
2. The user triggers refresh or the app performs a supported sync.
3. The backend asks the GitHub adapter for a fresh snapshot.
4. The backend updates the database cache if the sync succeeds.
5. The UI updates board, task tab, and feature tab data from the backend response.
6. If sync fails but cached data exists, the UI keeps cached data visible and marks it stale.

Expected result: the user can see updated source data while retaining a usable cached workspace when refresh fails.

### Journey 10 - Inspect a task quickly from the board

1. The user is on the workspace board in task-oriented mode.
2. The user single-clicks a task.
3. The app opens a quick task detail view from backend task data.
4. The user reviews the task at a glance.
5. The user closes the quick view and remains on the board.

Expected result: the user can inspect a task quickly without creating a persistent tab.

### Journey 11 - Open a task tab from the board

1. The user is on the workspace board.
2. The user double-clicks a task.
3. The app opens a task tab for that task.
4. If the task tab already exists, the app focuses the existing tab.
5. The task tab requests or reuses backend task detail data.
6. The user can return to the board by clicking the workspace tab.

Expected result: double click starts or restores a persistent task work session backed by real task data.

### Journey 12 - Open a task tab from a context menu

1. The user opens the context menu for a task.
2. The user chooses the action to open the task in a new tab.
3. The app opens a task tab for that task.
4. The context menu closes.

Expected result: users have an explicit context-menu path for opening a task work session.

### Journey 13 - Use task items from the sidebar

1. The user is on the workspace board where the sidebar is visible.
2. The sidebar shows important task groups from backend workspace data.
3. The user single-clicks a sidebar task item to inspect it quickly.
4. The user double-clicks a sidebar task item to open or focus its task tab.
5. The user can also open a task tab from the sidebar task context menu.

Expected result: sidebar task items follow the same product behavior as task cards on the board.

### Journey 14 - Inspect a feature quickly in Task Mode

1. The user is viewing task-level board content.
2. The user single-clicks a feature row.
3. The app opens a quick feature detail view from backend feature data.
4. The user reviews the feature at a glance.
5. Double-clicking the feature in this mode does not open a feature tab.

Expected result: Task Mode remains focused on task work while still allowing quick feature inspection.

### Journey 15 - Switch to Feature Mode

1. The user changes the board to Feature Mode.
2. The board shows feature-level content from backend workspace data.
3. The user scans features by their overall state.

Expected result: the user can review feature-level progress without task-level noise.

### Journey 16 - Open a feature tab in Feature Mode

1. The user is in Feature Mode.
2. The user single-clicks a feature to inspect it quickly.
3. The user double-clicks a feature to open or focus its feature tab.
4. The user can also open a feature tab from the feature context menu.

Expected result: Feature Mode supports both quick inspection and persistent feature work sessions.

### Journey 17 - Activate an existing task tab

1. A task tab is visible in the header.
2. The user clicks the task tab.
3. The task tab becomes active.
4. The main content shows the task work session.
5. The sidebar is hidden.

Expected result: the user returns to the same task work session without losing task context.

### Journey 18 - Read task tab content

1. The user opens a task tab.
2. The app shows task identity and current task state from backend detail data.
3. The user reviews task context, execution context, dependency or blocked state, related PR state, and task activity when available.
4. Missing optional information is shown as empty or unavailable rather than breaking the view.

Expected result: the user can understand the task without reading raw workflow files.

### Journey 19 - Copy task identity

1. The user is inside a task tab.
2. The user copies the task identity from the task header.
3. The app gives short feedback that the copy action succeeded.

Expected result: the user can quickly reference the task in issues, PRs, or documents.

### Journey 20 - Leave a task tab

1. The user closes a task tab or uses Back from inside a task tab.
2. If the task was opened from a feature tab, the app returns to that feature tab when possible.
3. Otherwise, the app returns to the workspace board or another relevant open tab.

Expected result: leaving a task tab preserves the most useful previous context.

### Journey 21 - Activate an existing feature tab

1. A feature tab is visible in the header.
2. The user clicks the feature tab.
3. The feature tab becomes active.
4. The main content shows the feature work session.
5. The sidebar is hidden.

Expected result: the user returns to the same feature work session without losing feature context.

### Journey 22 - Read feature tab content

1. The user opens a feature tab.
2. The app shows the feature identity and current feature state from backend detail data.
3. The user can move between feature views such as product spec, technical design, tasks, and logs or status.
4. Source documents are readable inside the dashboard.
5. Feature history and task summary are visible when available.

Expected result: the user can review feature context without leaving the feature tab.

### Journey 23 - Understand feature stage state

1. The user is inside a feature tab.
2. The user opens or hovers the current stage summary.
3. The app shows which feature stages are complete, current, or not yet complete.
4. The user dismisses the stage summary and remains in the feature tab.

Expected result: the user can understand the feature stage without reading raw status files.

### Journey 24 - Open a task from a feature tab

1. The user is inside a feature tab.
2. The user opens the feature tasks view.
3. The user selects a task.
4. The app opens or focuses the corresponding task tab.
5. When the user goes Back from that task, the app returns to the originating feature tab when possible.

Expected result: the user can drill down from feature context into task context and return cleanly.

### Journey 25 - Copy feature identity

1. The user is inside a feature tab.
2. The user copies the feature identity from the feature header.
3. The app gives short feedback that the copy action succeeded.

Expected result: the user can quickly reference the feature in issues, PRs, or documents.

### Journey 26 - Close a feature tab

1. The user closes a feature tab.
2. The feature tab is removed from the header.
3. If related task tabs are open, they remain available unless a later product decision changes that behavior.
4. The user remains in the same workspace.

Expected result: closing a feature tab does not unexpectedly close task work sessions or change workspace.

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
