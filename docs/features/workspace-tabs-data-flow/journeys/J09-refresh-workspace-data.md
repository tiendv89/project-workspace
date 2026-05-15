# J09 — Refresh workspace data

1. The user is viewing a workspace.
2. The user triggers a manual refresh.
3. The backend re-syncs from GitHub into the database mirror.
4. The UI updates board, task tab, and feature tab data from the backend response.
5. If sync fails but cached data exists, the UI keeps cached data visible and marks it stale.

**Expected result:** the user can see updated source data while retaining a usable cached workspace when refresh fails.
