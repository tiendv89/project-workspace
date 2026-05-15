# J02 — Load saved workspaces

1. The user opens the dashboard.
2. The UI asks the backend for saved workspaces.
3. The backend reads the database mirror and returns workspace summaries.
4. The UI shows the saved workspace list and marks the active workspace when one exists.

**Expected result:** saved workspaces load from the backend mirror, not from direct GitHub reads or hardcoded frontend fixtures.
