# Tasks - digital-factory-ui-visual-bugfix

> Feature status: `ready_for_implementation` - stage status: `tasks` (`approved`; all implementation tasks T1-T9 are done; T6 completed final regression QA). Machine state lives in `tasks/T<n>.yaml`; this file is the narrative task breakdown only.

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | Frontend API cache foundation | none |
| T2 | 2 | Board/sidebar/mode query cache migration | T1 |
| T3 | 2 | Task/feature tab detail query cache migration | T1 |
| T4 | 1 | Board visual cleanup and In Reviewing status | none |
| T5 | 1 | Log link formatting | none |
| T7 | 3 | Feature-origin task tab navigation and tab flicker hardening | T3 |
| T8 | 3 | Remove board sort controls | none |
| T9 | 3 | Sidebar task last-updated timestamps | none |
| T6 | 4 | Regression tests and browser/network QA | T2, T3, T4, T5, T7, T8, T9 |

## T1 — Frontend API cache foundation

### Description
Add the shared frontend request-cache foundation used by all board and tab read APIs. This task installs TanStack Query, mounts the cache provider above workspace/board surfaces, and defines stable workspace-scoped query-key helpers so later tasks can migrate hooks consistently.

### Required skills
- frontend-engineer
- typescript-best-practices
- nextjs-best-practices

### Subtasks
- [ ] Add `@tanstack/react-query` to the frontend package and lockfile.
- [ ] Mount a single shared cache provider in `src/app/providers/AppProviders.tsx` above `WorkspaceProvider`.
- [ ] Configure the initial read-query cache foundation; follow-up T2/T3 must enforce the updated 1-minute cache/refetch contract.
- [ ] Disable or avoid disruptive focus-based refetch behavior unless explicitly needed.
- [ ] Add query-key helper utilities for workspace detail, sidebar tasks, Task Mode lists, Feature Mode lists, task detail, feature detail, and feature-task detail.
- [ ] Normalize query params before they enter cache keys.
- [ ] Add focused tests proving query keys include workspace ID and relevant params.

## T2 — Board/sidebar/mode query cache migration

### Description
Migrate board-level read APIs to TanStack Query so the default board, sidebar, Task Mode, and Feature Mode reuse recently loaded data instead of fetching continuously or flickering during mode switching, board returns, or browser visit-back.

### Required skills
- frontend-engineer
- typescript-best-practices
- nextjs-best-practices

### Subtasks
- [ ] Migrate `useBoardData` from local `useEffect` state to cached query reads.
- [ ] Migrate `useSidebarTasks` / `usePullRequestTaskData` to cached query reads.
- [ ] Migrate `useBackendTaskSearch` to cached query reads keyed by workspace ID and normalized Task Mode params.
- [ ] Migrate `useBackendFeatureSearch` to cached query reads keyed by workspace ID and normalized Feature Mode params.
- [ ] Set effective board/list query cache time to 1 minute (`gcTime` / cache time) and freshness to 1 minute where these queries use default cache behavior.
- [ ] Replace the existing 60-second board `setInterval` refresh with TanStack Query `refetchInterval: 60_000`.
- [ ] Keep cached or previous board/list data visible during background refetches so mode switches do not blank or flicker.
- [ ] Preserve existing hook return shapes where practical.
- [ ] Ensure cached board/sidebar data renders immediately when returning to `/board` within the 1-minute cache window.
- [ ] Ensure manual reload and workspace sync still refetch current data.
- [ ] Ensure manual reload and workspace sync invalidate/refetch affected TanStack Query keys without forcing a full loading reset when cached data exists.

## T3 — Task/feature tab detail query cache migration

### Description
Migrate task and feature detail read APIs to TanStack Query so reopening a recently viewed task/feature tab, switching between task and feature tabs, or returning via browser visit-back reuses cached API data for the same workspace and entity without visible loading flicker.

### Required skills
- frontend-engineer
- typescript-best-practices
- nextjs-best-practices

### Subtasks
- [ ] Migrate `useWorkspaceTask` to cached query reads keyed by workspace ID and task ID.
- [ ] Migrate `useFeatureDetail` to cached query reads keyed by workspace ID and feature ID.
- [ ] Migrate `useFeatureTask` to cached query reads keyed by workspace ID, feature ID, and task ID.
- [ ] Set task/feature detail query cache time to 1 minute (`gcTime` / cache time).
- [ ] Use TanStack Query `refetchInterval: 60_000` where active tab detail queries need automatic refresh.
- [ ] Preserve existing loading, error, and retry behavior while using cached data when available.
- [ ] Ensure reopening a recently viewed task tab avoids unnecessary loading waits within the 1-minute cache window.
- [ ] Ensure reopening a recently viewed feature tab avoids unnecessary loading waits within the 1-minute cache window.
- [ ] Keep cached or previous tab detail content visible while background refetches run.
- [ ] Ensure workspace switching cannot show cached detail data from another workspace.

## T4 — Board visual cleanup and In Reviewing status

### Description
Apply the board visual fixes from the product spec: remove unrelated board UI and add the missing Task Mode `In Reviewing` status while preserving Feature Mode behavior.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Remove or hide the `Create Task` action from the `/board` surface.
- [ ] Remove or hide the `Recent updates` section from the `/board` surface.
- [ ] Add a Task Mode-only `In Reviewing` kanban column/status.
- [ ] Map tasks in the reviewing state into the `In Reviewing` column.
- [ ] Preserve Feature Mode status definitions and ensure Feature Mode does not display the Task Mode-only status.
- [ ] Match existing status label/color/empty-state behavior.
- [ ] Add render tests for board cleanup and the Task Mode-only `In Reviewing` status.

## T5 — Log link formatting

### Description
Format HTTP/HTTPS links in task and feature log/activity surfaces so users can identify and open references directly without leaving the board.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Reuse or extend `src/lib/url-tokenizer.ts` for HTTP/HTTPS URL tokenization.
- [ ] Apply link rendering to task activity timeline/log surfaces.
- [ ] Apply link rendering to feature log surfaces that display plain text logs.
- [ ] Render detected links with visible hyperlink styling.
- [ ] Open links in a new tab with `target="_blank"` and `rel="noopener noreferrer"`.
- [ ] Keep non-link text unchanged.
- [ ] Ensure malformed URL-like text degrades to plain text without crashing.
- [ ] Add focused tokenizer and render tests for link and non-link text.

## T7 — Feature-origin task tab navigation and tab flicker hardening

### Description
Update workspace tab behavior so clicking a task inside a feature tab opens or activates a normal task tab. When that task tab Back action is used, the task tab should close, its header should be removed, and the parent feature tab should become active again. This task also hardens tab-to-tab rendering so cached or previous content remains visible during task/feature tab switches.

### Required skills
- frontend-engineer
- typescript-best-practices
- nextjs-best-practices

### Subtasks
- [ ] Replace the feature task inline drilldown primary action with workspace `openTaskTab` / task-tab activation.
- [ ] Store feature return context on task tabs opened from a feature tab.
- [ ] Update task-tab Back behavior so feature-origin task tabs close/remove only the task tab and reactivate the parent feature tab.
- [ ] Preserve direct board-origin task-tab Back behavior: close the task tab and return to `/board`.
- [ ] Keep the parent feature tab open when returning from a feature-origin task tab.
- [ ] Prevent task/feature tab switches from clearing visible content when cached or previous data exists.
- [ ] Add component tests for feature-to-task tab opening, Back cleanup, parent feature reactivation, and no blank/flicker tab switching.

## T8 — Remove board sort controls

### Description
Remove the unnecessary sort button from `/board` in both Feature Mode and Task Mode. The board should keep its existing default ordering, status grouping, filtering, pagination, and detail-opening behavior; this task removes only the unused sort control and any now-dead sort-control wiring that is exclusive to that button.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Locate the board sort button/control rendered for Feature Mode and Task Mode.
- [ ] Remove the sort button from the `/board` UI in both modes.
- [ ] Remove dead sort-control state, props, handlers, labels, and tests only where they are exclusive to the removed button.
- [ ] Preserve the board's current default item order, status grouping, filters, pagination, and detail-opening behavior.
- [ ] Add or update render tests proving the sort button is absent in Feature Mode.
- [ ] Add or update render tests proving the sort button is absent in Task Mode.
- [ ] Add regression coverage proving removing the button does not change default board ordering/filtering behavior.

## T9 — Sidebar task last-updated timestamps

### Description
Render compact relative last-updated labels on sidebar task cards. Each card should read the task item's `execution.last_updated_at` value, compute the elapsed time against the browser's current clock, and show compact labels such as `50s ago`, `2m ago`, and `1h ago` across the `in_review`, `in_progress`, `in_reviewing`, `ready`, and `blocked` status lists.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Locate the sidebar task card/list rendering used by the `in_review`, `in_progress`, `in_reviewing`, `ready`, and `blocked` task status sections.
- [ ] Read `execution.last_updated_at` from the sidebar task item payload and update task/card types if the field is not already typed.
- [ ] Add or reuse a browser-side compact relative-time formatter for ISO timestamps with `Z` or explicit offsets.
- [ ] Render compact labels such as `50s ago`, `2m ago`, and `1h ago` in each sidebar task card without changing the card click target.
- [ ] Refresh relative labels as browser time advances without refetching task data only to update the text label.
- [ ] Handle missing or invalid `execution.last_updated_at` by omitting the label without crashing the sidebar.
- [ ] Preserve existing sidebar task grouping, ordering, empty states, status visibility, and task-card click behavior.
- [ ] Add focused formatter tests for seconds, minutes, hours, and invalid timestamps.
- [ ] Add render tests proving labels appear in task cards under `in_review`, `in_progress`, `in_reviewing`, `ready`, and `blocked`.

## T6 — Regression tests and browser/network QA

### Description
Verify the cache migration, board visual fixes, Task Mode `In Reviewing` status, log link formatting, feature-origin task tab navigation, sort-button removal, sidebar task timestamp labels, and flicker fixes together. This task should prove both UI behavior and reduced duplicate-fetch behavior during mode switching, tab switching, and browser visit-back.

### Required skills
- browser-qa-frontend
- typescript-best-practices

### Subtasks
- [ ] Add tests proving Task Mode and Feature Mode cache entries are independent and scoped by workspace/query params.
- [ ] Add tests proving returning from task/feature tabs to `/board` renders cached sidebar and kanban data immediately within the 1-minute window.
- [ ] Add tests proving reopening a recently viewed task/feature tab reuses cached detail data.
- [ ] Add tests proving active queries refetch through TanStack Query `refetchInterval: 60_000`, not a manual board interval.
- [ ] Add tests proving switching between task and feature tabs keeps cached or previous content visible when available.
- [ ] Add tests proving feature-origin task-tab Back closes/removes the task tab and returns to the parent feature tab.
- [ ] Add tests proving manual refresh and workspace sync refetch or invalidate affected workspace data.
- [ ] Add tests proving workspace switching cannot leak cached data from the previous workspace.
- [ ] Run focused render tests for removal of `Create Task` and `Recent updates`.
- [ ] Run focused render tests proving the sort button is absent in both Feature Mode and Task Mode.
- [ ] Run regression tests proving default board ordering/filtering behavior is unchanged after sort-button removal.
- [ ] Run focused formatter and render tests proving sidebar task cards show compact relative labels from `execution.last_updated_at` under `in_review`, `in_progress`, `in_reviewing`, `ready`, and `blocked`.
- [ ] Run focused tests proving missing or invalid sidebar task timestamps do not crash the sidebar or change task grouping/click behavior.
- [ ] Run focused render tests for Task Mode `In Reviewing` and Feature Mode exclusion.
- [ ] Run focused log-link tests for HTTP/HTTPS highlighting and safe new-tab links.
- [ ] Run browser QA for `/board` mode switching, sidebar timestamp readability, feature-origin task tab Back behavior, task/feature tab switching, and browser visit-back with network request observation.
