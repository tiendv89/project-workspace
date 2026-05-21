# J13 - Use task items from the sidebar

1. The user is on the workspace board where the sidebar is visible.
2. The sidebar loads its own active task list from `GET /api/workspaces/:workspaceId/tasks?status=in_progress,in_review,ready&sort=task_id_asc&page=1&limit=50`.
3. The sidebar does not derive its items from workspace detail, Task Mode search, feature detail, or task detail data.
4. The user single-clicks a sidebar task item to inspect it quickly.
5. The user double-clicks a sidebar task item to open or focus its task tab.
6. The user can also open a task tab from the sidebar task context menu.

**Expected result:** sidebar task items show only `in_progress`, `in_review`, and `ready` tasks from the independent workspace task-list query, then follow the same interaction behavior as task cards on the board.
