# Product Specification

## Feature

- Feature ID: `tasks-api-integration`
- Title: Feature Tasks API Integration
- Implementation repos: `workflow-backend`, `digital-factory-ui`
- Backend GitHub: https://github.com/tiendv89/workflow-backend
- Frontend GitHub: https://github.com/tiendv89/digital-factory-ui

## Problem

`digital-factory-ui` Task Mode on the kanban board needs feature context and
the related task data from the backend in one response. Today that integration
requires separate assumptions about feature and task data, and the combined task
items must include `updated_at` so the UI can rely on backend-provided freshness
data.

The current Task Mode tasks API on `workflow-backend-api.kitelabs.io` is missing
`updated_at` and must return that field on each task item:
`GET /api/workspaces/524e02c9-26ad-49c3-8303-3542859cfce3/tasks` with
`status=blocked,in_progress,reviewing,in_review,ready`, `sort=task_id_asc`,
`page=1`, and `limit=50`.

## Goals

- Add a backend API response that returns one feature and its related tasks in
  the same payload.
- Ensure every task item returned by the combined response includes
  `updated_at`.
- Ensure the current Task Mode tasks API on `workflow-backend-api.kitelabs.io`
  returns `updated_at` on every task item for
  `GET /api/workspaces/524e02c9-26ad-49c3-8303-3542859cfce3/tasks` with
  `status=blocked,in_progress,reviewing,in_review,ready`, `sort=task_id_asc`,
  `page=1`, and `limit=50`.
- Integrate `digital-factory-ui` Task Mode on the kanban board with the backend
  response for the feature and task data it needs.
- Preserve existing feature and task list behavior outside the new combined
  response.

## Non-goals

- No broad redesign of the Digital Factory UI.
- No unrelated backend endpoint or schema cleanup.
- No change to task lifecycle semantics.
- No frontend workaround that fabricates `updated_at` when the combined
  response does not provide it.

## Product Requirements

- The backend must provide a combined feature-and-tasks response for a single
  feature.
- The combined response must include the requested feature data and the related
  task items required by Task Mode.
- Every task item in the combined response must include `updated_at`.
- The existing Task Mode tasks API response for
  `/api/workspaces/:workspaceId/tasks?status=blocked,in_progress,reviewing,in_review,ready&sort=task_id_asc&page=1&limit=50`
  must include `updated_at` on every returned task item.
- `digital-factory-ui` Task Mode on the kanban board must consume the combined
  response for the feature context and task data it renders.
- Existing feature list and task list behavior must continue to work outside
  the new combined response.

## Acceptance Criteria

- The backend can return one feature and its related tasks in the same payload.
- Every task item in that combined payload includes `updated_at`.
- The existing Task Mode tasks API returns `updated_at` on every task item for
  the documented kanban query.
- Task Mode on the kanban board renders from the combined backend response for
  the feature and task data it needs.
- Existing feature and task list flows keep their current behavior outside the
  new combined response.
