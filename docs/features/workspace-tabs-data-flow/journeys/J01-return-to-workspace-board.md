# J01 - Return to the workspace board

1. The user is viewing a task tab or feature tab for the current workspace.
2. The user clicks the workspace tab.
3. The UI returns to the board view backed by `GET /api/workspaces/:workspaceId`.
4. Open task and feature tabs remain available for that workspace.

**Expected result:** the user can get back to the board without losing open work item sessions.
