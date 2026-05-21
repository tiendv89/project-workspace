# J11 - Open a task tab from the board

1. The user is on the workspace board.
2. The user double-clicks a task.
3. The app opens or focuses a task tab.
4. The task tab loads `GET /api/workspaces/:workspaceId/tasks/:taskId`.
5. The user can return to the board by clicking the workspace tab.

**Expected result:** double click starts or restores a persistent task work session backed by backend task detail.
