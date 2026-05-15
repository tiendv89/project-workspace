# J07 — Handle import or sync failure

1. The user submits import or refresh.
2. GitHub or adapter validation fails.
3. The UI keeps the current page stable.
4. The app shows a source-specific but user-readable error.
5. The user edits the input or retries.

**Expected result:** users can recover from source failures without losing the current workspace state.
