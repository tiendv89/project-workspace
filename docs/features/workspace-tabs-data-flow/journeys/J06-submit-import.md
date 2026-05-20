# J06 - Submit an imported workspace

1. The user provides `repo_url` plus optional `default_branch` and `name`.
2. The user submits the import form.
3. The UI sends `POST /api/workspaces/import`.
4. The backend returns `WorkspaceDetail` on `200 OK`.
5. The UI navigates to the returned workspace detail.

**Expected result:** import is handled by the backend API, and the UI does not parse GitHub files directly.
