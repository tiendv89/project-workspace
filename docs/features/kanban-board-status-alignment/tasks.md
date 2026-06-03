# Task Breakdown — kanban-board-status-alignment

Feature status: `in_tdd`. Stage: `tasks` (`awaiting_approval`; task breakdown revised and not yet approved). Machine state lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Define shared frontend status contract | — |
| T2 | 2 | Wire kanban columns to the new status contract | T1 |
| T3 | 2 | Wire mode-specific status filters to the new contract | T1 |
| T4 | 1 | Exclude empty task matches from feature-list API | — |
| T5 | 3 | Regression and integration validation | T2, T3, T4 |

## T1 — Define shared frontend status contract

### Description
Create or update the shared Digital Factory UI status contract used by board/sidebar rendering so labels and allowed statuses are defined in one place. This task establishes `in_review -> In Review`, `reviewing -> In Reviewing`, removes non-canonical `in_reviewing` usage as a status value, and defines the canonical allowlists for Feature Mode and Task Mode.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Locate the shared status constants, mapping helpers, or config module currently used by board and sidebar status rendering.
- [ ] Add or correct the `in_review` -> `In Review` label mapping.
- [ ] Add or correct the `reviewing` -> `In Reviewing` label mapping.
- [ ] Replace stale `in_reviewing` status value usage with `reviewing` where it represents `In Reviewing`.
- [ ] Define the Feature Mode allowlist as `in_design`, `in_tdd`, `ready_for_implementation`, `in_implementation`, `in_handoff`, `done`, `blocked`, `cancelled`.
- [ ] Define the Task Mode allowlist as `todo`, `ready`, `in_progress`, `blocked`, `in_review`, `reviewing`, `done`, `cancelled`.
- [ ] Add focused unit coverage for the shared label/value mapping and the two mode allowlists.

---

## T2 — Wire kanban columns to the new status contract

### Description
Apply the shared frontend status contract to kanban rendering so Feature Mode and Task Mode display only their supplied status columns in the specified order. This task removes any old status column outside the active mode allowlist and ensures the board never creates extra columns from legacy frontend config.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Locate the Feature Mode and Task Mode kanban column definitions.
- [ ] Render Feature Mode columns from the Feature Mode allowlist in order.
- [ ] Render Task Mode columns from the Task Mode allowlist in order.
- [ ] Remove any old Feature Mode or Task Mode kanban status column that is not in the supplied list for that mode.
- [ ] Ensure task/feature rows are grouped only into allowed columns for the active mode.
- [ ] Add render tests proving column order and absence of old status columns in Feature Mode.
- [ ] Add render tests proving column order and absence of old status columns in Task Mode.

---

## T3 — Wire mode-specific status filters to the new contract

### Description
Apply the same shared status contract to the Feature Mode and Task Mode filters. Each mode must expose only its supplied statuses, stop submitting old status values, and keep query serialization aligned with the visible filter options.

### Required skills
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Locate the Feature Mode and Task Mode status filter option builders and query serialization path.
- [ ] Configure Feature Mode status filters to expose only `in_design`, `in_tdd`, `ready_for_implementation`, `in_implementation`, `in_handoff`, `done`, `blocked`, `cancelled`.
- [ ] Configure Task Mode status filters to expose only `todo`, `ready`, `in_progress`, `blocked`, `in_review`, `reviewing`, `done`, `cancelled`.
- [ ] Remove any old Feature Mode or Task Mode filter option/query status that is not in the supplied list for that mode.
- [ ] Ensure stale URL/query/UI state does not reintroduce removed status values as visible filter options.
- [ ] Add focused tests proving filters in both modes expose and submit only the supplied status lists.

---

## T4 — Exclude empty task matches from feature-list API

### Description
Update `workflow-backend` so `/api/workspaces/:workspaceId/features?include=tasks&status=...` returns only features that have at least one included task matching the requested task statuses. If a feature's included `tasks` array is empty after the status filter is applied, exclude that feature from the response and ensure pagination metadata such as `total` reflects the filtered feature set. This task is not considered complete on backend-only tests; it must leave a contract that T5 verifies through the real frontend consumer path.

### Required skills
- backend-engineer
- typescript-best-practices

### Subtasks
- [ ] Locate the feature-list endpoint/query path for `/api/workspaces/:workspaceId/features`.
- [ ] Identify the `include=tasks` and task-status `status` filtering flow.
- [ ] Apply task-status filtering before deciding whether a parent feature matches the request.
- [ ] Exclude parent features whose included `tasks` array is empty after task-status filtering.
- [ ] Ensure `total`, `page`, and `limit` metadata reflect the filtered feature result set.
- [ ] Add backend tests where a done feature with no tasks matching `todo,ready,in_progress,reviewing,blocked,in_review,cancelled` is excluded.
- [ ] Add backend tests where a feature with at least one matching task remains and includes only matching tasks.
- [ ] Document the expected filtered response shape needed by the frontend integration check.
- [ ] Run focused backend validation for the feature-list API.

---

## T5 — Regression and integration validation

### Description
Verify the frontend and backend changes together after the status-contract and API filtering work land. This task confirms the board surfaces show only the new statuses, filters submit only allowed values, and the feature-list API no longer returns filtered-out features with `tasks: []`. Backend completion is accepted only after this cross-repo integration check passes.

### Required skills
- browser-qa-frontend
- frontend-engineer
- typescript-best-practices

### Subtasks
- [ ] Add or update focused frontend tests for sidebar label rendering.
- [ ] Verify Feature Mode and Task Mode render only the approved columns and filter options.
- [ ] Verify `in_reviewing` is not used as a task status value for `In Reviewing`.
- [ ] Verify the frontend calls or consumes `/api/workspaces/:workspaceId/features?include=tasks&status=...` without showing empty-match features after the backend change.
- [ ] Verify the frontend consumes the stricter `include=tasks&status=...` response without reintroducing empty-match feature rows.
- [ ] Run focused backend and frontend validation suites for the changed status/filter/API paths.
- [ ] Run browser or integration QA covering both modes and the filtered feature-list behavior.
