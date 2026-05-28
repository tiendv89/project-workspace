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
`src/app/providers/AppProviders.tsx`. T1 has introduced a shared TanStack Query
provider and query-key helpers, but the current cache defaults were written for
a 5-minute behavior and must be corrected to the new 1-minute contract.

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

`src/features/board/components/KanbanBoard/KanbanBoard.context.tsx` also owns a
manual `setInterval(..., 60_000)` refresh loop. That refresh should move into
TanStack Query `refetchInterval` so the data layer, cache lifetime, background
refresh, and loading behavior are controlled in one place.

Feature task rows are currently handled as an inline drilldown inside
`FeatureTabView`. The required behavior is to open or activate a normal task tab
from the feature tab, then make Back close that task tab and return to the
parent feature tab.

## Problem Framing

This feature changes only the frontend app. It must:

- Remove unrelated `Create Task` and `Recent updates` UI from `/board`.
- Add a Task Mode-only `In Reviewing` kanban column/status.
- Highlight HTTP/HTTPS links in log/activity text and open them safely in a new
  tab.
- Cache frontend read API data with a 1-minute cache lifetime so repeated mode
  switching, tab/default-board switching, and browser visit-back do not
  repeatedly fetch the same data inside that window.
- Refetch active board and tab read queries through TanStack Query
  `refetchInterval: 60_000` instead of manual intervals or local fetch loops.
- Keep previous/cached data visible during tab and mode switches when available
  so the UI does not flicker through blank loading states.
- Open task rows inside feature tabs as task tabs, and close/remove that task tab
  when Back returns to the parent feature tab.

The following behavior must remain stable:

- Manual refresh and workspace sync must still fetch current data.
- Workspace switching must not show stale data from the previous workspace.
- Existing board filters, search, pagination, tabs, and detail flows must keep
  their current user-facing behavior except where this feature explicitly
  changes them.
- No backend API change is required.

Fixed assumptions:

- The cache is frontend-only.
- TanStack Query is now the required implementation for this feature.
- Cache entries must be scoped by workspace and by query inputs that change the
  result.

## Options Considered

### Option A - Use TanStack Query as the shared request cache

Use `@tanstack/react-query` as the shared frontend request-cache library, keep
the provider mounted in `AppProviders`, and move the board/tab read hooks to
cached query hooks.

Pros:

- One consistent cache layer across board, sidebar, task tab, feature tab, and
  feature-task drilldown surfaces.
- Built-in stale time, cache lifetime (`gcTime` / cache time), deduplication,
  retained cached data, `refetchInterval`, manual refetch, and invalidation.
- Cache survives route/surface remounts because the provider sits above board
  and tab pages.
- Query keys make duplicate-fetch prevention testable.

Cons:

- Requires migrating every read hook that owns board/tab data.
- Requires correcting the existing T1 cache defaults from 5 minutes to 1 minute.

Implementation impact:

- Add the cache provider at the app-provider level.
- Migrate the listed hooks while preserving their external return shapes where
  practical.
- Update sync/manual refresh paths to use query invalidation or refetch.
- Replace the board 60-second `setInterval` with query-level
  `refetchInterval: 60_000`.

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
- Does not meet the updated product requirement to use TanStack Query and
  `refetchInterval`.

Implementation impact:

- Add custom cache utilities, then retrofit every hook to read/write the custom
  cache.

Dependency impact:

- Every hook still depends on the custom cache foundation, but the foundation is
  less battle-tested than a library.

## Chosen Design

Use Option A. TanStack Query is required for workspace-scoped board and tab data
because it directly supports the required 1-minute cache lifetime, request
deduplication, retained cached data, `refetchInterval`, manual refetch, and
workspace-scoped invalidation. The custom-cache option is rejected because the
product requirement now explicitly calls for TanStack Query.

Affected repository:

- `digital-factory-ui`

Compatibility considerations:

- Hook return shapes should remain stable where practical so UI components do
  not need broad rewrites.
- Query keys must include workspace ID and relevant parameters to avoid stale or
  cross-workspace data.
- Cached or previous data should render immediately during revisit, visit-back,
  tab-switch, and mode-switch flows while a background refresh may run when
  appropriate.

Operational and release implications:

- T1 has already introduced the frontend dependency and provider; follow-up
  tasks must correct the cache/refetch settings and migrate the remaining read
  hooks.
- No backend deployment is required.
- QA must verify visible loading behavior and network request behavior, not only
  the presence of cache code.

### Provider Setup

- Keep `@tanstack/react-query` as the shared frontend cache dependency.
- Keep `src/app/providers/AppProviders.tsx` wrapping `WorkspaceProvider` with a
  shared TanStack `QueryClientProvider`.
- Configure default read-query cache time with `gcTime: 60_000`.
- Configure default read-query freshness with `staleTime: 60_000` unless an
  individual query has a more specific product reason to be stale immediately.
- Keep cached data available while users navigate between board and tabs.
- Disable or avoid automatic refetch-on-window-focus unless product behavior
  explicitly requires it later.
- Use query-level `refetchInterval: 60_000` for active board/sidebar/list/detail
  reads that replace the existing automatic refresh behavior.

### Query Migration

Migrate these hooks to cached query hooks:

- `useBoardData`
- `useSidebarTasks`
- `useBackendTaskSearch`
- `useBackendFeatureSearch`
- `useFeatureDetail`
- `useFeatureTask`
- `useWorkspaceTask`

Implement these migrations with TanStack Query `useQuery`. Preserve the same
hook contract where practical, but derive loading states from cached query data
so a background refetch does not blank already-rendered content.

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

- Recently loaded frontend API data remains available for 1 minute.
- Browser visit-back, tab switching, and returning to `/board` reuse cached data
  when the cache entry is still valid.
- Returning from task/feature tabs to `/board` renders cached board, sidebar,
  and kanban data immediately when valid cached data exists.
- Task Mode and Feature Mode switching reuses cached mode/list data instead of
  forcing repeated requests.
- Reopening a recently viewed task or feature tab renders cached detail data
  without a fresh loading wait.
- Active queries refetch every 1 minute through TanStack Query
  `refetchInterval`.
- Manual retry/refresh actions call query `refetch`.
- Workspace sync invalidates affected workspace query keys after sync completes
  and updates visible data.
- Workspace switch uses workspace-scoped keys and keeps existing tab/filter
  reset behavior to prevent cross-workspace UI state leakage.
- Query consumers should distinguish initial loading from background fetching.
  If cached or previous data exists, tab/mode switches should keep that content
  visible and show any refresh affordance as non-blocking.

### Existing Auto Refresh

`BoardProvider` currently reloads board and sidebar data every 60 seconds with a
manual interval. After the cache migration, remove that interval and configure
the relevant TanStack Query reads with `refetchInterval: 60_000`. The refetch
must not reset the board to a full loading state while cached or previous data
is still available.

### Feature-Origin Task Tab Navigation

Feature task rows should no longer open an inline feature-task drilldown as the
primary behavior. Instead:

- `FeatureTasksPanel` calls the workspace tab API to open or activate the
  selected task as a task tab.
- The created task tab stores parent feature return context, such as the parent
  feature tab session ID and feature ID.
- `TaskTabView` Back checks that return context. If present, it closes/removes
  the active task tab and activates the parent feature tab.
- If no parent feature return context exists, Back keeps the existing direct
  behavior of closing the task tab and returning to `/board`.
- The parent feature tab remains open when the task tab is closed.

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
- The cache foundation already exists from T1, but T2/T3 must correct the
  effective cache/refetch behavior to the updated 1-minute TanStack Query
  contract.
- Board/sidebar cache migration and tab/detail cache migration can run in
  parallel after the cache foundation exists.
- Feature-origin task-tab navigation should run after task/feature tab detail
  query migration, because it touches the same tab surfaces and should avoid
  merge conflict with cache hook changes.
- Visual board cleanup and `In Reviewing` rendering do not depend on the cache
  layer.
- Log link rendering does not depend on the cache layer.
- Final browser/network QA depends on all implementation tasks.

External dependencies:

- `@tanstack/react-query` is the required dependency. T1 has already introduced
  it; follow-up work must use TanStack Query APIs rather than a custom cache.

Blocking decisions:

- None remain for planning. Use TanStack Query with 1-minute cache time and
  1-minute active-query refetch intervals.

Vendor/tooling choices:

- TanStack Query only.

Configuration dependencies:

- No backend configuration change.
- Existing `NEXT_PUBLIC_API_BASE_URL` behavior remains unchanged.

Release dependencies:

- The frontend package and lockfile changes from T1 must remain in place.
- No database migration or backend rollout is required.

## Parallelization / Blocking Analysis

External dependencies:

No unresolved external decisions remain. TanStack Query is already selected and
installed by T1.

```
T1: Frontend API cache foundation
  └── Complete - shared provider and query-key helpers exist
  │
  T2: Board/sidebar/mode query cache migration
    └── Can begin now - T1 is done; migrate board/sidebar reads, set 1-minute cache time, and replace the manual board interval with refetchInterval
  │
  T3: Task/feature tab detail query cache migration
    └── Can begin now - T1 is done; migrate task/feature detail reads and keep cached or previous data visible during tab switches
  └── T2 and T3 run in parallel

T4: Board visual cleanup and In Reviewing status
  └── Complete - board cleanup and Task Mode In Reviewing status are merged

T5: Log link formatting
  └── Can begin now - no blockers
  │
  T7: Feature-origin task tab navigation and tab flicker hardening
    └── BLOCKED on T3 (task/feature tab detail query migration must stabilize the tab data surfaces first)
  │
  T6: Regression tests and browser/network QA
    └── BLOCKED on T2 (board/sidebar/mode cache behavior must be implemented)
    └── BLOCKED on T3 (task/feature tab cache behavior must be implemented)
    └── BLOCKED on T4 (board visual/status fixes must be implemented)
    └── BLOCKED on T5 (log link formatting must be implemented)
    └── BLOCKED on T7 (feature-origin task tab back behavior and tab flicker hardening must be implemented)
```

T2, T3, and T5 can proceed now. T7 follows T3 to avoid tab-surface conflicts.
T6 remains the final verification task.

## Repository Impact

Affected repo:

- `digital-factory-ui`

Why:

- The feature changes frontend UI, frontend data-fetching hooks, app providers,
  and frontend tests.

Expected files/areas:

- `src/lib/query-client.ts`: set 1-minute `staleTime`, 1-minute `gcTime`, and
  shared query defaults.
- `src/app/providers/AppProviders.tsx`: keep the shared cache provider.
- `src/features/board/hooks/*`: migrate board, sidebar, task list, feature list,
  and feature detail query hooks to TanStack Query.
- `src/features/tasks/hooks/useWorkspaceTask.ts`: migrate task tab detail query.
- `src/features/workspaces/context/WorkspaceContext.tsx`: invalidate/refetch
  workspace query keys after sync, preserve workspace-switch reset behavior, and
  store/activate feature return context for feature-origin task tabs.
- `src/features/board/components/FeatureTabView/*`: open feature task rows as
  task tabs instead of inline drilldowns.
- `src/features/tasks/components/TaskTabView/TaskTabView.tsx`: close/remove the
  task tab and reactivate the parent feature tab when Back has feature return
  context.
- `src/features/board/components/KanbanBoard/KanbanBoard.context.tsx`: remove
  the manual 60-second interval in favor of TanStack Query `refetchInterval`.
- Board components under `src/features/board/components/*`: remove unwanted UI,
  add Task Mode `In Reviewing`, and format feature/task logs.
- Tests under `src/__tests__/` and browser QA specs.

Task repo values must be `digital-factory-ui`.

## Validation and Release Impact

Testing expectations:

- Unit tests for query-key generation and 1-minute cache/refetch behavior.
- Component tests proving board return, mode switch, and tab revisit do not show
  repeated full loading states while valid cached data exists.
- Component tests proving feature-task rows open task tabs, Back closes/removes
  the feature-origin task tab, and the parent feature tab becomes active again.
- Tests for manual refresh/sync invalidating or refetching current workspace
  data.
- Render tests for removal of `Create Task` and `Recent updates`.
- Render tests for Task Mode `In Reviewing` and Feature Mode exclusion.
- Unit/render tests for HTTP/HTTPS log link formatting.
- Browser QA verifying visible behavior, duplicate-fetch reduction, 1-minute
  background refetch behavior, and no blank/flickering tab switches.

Migration/config impact:

- No new backend migration is required. The frontend TanStack dependency from T1
  remains required.
- No backend config, API, or database migration is required.

Rollout concerns:

- Cache must not hide manual refresh or workspace sync updates.
- Cache must not leak data between workspaces.
- Auto refresh should run through TanStack Query `refetchInterval` and must not
  trigger disruptive full loading states.
- Feature-origin task tabs must remove only the task tab on Back; they must not
  close the parent feature tab.

Backward compatibility constraints:

- Existing hook consumers should keep working with minimal prop/state changes.
- Existing board filters, pagination, workspace selection, and tab behavior must
  remain compatible.

Deployment / handoff implications:

- Frontend-only release.
- Handoff should include explicit QA evidence for network request behavior
  during mode switching, tab switching, and browser visit-back.
