# Technical Design

## Feature

- Feature ID: `tasks-api-integration`
- Title: Feature Tasks API Integration
- Implementation repos: `workflow-backend`, `digital-factory-ui`

## 1. Current State

`digital-factory-ui` Task Mode currently depends on task data from
`workflow-backend`, but it does not have one backend response that carries both
feature context and the related task rows needed by the kanban board.

Existing backend endpoint used by Task Mode:

```text
GET /api/workspaces/:workspaceId/tasks
```

Known Task Mode request:

```text
GET /api/workspaces/524e02c9-26ad-49c3-8303-3542859cfce3/tasks?status=blocked,in_progress,reviewing,in_review,ready&sort=task_id_asc&page=1&limit=50
```

Current gap:

- The existing `/tasks` endpoint already supports Task Mode filtering, sorting,
  and pagination.
- The existing `/tasks` response is missing `updated_at` on returned task
  items.
- That endpoint must keep its current envelope and behavior. The only required
  response change is adding `updated_at` to each returned task item.

Existing feature collection endpoint to extend:

```text
GET /api/workspaces/:workspaceId/features
```

Current constraint:

- Calls without `include=tasks` must keep the current feature list behavior.
- The new Task Mode behavior is enabled only by `include=tasks`.
- The response must keep the existing top-level workspace/feature collection
  envelope: `success`, `data`, and `data.features[]`.

Repository boundaries:

- `workflow-backend` owns both API response changes.
- `digital-factory-ui` owns the Task Mode query/client integration and kanban
  rendering changes.
- Each implementation task changes one repository only.

## 2. Problem Framing

Two backend contracts must be implemented.

1. Existing task list compatibility contract:
   `GET /api/workspaces/:workspaceId/tasks` must return `updated_at` on every
   task item while preserving existing query params, pagination, sorting, and
   response envelope.
2. New feature-task Task Mode contract:
   `GET /api/workspaces/:workspaceId/features?include=tasks` must return
   workspace feature rows with embedded task rows. It must accept Task Mode
   task query params for `status`, `title`, `query`, `page`, `limit`, and
   `sort`.

Fixed decisions:

- The Task Mode combined read uses the feature collection route:
  `GET /api/workspaces/:workspaceId/features?include=tasks`.
- `include=tasks` is required for embedded `features[].tasks[]`.
- `page` and `limit` on this endpoint paginate `data.features[]`. Example:
  `page=1&limit=10` returns up to 10 feature rows, and each returned feature row
  includes its matching `tasks[]`.
- `task_counts` and `stages` remain feature summary fields. They
  describe the feature as a whole and are not filtered by the Task Mode task
  query.
- Backend applies `status`, `title`, `query`, and `sort` to the task rows used
  for Task Mode, groups matching tasks under their parent feature, then applies
  `page` and `limit` to the feature rows returned in `data.features[]`.
- Every embedded task item must include `updated_at`.
- Embedded task rows must return these fields: `id`, `task_id`, `feature_id`,
  `task_name`, `feature_name`, `title`, `status`, `repo`, `branch`,
  `is_blocked`, `pr`, `workspace_pr`, and `updated_at`.
- Frontend data fetching uses TanStack Query with a 60-second cache window and
  `refetchInterval: 60_000`.

## 3. API Contract

### 3.1 Existing Tasks API Change

Endpoint:

```text
GET /api/workspaces/:workspaceId/tasks
```

Input params:

| Input | Required | Required behavior |
|---|---:|---|
| `workspaceId` path param | yes | Existing workspace ID resolution and authorization rules apply. |
| `status` | no | Preserve existing comma-separated status filtering. Must support the known Task Mode value `blocked,in_progress,reviewing,in_review,ready`. |
| `title` | no | Preserve existing title search behavior. |
| `query` | no | Preserve existing general search behavior. |
| `sort` | no | Preserve existing sorting behavior. Known Task Mode value is `task_id_asc`. |
| `page` | no | Preserve existing pagination behavior. Known Task Mode value is `1`. |
| `limit` | no | Preserve existing pagination behavior. Known Task Mode value is `50`. |

Response rule:

- Do not change the existing top-level `/tasks` response envelope.
- Do not rename existing task fields.
- Do not remove existing task fields.
- Add `updated_at` to every task object returned by the existing task list.

Required task item shape after the change:

```json
{
  "id": "49adb018-692d-4ebf-a568-2178547a6e4e",
  "task_id": "49adb018-692d-4ebf-a568-2178547a6e4e",
  "task_name": "T1",
  "feature_id": "44980262-3463-498e-968f-d356ec416dc9",
  "feature_name": "feature-status-dashboard-v2",
  "title": "v1 archive + v2 scaffold",
  "status": "in_review",
  "repo": "digital-factory-ui",
  "branch": "feature/feature-status-dashboard-v2-T1",
  "is_blocked": false,
  "pr": {
    "url": "https://github.com/tiendv89/digital-factory-ui/pull/7",
    "status": "merged"
  },
  "workspace_pr": {
    "url": "https://github.com/tiendv89/project-workspace/pull/58",
    "status": "open"
  },
  "updated_at": "2026-05-29T11:59:28.33912Z"
}
```

Minimum required fields for every returned `/tasks` item:

- `id`
- `task_id`
- `task_name`
- `feature_id`
- `feature_name`
- `title`
- `status`
- `repo`
- `branch`
- `is_blocked`
- `pr`
- `workspace_pr`
- `updated_at`

### 3.2 New Feature-Task Task Mode API

Endpoint:

```text
GET /api/workspaces/:workspaceId/features?include=tasks
```

Required Task Mode request example:

```text
GET /api/workspaces/524e02c9-26ad-49c3-8303-3542859cfce3/features?include=tasks&status=blocked,in_progress,reviewing,in_review,ready&sort=task_id_asc&page=1&limit=50
```

Input params:

| Input | Required | Default | Validation and behavior |
|---|---:|---|---|
| `workspaceId` path param | yes | none | Existing workspace ID resolution and authorization rules apply. |
| `include` | yes for Task Mode | none | Must equal `tasks` to enable embedded `features[].tasks[]`. If absent, preserve existing feature list behavior. |
| `status` | no | no status filter | Comma-separated task statuses applied to embedded `features[].tasks[]`. Must support at least `blocked`, `in_progress`, `reviewing`, `in_review`, and `ready`. |
| `title` | no | none | Task title search applied to embedded `features[].tasks[]`. |
| `query` | no | none | General task search applied to embedded `features[].tasks[]` using the same semantics as the existing `/tasks` endpoint. |
| `page` | no | `1` | Positive integer. Applies to `data.features[]` after task filters/search are applied. |
| `limit` | no | `50` | Positive integer. Maximum number of feature rows returned in `data.features[]`. Values above the existing feature-list max limit must use the existing validation error; if no max exists, add a max of `100`. |
| `sort` | no | `task_id_asc` | Task sort applied to embedded tasks before grouping under feature rows. Must support `task_id_asc`. |

Filter semantics:

- Apply `status`, `title`, and `query` to task rows before pagination.
- If both `title` and `query` are present, both filters apply.
- Apply `sort` to embedded task rows after filters.
- Return `tasks: []` when a feature has no matching tasks for the query.

Pagination semantics:

- `page` is 1-based.
- `limit` is the maximum number of feature rows returned in `data.features[]`.
- `data.page` echoes the resolved page.
- `data.limit` echoes the resolved limit.
- `data.total` is the total number of feature rows that match the request
  after task filters/search are applied.
- `page` and `limit` paginate feature rows. They do not slice the task list
  inside an individual returned feature row.

Success response:

```json
{
  "success": true,
  "data": {
    "id": "e2a00270-3358-4264-8aa6-785279feb5e4",
    "name": "workspace",
    "slug": "workspace",
    "page": 1,
    "limit": 10,
    "total": 42,
    "features": [
      {
        "id": "4ec60aea-faa5-453c-80c2-bfdee917e5fa",
        "feature_id": "4ec60aea-faa5-453c-80c2-bfdee917e5fa",
        "feature_name": "digital-factory-ui-visual-bugfix",
        "title": "Digital Factory UI Visual Bug Fix",
        "status": "done",
        "current_stage": "done",
        "updated_at": "2026-05-29T11:59:28.33912Z",
        "task_counts": {
          "total": 9,
          "done": 9,
          "in_progress": 0,
          "blocked": 0,
          "ready": 0,
          "todo": 0
        },
        "stages": {
          "product_spec": {
            "reviewed_at": "2026-05-28T13:57:09+0700",
            "reviewed_by": "unknown@local",
            "review_status": "approved",
            "review_comment": "Product spec approved. Feature advances to technical design."
          },
          "technical_design": {
            "reviewed_at": "2026-05-28T14:12:20+0700",
            "reviewed_by": "unknown@local",
            "review_status": "approved",
            "review_comment": "Technical design approved. Feature advances to task planning."
          },
          "tasks": {
            "reviewed_at": "2026-05-28T14:14:20+0700",
            "reviewed_by": "unknown@local",
            "review_status": "approved",
            "review_comment": "Task breakdown approved."
          },
          "handoff": {
            "reviewed_at": null,
            "reviewed_by": null,
            "review_status": "draft",
            "review_comment": null
          }
        },
        "tasks": [
          {
            "id": "49adb018-692d-4ebf-a568-2178547a6e4e",
            "task_id": "49adb018-692d-4ebf-a568-2178547a6e4e",
            "task_name": "T1",
            "feature_id": "44980262-3463-498e-968f-d356ec416dc9",
            "feature_name": "feature-status-dashboard-v2",
            "title": "v1 archive + v2 scaffold",
            "status": "in_review",
            "repo": "digital-factory-ui",
            "branch": "feature/feature-status-dashboard-v2-T1",
            "is_blocked": false,
            "pr": {
              "url": "https://github.com/tiendv89/digital-factory-ui/pull/7",
              "status": "merged"
            },
            "workspace_pr": {
              "url": "https://github.com/tiendv89/project-workspace/pull/58",
              "status": "open"
            },
            "updated_at": "2026-05-29T11:59:28.33912Z"
          }
        ]
      },
      {
        "id": "cadfdc50-7fb0-4921-8f67-b4412cf51798",
        "feature_id": "cadfdc50-7fb0-4921-8f67-b4412cf51798",
        "feature_name": "agent-rag-v3",
        "title": "Agent RAG v3",
        "status": "in_design",
        "current_stage": "product_spec",
        "updated_at": "2026-05-29T09:33:04.562704Z",
        "task_counts": {
          "total": 0,
          "done": 0,
          "in_progress": 0,
          "blocked": 0,
          "ready": 0,
          "todo": 0
        },
        "stages": {},
        "tasks": []
      }
    ]
  }
}
```

Required top-level response fields:

- `success`
- `data`
- `data.id`
- `data.name`
- `data.slug`
- `data.page`
- `data.limit`
- `data.total`
- `data.features`

Required fields for every `data.features[]` item when `include=tasks` is
present:

- `id`
- `feature_id`
- `feature_name`
- `title`
- `status`
- `current_stage`
- `task_counts`
- `stages`
- `tasks`

Required fields for every embedded `features[].tasks[]` item:

- `id`
- `task_id`
- `task_name`
- `feature_id`
- `feature_name`
- `title`
- `status`
- `repo`
- `branch`
- `is_blocked`
- `pr`
- `workspace_pr`
- `updated_at`

Error responses:

- Missing workspace must use the existing backend not-found convention.
- Unauthorized workspace access must use the existing backend authorization
  convention.
- Invalid query params must use the existing backend validation error
  convention.
- Do not introduce a new error envelope for this feature.

## 4. Options Considered

### Option A: Frontend joins `/features` and `/tasks`

The frontend would continue calling `/tasks` for Task Mode, separately call a
feature endpoint for feature context, and merge data locally.

Pros:

- Smaller backend change.
- Frontend can start without waiting for a grouped response.

Cons:

- Does not satisfy the requirement for one backend payload with feature context
  and related task rows.
- Duplicates grouping logic in `digital-factory-ui`.
- Search, filtering, and pagination remain split across multiple client-side
  assumptions.

Implementation impact:

- Backend only adds `updated_at` to `/tasks`.
- Frontend adds merge logic and extra cache keys.

Dependency impact:

- Fewer backend dependencies, but the final Task Mode behavior remains less
  stable.

### Option B: Extend `/features?include=tasks`

The backend owns the feature-task grouping. The frontend passes Task Mode query
params to the feature collection endpoint and renders `data.features[].tasks[]`.

Pros:

- One response contains workspace context, feature rows, and task rows.
- Query behavior is centralized in `workflow-backend`.
- `digital-factory-ui` can cache one Task Mode query per workspace/query state.
- Calls without `include=tasks` remain backward compatible.

Cons:

- Backend must define and test feature-list pagination with embedded task rows.
- Frontend is blocked on the backend response contract before final
  integration.

Implementation impact:

- Backend adds `include=tasks` query handling for task filters, search, sort,
  pagination, and embedded `updated_at`.
- Frontend adds typed API/query support and switches Task Mode to the new
  response.

Dependency impact:

- Frontend T3/T4 are blocked until backend T2 response shape is stable.

### Option C: Add a new `/feature-tasks` route

The backend would add a dedicated route such as
`GET /api/workspaces/:workspaceId/feature-tasks`.

Pros:

- Clean route dedicated to Task Mode.

Cons:

- Adds a new route family when the feature collection route already exists.
- Does not follow the chosen endpoint direction.
- More backend and frontend migration surface.

Implementation impact:

- Higher than Option B.

Dependency impact:

- Requires an additional route decision before implementation.

## 5. Chosen Design

Choose Option B.

`workflow-backend` must implement two scoped backend changes:

1. Add `updated_at` to every task item returned by the existing
   `GET /api/workspaces/:workspaceId/tasks` endpoint.
2. Extend `GET /api/workspaces/:workspaceId/features?include=tasks` so Task
   Mode can request feature context and embedded task rows in one response.

`digital-factory-ui` must implement three scoped frontend changes:

1. Add typed DTOs, request builder, query key, and TanStack Query hook for
   `GET /api/workspaces/:workspaceId/features?include=tasks`.
2. Configure Task Mode query caching with:
   - `staleTime: 60_000`
   - `gcTime: 60_000` for TanStack Query v5 or `cacheTime: 60_000` for v4
   - `refetchInterval: 60_000`
3. Wire the kanban Task Mode board to render feature rows from
   `data.features[]`, task rows from `features[].tasks[]`, and feature-list
   pagination state from `data.page`, `data.limit`, and `data.total`.

Compatibility rules:

- Feature list calls without `include=tasks` must behave as they do today.
- Existing `/tasks` callers must keep working and only gain `updated_at`.
- Frontend loading, empty, and error states must remain in place.
- Frontend must not fabricate `updated_at`.

Operational rules:

- Backend T1 and T2 must be merged and deployed before final frontend live QA.
- Frontend tests may mock the new response before backend deployment.
- Final QA must verify the real network request and response shape.

## 6. Dependency Analysis

Internal dependencies:

- T1 updates the shared task item serialization contract for `/tasks`.
- T2 must reuse the same task serialization shape so `/tasks` and embedded
  `features[].tasks[]` both include `updated_at`.
- T3 depends on T2 because the frontend DTOs and query keys need the final
  feature-task response shape.
- T4 depends on T3 because Task Mode must consume the typed query hook rather
  than hand-building the request in the board component.
- T5 depends on T4 and a deployed backend because browser/network QA must
  validate the real endpoint.

External dependencies:

- A deployed or locally runnable `workflow-backend` environment is needed for
  final browser/network QA.
- Existing backend workspace authorization and validation conventions must be
  reused.

Blocking decisions:

- None remain open for endpoint selection or response shape.
- T2 must use the existing `/tasks` limit cap if one exists. If the current
  `/tasks` endpoint has no explicit cap, T2 must add a safe cap before release.

Vendor/tooling choices:

- Frontend data fetching uses TanStack Query.
- Cache lifetime field depends on the installed TanStack Query major version:
  `gcTime` for v5, `cacheTime` for v4.

Configuration dependencies:

- No new environment variables are expected.
- Frontend must continue using the existing `workflow-backend` API base URL
  configuration.

Release dependencies:

- Backend T1 and T2 must deploy before frontend T5 can pass live network QA.
- Frontend T3 and T4 can be built against mocked API responses while backend
  work is in progress.

## 7. Parallelization / Blocking Analysis

External dependency:

- Backend deployment after T1 and T2 unblocks T5 live browser/network QA.

```text
T1: Add updated_at to existing tasks API - workflow-backend
  └── Can begin now - no blockers
  │
  T2: Add feature-task response with feature pagination - workflow-backend
    └── BLOCKED on T1 (embedded tasks must reuse the finalized task item serialization with updated_at)
    │
    T3: Add feature-task query client and TanStack cache - digital-factory-ui
      └── BLOCKED on T2 (DTOs and query keys require the final feature-task response shape)
      │
      T4: Wire Task Mode kanban to feature-task API - digital-factory-ui
        └── BLOCKED on T3 (board wiring must consume the typed query hook and normalized cache key)
        │
        T5: Regression and browser/network QA - digital-factory-ui
          └── BLOCKED on T4 (Task Mode must be wired before end-to-end QA)
          └── BLOCKED on backend deployment (live API must expose updated_at and include=tasks behavior)
```

T1 is the first implementation task. T2 follows T1 so both task response shapes
share the same `updated_at` serialization. T3, T4, and T5 are sequential in
`digital-factory-ui` because each layer depends on the previous frontend layer.

## 8. Repository Impact

`workflow-backend`:

- Add `updated_at` to task DTOs returned by
  `GET /api/workspaces/:workspaceId/tasks`.
- Extend `GET /api/workspaces/:workspaceId/features?include=tasks` to parse
  `status`, `title`, `query`, `page`, `limit`, and `sort`.
- Return `tasks` on every feature row when `include=tasks` is present.
- Return `page`, `limit`, and `total` at `data` level for feature-list
  pagination.
- Preserve existing feature list behavior when `include=tasks` is absent.
- Preserve existing `/tasks` behavior except for the added `updated_at` field.
- Add backend tests for both endpoint contracts.

`digital-factory-ui`:

- Add typed API client support for
  `GET /api/workspaces/:workspaceId/features?include=tasks`.
- Add DTOs for workspace response, feature rows, embedded task rows, and
  feature-list pagination metadata.
- Add TanStack Query keys and hook for Task Mode feature-task loading.
- Configure 60-second cache and 60-second refetch interval.
- Wire Task Mode search, status filters, sort, page, and limit to backend query
  params.
- Render feature context from `data.features[]`.
- Render task rows from `features[].tasks[]`.
- Read feature-list pagination state from `data.page`, `data.limit`, and
  `data.total`.

## 9. Validation and Release Impact

Backend validation:

- Test the existing `/tasks` endpoint with:
  `status=blocked,in_progress,reviewing,in_review,ready`,
  `sort=task_id_asc`, `page=1`, and `limit=50`.
- Assert every returned `/tasks` item includes `updated_at`.
- Test `/features?include=tasks` accepts `status`, `title`, `query`, `page`,
  `limit`, and `sort`.
- Assert `/features?include=tasks` returns `success`, `data`, and
  `data.features[]`.
- Assert `/features?include=tasks` returns `data.page`, `data.limit`, and
  `data.total` for feature-list pagination.
- Assert every feature row with `include=tasks` includes `tasks`.
- Assert every embedded task item includes `updated_at`.
- Assert optional task fields already present in source data are preserved.
- Assert invalid query params use the existing backend validation error
  envelope.
- Assert calls to `/features` without `include=tasks` preserve current
  behavior.

Frontend validation:

- API client tests prove the request builder emits:
  `include=tasks`, `status`, `title`, `query`, `page`, `limit`, and
  `sort=task_id_asc`.
- Query tests prove the TanStack Query key includes workspace ID and normalized
  Task Mode params.
- Query tests prove the hook uses a 60-second cache window and
  `refetchInterval: 60_000`.
- Render tests prove Task Mode reads feature context from `data.features[]`.
- Render tests prove Task Mode reads task rows from `features[].tasks[]` and
  uses backend-provided `updated_at`.
- Pagination tests prove Task Mode reads feature-list `page`, `limit`, and
  `total` from `data`.
- Regression tests prove Feature Mode and existing task list flows outside the
  new combined response still work.
- Browser/network QA proves the kanban board calls
  `GET /api/workspaces/:workspaceId/features?include=tasks` with the active
  Task Mode query params.

Migration and rollout:

- No database migration is expected unless `updated_at` is not already stored
  in the backend task model.
- Backend deploy must happen before final frontend live QA.
- Frontend may be developed with mocked responses but cannot complete handoff
  until live backend verification passes.
