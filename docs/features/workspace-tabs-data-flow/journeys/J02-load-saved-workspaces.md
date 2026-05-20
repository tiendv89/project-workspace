# J02 - Load saved workspaces

1. The app loads.
2. The UI calls `GET /api/workspaces`.
3. The backend returns saved `WorkspaceSummary[]` records.
4. The UI shows the saved workspace list or an empty state.

**Expected result:** saved workspaces come from the backend API, not from direct GitHub reads or frontend fixtures.
