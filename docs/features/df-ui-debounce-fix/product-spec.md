# Product Specification

## Feature
**Feature ID:** df-ui-debounce-fix
**Title:** Fix UI: relative timestamps, active status indicators, search debounce, and task title wrapping in digital-factory-ui

## Problem

The digital-factory-ui currently has 3 UX issues that need to be addressed:

1. **Task sidebar does not display update timestamps.** Users cannot tell when a task was last updated, making it difficult to track progress and data freshness.

2. **The `in_progress` and `reviewing` statuses lack a visual indicator that the task is actively being processed.** Users cannot distinguish between a task that is currently running (an agent is working on it) and one that is idle (waiting).

3. **The search input in both task mode and feature mode has no debounce.** Every keystroke triggers an API request, wasting resources and causing a laggy user experience.

4. **Task card titles are shortened (shorthand/ellipsis).** Users cannot read the full task title in the sidebar or in task cards across feature/task modes; titles should display the full text and wrap up to 5 rows.

## Goals

- Display relative timestamps for each task in the sidebar based on the `updated_at` field, compared against the browser's current time. Format: `just now`, `45s ago`, `1m ago`, `2 hours ago`, `1 day ago`, etc.
- The timestamp must be **visually prominent** so users can easily notice it.
- Add an animated loading spinner icon for tasks with `in_progress` and `reviewing` statuses so users know an agent is actively processing the task.
- The loading icon must be **visually prominent** and easy to recognize.
- Add a 300ms debounce to the search input in both task list mode and feature list mode.
- Display full task title text in the sidebar and in task cards across feature/task modes (no shorthand), allowing wrapping up to 5 rows. If the title exceeds 5 rows, clamp at row 5.

## Non-goals

- Do not change backend logic or API response format.
- Do not add real-time polling for timestamps — relative time is calculated at render time only.
- Do not change the current sidebar filtering or sorting behavior.
- Do not add websockets or server-sent events for status updates.
- Do not redesign the task card layout beyond title wrapping/clamping.

## Success criteria

- Every task in the sidebar displays a relative timestamp (e.g., "just now", "45s ago", "3m ago", "1 hour ago", "2 days ago") based on `updated_at`.
- The timestamp is visually prominent (distinct color or font weight) compared to other sidebar information.
- The relative time is recalculated when the user switches tabs or refocuses the browser window.
- Tasks with `in_progress` status display a clearly visible animated spinner icon.
- Tasks with `reviewing` status display a clearly visible animated spinner icon.
- Rapid typing in the task/feature search input does not trigger API requests until the user stops typing for at least 300ms.
- Task card titles in the sidebar and in task cards across feature/task modes display full text across up to 5 rows (no shorthand). If longer than 5 rows, the text is clamped at the 5th row.
- Existing functionality is not affected (regression-free).

## User stories

- **As a developer**, I want to see the last update time of each task in the sidebar so I can tell which tasks were recently changed and which are stale.
- **As a tech lead**, I want to see a loading icon on tasks being processed by an agent (`in_progress`, `reviewing`) so I can distinguish actively running tasks from idle ones without opening task details.
- **As any user**, I want a smooth search experience — typing should not cause lag or jank, and API calls should only fire after I finish typing.
- **As a user**, I want to read the full task title in the sidebar and in task cards across feature/task modes without shorthand, even if it spans multiple lines (up to 5 rows).

## Architecture decisions (resolved during spec discussion)

### D1. Client-side relative time calculation

Use the browser's current time (`Date.now()`) to compare against `updated_at` from the API. The relative time is recalculated on each component re-render (window focus, tab change, or data refresh).

**Rationale:** No backend changes required. Simply parse `updated_at` and compute the delta on the client.

### D2. 300ms debounce for search input

Apply a 300ms debounce — the standard interval for search inputs, balancing responsiveness with API load reduction.

**Rationale:** 300ms is the industry standard for search debounce. It is fast enough that users do not perceive a delay, yet long enough to eliminate redundant requests.

### D3. CSS-only animated spinner for active statuses

Use CSS `@keyframes` animation (no external library) for the spinner icon. Use an accent color for visual prominence. Apply the same spinner style to both `in_progress` and `reviewing` statuses.

**Rationale:** No new dependencies. CSS animation is sufficient for a spinner. A single spinner style for both active statuses ensures visual consistency.

### D4. Task title wrapping with a 5-row clamp

Render task titles as multi-line text (no shorthand) across the sidebar and task cards in feature/task modes, and apply a 5-row line clamp (`line-clamp: 5`, `-webkit-line-clamp: 5`). This preserves readability while preventing cards from growing unbounded in height.

**Rationale:** Users can read the full title in most cases, while the UI remains stable even with very long titles.

## Open questions for discussion

- Should relative timestamps also be displayed in the feature list, or only in the task sidebar?
- Is 300ms the right debounce interval, or should it be adjusted?

## Dependencies and risks

### Dependencies

- The API response already includes an `updated_at` field per task — no backend changes needed.
- The browser must support the `Date` API and CSS `@keyframes` animation (all modern browsers do).

### Risks

- If `updated_at` is `null` or missing, a fallback of "N/A" should be displayed, or the timestamp should be hidden.
- Debounce may feel "slow" to fast typists — UX testing is required.
- The spinner animation may be distracting if many tasks are in an active state simultaneously — consider a subtle animation style.
- Long titles could increase card height and cause layout shift; the 5-row clamp mitigates this but should be validated visually in sidebar + feature/task cards.
