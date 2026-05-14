# J06 — Submit an imported workspace

1. The user provides a GitHub repository URL and access token when required.
2. The user submits the import form.
3. The UI sends the import request to the backend.
4. The backend reads the GitHub repository and syncs features, tasks, and documents into the database mirror.
5. The app adds the workspace to the saved workspace list and opens it.

**Expected result:** import creates a database-mirrored workspace. The UI does not parse any GitHub files directly.
