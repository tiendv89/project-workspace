# J04 — Search and select a saved workspace

1. The user opens the workspace switcher.
2. The user searches for a workspace.
3. The app filters the saved workspace list.
4. If there is no match, the app shows an empty state.
5. The user selects a workspace from the results.
6. The app asks the backend for that workspace detail.
7. The app switches to that workspace and returns to the board view.
8. Task and feature tabs from the previous workspace are not shown in the newly selected workspace.

**Expected result:** workspace switching is fast and does not leak tabs or context from another workspace.
