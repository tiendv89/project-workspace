# J04 - Search and select a saved workspace

1. The user opens the workspace switcher.
2. The user searches for a workspace.
3. The app filters the loaded `WorkspaceSummary[]` list.
4. If there is no match, the app shows an empty state.
5. The user selects a workspace from the results.
6. The UI loads `GET /api/workspaces/:workspaceId`.
7. The app switches to that workspace and returns to the board view.
8. Tabs from the previous workspace are hidden or cleared.

**Expected result:** workspace switching is fast and does not leak tabs or context from another workspace.
