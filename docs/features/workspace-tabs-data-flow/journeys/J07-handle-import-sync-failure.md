# J07 - Handle import or sync failure

1. The user submits import or refresh.
2. GitHub, adapter validation, database, or timeout handling fails.
3. The backend returns a structured `ApiError` or stale cached data when available.
4. The UI shows the error inline or keeps the stale cached workspace visible with a source-state warning.

**Expected result:** the user can understand the failure without losing usable cached data.
