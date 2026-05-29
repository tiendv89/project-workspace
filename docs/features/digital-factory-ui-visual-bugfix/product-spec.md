# Product Specification

## Feature

- Feature ID: `digital-factory-ui-visual-bugfix`
- Title: Digital Factory UI Visual Bug Fix
- Implementation repo: `digital-factory-ui`
- GitHub: https://github.com/tiendv89/digital-factory-ui

## Problem

The `/board` screen has a few visual and interaction issues that make the board
feel noisy, incomplete, and slower than needed:

1. The board currently shows a `Create Task` action and a `Recent updates`
   section, but this bug-fix track should keep `/board` focused on reviewing the
   existing workflow state.
2. Task Mode does not expose an `In Reviewing` status on the kanban board, so
   tasks that are actively being reviewed can be hidden or mixed into a less
   precise review state.
3. Activity logs and task logs render HTTP/HTTPS links as plain text, making it
   hard to identify useful references such as GitHub PRs, issue links, or
   external evidence.
4. Switching between Task Mode and Feature Mode repeatedly causes fresh data
   fetches and visible loading flicker even when the same board data was just
   loaded.
5. Within the same workspace, switching between open task/feature tabs and the
   default board screen reloads data again. Users have to wait for the sidebar
   and kanban board loading states even though they were just viewing the same
   workspace.
6. From a feature tab, clicking a task currently does not behave like a normal
   workspace task tab. The expected flow is feature tab -> task tab -> Back
   closes the task tab and returns to the parent feature tab.

## Goals

- Keep `/board` focused on the kanban workflow by removing unrelated creation
  and recent-update UI from this screen.
- Show the full Task Mode review lifecycle on the board, including an
  `In Reviewing` column/status.
- Make HTTP/HTTPS links inside logs visually recognizable and directly
  clickable.
- Avoid unnecessary fetches and loading flicker when users switch between Task
  Mode and Feature Mode within a short time window.
- Avoid unnecessary fetches and loading flicker when users switch between
  workspace tabs and the default board screen in the same workspace.
- Use TanStack Query for frontend read caching and automatic 1-minute refetches
  instead of ad hoc `useEffect` fetch loops or manual intervals.
- Opening a task from inside a feature tab should create or activate a task tab,
  and the task tab Back action should close that task tab and return to the
  parent feature tab.
- Preserve the existing board layout, status semantics, and detail workflows
  except for the targeted fixes listed in this spec.

## Non-goals

- No backend API changes are required by this product spec.
- No redesign of the full kanban board.
- No new task-creation workflow on `/board`.
- No changes to Feature Mode status definitions beyond preserving its existing
  behavior.
- No server-side caching or CDN behavior.
- No changes to authentication, authorization, or workspace selection.

## User Journey

### Journey 1 - Use a cleaner `/board` screen

1. The user opens `/board`.
2. The board shows the workflow view and its mode controls.
3. The `Create Task` button is not visible on this screen.
4. The `Recent updates` section is not visible on this screen.

### Journey 2 - Review tasks in Task Mode

1. The user switches to Task Mode.
2. The kanban board shows the existing task-status columns plus an
   `In Reviewing` column/status.
3. Tasks currently in the reviewing state appear in that column.
4. Empty `In Reviewing` states behave like the other empty task columns.
5. Feature Mode remains unchanged and does not inherit Task Mode-only statuses.

### Journey 3 - Open links from logs

1. The user opens a task detail view, activity log, or any log surface that can
   contain plain text log messages.
2. If a log message includes an HTTP or HTTPS URL, the URL is highlighted as a
   link.
3. The user clicks the highlighted link.
4. The link opens in a new browser tab, and the current board remains open.
5. Non-link text remains readable as normal log text.

### Journey 4 - Switch modes without repeated refetches or flicker

1. The user switches between Task Mode and Feature Mode on `/board`.
2. The board uses cached data for recently loaded mode data.
3. The board avoids full loading resets when valid cached or previous data is
   available.
4. Background refetches may run, but the previous board content remains visible.

### Journey 5 - Switch between tabs and the default board smoothly

1. The user opens a task tab or feature tab from the board.
2. The user switches back to the default board screen that shows the sidebar and
   kanban board.
3. The board reuses recently loaded workspace data instead of showing a full
   loading wait again.
4. The user can switch between tabs and the board repeatedly without repeated
   fetch/loading interruptions or visual flicker for the same workspace.

### Journey 6 - Open a task from a feature tab and return cleanly

1. The user is viewing a feature tab.
2. The user clicks a task in that feature's task list.
3. The app opens or activates the corresponding task tab in the workspace tab
   strip.
4. The user clicks Back from the task tab.
5. The task tab is removed from the tab strip.
6. The parent feature tab becomes active again.
7. If a task tab has no parent feature return target, Back keeps the existing
   behavior of closing the task tab and returning to the default board.

## Product Requirements

### Board cleanup

- `/board` must not show a `Create Task` button.
- `/board` must not show a `Recent updates` section.
- Removing those elements must not break existing board navigation, mode
  switching, filtering, or task/feature detail opening.

### Task Mode `In Reviewing` status

- Task Mode must include a visible `In Reviewing` column/status.
- Tasks in the reviewing state must be grouped under `In Reviewing`.
- The label must be human-readable as `In Reviewing`.
- The column must match the visual behavior of the other Task Mode columns,
  including empty state and scrolling/collapse behavior where applicable.
- Feature Mode must not show this Task Mode-only status.

### Link formatting in logs

- HTTP and HTTPS URLs in activity/log text must be visually highlighted.
- Highlighted URLs must be clickable links.
- Clicking a link must open it in a new tab without navigating the board away.
- Log text without links must render normally.
- Malformed URL-like text must not crash the log surface.

### Mode-switch data caching

- Frontend read API data used by the board must be managed through TanStack
  Query.
- Cached read data should use a 1-minute cache lifetime. In TanStack Query v5
  terms, the relevant `gcTime` / cache time should be 1 minute.
- Active board read queries should refresh through TanStack Query
  `refetchInterval` every 1 minute instead of a separate manual interval.
- Switching between Task Mode and Feature Mode should reuse recently loaded data
  instead of fetching continuously.
- Switching between Task Mode and Feature Mode must not blank the board or show
  a full loading state when valid cached or previous data exists.
- Manual refresh, workspace change, or changed board controls should still load
  the correct current data.
- The implementation should replace local `useEffect` + state fetch loops for
  board read APIs with TanStack Query reads where those loops own backend API
  request lifecycle.

### Workspace tab and default-screen data caching

- Recently loaded workspace API data should remain available when the user
  switches between task tabs, feature tabs, and the default board screen.
- Returning to the default board screen in the same workspace should not force a
  full reload of the sidebar and kanban board if the data was recently loaded.
- Reopening a recently viewed task or feature tab should avoid unnecessary
  loading waits for the same data.
- Switching between task and feature tabs should keep the previous content or
  cached content visible when available so the app does not flicker through
  empty loading states.
- Manual refresh and workspace sync must still fetch current data.

### Feature-to-task tab navigation

- Clicking a task from inside a feature tab must open or activate the task as a
  workspace task tab.
- The task tab should keep enough return context to know when it was opened from
  a feature tab.
- Back from a task tab opened from a feature tab must close the task tab, remove
  its tab header, and reactivate the parent feature tab.
- Back from a task tab opened directly from the board should keep the existing
  behavior: close the task tab and return to the default board.
- The feature tab itself must remain open when returning from the task tab.

## Acceptance Criteria

- `/board` no longer displays `Create Task`.
- `/board` no longer displays `Recent updates`.
- Task Mode includes an `In Reviewing` column/status.
- Tasks in the reviewing state appear under `In Reviewing`.
- Feature Mode does not display the Task Mode-only `In Reviewing` status.
- HTTP/HTTPS URLs in task activity logs and log views are highlighted and
  clickable.
- Clicking a formatted log link opens a new tab and keeps the board open.
- Plain log text remains unchanged.
- Invalid URL-like text does not crash the page.
- Switching between Task Mode and Feature Mode reuses cached frontend API data
  for recently loaded board data instead of fetching continuously or flickering
  through full loading states.
- Board read queries use TanStack Query `refetchInterval` set to 1 minute.
- Board read query cache time is 1 minute.
- Manual refresh, workspace changes, and changed board controls still fetch the
  appropriate latest data.
- Switching between task/feature tabs and the default board screen in the same
  workspace reuses recently loaded API data instead of forcing repeated loading
  states or duplicate fetches.
- The sidebar and kanban board remain usable immediately when returning to the
  default board screen with valid cached data.
- Clicking a task inside a feature tab opens or activates a task tab.
- Back from a feature-origin task tab closes and removes that task tab, then
  returns to the parent feature tab.
- Switching between task and feature tabs keeps cached or previous content
  visible when available and avoids visible blank/loading flicker.
