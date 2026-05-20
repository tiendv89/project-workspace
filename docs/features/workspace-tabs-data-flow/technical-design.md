# Technical Design

## Feature

- Feature ID: `workspace-tabs-data-flow`
- Title: `Workspace Tabs and Backend API Data Flow`

## 1. Current State

`digital-factory-ui` currently treats workspace data as a browser-owned concern. The UI path this feature replaces is direct GitHub access from the browser, local parsing, and ephemeral workspace state.

```text
Today:

  digital-factory-ui (browser)
    -> api.github.com       (direct GitHub API calls)
    -> frontend parsers     (workflow YAML and markdown handling)
    -> localStorage         (single active workspace/session state)
```

The backend contract now exists in `workflow-backend` `api-service`. The frontend must move to that contract:

```text
Target:

  digital-factory-ui
    -> workflow-backend api-service
      -> /api/workspaces...
        -> normalized workspace, feature, task,
           source-state, and structured error payloads
```

Key constraints:

- `workflow-backend` is the read-side API service for the dashboard. Local default base URL is `http://localhost:8081`; public routes use `/api`.
- `workspace-github-adapter` owns GitHub ingestion, webhook/task sync, and write-side database updates. The frontend does not call it directly.
- `digital-factory-ui` is the UI consumer. It must call `workflow-backend` and stop treating GitHub, YAML, local storage, or database rows as the durable workspace source of truth.
- GitHub still owns workflow state writes. This feature introduces UI reads and tab/session behavior only.
- Backend identifiers are already normalized: `workspaceId`, `featureId`, and `taskId` are UUID route ids; `feature_name` and `task_name` are display/source labels.

## 2. Problem Framing

Two things must be built in the frontend:

1. **Backend API integration**: replace direct GitHub/local parsing paths with a typed `workflow-backend` client for workspace list, import, workspace detail, sync, feature search/detail, and task search/detail routes.
2. **Workspace tab data flow**: use those backend payloads to drive the workspace board, workspace switcher, import modal, task quick view, task tab, feature quick view, feature tab, Kanban board polling, sidebar active-task polling, search/filter controls, and stale/error states.

The UI always reads from the backend API. It does not need to know whether the underlying data came from a fresh sync or a cached database projection. That distinction belongs to `source_state` and structured `ApiError` payloads, not to separate frontend code paths.

What must remain stable:

- Existing task YAML ownership, agent claim protocol, approval gates, and workflow lifecycle are unchanged.
- No frontend write path to task state.
- No direct GitHub file parsing inside UI components.
- No backend route or database schema work in this feature unless implementation finds the deployed service differs from the documented API.

## 3. Options Considered

### Option A - Keep frontend direct-GitHub reads

The frontend continues to call GitHub APIs and parse workspace files in the browser.

Pros:

- Lowest short-term frontend change.
- Existing experimental parsing code could remain in place.

Cons:

- Conflicts with the delivered backend API contract.
- Keeps token, rate-limit, YAML, and source-shape handling in the browser.
- Cannot share saved workspaces across sessions/devices reliably.
- Makes stale-cache fallback harder to represent.
- Duplicates backend normalization logic in the UI.

Implementation impact:

- Leaves current GitHub/YAML parsing seams in place and requires additional defensive code for auth, rate limits, parser failures, and stale UI states.
- Does not create the API client boundary required by the new backend contract.

Dependency impact:

- Keeps the frontend coupled to GitHub availability and source file layout.
- Bypasses `workflow-backend`, so the UI cannot reliably consume saved workspace state from the backend.

Not chosen.

### Option B - Backend API client with route-by-route integration

The frontend adds a typed API client and progressively wires each workspace surface to the documented `workflow-backend` routes.

Pros:

- Matches the backend contract and service split.
- Keeps the UI focused on view state, interactions, and rendering.
- Gives a small, testable boundary for structured errors and source-state handling.
- Allows component tests to mock the same DTOs that production uses.

Cons:

- Requires replacing existing GitHub/local parsing assumptions across several UI surfaces.
- Requires careful identifier handling so UUID route ids are not confused with source labels like `T1`.

Implementation impact:

- Adds a focused client/types layer first, then migrates workspace, task, feature, sync, import, board polling, and sidebar polling surfaces route by route.
- Lets tests mock the documented backend DTOs while browser QA runs against a live `workflow-backend` instance.

Dependency impact:

- Depends on the documented `workflow-backend` route set and `VITE_API_BASE_URL` configuration.
- Does not depend on frontend access to GitHub tokens, YAML files, or database details.

Chosen.

### Option C - Graph/cache layer in the frontend

The frontend builds a client-side normalized cache that abstracts the backend routes behind a local graph model.

Pros:

- Can reduce duplicate fetches across board, task tab, and feature tab surfaces.
- Can make optimistic UI transitions easier later.

Cons:

- Adds abstraction before the backend integration is stable.
- Risks hiding backend source-state and error semantics.
- Over-scopes this feature; persistent workspace state already belongs to the backend.

Implementation impact:

- Requires designing and maintaining a local normalized cache in addition to backend DTOs and view state.
- Increases the amount of migration work before the UI proves the backend route integration.

Dependency impact:

- Still depends on the same backend API contract while adding a second frontend contract to keep in sync.
- Makes stale/error behavior harder to trace back to backend `source_state` and `ApiError`.

Not chosen for this feature. A small query cache from the existing frontend stack is acceptable, but it must not become a second source of truth.

## 4. Chosen Design

### Architecture

`digital-factory-ui` consumes `workflow-backend` directly. All backend calls go through one typed client.

```text
┌─────────────────────────────────────────────────────────┐
│ digital-factory-ui                                      │
│                                                         │
│ Workspace shell                                         │
│   ├─ Workspace switcher       -> GET /api/workspaces    │
│   ├─ Import modal             -> POST /api/workspaces/import
│   ├─ Workspace board          -> GET /api/workspaces/:workspaceId
│   ├─ Feature Mode/search      -> GET /api/workspaces/:workspaceId/features
│   ├─ Task Mode/search         -> GET /api/workspaces/:workspaceId/tasks
│   ├─ Sidebar active tasks     -> GET /api/workspaces/:workspaceId/tasks?status=in_progress,in_review,ready
│   ├─ Task quick view/tab      -> GET /api/workspaces/:workspaceId/tasks/:taskId
│   ├─ Feature tab              -> GET /api/workspaces/:workspaceId/features/:featureId
│   └─ Board polling            -> GET /api/workspaces/:workspaceId
│                                                         │
│ Owns: UI state, open tabs, search params, loading,      │
│       empty, stale, and error presentation              │
└─────────────────────────────────────────────────────────┘
                          │ HTTP JSON
┌─────────────────────────────────────────────────────────┐
│ workflow-backend api-service                            │
│                                                         │
│ Serves normalized WorkspaceDetail, FeatureDetail,       │
│ TaskDetail, SourceState, and ApiError payloads from the │
│ backend data layer.                                     │
└─────────────────────────────────────────────────────────┘
```

### Frontend API Client

Add or update a dedicated `workflow-backend` client in `digital-factory-ui`, following the repo's existing service/query conventions.

```ts
const API_BASE = import.meta.env.VITE_API_BASE_URL ?? "http://localhost:8081";

export type ApiError = {
  code: string;
  message: string;
  source: "github" | "database" | "parser" | "adapter" | "validation";
  retryable: boolean;
  cached_data?: unknown;
};

export async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    ...init,
    headers: {
      Accept: "application/json",
      ...(init?.body ? { "Content-Type": "application/json" } : {}),
      ...(init?.headers || {}),
    },
  });

  const text = await res.text();
  const body = text ? JSON.parse(text) : null;

  if (!res.ok) {
    throw body as ApiError;
  }

  return body as T;
}
```

Required methods:

```ts
listWorkspaces(): Promise<WorkspaceSummary[]>
importWorkspace(body: ImportWorkspaceRequest): Promise<WorkspaceDetail>
getWorkspace(workspaceId: string): Promise<WorkspaceDetail>
searchFeatures(workspaceId: string, params?: URLSearchParams): Promise<FeatureSummary[]>
searchWorkspaceTasks(workspaceId: string, params?: URLSearchParams): Promise<TaskSummary[]>
getWorkspaceTask(workspaceId: string, taskId: string): Promise<TaskDetail>
syncWorkspace(workspaceId: string): Promise<WorkspaceDetail>
getFeature(workspaceId: string, featureId: string): Promise<FeatureDetail>
searchFeatureTasks(workspaceId: string, featureId: string, params?: URLSearchParams): Promise<TaskSummary[]>
getFeatureTask(workspaceId: string, featureId: string, taskId: string): Promise<TaskDetail>
```

Client rules:

- Prefix every path with the configured API base.
- Always parse response text before checking `res.ok`.
- Throw `ApiError` for non-2xx responses.
- Preserve backend `code`, `source`, `message`, and `retryable`.
- Use `URLSearchParams` for filters.
- Never coerce public UUID route ids into display/source labels.

### Backend Route Contract

The frontend consumes these routes exactly:

| UI use case | Method and path | Success type |
|---|---|---|
| Saved workspace list | `GET /api/workspaces` | `WorkspaceSummary[]` |
| Import workspace | `POST /api/workspaces/import` | `WorkspaceDetail` |
| Workspace dashboard | `GET /api/workspaces/:workspaceId` | `WorkspaceDetail` |
| Feature list/search | `GET /api/workspaces/:workspaceId/features` | `FeatureSummary[]` |
| Workspace task list/search | `GET /api/workspaces/:workspaceId/tasks` | `TaskSummary[]` |
| Board sidebar active task list | `GET /api/workspaces/:workspaceId/tasks?status=in_progress,in_review,ready&sort=task_id_asc&page=1&limit=50` | `TaskSummary[]` |
| Workspace-scoped task detail | `GET /api/workspaces/:workspaceId/tasks/:taskId` | `TaskDetail` |
| Manual sync | `POST /api/workspaces/:workspaceId/sync` | `WorkspaceDetail` |
| Feature detail | `GET /api/workspaces/:workspaceId/features/:featureId` | `FeatureDetail` |
| Feature-scoped task list | `GET /api/workspaces/:workspaceId/features/:featureId/tasks` | `TaskSummary[]` |
| Feature-scoped task detail | `GET /api/workspaces/:workspaceId/features/:featureId/tasks/:taskId` | `TaskDetail` |

`POST /api/workspaces/import` succeeds with `200 OK` and a persisted `WorkspaceDetail`. The frontend must not treat `202 Accepted` as the success case for this route.

Common headers:

- GET requests send `Accept: application/json`.
- POST requests with JSON send `Accept: application/json` and `Content-Type: application/json`.

Structured errors:

| Code | HTTP status | Frontend behavior |
|---|---:|---|
| `DATABASE_NOT_FOUND` | 404 | Show not-found state for workspace, feature, or task. |
| `GITHUB_NOT_FOUND` | 404 | Show source access or missing repository/path state. |
| `VALIDATION_INVALID_URL` | 400 | Mark import repository URL invalid. |
| `VALIDATION_MISSING_INPUT` | 400 | Keep modal open and mark the missing field. |
| `VALIDATION_INVALID_QUERY` | 400 | Show filter error or reset invalid pagination/sort controls. |
| `GITHUB_UNAUTHORIZED` | 401 | Show source auth/access guidance. |
| `GITHUB_RATE_LIMIT` | 429 | Show rate-limit message and retry affordance if appropriate. |
| `ADAPTER_TIMEOUT` | 504 | Show retryable adapter/sync failure. |
| Other errors | 500 | Show generic backend failure with retry only when `retryable=true`. |

Frontend API use cases:

- Workspace list: `GET /api/workspaces` drives the switcher, landing state, and first app load.
- Import workspace: `POST /api/workspaces/import` sends `repo_url`, optional `default_branch`, and optional `name`; success navigates to returned `WorkspaceDetail`.
- Workspace dashboard: `GET /api/workspaces/:workspaceId` returns workspace freshness plus feature and task summaries in one response.
- Feature list: `GET /api/workspaces/:workspaceId/features` supports `title`, `status`, `sort`, `page`, and `limit`.
- Workspace task list: `GET /api/workspaces/:workspaceId/tasks` supports `task_id`, `title`, `status`, `repo`, `sort`, `page`, and `limit`.
- Board sidebar active task list: `GET /api/workspaces/:workspaceId/tasks?status=in_progress,in_review,ready&sort=task_id_asc&page=1&limit=50` is a separate sidebar query. Do not derive the sidebar from workspace detail, task detail, feature detail, or another list response.
- Workspace-scoped task detail: `GET /api/workspaces/:workspaceId/tasks/:taskId` is used when the UI knows a workspace and task UUID but not the feature UUID.
- Manual sync: `POST /api/workspaces/:workspaceId/sync` returns `WorkspaceDetail`; if sync fails but cached data exists, a `200 OK` response can still contain `source_state.stale=true`.
- Feature detail: `GET /api/workspaces/:workspaceId/features/:featureId` returns documents, feature-scoped tasks, task counts, and source freshness.
- Feature-scoped task list/detail: feature pages use `/features/:featureId/tasks` and `/features/:featureId/tasks/:taskId` when the feature UUID is already known.
- Deferred: `GET /api/workspaces/:workspaceId/activity` exists in the backend contract but is not integrated in this feature phase.

### Identifier Contract

| Field | Meaning | Frontend usage |
|---|---|---|
| `workspaceId` | Workspace UUID | Route parameter for workspace routes. |
| `featureId` | Public feature UUID from `feature_id` | Route parameter for feature routes. |
| `taskId` | Public task UUID from `task_id` | Route parameter for task routes. |
| `feature_name` | Display/source slug | Display label only. |
| `task_name` | Display/source label such as `T1` | Display label only. |
| query `task_id` | Text filter over `task_name` | Task-name search input. |

Open tab identity uses route UUIDs. Visible badges can show `feature_name` and `task_name`.

### Query Strategy

Feature list/search:

```text
GET /api/workspaces/:workspaceId/features?title=<query>&status=<csv>&sort=title_asc&page=1&limit=20
```

Workspace task list/search:

```text
GET /api/workspaces/:workspaceId/tasks?task_id=<taskNameQuery>&title=<titleQuery>&status=<csv>&repo=<repo>&sort=task_id_asc&page=1&limit=20
```

Board sidebar active task list:

```text
GET /api/workspaces/:workspaceId/tasks?status=in_progress,in_review,ready&sort=task_id_asc&page=1&limit=50
```

The board sidebar owns this request independently. It is not hydrated from `WorkspaceDetail.tasks`, task-tab detail payloads, feature-tab payloads, or Task Mode search results.

Feature-scoped task list:

```text
GET /api/workspaces/:workspaceId/features/:featureId/tasks?status=ready&sort=task_id_asc&page=1&limit=20
```

Status filtering is exact string matching. The frontend can pass common statuses such as `todo`, `ready`, `in_progress`, `in_review`, `blocked`, `done`, and any additional visible workspace status.

Invalid pagination or sort values return `VALIDATION_INVALID_QUERY`; the UI should show an inline filter error or reset invalid controls.

### Shared DTOs

The frontend should define TypeScript types that match the backend response names. These are the minimum fields the UI depends on:

```ts
type SourceState = {
  stale: boolean;
  last_synced_at?: string;
  error_code?: string;
};

type WorkspaceSummary = {
  id: string;
  name: string;
  slug: string;
  repo_url: string;
  source_state: SourceState;
  updated_at: string;
};

type WorkspaceDetail = WorkspaceSummary & {
  features: FeatureSummary[];
  tasks: TaskSummary[];
};

type FeatureSummary = {
  id: string;
  feature_id: string;
  feature_name: string;
  title: string;
  status: string;
  current_stage: string;
  stages?: Array<{ id: string; status: string }>;
  updated_at: string;
  task_counts: TaskCounts;
};

type TaskSummary = {
  id: string;
  task_id: string;
  task_name: string;
  feature_id: string;
  feature_name: string;
  title: string;
  status: string;
  repo: string;
  branch: string;
  is_blocked: boolean;
  pr: PullRequestRef | null;
  workspace_pr: PullRequestRef | null;
};
```

Detail payload requirements:

- `FeatureDetail` includes `workspace_id`, `documents[]`, `tasks[]`, `task_counts`, and `source_state`.
- `TaskDetail` includes `workspace_id`, `depends_on`, `execution`, and `pr_refs[]`.
- Backend payloads may include activity fields, but the activity timeline endpoint and activity timeline rendering are deferred and not required for this feature phase.

### Workspace Shell State

The workspace shell owns UI state only:

| State | Source | Purpose |
|---|---|---|
| Saved workspace list | `GET /api/workspaces` | Workspace switcher and first load. |
| Active workspace detail | `GET /api/workspaces/:workspaceId`, import, or sync response | Board baseline, feature list, Task Mode defaults, source state. |
| Sidebar active task list | `GET /api/workspaces/:workspaceId/tasks?status=in_progress,in_review,ready&sort=task_id_asc&page=1&limit=50` | Board sidebar only; independent from board/detail/tab data. |
| Kanban board polling | `GET /api/workspaces/:workspaceId` | Refresh board data while the board is active. |
| Active surface | UI state | `board`, `task`, or `feature`. |
| Open work item tabs | UI state keyed by `workspaceId` | Persistent task and feature sessions. |
| Active task detail | Task detail route | Quick task view and task tab. |
| Active feature detail | Feature detail route | Quick feature view and feature tab. |
| Search/filter params | UI state serialized to `URLSearchParams` | List refreshes. |

Switching workspace clears or hides tabs from the previous workspace. If tabs are cached by workspace, only tabs for the active workspace may be visible.

### Use-Case Flows

#### First load and workspace switcher

1. Load `GET /api/workspaces`.
2. If the response is empty, show the no-workspace empty state and import action.
3. If workspaces exist, select the current or first workspace and load `GET /api/workspaces/:workspaceId`.
4. Filter the loaded workspace summaries locally in the switcher.
5. Selecting another workspace loads its detail and returns to the board.

#### Import workspace

1. Modal collects `repo_url`, optional `default_branch`, and optional `name`.
2. Submit calls `POST /api/workspaces/import`.
3. On `200 OK`, store the returned `WorkspaceDetail`, update saved workspaces if needed, close the modal, and navigate to the workspace board.
4. On validation, GitHub, adapter, or database errors, keep the modal open and render the structured error.

#### Workspace dashboard

`GET /api/workspaces/:workspaceId` drives the board:

- `features[]` powers Feature Mode and progress badges.
- `tasks[]` powers Task Mode defaults.
- `source_state` powers freshness warnings.
- `task_counts` powers feature progress summaries.

The board sidebar does not use the dashboard payload as its source. It refreshes independently through:

```text
GET /api/workspaces/:workspaceId/tasks?status=in_progress,in_review,ready&sort=task_id_asc&page=1&limit=50
```

Only active work statuses appear in the sidebar: `in_progress`, `in_review`, and `ready`.

#### Board and sidebar polling

Kanban board polling is still required in this phase:

```text
GET /api/workspaces/:workspaceId
```

The board polling loop runs only while the workspace board is active. It refreshes the board baseline without replacing task or feature tab session state.

Sidebar task polling is also required and uses its own request:

```text
GET /api/workspaces/:workspaceId/tasks?status=in_progress,in_review,ready&sort=task_id_asc&page=1&limit=50
```

The sidebar polling loop runs only while the board/sidebar is visible. It is independent from Kanban board polling, Task Mode search polling, task detail fetches, and feature detail fetches.

#### Task detail

Generic task drawer and task tab use:

```text
GET /api/workspaces/:workspaceId/tasks/:taskId
```

When the UI is already inside a feature, task drilldown can use:

```text
GET /api/workspaces/:workspaceId/features/:featureId/tasks/:taskId
```

#### Feature detail

Feature tab uses:

```text
GET /api/workspaces/:workspaceId/features/:featureId
```

Feature task filtering inside the tab uses the feature-scoped task list route.

#### Deferred activity timeline

The backend activity route is not integrated in this phase:

```text
GET /api/workspaces/:workspaceId/activity
```

Do not add the activity timeline client method, polling, tab panel, or tests in this feature. Activity/log surfaces can be planned in a later feature.

#### Manual sync

1. User triggers refresh.
2. UI calls `POST /api/workspaces/:workspaceId/sync`.
3. On `200 OK`, replace active workspace detail with the returned `WorkspaceDetail`.
4. If `source_state.stale=true`, keep data visible and show a warning using `source_state.error_code`.
5. If no cached data can be returned, render the structured `ApiError`.

### UI Interaction Rules

Workspace shell:

- Workspace tab returns from task or feature tabs to the current workspace board.
- Workspace dropdown opens from the workspace tab control.
- Sidebar is visible on the board only.
- Sidebar data is fetched with the independent active-task query and must not be coupled to Task Mode search state, task detail state, or feature detail state.
- Task and feature tabs are full work sessions without the board sidebar.

Task entry points:

- Single click opens quick task inspection.
- Double click opens or focuses a task tab.
- Context menu offers `New tab`.
- Sidebar task items come from the independent active-task query and follow the same behavior as board task cards.

Feature entry points:

- Task Mode single click opens quick feature inspection.
- Task Mode double click does not open a feature tab.
- Feature Mode single click opens quick feature inspection.
- Feature Mode double click opens or focuses a feature tab.
- Feature Mode context menu offers `New tab`.

Use native `dblclick`. Do not delay single-click feedback to infer double-clicks. If double-click opens a persistent tab, close or avoid leaving a conflicting quick view open.

### Source State And Error Handling

The UI must keep backend source status visible without blanking usable data:

- `source_state.stale=false`: normal fresh state.
- `source_state.stale=true`: warning banner while data stays visible.
- `source_state.error_code`: compact source warning.
- `ApiError.retryable=true`: show retry affordance where repeating the request is safe.
- `VALIDATION_MISSING_INPUT` and `VALIDATION_INVALID_URL`: stay inside the import modal and mark the relevant field.
- `VALIDATION_INVALID_QUERY`: show filter error or reset invalid controls.
- Empty arrays are successful responses and render empty states.

## 5. Dependency Analysis

### Internal dependencies

- T1 is the only wave 1 task. It owns API client, DTOs, error parsing, and query-param helpers.
- T2 depends on T1. It owns saved workspace list, workspace detail bootstrap, switcher, import modal, and workspace switching.
- T3 depends on T1 and T2. It owns feature/task search, filters, Kanban board polling, sidebar active-task polling, manual sync, stale-source UX, empty states, and retry affordances.
- T4 depends on T1, T2, and T3. It owns task quick views, workspace-scoped task drawer, and task tab.
- T5 depends on T1, T2, and T3. It owns Feature Mode, feature tab, and feature-scoped task drilldown.
- T6 depends on T4 and T5. It owns document rendering, source-state presentation, and copy affordances across task and feature tabs.
- T7 depends on T1 through T6. It owns browser QA, regression coverage, and final fixes.

### External dependencies

- `workflow-backend` `api-service` must be reachable from `digital-factory-ui` using the configured API base URL.
- The backend route set must match the documented contract, including `GET /api/workspaces/:workspaceId/tasks/:taskId`.
- Test fixtures or mocks must match real backend DTOs exactly when the backend is not running locally.
- Browser QA needs a workspace with representative features, tasks, documents, stale state, structured errors, and active tasks for sidebar polling.

### Blocking decisions

- **Backend success status for import**: resolved. Frontend treats `200 OK` with `WorkspaceDetail` as success.
- **Route identifiers**: resolved. Use UUID route ids from `workspaceId`, `feature_id`, and `task_id`; use `feature_name` and `task_name` only for display.
- **Frontend durable source**: resolved. Backend payloads are the source of truth; local tab state is view/session state only.

### Configuration dependencies

- `VITE_API_BASE_URL` or the existing frontend equivalent for `workflow-backend`.
- Optional mocked API layer for unit/component tests.

### Release dependencies

- `workflow-backend` must be deployed or running locally before full integration QA.
- Frontend can begin against mocks after T1, but final browser QA requires live backend-compatible responses.

## 6. Parallelization / Blocking Analysis

```text
D1: workflow-backend API availability
  └── Use contract-faithful mocks for unit/component work; unblock final browser QA by running or deploying api-service.

T1: Frontend API client and shared workflow DTOs
  └── Can begin now - no blockers
  │
  T2: Workspace switcher, import modal, and board bootstrap integration
    └── BLOCKED on T1 (typed API client, DTOs, and request/error boundary must exist)
    │
    T3: Workspace search, filters, refresh, and stale-source UX
      └── BLOCKED on T1 (query-param helpers and shared error/source-state types must exist)
      └── BLOCKED on T2 (active workspace detail and shell state must exist before list refresh and sync UX)
      │
      T4: Task quick views, workspace-scoped task drawer, and task tab
      T5: Feature mode, feature tab, and feature-scoped task drilldown
        └── T4 and T5 run in parallel
        └── BLOCKED on T1 (TaskSummary, TaskDetail, FeatureSummary, and FeatureDetail types must exist)
        └── BLOCKED on T2 (workspace shell, active workspace, and tab-session state must exist)
        └── BLOCKED on T3 (list refresh, stale/error state, and search/filter behavior must exist)
        │
        T6: Document rendering, source state, and copy affordances
          └── BLOCKED on T4 (task detail surface must exist for task copy behavior)
          └── BLOCKED on T5 (feature detail surface must exist for documents and feature copy behavior)
          │
          T7: End-to-end browser QA and regression coverage
            └── BLOCKED on T1 (API client contract must be stable to mock and assert)
            └── BLOCKED on T2 (workspace list, switcher, import, and board bootstrap must work)
            └── BLOCKED on T3 (sync, stale-source, empty-state, and retry flows must work)
            └── BLOCKED on T4 (task behavior must work)
            └── BLOCKED on T5 (feature behavior must work)
            └── BLOCKED on T6 (document, source-state, and copy behavior must work)
            └── BLOCKED on D1 (browser QA needs live or contract-faithful workflow-backend responses)
```

T2 and T3 are sequenced because refresh/search/polling UX needs the active workspace shell from T2. T4 and T5 can run in parallel after T3 because task surfaces and feature surfaces have separate UI ownership. T6 is intentionally later because document rendering, source-state display, and copy behavior span both surfaces. T7 owns final integrated verification.

## 7. Repository Impact

| Repo | Changes |
|---|---|
| `digital-factory-ui` | API client, DTOs, query helpers, workspace shell, workspace switcher, import modal, board backend loading, Kanban board polling, sidebar active-task polling, task/feature search, sync/stale UX, task quick view, task tab, feature quick view, feature tab, document rendering, tests, and browser QA. |
| `management-repo` | Planning artifacts only under `docs/features/workspace-tabs-data-flow/`. |

Dependency repo:

| Repo | Role |
|---|---|
| `workflow-backend` | Provides the existing frontend API contract. No implementation changes are expected from this feature unless live behavior differs from the documented contract. |
| `workspace-github-adapter` | Upstream sync/write-side dependency behind `workflow-backend`. The frontend does not call it directly. |

Unaffected repos: `workflow`, `rag-service`, and `git-nexus`.

## 8. Validation and Release Impact

### Testing expectations

- **Unit tests**: API request construction, response parsing, structured `ApiError` handling, query-param serialization, identifier helpers.
- **Component tests**: workspace switcher, import modal, workspace board bootstrap, Kanban board polling, sidebar active-task polling, search/filter controls, manual sync, stale-source banner, retryable errors, empty states.
- **Task surface tests**: quick task inspection, task tab open/focus/close, workspace-scoped task detail loading, metadata fallbacks, PR refs, copy feedback, and Back behavior.
- **Feature surface tests**: Feature Mode gating, feature tab open/focus/close, feature detail loading, document views, feature task list, feature-scoped task drilldown, copy feedback, and Back behavior.
- **Browser QA**: saved workspace list, import success/failure, sync success/stale failure, workspace switch cleanup, Kanban board polling, sidebar active-task polling, task single/double/right click, feature single/double/right click, task tab, feature tab, source-state notices, and responsive tab overflow.

### Migration / config impact

- No database migration in this feature.
- No backend route implementation in this feature.
- Frontend runtime config must point to `workflow-backend` through `VITE_API_BASE_URL` or the repo's existing equivalent.

### Rollout concerns

- Keep existing board behavior stable when no work item tabs are open.
- Ensure stale cached data is visibly marked and not blanked.
- Ensure workspace switching does not leak tabs or selected detail state across workspaces.
- Ensure no direct GitHub workspace-data reads remain in browser flows.
- Ensure no agent, chat, model selector, composer, or conversation controls are introduced by this feature.

### Backward compatibility

- Existing UI paths can coexist during rollout only behind controlled feature work. The final feature behavior must read workspace data through `workflow-backend`.
- Existing task/feature display conventions should be adapted through frontend view models, not by changing backend DTO semantics.
