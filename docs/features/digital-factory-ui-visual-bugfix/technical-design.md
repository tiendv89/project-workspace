# Technical Design

## Feature

- Feature ID: `digital-factory-ui-visual-bugfix`
- Title: `Digital Factory UI Visual Bug Fix`
- Implementation repo: `digital-factory-ui`

## Current State

The implementation repo is a Next.js app. The board route lives at
`src/app/board/page.tsx` and renders `BoardProvider`, `BoardHeader`,
`TaskTrackingPanel`, and `KanbanBoard`.

Global workspace state is provided by
`src/features/workspaces/context/WorkspaceContext.tsx` through
`src/app/providers/AppProviders.tsx`. Today `AppProviders` only mounts
`WorkspaceProvider`; there is no shared frontend request-cache provider.

The current read hooks use local hook state around direct backend API calls:

- `useBoardData` calls `getWorkspace`.
- `useSidebarTasks` calls `searchWorkspaceTasks`.
- `useBackendTaskSearch` calls `searchWorkspaceTasksPage`.
- `useBackendFeatureSearch` calls `searchFeaturesPage`.
- `useFeatureDetail` calls `getFeature`.
- `useFeatureTask` calls `getFeatureTask`.
- `useWorkspaceTask` calls `getWorkspaceTask`.

Because these hooks store data inside each mounted component, remounting a board
surface, task tab, or feature tab loses previous results and shows loading while
the same API data is fetched again. This affects:

- Task Mode / Feature Mode switching.
- Returning from task or feature tabs to the default board screen.
- Reopening recently viewed task or feature tabs.
- Browser visit-back flows to recently viewed board/tab surfaces.

The project does not currently list `@tanstack/react-query` in `package.json`.

## Problem Framing

This feature changes only the frontend app. It must:

- Remove unrelated `Create Task` and `Recent updates` UI from `/board`.
- Add a Task Mode-only `In Reviewing` kanban column/status.
- Highlight HTTP/HTTPS links in log/activity text and open them safely in a new
  tab.
- Cache frontend read API data for 5 minutes so repeated mode switching,
  tab/default-board switching, and browser visit-back do not repeatedly fetch
  the same data.

The following behavior must remain stable:

- Manual refresh and workspace sync must still fetch current data.
- Workspace switching must not show stale data from the previous workspace.
- Existing board filters, search, pagination, tabs, and detail flows must keep
  their current user-facing behavior except where this feature explicitly
  changes them.
- No backend API change is required.

Fixed assumptions:

- The cache is frontend-only.
- TanStack Query is the preferred implementation, but an equivalent frontend
  caching library is acceptable if it meets the same 5-minute behavior.
- Cache entries must be scoped by workspace and by query inputs that change the
  result.

## Options Considered

### Option A - Add TanStack Query or equivalent shared request caching

Add a mature frontend request-cache library, preferably
`@tanstack/react-query`, mount one shared provider in `AppProviders`, and move
the board/tab read hooks to cached query hooks.

Pros:

- One consistent cache layer across board, sidebar, task tab, feature tab, and
  feature-task drilldown surfaces.
- Built-in stale time, deduplication, retained cached data, refetch, and
  invalidation.
- Cache survives route/surface remounts because the provider sits above board
  and tab pages.
- Query keys make duplicate-fetch prevention testable.

Cons:

- Adds a runtime dependency if no equivalent library is already present.
- Requires migrating every read hook that owns board/tab data.

Implementation impact:

- Add the cache provider at the app-provider level.
- Migrate the listed hooks while preserving their external return shapes where
  practical.
- Update sync/manual refresh paths to use query invalidation or refetch.

Dependency impact:

- Cache-aware hook migration depends on the provider and query-key helpers.
- Browser QA depends on the cache migration plus visual/log fixes.

### Option B - Build a custom in-memory cache around existing hooks

Create a custom cache module and keep the current `useEffect + useState` hook
structure.

Pros:

- No new dependency.
- Can be small if only one or two hooks are covered.

Cons:

- Reimplements stale time, dedupe, invalidation, loading state, error state, and
  race behavior manually.
- Higher risk of inconsistent cache behavior across board, sidebar, and tabs.
- Harder to extend as more surfaces need caching.

Implementation impact:

- Add custom cache utilities, then retrofit every hook to read/write the custom
  cache.

Dependency impact:

- Every hook still depends on the custom cache foundation, but the foundation is
  less battle-tested than a library.

## Chosen Design

Use Option A. Add a shared frontend API cache for workspace-scoped board and tab
data. TanStack Query is the recommended package because it directly supports the
required 5-minute stale time, request deduplication, retained cached data,
manual refetch, and workspace-scoped invalidation. If the implementation uses a
different library, it must provide the same user-visible behavior.

Affected repository:

- `digital-factory-ui`

Compatibility considerations:

- Hook return shapes should remain stable where practical so UI components do
  not need broad rewrites.
- Query keys must include workspace ID and relevant parameters to avoid stale or
  cross-workspace data.
- Cached data should render immediately during revisit/visit-back flows while a
  background refresh may run when appropriate.

Operational and release implications:

- Frontend dependency installation and lockfile update are required if the
  selected cache library is not already present.
- No backend deployment is required.
- QA must verify visible loading behavior and network request behavior, not only
  the presence of cache code.

### Provider Setup

- Add `@tanstack/react-query`, or an equivalent frontend caching library if the
  project owner chooses a different package.
- Update `src/app/providers/AppProviders.tsx` to create one shared cache client
  and wrap `WorkspaceProvider` with the cache provider.
- Configure read queries with a 5-minute stale time / TTL.
- Keep cached data available while users navigate between board and tabs.
- Disable or avoid automatic refetch-on-window-focus unless product behavior
  explicitly requires it later.

### Query Migration

Migrate these hooks to cached query hooks:

- `useBoardData`
- `useSidebarTasks`
- `useBackendTaskSearch`
- `useBackendFeatureSearch`
- `useFeatureDetail`
- `useFeatureTask`
- `useWorkspaceTask`

If using TanStack Query, implement these migrations with `useQuery`. If using a
different cache library, preserve the same hook contract and 5-minute cache
behavior.

### Query Keys

Use explicit workspace-scoped query keys:

- Workspace board root: `["workspace", workspaceId, "detail"]`
- Sidebar tracked tasks:
  `["workspace", workspaceId, "sidebar-tasks", normalizedSidebarParams]`
- Task Mode list/search:
  `["workspace", workspaceId, "tasks", normalizedTaskSearchParams]`
- Feature Mode list/search:
  `["workspace", workspaceId, "features", normalizedFeatureSearchParams]`
- Task tab detail: `["workspace", workspaceId, "task", taskId]`
- Feature tab detail: `["workspace", workspaceId, "feature", featureId]`
- Feature-task drilldown detail:
  `["workspace", workspaceId, "feature", featureId, "task", taskId]`

Normalize params before putting them into query keys so equivalent input states
reuse the same cache entry.

### Cache Behavior

- Recently loaded frontend API data remains available for 5 minutes.
- Browser visit-back, tab switching, and returning to `/board` reuse cached data
  when the cache entry is still valid.
- Returning from task/feature tabs to `/board` renders cached board, sidebar,
  and kanban data immediately when valid cached data exists.
- Task Mode and Feature Mode switching reuses cached mode/list data instead of
  forcing repeated requests.
- Reopening a recently viewed task or feature tab renders cached detail data
  without a fresh loading wait.
- Manual retry/refresh actions call query `refetch` or equivalent.
- Workspace sync invalidates affected workspace query keys after sync completes
  and updates visible data.
- Workspace switch uses workspace-scoped keys and keeps existing tab/filter
  reset behavior to prevent cross-workspace UI state leakage.

### Existing Auto Refresh

`BoardProvider` currently reloads board and sidebar data every 60 seconds. After
the cache migration, this interval should invalidate or refetch the relevant
workspace board/sidebar queries instead of bypassing the shared cache. The
interval must not reset the board to a full loading state while cached data is
still available.

### Visual Fixes

Board cleanup:

- Remove the `Create Task` action from the `/board` surface.
- Remove the `Recent updates` section from `/board`.
- Keep existing board header, mode switching, filters, pagination, sidebar, and
  detail-tab entry points intact.

Task Mode `In Reviewing`:

- Add a Task Mode-only `In Reviewing` column/status.
- Map tasks in the reviewing state to that column.
- Keep Feature Mode status definitions unchanged.
- Reuse the existing status color/label pattern.

Log link rendering:

- Reuse or extend `src/lib/url-tokenizer.ts`.
- Apply link rendering to task activity/log surfaces and feature log surfaces
  that display plain text log messages.
- Render HTTP/HTTPS tokens as links with `target="_blank"` and
  `rel="noopener noreferrer"`.
- Leave non-link text unchanged and degrade malformed URL-like text to plain
  text.

## Dependency Analysis

Internal dependencies:

- Cache hook migrations depend on the shared cache provider and stable query-key
  helpers.
- Board/sidebar cache migration and tab/detail cache migration can run in
  parallel after the cache foundation exists.
- Visual board cleanup and `In Reviewing` rendering do not depend on the cache
  layer.
- Log link rendering does not depend on the cache layer.
- Final browser/network QA depends on all implementation tasks.

External dependencies:

- `@tanstack/react-query` is the recommended dependency. If another library is
  selected, it must support 5-minute stale time / TTL, request deduplication,
  retained data, manual refetch, and workspace-scoped invalidation.

Blocking decisions:

- None remain for planning. The implementation may use TanStack Query by
  default.

Vendor/tooling choices:

- Preferred: TanStack Query.
- Acceptable alternative: any equivalent frontend cache library meeting the same
  contract.

Configuration dependencies:

- No backend configuration change.
- Existing `NEXT_PUBLIC_API_BASE_URL` behavior remains unchanged.

Release dependencies:

- Frontend package and lockfile changes must ship with the cache provider.
- No database migration or backend rollout is required.

## Parallelization / Blocking Analysis

External dependencies:

`D1: Frontend cache library installation` - use TanStack Query by default; if a
different library is selected, it must be selected before T1 starts.

```
T1: Frontend API cache foundation
  └── Can begin now — no blockers
  │
  T2: Board/sidebar/mode query cache migration
    └── BLOCKED on T1 (shared cache provider and query-key helpers must exist)
  │
  T3: Task/feature tab detail query cache migration
    └── BLOCKED on T1 (shared cache provider and query-key helpers must exist)
  └── T2 and T3 run in parallel

T4: Board visual cleanup and In Reviewing status
  └── Can begin now — no blockers

T5: Log link formatting
  └── Can begin now — no blockers
  │
  T6: Regression tests and browser/network QA
    └── BLOCKED on T2 (board/sidebar/mode cache behavior must be implemented)
    └── BLOCKED on T3 (task/feature tab cache behavior must be implemented)
    └── BLOCKED on T4 (board visual/status fixes must be implemented)
    └── BLOCKED on T5 (log link formatting must be implemented)
```

T1, T4, and T5 can start immediately after task approval. T2 and T3 run in
parallel after T1. T6 is the final verification task.

## Repository Impact

Affected repo:

- `digital-factory-ui`

Why:

- The feature changes frontend UI, frontend data-fetching hooks, app providers,
  and frontend tests.

Expected files/areas:

- `package.json` and lockfile: add the selected cache library if needed.
- `src/app/providers/AppProviders.tsx`: mount the shared cache provider.
- `src/features/board/hooks/*`: migrate board, sidebar, task list, feature list,
  and feature detail query hooks.
- `src/features/tasks/hooks/useWorkspaceTask.ts`: migrate task tab detail query.
- `src/features/workspaces/context/WorkspaceContext.tsx`: invalidate/refetch
  workspace query keys after sync and preserve workspace-switch reset behavior.
- Board components under `src/features/board/components/*`: remove unwanted UI,
  add Task Mode `In Reviewing`, and format feature/task logs.
- Tests under `src/__tests__/` and browser QA specs.

Task repo values must be `digital-factory-ui`.

## Validation and Release Impact

Testing expectations:

- Unit tests for query-key generation and 5-minute cache behavior.
- Component tests proving board return, mode switch, and tab revisit do not show
  repeated full loading states while valid cached data exists.
- Tests for manual refresh/sync invalidating or refetching current workspace
  data.
- Render tests for removal of `Create Task` and `Recent updates`.
- Render tests for Task Mode `In Reviewing` and Feature Mode exclusion.
- Unit/render tests for HTTP/HTTPS log link formatting.
- Browser QA verifying visible behavior and duplicate-fetch reduction.

Migration/config impact:

- Frontend dependency installation and lockfile update are required if TanStack
  Query or another cache library is added.
- No backend config, API, or database migration is required.

Rollout concerns:

- Cache must not hide manual refresh or workspace sync updates.
- Cache must not leak data between workspaces.
- Auto refresh should not trigger disruptive full loading states.

Backward compatibility constraints:

- Existing hook consumers should keep working with minimal prop/state changes.
- Existing board filters, pagination, workspace selection, and tab behavior must
  remain compatible.

Deployment / handoff implications:

- Frontend-only release.
- Handoff should include explicit QA evidence for network request behavior
  during mode switching, tab switching, and browser visit-back.
