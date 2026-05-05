# Product Specification

## Feature

- Feature ID: `dashboard`
- Title: `Workflow Dashboard Web`

## References

- Workspaces page Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=62-3198&t=dBztH5XSYbZ9jPyR-0
- Workspace detail page Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=71-85&t=xHuTHtgkwgQhVAcT-0
- Task tracking panel Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=71-2&t=xHuTHtgkwgQhVAcT-0
- Task detail Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=62-3276&t=dBztH5XSYbZ9jPyR-0

## Problem

Teams using the workflow system manage their project state through YAML files in a management repository. Today there is no visual interface to that state — users must read raw YAML or rely on CLI tools. The goal of the dashboard is to give any team a browser-based view of their workflow: what features exist, where each task stands, and what is blocked or in review.

## Goals

- Let a user connect their management repository to the dashboard and immediately see a live Kanban view of all features and tasks.
- Read and parse workflow YAML directly from the connected repository so the board always reflects the real state of the repo.
- Require no login in v1 — the repository access credential is the only gate.

## Non-goals

- User authentication and accounts are out of scope for v1.
- Adding a second workspace after the initial import is deferred.
- Creating, editing, or deleting features or tasks from the UI is out of scope.
- Kanban drag-and-drop or task status mutations are out of scope.
- Real-time sync (websocket / SSE) is out of scope; sync-on-load and a manual refresh are sufficient.
- AI chat integration is out of scope.
- GitHub Bot Account access is out of scope for v1.

## User Journey

### Journey 1 — Connect a management repository (primary)

1. The user opens the dashboard for the first time. No login is required.
2. The app has no workspace configured yet, so it presents a single prompt: connect a management repository.
3. The user provides:
   - A GitHub repository input that follows the expected repository pattern (for example `org/project-workspace` or `https://github.com/org/project-workspace`).
   - A way for the system to access that repository — see **Repository Access** below.
4. The user submits. The system clones the repository, reads all workflow YAML files, and builds the board state.
5. On success, the system persists the workspace metadata and backend repo cache so the workspace can be opened again without a new import.
6. The user is taken directly to the Kanban board for that workspace.
7. On failure (access denied, clone/sync failure, or no workflow YAML found), the user sees a clear error and can correct their input.

### Journey 1b — Return to an imported workspace

1. The user opens the dashboard after a workspace was already imported.
2. The app loads the existing workspace metadata from the backend.
3. The backend serves the board from the persisted workspace record and cached repository data.
4. The user reaches the Kanban board without re-entering the repository input or PAT.
5. If the cached repository is missing or stale, the UI shows a sync/reconnect action instead of forcing a full re-import.

### Journey 2 — View the workflow board

1. The user is on the Kanban board of their connected workspace.
2. The board shows all features as expandable rows across 7 status columns: `TODO`, `READY`, `IN PROGRESS`, `BLOCKED`, `IN REVIEW`, `DONE`, `CANCELLED`.
3. Each feature row shows its lifecycle status, progress, and can be expanded to reveal individual task cards in their respective status columns.
4. The user can search features and tasks by title, and filter columns by task status.
5. Clicking a task card opens a detail panel showing metadata, PR links, dependencies, blocked reason, and the activity log.

### Journey 3 — Refresh the board

1. The user wants to see the latest state from the repository.
2. They click a `Sync` button on the board.
3. If the PAT is no longer available in the current browser session, the app asks the user to provide it again for this sync.
4. The system re-pulls the repository and re-parses the YAML.
5. The board updates to reflect any changes since the last sync.

### Journey 4 — Review task status from the left panel

1. The user is on the Kanban board of their connected workspace.
2. The left side of the board shows a compact task status panel with three rows: `IN PROGRESS`, `READY`, and `IN REVIEW`.
3. Each row lists tasks whose current task YAML status matches that row.
4. Each task item shows the task title, parent feature name, and a status-aware elapsed time:
   - `IN REVIEW`: how long the task has been done and waiting for review.
   - `READY`: how long the task has been ready.
   - `IN PROGRESS`: how long the task has been in progress.

5. Clicking a task in the left panel opens the same task detail panel used by task cards on the Kanban board.

## Repository Access

V1 uses GitHub Personal Access Token access only.

### GitHub Personal Access Token

The user provides a GitHub PAT with read access to the repository. The system sends the PAT to the backend for import and sync only. The token is not persisted in browser storage or backend durable storage, and it is never returned to the browser.

## Data Read From Repository

The system reads the following from the connected repository:

- `docs/features/<featureId>/status.yaml` — feature title, lifecycle status, current stage.
- `docs/features/<featureId>/tasks/T<n>.yaml` — task title, status, branch, dependencies, blocked reason, execution actor, PR links, and activity log with status transition timestamps.

No other files are read. The system treats the YAML as read-only; it never writes back to the repository.

## API Surface (high level)

| Method | Path                           | Purpose                                         |
| ------ | ------------------------------ | ----------------------------------------------- |
| `GET`  | `/api/workspaces`      | Return the existing imported workspace, if any. |
| `POST` | `/api/workspaces`              | Clone the repo and import workflow YAML.        |
| `GET`  | `/api/workspaces/:workspaceId` | Return one workspace detail record.             |
| `GET`  | `/api/workspaces/:id/features` | Return parsed features and tasks for the board. |
| `POST` | `/api/workspaces/:id/sync`     | Re-pull and re-parse using a transient PAT when needed. |

Detailed request/response contracts are defined in the technical design.

## Acceptance Criteria

- A user with no account can open the dashboard, provide a GitHub repository input and access credential, and reach the Kanban board without any login step.
- After the first successful import, a user can reopen the dashboard and reach the existing board without re-importing or re-entering PAT.
- The board reflects the real YAML state of the repository — no hardcoded or seeded sample data.
- Board access fails with a clear error if the credential cannot access the repository, import/sync fails, or workflow YAML cannot be found.
- The `Sync` button pulls fresh state from the repository and updates the board using the in-memory PAT or a PAT re-entered for that sync.
- The board includes a left-side task status panel with `IN PROGRESS`, `READY`, and `IN REVIEW` rows, and each row contains only tasks matching that status.
- Each left-panel task item shows elapsed time derived from when the task entered its current status: time in progress for `IN PROGRESS`, time since ready for `READY`, and time waiting for review after completion for `IN REVIEW`.
- The connect flow accepts a GitHub PAT as the only v1 repository access method.
- Private repository tokens are used transiently for import/sync only; they are not persisted in browser storage or backend durable storage.
- If the repository contains no recognisable workflow YAML, the board shows an empty state with guidance rather than crashing.
