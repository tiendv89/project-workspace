# J24 - Open a task from a feature tab

1. The user is inside a feature tab.
2. The user opens the feature Tasks view.
3. The user selects a task.
4. The app opens or focuses the corresponding task tab.
5. When the UI already knows the feature UUID, task detail can load through `GET /api/workspaces/:workspaceId/features/:featureId/tasks/:taskId`.
6. Back from that task returns to the originating feature tab when possible.

**Expected result:** the user can drill down from feature context into task context and return cleanly.
