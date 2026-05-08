# Technical Design

## Feature
- Feature ID: `ui-interaction-updates`
- Title: UI Interaction Updates

## 1. Current State

The implementation target is `digital-factory-ui`, a Next.js/React workspace dashboard app.

Relevant current implementation state from the repo:

- `/board` renders `BoardHeader`, `TaskTrackingPanel`, `KanbanBoard`, optional `TaskTrackingDetailPanel`, and `TaskDetailSheetMount`.
- `TaskTrackingPanel` currently behaves like a left navigation rail. Selecting `IN REVIEW`, `IN PROGRESS`, or `READY` replaces the Kanban Board with `TaskTrackingDetailPanel`.
- `TaskTrackingPanel` uses a fixed `w-72` width instead of a percentage-based 15% / 85% workspace split.
- `BoardProvider` loads the main board data with `useBoardData` and separate tracked pull-request task data with `usePullRequestTaskData`.
- Manual sync calls both reload functions, but there is no 60 second automatic refresh interval.
- The Kanban feature row already has partial support for status pills, done/total counts, a segment bar, last modified time, and collapsed rows.
- The current feature row label can fall back to `feature.title`; the product spec requires the displayed feature label to use `feature_id`.
- The status filter currently defaults to an empty selection, which means "show everything"; it is not persisted as a saved user preference.

Current constraints:

- Preserve existing workflow data contracts from parsed `status.yaml` and `tasks/T<n>.yaml`.
- Keep the implementation frontend-only inside `digital-factory-ui`; no backend change is required.
- Reuse the existing board context, GitHub Contents API client, YAML parsing, status helpers, and task detail sheet.
- The user-facing board must remain visible while interacting with the sidebar.
- Automatic refresh must not reset UI state such as collapse state, filters, search, selected task, or modal visibility.

## 2. Problem Framing

The UI needs to shift from a left navigation pattern to a persistent companion sidebar pattern.

The sidebar must:

- Occupy approximately 15% of the main workspace width on desktop, while the Kanban Board occupies approximately 85%.
- Render the 3 priority task rows directly in the sidebar: `IN PROGRESS`, `IN REVIEW`, and `READY`.
- Keep all 3 rows expanded by default, while allowing per-row collapse and expand.
- Show task cards inside the rows and open the existing task detail modal when a task is clicked.
- Refresh those 3 rows every 60 seconds without losing the user's current board context.
- Continue responding to search and status filter changes.

The Kanban Board must:

- Stay visible on the right while the sidebar is used.
- Keep collapsed feature rows by default.
- Display the feature row summary with `feature_id`, status pill, done/total count, equal task status segments, and last modified time when available.

The status filter must:

- Default to all statuses except `Done` when no saved preference exists.
- Persist the user's latest status filter choices across reloads.

## 3. Options Considered

### Option A: Keep current sidebar as navigation and only adjust labels

This keeps `TaskTrackingPanel` as a selector for `TaskTrackingDetailPanel`.

Pros:

- Small implementation change.
- Low immediate risk to existing files.

Cons:

- Violates the product requirement that the Kanban Board always remains visible.
- Does not show tasks directly inside the sidebar.
- Does not deliver the 15% / 85% companion layout.

Implementation impact:

- Minimal code changes, but the resulting UI would still be wrong.

Dependency impact:

- No new dependencies, but the design remains blocked by product mismatch.

### Option B: Convert the sidebar into a direct task companion panel

This removes the replacement-detail-panel interaction from the main flow and renders collapsible task groups directly in the sidebar.

Pros:

- Matches the product spec directly.
- Keeps the board visible while users inspect high-priority tasks.
- Reuses existing `TaskDetailSheetMount` for task details.
- Keeps implementation in existing board component boundaries.

Cons:

- Requires coordinated layout, context, filtering, and test updates.
- The current `TaskTrackingDetailPanel` becomes obsolete for the primary journey and should be removed or left unused intentionally.

Implementation impact:

- Update `/board` layout, `TaskTrackingPanel`, task grouping, context refresh behavior, and tests.

Dependency impact:

- No external dependency. Depends on existing parsed board and tracked task data.

### Option C: Merge sidebar tasks into the main Kanban Board columns

This would make the 3 priority rows part of the main board area instead of a left sidebar.

Pros:

- Avoids two parallel task displays.
- Could reduce duplicate filtering logic.

Cons:

- Violates the required left sidebar layout.
- Makes the board denser and harder to scan.
- Does not satisfy the explicit 15% / 85% workspace split.

Implementation impact:

- Larger board rewrite with poorer fit to the product requirement.

Dependency impact:

- No external dependency, but higher UI regression risk.

## 4. Chosen Design

Choose Option B: convert the sidebar into a persistent task companion panel.

The main workspace below the header will use a two-column flex/grid layout:

- Sidebar target width: approximately 15%.
- Kanban Board target width: approximately 85%.
- Sidebar should also define practical min/max width constraints so labels and task cards remain readable.
- Kanban Board should keep `min-width: 0` and own its internal horizontal scroll.

`TaskTrackingPanel` becomes the owner of the sidebar experience:

- Render 3 collapsible sections in product order: `IN PROGRESS`, `IN REVIEW`, `READY`.
- All sections start expanded.
- Each section shows a status icon, status label, and task count.
- Each section renders task cards directly below its header.
- Empty sections display `No tasks.`
- Clicking a task calls `setSelectedTask` from board context, opening the existing `TaskDetailSheetMount`.

Data and refresh behavior:

- Add a 60 second interval in the board data layer or `BoardProvider` that calls the same reload path as manual sync.
- The interval must be cleaned up on unmount.
- The interval should refresh the data backing the sidebar rows without resetting local UI state.
- Manual sync remains available and refreshes immediately.

Search and filter behavior:

- Sidebar task grouping should apply the current search query and active status filter before rendering cards.
- Default status filter should be all task statuses except `done` when no saved filter exists.
- Persist user-selected filter state in `localStorage`.

Feature row behavior:

- Feature row summary must display `feature.id` as the primary label.
- Segment bar should render one equal-width segment per task instead of grouped flex widths.
- Status pill, done/total count, and last modified time remain in the right-side group.

Affected repositories:

- `digital-factory-ui` only.

Compatibility considerations:

- Existing YAML shape remains unchanged.
- Existing connect/import workspace behavior remains unchanged.
- Existing task detail sheet is reused; no new modal contract is introduced.
- Existing manual sync behavior remains compatible and becomes one of two refresh paths.

Operational and release implications:

- No database migration.
- No backend service change.
- No new runtime secret.
- Browser QA must verify interval refresh with fake timers/unit tests and real manual sync behavior in the app.

## 5. Dependency Analysis

Internal dependencies:

- `TaskTrackingPanel` depends on `BoardProvider` context for task data, search/filter state, and `setSelectedTask`.
- Sidebar refresh depends on the existing reload functions from `useBoardData` and `usePullRequestTaskData`.
- Status filter persistence depends on `STATUS_COLUMNS`, `matchesStatusFilter`, and a new or extended localStorage helper.
- Feature row refinements depend on parsed `ParsedFeature` and `ParsedTask` data already available in `FeatureRow`.

External dependencies:

- GitHub Contents API remains the only remote data source used by the frontend.
- No new package is required.

Blocking decisions:

- None. The target ratio, sidebar rows, and 60 second refresh interval are now fixed by product direction.

Vendor/tooling choices:

- Continue using Next.js, React, TypeScript, Tailwind classes, HeroUI-compatible styling, and lucide-react icons already present in the repo.
- Continue using Vitest for unit tests.

Configuration dependencies:

- No new environment variable.
- `localStorage` is used for persisted status filter preferences, matching existing workspace and panel-selection storage patterns.

Release dependencies:

- Must be released after task approval.
- QA should run in a real browser against an imported workspace with tasks in `in_progress`, `in_review`, and `ready`.

## 6. Parallelization / Blocking Analysis

External decisions/dependencies:

None. Width split, sidebar row set, refresh interval, and target repo are fixed.

```text
T1: Board refresh and filter persistence foundation
  └── Can begin now — no blockers

T2: Sidebar companion panel and 15/85 board layout
  └── Can begin now — no blockers

T3: Feature row summary refinements
  └── Can begin now — no blockers
  └── T1, T2, and T3 run in parallel

T4: Integration tests and browser QA
  └── BLOCKED on T1 (refresh and persisted filter behavior must be implemented)
  └── BLOCKED on T2 (sidebar companion panel and layout must be in place)
  └── BLOCKED on T3 (feature row summary behavior must be final)
```

## 7. Repository Impact

### `digital-factory-ui`

Reason: owns the Next.js board UI, sidebar components, board context, status filters, and tests.

Expected affected areas:

- `src/app/board/page.tsx`
- `src/features/board/components/TaskTrackingPanel/`
- `src/features/board/components/KanbanBoard/`
- `src/features/board/components/FeatureRow/`
- `src/features/board/lib/`
- `src/features/board/hooks/`
- `src/__tests__/`

No other workspace repo should be changed for this feature.

## 8. Validation and Release Impact

Testing expectations:

- Unit tests for 60 second interval refresh using fake timers.
- Unit tests for default status filter excluding `done`.
- Unit tests for persisted status filter restore/save behavior.
- Unit tests for sidebar grouping order, empty state, task-card click, and search/filter application.
- Unit tests for feature row label and equal-width task segment rendering where practical.
- TypeScript type-check must pass.
- Production build should pass before PR.

Manual/browser QA expectations:

- Open `/board` with an imported workspace.
- Verify the header remains at the top.
- Verify sidebar left and Kanban Board right use approximately 15% / 85% of content width on desktop.
- Verify all 3 sidebar rows start expanded.
- Verify each row can collapse and expand independently.
- Verify `IN PROGRESS`, `IN REVIEW`, and `READY` task cards render directly in the sidebar.
- Verify clicking a sidebar task opens the task detail modal while the board remains visible.
- Verify search and status filter update sidebar and board results.
- Verify auto-refresh runs every 60 seconds without resetting search, filter, collapse state, selected modal, or board visibility.
- Verify manual sync still refreshes immediately.
- Verify feature rows stay collapsed by default and display `feature_id`, status pill, done/total, equal task segments, and last modified time.

Migration/config impact:

- No migration.
- No new runtime config.
- Adds or updates `localStorage` keys for status filter persistence.

Backward compatibility constraints:

- Existing workspace data remains readable.
- Existing task detail modal behavior remains intact.
- Existing manual sync remains intact.

Deployment/handoff implications:

- This is a frontend-only change in `digital-factory-ui`.
- Handoff should include the localStorage key used for persisted filters and the exact 60 second refresh behavior.
