# Tasks - tasks-api-integration

> Feature status: `ready_for_implementation` - stage status: `tasks` (`approved`; T1 is ready, T2-T5 remain dependency-blocked). Machine state lives in `tasks/T<n>.yaml`; this file is the narrative task breakdown only.

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | Add updated_at to existing tasks API | none |
| T2 | 2 | Add feature-task response with feature pagination | T1 |
| T3 | 3 | Add feature-task query client and TanStack cache | T2 |
| T4 | 4 | Wire Task Mode kanban to feature-task API | T3 |
| T5 | 5 | Regression and browser/network QA | T4 |

## T1 — Add updated_at to existing tasks API

### Description
Update `workflow-backend` so the existing
`GET /api/workspaces/:workspaceId/tasks` response includes `updated_at` on every
task item while preserving the endpoint's current Task Mode filtering, sorting,
and pagination behavior.

### Required skills
- backend-engineer
- go-best-practices

### Subtasks
- [ ] Locate the task list handler, DTO, and serializer used by `/api/workspaces/:workspaceId/tasks`.
- [ ] Add `updated_at` to the task item response without changing existing field names or pagination shape.
- [ ] Verify the known Task Mode query returns `updated_at`: `status=blocked,in_progress,reviewing,in_review,ready`, `sort=task_id_asc`, `page=1`, `limit=50`.
- [ ] Preserve existing `status`, `title`, `query`, `page`, `limit`, and `sort` behavior.
- [ ] Add backend tests proving every task item in the `/tasks` response includes `updated_at`.
- [ ] Run the focused backend test suite for the tasks endpoint.

## T2 — Add feature-task response with feature pagination

### Description
Extend `workflow-backend` `GET /api/workspaces/:workspaceId/features?include=tasks`
so Task Mode can request feature context and embedded task rows in one payload.
The endpoint must support task status filtering, title/query search, task sort,
and feature-list pagination through `data.page`, `data.limit`, and
`data.total`. `page` and `limit` apply to `data.features[]`; each returned
feature row includes its `tasks[]`.

### Required skills
- backend-engineer
- go-best-practices

### Subtasks
- [ ] Locate the workspace feature collection handler and current `include=tasks` implementation.
- [ ] Add task query parsing for `include=tasks`, `status`, `title`, `query`, `page`, `limit`, and `sort`.
- [ ] Ensure `status` accepts comma-separated task statuses such as `blocked,in_progress,reviewing,in_review,ready`.
- [ ] Apply `status`, `title`, and `query` filters to task rows before grouping them under feature rows.
- [ ] Apply `sort=task_id_asc` to embedded task rows.
- [ ] Apply `page` and `limit` to the feature rows returned in `data.features[]`; for example, `limit=10` returns up to 10 feature rows with their embedded tasks.
- [ ] Ensure every embedded task item includes `id`, `task_id`, `task_name`, `feature_id`, `feature_name`, `title`, `status`, `repo`, `branch`, `is_blocked`, `pr`, `workspace_pr`, and `updated_at`.
- [ ] Return `tasks: []` for feature rows with no matching tasks when `include=tasks` is present.
- [ ] Preserve feature list behavior when `include=tasks` is absent.
- [ ] Preserve existing feature context fields, `task_counts` and `stages`.
- [ ] Return `page`, `limit`, and `total` at `data` level so the frontend can page feature rows.
- [ ] Do not return `task_page` or `has_more` in the new response.
- [ ] Add backend tests for `include=tasks` filtering, search, pagination, sorting, and `updated_at`.
- [ ] Add compatibility tests proving normal feature list calls still pass.

## T3 — Add feature-task query client and TanStack cache

### Description
Add the `digital-factory-ui` API client, types, query keys, and TanStack Query
hook for the new Task Mode feature-task endpoint. The hook must call
`GET /api/workspaces/:workspaceId/features?include=tasks` and cache each
workspace/query state for 60 seconds while refetching every 60 seconds.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Add or update DTOs for workspace feature-task responses, feature rows, embedded tasks, and pagination metadata.
- [ ] Add a request builder for `GET /api/workspaces/:workspaceId/features?include=tasks`.
- [ ] Support `status`, `title`, `query`, `page`, `limit`, and `sort` params in the request builder.
- [ ] Normalize status CSV, search params, pagination params, and sort params before they enter query keys.
- [ ] Add a Task Mode feature-task query key scoped by workspace ID and normalized params.
- [ ] Add a TanStack Query hook with `staleTime: 60_000`, `refetchInterval: 60_000`, and 60-second cache behavior through `gcTime` or `cacheTime`.
- [ ] Ensure frontend DTOs require embedded task `updated_at` and feature-list pagination metadata at `data.page`, `data.limit`, and `data.total`.
- [ ] Ensure frontend DTOs do not require or read `task_page` or `has_more`.
- [ ] Preserve existing frontend API error parsing and retry behavior.
- [ ] Add frontend tests for request construction, query key construction, and cache/refetch configuration.

## T4 — Wire Task Mode kanban to feature-task API

### Description
Migrate `digital-factory-ui` Task Mode on the kanban board to consume the new
feature-task query hook for feature context, task rows, search, filters, and
pagination. Existing loading, empty, error, and list behavior must remain
consistent while the data source changes.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Identify the current Task Mode kanban data-loading path and UI state owners.
- [ ] Replace the Task Mode board data source with the feature-task query hook.
- [ ] Map Task Mode status filters to the backend `status` query param.
- [ ] Map title/search controls to `title` and/or `query` params per the backend contract.
- [ ] Map pagination controls to `page` and `limit`.
- [ ] Keep `sort=task_id_asc` for the Task Mode board unless the current UI explicitly selects another sort.
- [ ] Render feature context from the response's feature rows.
- [ ] Render task rows from `features[].tasks[]` and use backend-provided `updated_at`.
- [ ] Read feature-list pagination state from `data.page`, `data.limit`, and `data.total`.
- [ ] Preserve existing loading, empty, and error states.
- [ ] Ensure Feature Mode and existing task list flows outside the new combined response still work.
- [ ] Do not use `task_page` or `has_more` for Task Mode pagination.
- [ ] Add render tests for status filtering, search, pagination, and displayed `updated_at`.

## T5 — Regression and browser/network QA

### Description
Verify the backend/frontend integration from the `digital-factory-ui` side after
Task Mode is wired to the new API. This task proves the correct endpoint and
query params are used, the 60-second TanStack Query behavior is active, and
existing list flows still behave correctly.

### Required skills
- browser-qa-frontend
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Add regression coverage proving Task Mode calls `GET /api/workspaces/:workspaceId/features?include=tasks`.
- [ ] Verify Task Mode includes `status`, `title` or `query`, `page`, `limit`, and `sort=task_id_asc` when those controls are active.
- [ ] Verify Task Mode reads `updated_at` from embedded backend task items.
- [ ] Verify Task Mode reads feature-list pagination metadata from `data.page`, `data.limit`, and `data.total`.
- [ ] Verify Task Mode does not expect `task_page` or `has_more`.
- [ ] Verify TanStack Query uses a 60-second cache window and `refetchInterval: 60_000`.
- [ ] Verify existing Feature Mode list behavior does not switch to the combined response unintentionally.
- [ ] Verify the existing `/tasks` response still works for consumers and includes `updated_at`.
- [ ] Run browser/network QA against a backend environment where T1 and T2 are deployed.
- [ ] Document any backend deployment dependency or live API mismatch found during QA.
