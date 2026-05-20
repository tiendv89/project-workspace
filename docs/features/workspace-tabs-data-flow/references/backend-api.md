# Frontend API Docs

This document is for frontend integration with `workflow-backend` (`api-service`).
Only call the public endpoints listed below.

## Base URL

The frontend must load the backend API base URL from environment configuration, for example `VITE_API_BASE_URL` or the repo's existing equivalent.

```text
VITE_API_BASE_URL=<workflow-backend-api-base-url>
```

API prefix:

```text
/api
```

There is no auth middleware in the current API. JSON requests should use these headers:

```http
Content-Type: application/json
Accept: application/json
```

## Common response

Success:

```json
{
  "success": true,
  "data": {}
}
```

Error:

```json
{
  "success": false,
  "error": {
    "code": "DATABASE_NOT_FOUND",
    "message": "workspace not found: <id>",
    "retryable": false,
    "path": "/internal/workspaces/<id>/sync",
    "cached_data": null
  }
}
```

`path` and `cached_data` only appear when the backend has that data.

Common HTTP statuses:

| Status | When |
|---|---|
| `200` | Success |
| `400` | Invalid body or query parameter |
| `401` | Invalid GitHub token during import/sync |
| `404` | Workspace/feature/task does not exist |
| `429` | GitHub rate limit |
| `504` | Adapter timeout |
| `500` | Database/adapter error or another server error |

## IDs used in routes

The following route params should use UUIDs returned by the API:

| Param | Get from field |
|---|---|
| `workspaceId` | `workspace.id` |
| `featureId` | `feature.feature_id` |
| `taskId` | `task.task_id` |

`feature_name` and `task_name` are only for display/search and should not be used as route params.

## Pagination and sort

List/search endpoints do not return pagination metadata. The response `data` is an array.

| Param | Default | Notes |
|---|---:|---|
| `page` | `1` | Must be an integer `>= 1` |
| `limit` | `0` | `0` or omitted means unlimited |

Feature sort values:

```text
title_asc
title_desc
status_asc
status_desc
updated_at_asc
updated_at_desc
time_asc
time_desc
createdAt
-createdAt
```

Task sort values:

```text
task_id_asc
task_id_desc
title_asc
title_desc
status_asc
status_desc
repo_asc
repo_desc
updated_at_asc
updated_at_desc
time_asc
time_desc
createdAt
-createdAt
```

Defaults:

| Endpoint type | Default sort |
|---|---|
| Features | `updated_at_desc` |
| Tasks | `task_id_asc` |

The `status` filter supports one or more comma-separated values:

```text
?status=ready
?status=ready,in_progress,blocked
```

## Quick endpoint reference

| Method | Endpoint | Returned data |
|---|---|---|
| `GET` | `/healthz` | Health check |
| `GET` | `/api/workspaces` | `WorkspaceSummary[]` |
| `POST` | `/api/workspaces/import` | `WorkspaceDetail` |
| `GET` | `/api/workspaces/:workspaceId` | `WorkspaceDetail` |
| `POST` | `/api/workspaces/:workspaceId/sync` | `WorkspaceDetail` |
| `GET` | `/api/workspaces/:workspaceId/features` | `FeatureSummary[]` |
| `GET` | `/api/workspaces/:workspaceId/features/:featureId` | `FeatureDetail` |
| `GET` | `/api/workspaces/:workspaceId/tasks` | `TaskSummary[]` |
| `GET` | `/api/workspaces/:workspaceId/tasks/:taskId` | `TaskDetail` |
| `GET` | `/api/workspaces/:workspaceId/features/:featureId/tasks` | `TaskSummary[]` |
| `GET` | `/api/workspaces/:workspaceId/features/:featureId/tasks/:taskId` | `TaskDetail` |
| `GET` | `/api/workspaces/:workspaceId/activity` | `ActivityEvent[]` |

## Endpoint details

### `GET /api/workspaces`

List imported workspaces.

Query params: none.

Example:

```http
GET /api/workspaces
```

Response `data`: `WorkspaceSummary[]`

```json
[
  {
    "id": "workspace-uuid",
    "name": "Project Workspace",
    "slug": "project-workspace",
    "repo_url": "https://github.com/org/repo",
    "source_state": {
      "stale": false,
      "last_synced_at": "2026-05-20T10:00:00Z"
    },
    "updated_at": "2026-05-20T10:00:00Z"
  }
]
```

### `POST /api/workspaces/import`

Import a workspace from the GitHub repo that manages the workflow.

Body:

| Field | Required | Notes |
|---|---|---|
| `repo_url` | yes | GitHub repo URL |
| `default_branch` | no | Branch to import, for example `main` |
| `name` | no | Display name override |

Example:

```http
POST /api/workspaces/import
Content-Type: application/json
```

```json
{
  "repo_url": "https://github.com/org/project-workspace",
  "default_branch": "main",
  "name": "Project Workspace"
}
```

Response `data`: `WorkspaceDetail`

### `GET /api/workspaces/:workspaceId`

Get workspace details, including workspace summary, features, and tasks.

Query params: none.

Example:

```http
GET /api/workspaces/018f7f1c-1234-7000-9000-111111111111
```

Response `data`: `WorkspaceDetail`

### `POST /api/workspaces/:workspaceId/sync`

Trigger a manual sync for the workspace.

Body: no body required.

Example:

```http
POST /api/workspaces/018f7f1c-1234-7000-9000-111111111111/sync
```

Response `data`: `WorkspaceDetail`

If sync fails but the database still has cached data, the backend may return `success: true` with `data.source_state.stale = true`. The frontend should still display the old data and show the stale state if needed.

### `GET /api/workspaces/:workspaceId/features`

Search/list features in a workspace.

Query params:

| Param | Notes |
|---|---|
| `title` | Case-insensitive contains search by title |
| `status` | Exact status, supports CSV |
| `sort` | One of the feature sort values |
| `page` | Integer `>= 1` |
| `limit` | Integer `>= 0` |

Examples:

```http
GET /api/workspaces/:workspaceId/features
GET /api/workspaces/:workspaceId/features?title=data&status=ready,in_progress&sort=updated_at_desc&limit=20
```

Response `data`: `FeatureSummary[]`

### `GET /api/workspaces/:workspaceId/features/:featureId`

Get details for a feature: summary, documents, tasks, activity, and source state.

Query params: none.

Example:

```http
GET /api/workspaces/:workspaceId/features/:featureId
```

Response `data`: `FeatureDetail`

### `GET /api/workspaces/:workspaceId/tasks`

Search/list all tasks in a workspace without knowing the feature first.

Query params:

| Param | Notes |
|---|---|
| `task_id` | Contains search by `task_name`, for example `T1` |
| `title` | Case-insensitive contains search by title |
| `status` | Exact status, supports CSV |
| `repo` | Exact repo id/name stored in the task |
| `sort` | One of the task sort values |
| `page` | Integer `>= 1` |
| `limit` | Integer `>= 0` |

Examples:

```http
GET /api/workspaces/:workspaceId/tasks
GET /api/workspaces/:workspaceId/tasks?status=ready,in_progress&repo=workflow-backend&sort=task_id_asc
GET /api/workspaces/:workspaceId/tasks?task_id=T1&limit=10
```

Response `data`: `TaskSummary[]`

### `GET /api/workspaces/:workspaceId/tasks/:taskId`

Get task details when the frontend only knows `workspaceId` and `taskId`.

Query params: none.

Example:

```http
GET /api/workspaces/:workspaceId/tasks/:taskId
```

Response `data`: `TaskDetail`

### `GET /api/workspaces/:workspaceId/features/:featureId/tasks`

Search/list tasks in a feature.

Query params are the same as `GET /api/workspaces/:workspaceId/tasks`:

| Param | Notes |
|---|---|
| `task_id` | Contains search by `task_name`, for example `T1` |
| `title` | Case-insensitive contains search by title |
| `status` | Exact status, supports CSV |
| `repo` | Exact repo id/name stored in the task |
| `sort` | One of the task sort values |
| `page` | Integer `>= 1` |
| `limit` | Integer `>= 0` |

Example:

```http
GET /api/workspaces/:workspaceId/features/:featureId/tasks?status=ready&sort=task_id_asc
```

Response `data`: `TaskSummary[]`

### `GET /api/workspaces/:workspaceId/features/:featureId/tasks/:taskId`

Get task details when the frontend is in the feature detail context.

Query params: none.

Example:

```http
GET /api/workspaces/:workspaceId/features/:featureId/tasks/:taskId
```

Response `data`: `TaskDetail`

### `GET /api/workspaces/:workspaceId/activity`

Get the workspace activity timeline, optionally filtered by feature/task.

Query params:

| Param | Notes |
|---|---|
| `featureId` | Feature UUID, optional |
| `taskId` | Task UUID, optional |

Examples:

```http
GET /api/workspaces/:workspaceId/activity
GET /api/workspaces/:workspaceId/activity?featureId=:featureId
GET /api/workspaces/:workspaceId/activity?taskId=:taskId
GET /api/workspaces/:workspaceId/activity?featureId=:featureId&taskId=:taskId
```

Response `data`: `ActivityEvent[]`

## Main data models

### `WorkspaceSummary`

```json
{
  "id": "workspace-uuid",
  "name": "Project Workspace",
  "slug": "project-workspace",
  "repo_url": "https://github.com/org/repo",
  "source_state": {
    "stale": false,
    "last_synced_at": "2026-05-20T10:00:00Z"
  },
  "updated_at": "2026-05-20T10:00:00Z"
}
```

### `WorkspaceDetail`

```json
{
  "id": "workspace-uuid",
  "name": "Project Workspace",
  "slug": "project-workspace",
  "repo_url": "https://github.com/org/repo",
  "source_state": {
    "stale": false,
    "last_synced_at": "2026-05-20T10:00:00Z"
  },
  "updated_at": "2026-05-20T10:00:00Z",
  "features": [],
  "tasks": []
}
```

### `FeatureSummary`

```json
{
  "id": "row-uuid",
  "feature_id": "feature-uuid",
  "feature_name": "workspace-data-backend",
  "title": "Workspace data backend",
  "status": "ready",
  "current_stage": "tasks",
  "stages": [],
  "updated_at": "2026-05-20T10:00:00Z",
  "task_counts": {
    "total": 7,
    "done": 2,
    "in_progress": 1,
    "blocked": 0,
    "ready": 3,
    "todo": 1
  }
}
```

### `FeatureDetail`

```json
{
  "id": "row-uuid",
  "feature_id": "feature-uuid",
  "feature_name": "workspace-data-backend",
  "title": "Workspace data backend",
  "status": "ready",
  "current_stage": "tasks",
  "stages": [],
  "updated_at": "2026-05-20T10:00:00Z",
  "task_counts": {
    "total": 7,
    "done": 2,
    "in_progress": 1,
    "blocked": 0,
    "ready": 3,
    "todo": 1
  },
  "workspace_id": "workspace-uuid",
  "documents": [
    {
      "document_type": "technical-design",
      "source_path": "docs/features/workspace-data-backend/technical-design.md",
      "url": "https://github.com/org/repo/blob/main/docs/features/..."
    }
  ],
  "tasks": [],
  "activity": [],
  "source_state": {
    "stale": false
  }
}
```

### `TaskSummary`

```json
{
  "id": "row-uuid",
  "task_id": "task-uuid",
  "task_name": "T1",
  "feature_id": "feature-uuid",
  "feature_name": "workspace-data-backend",
  "title": "Implement reader API",
  "status": "in_progress",
  "repo": "workflow-backend",
  "branch": "feature/workspace-data-backend-T1",
  "is_blocked": false,
  "pr": null,
  "workspace_pr": null
}
```

### `TaskDetail`

```json
{
  "id": "row-uuid",
  "task_id": "task-uuid",
  "task_name": "T1",
  "feature_id": "feature-uuid",
  "feature_name": "workspace-data-backend",
  "title": "Implement reader API",
  "status": "in_progress",
  "repo": "workflow-backend",
  "branch": "feature/workspace-data-backend-T1",
  "next_action": "",
  "is_blocked": false,
  "blocked_reason": "",
  "workspace_id": "workspace-uuid",
  "depends_on": [],
  "execution": {
    "actor_type": "codex",
    "last_updated_by": "codex",
    "last_updated_at": "2026-05-20T10:00:00Z"
  },
  "pr_refs": [
    {
      "label": "workflow-backend",
      "url": "https://github.com/org/workflow-backend/pull/3",
      "status": "open",
      "repo": "workflow-backend"
    }
  ],
  "activity": []
}
```

### `ActivityEvent`

```json
{
  "action": "status_changed",
  "scope": "task",
  "actor": "codex",
  "occurred_at": "2026-05-20T10:00:00Z",
  "note": "moved to ready",
  "feature_id": "feature-uuid",
  "task_id": "task-uuid"
}
```

## Suggested frontend flows

Load workspace dashboard:

```text
GET /api/workspaces
GET /api/workspaces/:workspaceId
```

Load feature board with filters:

```text
GET /api/workspaces/:workspaceId/features?status=ready,in_progress&sort=updated_at_desc
GET /api/workspaces/:workspaceId/tasks?status=ready,in_progress&sort=task_id_asc
```

Open feature details:

```text
GET /api/workspaces/:workspaceId/features/:featureId
```

Open task details:

```text
GET /api/workspaces/:workspaceId/tasks/:taskId
```

Refresh data from GitHub:

```text
POST /api/workspaces/:workspaceId/sync
```
