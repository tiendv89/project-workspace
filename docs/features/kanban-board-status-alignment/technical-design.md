# Technical Design

## Feature

- Feature ID: `kanban-board-status-alignment`
- Title: `Kanban Board Status Alignment`
- Implementation repo: `digital-factory-ui`

## 1. Current state

The approved product spec defines the status contract this feature must render.

The affected implementation surface is the Digital Factory UI board. The
frontend has task sidebar and kanban board status configuration that controls:

- which task statuses appear in the sidebar and board,
- which labels are shown for status values,
- which kanban status columns appear in Feature Mode,
- which kanban status columns appear in Task Mode.
- which status filter options are available in each mode.

The product spec fixes a narrower UI contract than the full task lifecycle:

- Feature Mode must show `in_design`, `in_tdd`,
  `ready_for_implementation`, `in_implementation`, `in_handoff`, `done`,
  `blocked`, and `cancelled`.
- Task Mode must show `todo`, `ready`, `in_progress`, `blocked`,
  `in_review`, `reviewing`, `done`, and `cancelled`.
- `In Review` must map to `in_review`.
- `In Reviewing` must map to `reviewing`.

These mode lists are strict allowlists. The implementation must remove any
existing Feature Mode or Task Mode kanban status column that is not in the
corresponding product-spec list.

The status filters for both modes must follow the same allowlists. If a filter
currently exposes or submits a status outside the supplied list for that mode,
that old filter option/value must be removed.

Current limitations:

- The sidebar is missing a distinct `In Review` label for `in_review`.
- Review-related task display risks conflating `in_review`, `reviewing`, and
  the non-canonical `in_reviewing` value.
- Feature Mode and Task Mode can drift if they share one broad status list or
  if display labels are patched per component.

Repo boundary:

- `project-workspace` owns this feature plan.
- `digital-factory-ui` owns the frontend implementation.
- `workflow-backend` owns the feature-list API behavior for
  `/api/workspaces/:workspaceId/features`.

## 2. Problem framing

The frontend must align board/sidebar status display with the approved product
contract while keeping unrelated workflow data, navigation, search UX,
pagination UX, and detail behavior stable. The backend must also make
task-status filtering on the feature-list endpoint match the included task
results.

What needs to change:

- Add or correct a label mapping for `in_review` -> `In Review`.
- Add or correct a label mapping for `reviewing` -> `In Reviewing`.
- Ensure Task Mode status columns use the exact eight-value task list from the
  product spec.
- Ensure Feature Mode status columns use the exact eight-value feature list from
  the product spec.
- Remove any existing kanban status column that is outside the supplied list for
  its mode.
- Ensure Feature Mode status filters use only the supplied Feature Mode status
  list.
- Ensure Task Mode status filters use only the supplied Task Mode status list.
- Remove any existing status filter option/value that is outside the supplied
  list for its mode.
- Update the feature-list API so `include=tasks&status=<task-status-list>`
  excludes any feature whose included task list is empty after applying the task
  status filter.
- Replace any frontend-only `in_reviewing` mapping that is being used
  as the value for `In Reviewing`.

What must remain stable:

- Existing board card data shape.
- Existing backend query params and API contracts.
- Existing card click behavior and tab/detail navigation.
- Existing search UX, pagination UX, empty-state behavior, and loading
  behavior outside the status allowlist/filter corrections described in this
  feature.
- Existing styling system except for status labels/visibility implied by this
  feature.

Fixed assumptions:

- Backend values already use workflow status strings.
- UI status display and filter-option work is frontend-owned, while the
  feature-list `include=tasks&status=...` response filtering is a backend fix.
- The product spec intentionally excludes task statuses
  `review_passed`, `review_incomplete`, and `change_requested` from Task Mode
  kanban columns for this UI.
- Excluded statuses must not remain visible as extra Task Mode columns.
- Excluded statuses must not remain visible or selectable in Task Mode filters.

## 3. Options considered

### TD-A. Status contract location

#### Option A1 - Centralize status labels and mode lists

Define or correct shared frontend status configuration for task labels, Feature
Mode columns, and Task Mode columns. Sidebar and kanban board consume that
configuration.

Pros:

- Keeps labels, filters, and mode-specific status lists consistent.
- Reduces risk of one component showing stale values.
- Makes tests straightforward because the status contract has one source.

Cons:

- Requires finding all current status configuration consumers.
- May need small refactors if sidebar and kanban board currently own separate
  status arrays.

Implementation impact:

- Update the existing status constants/configuration module or introduce a
  small local status contract module if none exists.
- Wire sidebar and kanban board status rendering to the corrected values.
- Wire Feature Mode and Task Mode status filters to the corrected mode-specific
  values.

Dependency impact:

- Depends only on existing frontend code paths.

#### Option A2 - Patch labels and columns per component

Change the sidebar, kanban board, and filters independently where each status
appears.

Pros:

- Quick for a very small code path.
- Minimal abstraction work.

Cons:

- Higher risk of inconsistent sidebar vs board behavior.
- Higher risk of inconsistent filter vs board behavior.
- Easier for `in_reviewing` to survive in one surface.
- More duplicate tests and future maintenance.

Implementation impact:

- Patch each visible component and its tests separately.

Dependency impact:

- No external dependencies, but each component remains a separate source of
  truth.

#### Recommendation: Option A1

Use a shared frontend status contract for labels and mode-specific kanban lists.
The product requirement is about consistency across sidebar, board, and filters,
so one contract is safer than per-component patches.

### TD-B. Handling non-canonical `in_reviewing`

#### Option B1 - Replace `in_reviewing` with `reviewing`

Treat `reviewing` as the only value for the `In Reviewing` label. Remove
frontend display mappings that use `in_reviewing`.

Pros:

- Matches the approved product spec.
- Matches the approved task status value for this UI.
- Avoids hidden local status values.

Cons:

- If old mock data or tests use `in_reviewing`, they need updates.

Implementation impact:

- Search frontend status constants, fixtures, mocks, and tests for
  `in_reviewing`.
- Replace it with `reviewing` where it represents the task status value.

Dependency impact:

- No backend dependency.

#### Option B2 - Alias `in_reviewing` to `reviewing`

Keep accepting `in_reviewing` as a UI alias while showing `In Reviewing`.

Pros:

- Could preserve compatibility with stale fixtures.

Cons:

- Preserves a non-canonical value.
- Makes tests less strict and can hide future data-contract drift.
- Conflicts with the product success criterion.

Implementation impact:

- Add alias normalization in the frontend.

Dependency impact:

- No backend dependency, but the UI contract remains less precise.

#### Recommendation: Option B1

Use `reviewing` as the only value for `In Reviewing`. Update stale frontend
fixtures/tests instead of preserving a non-canonical alias.

### TD-C. Feature-list task-status filtering

#### Option C1 - Filter parent features after applying included-task status filters

When `include=tasks` and a task-status `status` filter are present, apply the
task status filter to included tasks and exclude parent features whose resulting
included `tasks` array is empty.

Pros:

- Matches the user's observed API expectation directly.
- Keeps response semantics aligned: a filtered feature row must have matching
  included tasks.
- Prevents the frontend from receiving and then hiding irrelevant features.

Cons:

- Changes current backend response behavior for this query shape.
- Requires backend tests around pagination/total semantics.

Implementation impact:

- Update the `workflow-backend` feature-list query path for
  `/api/workspaces/:workspaceId/features`.
- Ensure `total` reflects the post-filter feature count for the request.
- Add API/query tests where a feature with no matching included tasks is
  excluded.

Dependency impact:

- No frontend dependency for the backend behavior, but frontend filter results
  depend on this response contract being correct.

#### Option C2 - Keep backend response and hide empty-task features in frontend

Allow the backend to return features with `tasks: []` and filter them out in the
Digital Factory UI.

Pros:

- Avoids backend query changes.
- Can be implemented quickly in one frontend surface.

Cons:

- Leaves the API contract incorrect for other consumers.
- Makes `total` misleading because it can include features hidden by the
  frontend.
- Duplicates filtering logic outside the source endpoint.

Implementation impact:

- Add frontend-only filtering before rendering Feature Mode results.

Dependency impact:

- Future API consumers would need to repeat the same workaround.

#### Recommendation: Option C1

Fix the backend endpoint. The user-provided example shows the API itself is
returning non-matching features for a task-status filtered request, so the
correct behavior belongs in `workflow-backend`, not only in the frontend.

## 4. Chosen design

Selected options:

- `TD-A`: **Option A1** — centralize status labels and mode lists.
- `TD-B`: **Option B1** — replace `in_reviewing` with `reviewing`.
- `TD-C`: **Option C1** — filter parent features after applying included-task status filters.

Implement three frontend tasks in `digital-factory-ui`, one backend filtering
task in `workflow-backend`, and one validation task in `digital-factory-ui`.

The frontend work is split into:

- a shared status-contract task,
- a kanban-column wiring task,
- a mode-specific filter wiring task.

The backend task should:

- update `/api/workspaces/:workspaceId/features` when called with
  `include=tasks&status=<task-status-list>`,
- apply the status filter to included tasks,
- exclude parent features whose included `tasks` array is empty after that
  filter,
- keep pagination metadata consistent with the filtered feature set,
- add backend tests for the empty-task exclusion and total count.

The validation task should:

- verify the shared status contract is reflected in sidebar labels, kanban
  columns, and mode-specific filters,
- verify the frontend does not reintroduce removed status values,
- verify the stricter backend filtered response is consumed correctly,
- verify backend-complete is not treated as done until the frontend is run
  against the changed API behavior and the combined flow passes.

Affected repositories:

- `digital-factory-ui`: implementation and tests.
- `workflow-backend`: feature-list API filtering and tests.
- `project-workspace`: planning artifacts only.

Compatibility considerations:

- No new API query params.
- The backend response becomes stricter for `include=tasks&status=...`: features
  without matching included tasks are omitted.
- If frontend board configuration currently includes a status outside the
  supplied mode list, that status must be removed from the kanban columns for
  that mode.
- If frontend filter configuration currently includes a status outside the
  supplied mode list, that status must be removed from the filter for that mode.
- If backend data contains a status outside the visible mode list, the board
  must not create an extra kanban column for it.
- If URL/query state or stale UI state contains a status outside the visible
  mode list, the filter should not expose that value as an available option for
  that mode.
- Existing board interactions and navigation should remain unchanged.
- Backend task completion requires integration evidence that the Digital Factory
  UI no longer renders features whose task list becomes empty under
  `include=tasks&status=...`.

Operational and release implications:

- Normal frontend deploy only.
- No migration or feature flag required.

## 5. Dependency analysis

### Internal dependencies

- Existing Digital Factory UI sidebar status rendering.
- Existing Digital Factory UI kanban board mode/status configuration.
- Existing Digital Factory UI status filter option/query configuration.
- Existing workflow-backend feature-list query/filter implementation.
- Existing frontend tests or test utilities for board/sidebar rendering.
- A reproducible frontend path that exercises the backend
  `include=tasks&status=...` contract after the backend change lands.
- Existing backend API/query tests for workspace feature listing.

### External dependencies

- None.

### Blocking decisions

- None. Product status lists, label mappings, and backend filtered-response
  behavior are fixed.

### Vendor/tooling choices

- No new vendor or library dependency.
- Use existing frontend test runner and component test patterns.
- Use existing backend test/query patterns in `workflow-backend`.

### Configuration dependencies

- None.

### Release dependencies

- Standard `digital-factory-ui` build/test/deploy flow.
- Standard `workflow-backend` build/test/deploy flow.

### Unresolved dependencies

- None.

## 6. Parallelization / blocking analysis

External decisions/dependencies:

- None. The product spec fixes status lists, label mappings, and backend
  filtered-response behavior.

Per-task dependency diagram:

```text
T1: Define shared frontend status contract — digital-factory-ui
  └── Can begin now — no blockers

T2: Wire kanban columns to the new status contract — digital-factory-ui
T3: Wire mode-specific status filters to the new contract — digital-factory-ui
  └── T2 and T3 run in parallel
  └── BLOCKED on T1 (shared frontend status contract must be finalized first)

T4: Exclude empty task matches from feature-list API — workflow-backend
  └── Can begin now — no blockers

T5: Regression and integration validation — digital-factory-ui
  └── BLOCKED on T2 (kanban columns must use the new status contract)
  └── BLOCKED on T3 (filters must use the new status contract)
  └── BLOCKED on T4 (backend filtered feature-list response must be available)
```

T1 is the frontend foundation. T2 and T3 then split the visible board/filter
work so they can proceed in parallel without mixing concerns. T4 is independent
backend API work. T5 is held until both the frontend contract changes and the
backend filtered-response fix are available.

## 7. Repository impact

- `digital-factory-ui`: update frontend status configuration, sidebar label
  rendering, kanban mode status lists, mode-specific filter options/query
  values, fixtures/mocks if needed, and focused tests.
- `workflow-backend`: update feature-list filtering so
  `include=tasks&status=...` returns only features with at least one included
  task matching the requested statuses; add API/query tests and verify `total`.
- `project-workspace`: stores this feature plan, technical design, task
  breakdown, and task state.

Task repo values must use `digital-factory-ui` and `workflow-backend`, both of
which are declared in `workspace.yaml`.

## 8. Validation and release impact

### Testing expectations

- Focused unit/component tests for task status labels:
  - `in_review` renders `In Review`.
  - `reviewing` renders `In Reviewing`.
- Focused tests for Feature Mode status list and order.
- Focused tests for Task Mode status list and order.
- Focused tests proving Feature Mode and Task Mode do not render any old status
  columns outside the supplied lists.
- Focused tests proving Feature Mode and Task Mode filters expose only the
  supplied status lists and do not submit old statuses.
- Focused tests proving the shared frontend status contract drives both columns
  and filters.
- Regression check that `in_reviewing` is not used as the task status value for
  `In Reviewing`.
- Existing board/sidebar tests should continue to pass.
- Backend API/query tests for
  `/api/workspaces/:workspaceId/features?include=tasks&status=...` proving:
  - features with `tasks: []` after status filtering are excluded,
  - features with at least one matching task remain,
  - `total` matches the filtered feature count.

### Migration / config impact

- No database migration.
- No runtime config change.
- No backend schema change.
- Existing endpoint behavior changes only for the filtered
  `include=tasks&status=...` query shape.

### Rollout concerns

- Low-risk frontend/backend behavior release.
- Watch for any stale fixture/mock data using `in_reviewing`.
- Watch for any consumer that expected parent features with empty included task
  arrays in filtered feature-list responses.

### Backward compatibility

- Backend status values remain unchanged.
- Backend response semantics become stricter for task-status filtered
  `include=tasks` feature-list requests.
- Existing user navigation and board interactions remain unchanged.

### Deployment / handoff implications

- Handoff should include the final status lists, filter option/value evidence,
  label/value mapping evidence, backend API filtering evidence, and test
  results from `digital-factory-ui` and `workflow-backend`.
