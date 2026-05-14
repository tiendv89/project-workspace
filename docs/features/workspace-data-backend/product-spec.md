# Product Specification

## Feature

- Feature ID: `workspace-data-backend`
- Title: `Workspace Data Backend — GitHub Sync and Read API`

## Problem

The dashboard UI reads workspace, feature, and task data directly from the GitHub API on every page load. As more features and tasks are added, this becomes too slow and too fragile — a single GitHub API failure breaks the entire board, and nothing persists when the browser session ends.

GitHub still owns writes for task state (claims, transitions, approvals). That will remain unchanged — the `workflow-db` feature handles the longer-term agent write-path migration. The gap this feature addresses is on the read side: there is no server-backed store that mirrors workspace records and serves them reliably to the UI.

Users need the dashboard to load workspace data across sessions and devices without re-entering repository credentials every time. When a GitHub sync fails, users should still see the last known state rather than a blank screen.

## Dependencies

- **`workflow-db`** — provides the relational database that this feature writes workspace snapshots into. The workspace sync and cache layer builds on top of the same database infrastructure.

## Goals

- Mirror GitHub workspace data (features, tasks, documents, activity) to a server-backed database after import or sync.
- Provide stable backend read APIs for workspace list, workspace detail, feature detail, task detail, source documents, and activity.
- Let users save a workspace once and reopen it across sessions and devices without re-importing.
- Serve stale cached data when a GitHub sync fails, rather than returning an error that blanks the board.
- Return clear, machine-readable source errors with a user-readable message and retryability hint.

## Non-goals

- No UI changes — interface work is in `workspace-tabs-data-flow`.
- No agent write path — task claims, status transitions, and approvals remain in GitHub for now. Write-path migration is `workflow-db`.
- No workflow lifecycle changes — feature stages, approval gates, and task YAML ownership are unchanged.
- No agent, chat, model, or conversation controls.

## Acceptance Criteria

- Backend APIs expose workspace list, workspace detail, feature detail, task detail, source documents, and activity data.
- GitHub adapter can import a workspace repository and store a normalized snapshot in the database.
- GitHub adapter can sync an existing saved workspace and update the snapshot on success.
- Saved workspaces persist across browser sessions — returning users reopen a workspace without re-entering repository credentials.
- When a GitHub sync fails and a cached snapshot exists, the backend returns cached data marked as stale.
- When a sync fails and no cache exists, the backend returns a structured error.
- GitHub remains the sole writer for task state. The database layer stores read-only mirrors only.
- Source errors include a machine-readable code, user-readable message, source kind, and retryability hint.
