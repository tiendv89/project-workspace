# Tasks - digital-factory-ui-visual-bugfix

> Feature status: `ready_for_implementation` - stage status: `tasks` (`approved`; T1, T4, and T5 are ready). Machine state lives in `tasks/T<n>.yaml`; this file is the narrative task breakdown only.

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | Frontend API cache foundation | none |
| T2 | 2 | Board/sidebar/mode query cache migration | T1 |
| T3 | 2 | Task/feature tab detail query cache migration | T1 |
| T4 | 1 | Board visual cleanup and In Reviewing status | none |
| T5 | 1 | Log link formatting | none |
| T6 | 3 | Regression tests and browser/network QA | T2, T3, T4, T5 |

## T1 — Frontend API cache foundation

### Description
Add the shared frontend request-cache foundation used by all board and tab read APIs. This task installs TanStack Query or the selected equivalent library, mounts the cache provider above workspace/board surfaces, and defines stable workspace-scoped query-key helpers so later tasks can migrate hooks consistently.

### Required skills
- frontend-engineer
- typescript-best-practices
- nextjs-best-practices

### Subtasks
- [ ] Add `@tanstack/react-query` or the selected equivalent cache library to the frontend package and lockfile.
- [ ] Mount a single shared cache provider in `src/app/providers/AppProviders.tsx` above `WorkspaceProvider`.
- [ ] Configure the default read-query stale time / TTL to 5 minutes.
- [ ] Disable or avoid disruptive focus-based refetch behavior unless explicitly needed.
- [ ] Add query-key helper utilities for workspace detail, sidebar tasks, Task Mode lists, Feature Mode lists, task detail, feature detail, and feature-task detail.
- [ ] Normalize query params before they enter cache keys.
- [ ] Add focused tests proving query keys include workspace ID and relevant params.

## T2 — Board/sidebar/mode query cache migration

### Description
Migrate board-level read APIs to the shared frontend cache so the default board, sidebar, Task Mode, and Feature Mode reuse recently loaded data instead of fetching continuously during mode switching, board returns, or browser visit-back.

### Required skills
- frontend-engineer
- typescript-best-practices
- nextjs-best-practices

### Subtasks
- [ ] Migrate `useBoardData` from local `useEffect` state to cached query reads.
- [ ] Migrate `useSidebarTasks` / `usePullRequestTaskData` to cached query reads.
- [ ] Migrate `useBackendTaskSearch` to cached query reads keyed by workspace ID and normalized Task Mode params.
- [ ] Migrate `useBackendFeatureSearch` to cached query reads keyed by workspace ID and normalized Feature Mode params.
- [ ] Preserve existing hook return shapes where practical.
- [ ] Ensure cached board/sidebar data renders immediately when returning to `/board` within the 5-minute cache window.
- [ ] Ensure manual reload and workspace sync still refetch current data.
- [ ] Update the existing 60-second board refresh so it refetches through the shared cache without forcing a full loading reset.

## T3 — Task/feature tab detail query cache migration

### Description
Migrate task and feature detail read APIs to the shared frontend cache so reopening a recently viewed task/feature tab or returning via browser visit-back reuses cached API data for the same workspace and entity.

### Required skills
- frontend-engineer
- typescript-best-practices
- nextjs-best-practices

### Subtasks
- [ ] Migrate `useWorkspaceTask` to cached query reads keyed by workspace ID and task ID.
- [ ] Migrate `useFeatureDetail` to cached query reads keyed by workspace ID and feature ID.
- [ ] Migrate `useFeatureTask` to cached query reads keyed by workspace ID, feature ID, and task ID.
- [ ] Preserve existing loading, error, and retry behavior while using cached data when available.
- [ ] Ensure reopening a recently viewed task tab avoids unnecessary loading waits within the 5-minute cache window.
- [ ] Ensure reopening a recently viewed feature tab avoids unnecessary loading waits within the 5-minute cache window.
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

## T6 — Regression tests and browser/network QA

### Description
Verify the cache migration, board visual fixes, Task Mode `In Reviewing` status, and log link formatting together. This task should prove both UI behavior and reduced duplicate-fetch behavior during mode switching, tab switching, and browser visit-back.

### Required skills
- browser-qa-frontend
- typescript-best-practices

### Subtasks
- [ ] Add tests proving Task Mode and Feature Mode cache entries are independent and scoped by workspace/query params.
- [ ] Add tests proving returning from task/feature tabs to `/board` renders cached sidebar and kanban data immediately within the 5-minute window.
- [ ] Add tests proving reopening a recently viewed task/feature tab reuses cached detail data.
- [ ] Add tests proving manual refresh and workspace sync refetch or invalidate affected workspace data.
- [ ] Add tests proving workspace switching cannot leak cached data from the previous workspace.
- [ ] Run focused render tests for removal of `Create Task` and `Recent updates`.
- [ ] Run focused render tests for Task Mode `In Reviewing` and Feature Mode exclusion.
- [ ] Run focused log-link tests for HTTP/HTTPS highlighting and safe new-tab links.
- [ ] Run browser QA for `/board` mode switching, task/feature tab switching, and browser visit-back with network request observation.
