# Product Specification

## Feature

- Feature ID: `dashboard`
- Title: `Workflow Dashboard Web`

## References

- Workspaces page Figma: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=62-3198&m=dev
- Workspace detail page Figma: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=98-2&m=dev
- Task tracking panel Figma: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=71-2&m=dev
- Task detail Figma: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=62-3449&m=dev

## Problem

Teams using the workflow system manage their project state through YAML files in a management repository. Today there is no visual interface to that state — users must read raw YAML or rely on CLI tools. The goal of the dashboard is to give any team a browser-based view of their workflow: what features exist, where each task stands, and what is blocked or in review.

This is an alpha-stage MVP. Simplicity and speed to value are priorities over infrastructure correctness. No backend server is required or introduced in v1.

## Goals

- Let a user connect their management repository to the dashboard and immediately see a live Kanban view of all features and tasks.
- Read and parse workflow YAML directly from the GitHub Contents API — called from the browser, no backend server required.
- Support both public repositories (no credential) and private repositories (GitHub Personal Access Token).
- Persist workspace identity and PAT in `localStorage` so a returning user never needs to re-import or re-enter credentials.
- Deliver a read-only alpha overview; task mutation, account management, and server-side sync infrastructure are deferred.

## Non-goals

- No backend server is required or designed in this spec.
- User authentication and accounts are out of scope for v1.
- Adding a second workspace after the initial import is deferred.
- Creating, editing, or deleting features or tasks from the UI is out of scope.
- Kanban drag-and-drop or task status mutations are out of scope.
- Real-time sync (websocket / SSE) is out of scope; sync-on-load and a manual refresh are sufficient.
- AI chat integration is out of scope.
- GitLab and Bitbucket repository access are out of scope for v1; only GitHub repositories are supported.
- Secure server-side token storage is out of scope; the PAT is stored in `localStorage` as an accepted tradeoff for this internal alpha.

## User Journey

### Journey 1 — Connect a management repository (primary)

1. The user opens the dashboard for the first time. No login is required.
2. The app has no workspace configured yet, so it presents a single prompt: connect a management repository.
3. The user provides:
   - A GitHub repository identifier — `owner/repo` or a full `https://github.com/owner/repo` URL.
   - For private repositories: a GitHub Personal Access Token with read access.
4. The user submits. The app calls the GitHub Contents API directly from the browser to read workflow YAML and builds the board state.
5. On success, the app stores the repository identity and PAT (if provided) in `localStorage` keyed by workspace ID.
6. The user is taken directly to the Kanban board for that workspace.
7. On failure (access denied, invalid PAT, or no workflow YAML found), the user sees a clear error and can correct their input.

### Journey 1b — Return to an imported workspace

1. The user opens the dashboard in the same browser after a workspace was previously imported.
2. The app reads the workspace identity and, for private repositories, the stored PAT from `localStorage`.
3. Board data loads immediately — no re-entry required.

### Journey 2 — View the workflow board

1. The user is on the Kanban board of their connected workspace.
2. The board shows all features as expandable rows across 7 status columns: `TODO`, `READY`, `IN PROGRESS`, `BLOCKED`, `IN REVIEW`, `DONE`, `CANCELLED`.
3. Each feature row shows its lifecycle status, progress, and can be expanded to reveal individual task cards in their respective status columns.
4. The user can search features and tasks by title, and filter columns by task status.
5. Clicking a task card opens a detail panel showing metadata, PR links, dependencies, blocked reason, and the activity log.

### Journey 3 — Refresh the board

1. The user wants to see the latest state from the repository.
2. They click a `Sync` button on the board.
3. The app re-fetches the GitHub Contents API using the stored PAT from `localStorage` (or unauthenticated for public repos).
4. The board updates to reflect any changes since the last load.

### Journey 4 — Review task status from the left panel

1. The user is on the Kanban board.
2. The left side of the board shows a compact task status panel with three rows: `IN PROGRESS`, `READY`, and `IN REVIEW`.
3. Each row lists tasks whose current YAML status matches that row.
4. Each task item shows the task title, parent feature name, and a status-aware elapsed time:
   - `IN PROGRESS`: how long the task has been in progress.
   - `READY`: how long the task has been ready and waiting to be claimed.
   - `IN REVIEW`: how long the task has been waiting for review since it was submitted.
5. Clicking a task in the left panel opens the same task detail panel used by task cards on the Kanban board.

## Repository Access

V1 reads repository data from the browser using the GitHub Contents API (`https://api.github.com`). No backend proxy is involved.

### Public repositories

No credential is required. The app calls the GitHub Contents API unauthenticated.

### Private repositories

The user provides a GitHub Personal Access Token (classic `ghp_` or fine-grained `github_pat_`) with read access to the repository. The PAT is:

- Passed directly from the browser to the GitHub Contents API as a `Bearer` token in the `Authorization` header.
- Stored in `localStorage` keyed by workspace ID after a successful import, so the user never needs to re-enter it.
- Never sent to any backend server.

This is an internal alpha tool; durable local PAT storage is an acceptable tradeoff for simplicity.

## Data Read From Repository

The app reads the following from the connected repository via the GitHub Contents API:

- `docs/features/` — directory listing to discover all feature IDs.
- `docs/features/<featureId>/status.yaml` — feature title, lifecycle status, current stage.
- `docs/features/<featureId>/tasks/` — directory listing to discover all task files for a feature.
- `docs/features/<featureId>/tasks/T<n>.yaml` — task status, branch, dependencies, blocked reason, execution actor, PR links, and activity log with status transition timestamps.

No other files are read. The app treats all YAML as read-only and never writes back to the repository.

## Acceptance Criteria

- A user with no account can open the dashboard, provide a GitHub repository identifier and optional PAT, and reach the Kanban board without any login step.
- Public repositories load without a PAT. Private repositories require a PAT.
- After the first successful import, a user can reopen the dashboard and the board loads immediately — workspace identity and PAT are both restored from `localStorage` without re-entry.
- The board reflects the real YAML state of the repository — no hardcoded or seeded sample data.
- Board access fails with a clear error if the repository cannot be accessed, the PAT is invalid, or no workflow YAML is found under `docs/features/`.
- The `Sync` button re-fetches data from the GitHub Contents API using the stored PAT from `localStorage` and updates the board.
- The board includes a left-side task status panel with `IN PROGRESS`, `READY`, and `IN REVIEW` rows; each row contains only tasks matching that status.
- Each left-panel task item shows elapsed time derived from when the task last entered its current status.
- Private repository PATs are stored in `localStorage` keyed by workspace ID and never sent to any backend.
- If the repository contains no recognisable workflow YAML under `docs/features/`, the board shows an empty state with guidance rather than crashing.
