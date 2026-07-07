
# Tasks — ui-go-owned-task-status-and-block

## Dependency diagram

```
T1: Expose dispatched_at/conflict_state/blocked_details/blocked_from_status (workflow-backend)
  │
  ├──> T2: Add POST .../tasks/:taskId/recover endpoint (workflow-backend)
  │      └── depends on T1 (sequenced into a separate commit/PR on the same files to avoid merge conflicts — see technical-design.md Parallelization section)
  │
  └──> T3: Task tab status display + Unblock + recover actions (digital-factory-ui)
         └── depends on T1 (needs the new read fields) and T2 (needs the recover endpoint)
```

No `workflow-bff` task exists — per technical-design.md, the BFF's existing longest-prefix-match routing already forwards the new `/recover` path to `workflow-backend` automatically; no BFF code, config, or test change is required.

T3 combines what was originally three separate frontend tasks (status display, explicit unblock, stuck-task recover) into one, since all three land in the same file (`SpecPanel` in `task-review-view.tsx`) and were only sequenced against each other to avoid concurrent edits — merging avoids that artificial overhead while preserving the real dependencies on T1 and T2.

## Index

| ID | Title | Repo | Depends On | Actor |
|---|---|---|---|---|
| T1 | Expose dispatched_at/conflict_state/blocked_details/blocked_from_status in task read API | workflow-backend | | agent |
| T2 | Add guarded POST .../tasks/:taskId/recover endpoint | workflow-backend | T1 | agent |
| T3 | Task tab: status display, explicit Unblock action, and stuck-task recover action | digital-factory-ui | T1, T2 | agent |

---

## T1 — Expose dispatched_at/conflict_state/blocked_details/blocked_from_status in task read API

### Description
The `workspace_tasks` table already has `dispatched_at`, `conflict_state`, `blocked_details`, and `blocked_from_status` columns (written by the orchestrator), but the read path in `workflow-backend` does not surface them. This task closes that gap so the API returns them on every task read/list/search response.

- Extend the SQL SELECT list in `internal/database/queries.go` for `GetWorkspaceTask`, `GetWorkspaceTaskByID`, `ListFeatureTasks`, `ListWorkspaceTasks`, and `searchTasks` to include `dispatched_at`, `conflict_state`, `blocked_details`, `blocked_from_status`.
- Extend the `WorkspaceTask` struct (`internal/database`) and all `scanTask`-equivalent scan calls to read the four new nullable columns (`dispatched_at *time.Time`, `conflict_state *string`, `blocked_details *string`, `blocked_from_status *string`).
- Extend `domain.TaskSummary` and `domain.TaskDetail` (`internal/domain`) with `DispatchedAt *time.Time`, `ConflictState string` (default `"none"` when the DB value is null), `BlockedDetails string`, `BlockedFromStatus string`.
- Extend `toTaskSummary` and `taskDetailFromRow` (`internal/service/workspace.go`) to populate the new fields.
- JSON field names: `dispatched_at`, `conflict_state`, `blocked_details`, `blocked_from_status` (snake_case, consistent with existing fields).
- This is purely additive to the response shape — no existing field is renamed, removed, or reinterpreted.

### Required skills
- go-best-practices

### Subtasks
- [ ] Extend SQL SELECT lists for all task read/list/search queries in `internal/database/queries.go`
- [ ] Add the four new nullable fields to the `WorkspaceTask` struct and update scan calls
- [ ] Add the four new fields to `domain.TaskSummary` / `domain.TaskDetail`
- [ ] Populate the new fields in `toTaskSummary` / `taskDetailFromRow`
- [ ] Add/extend unit tests covering the new fields appear in `GetWorkspaceTask`, `GetTask`, `SearchTasks`, `SearchWorkspaceTasks` responses (including the null → `"none"` default for `conflict_state`)
- [ ] Run full test suite + lint clean

---

## T2 — Add guarded POST .../tasks/:taskId/recover endpoint

### Description
Add a new endpoint that recovers a task stuck in an in-flight processing state, independent of the existing `/unblock` endpoint (which only handles `status = 'blocked'`). Per technical-design.md Option B:

- Route: `POST /api/workspaces/:workspaceId/features/:featureId/tasks/:taskId/recover`.
- Request body: optional `note` (same shape as `/unblock`'s body).
- Server-side guard logic, mutually exclusive branches, evaluated in this priority order:
  1. If `conflict_state = 'resolving'` → guarded `UPDATE ... SET conflict_state = 'conflicted' WHERE conflict_state = 'resolving'` (task `status` column untouched). Clear rebase dispatch columns (handle/nonce) the same way `rollbackResolving` does in `workflow-orchestrator`.
  2. Else if `status = 'reviewing'` → guarded `UPDATE ... SET status = 'in_review' WHERE status = 'reviewing'`, clearing dispatch columns (mirrors `dispatchOutExtra()`).
  3. Else if `status = 'in_progress'` → guarded `UPDATE ... SET status = 'ready' WHERE status = 'in_progress'`, clearing dispatch columns.
  4. Else → 409 (task is not in a recoverable processing state).
- Each branch is a single guarded `UPDATE ... WHERE ... AND <current-state predicate>` — no `SELECT`-then-`UPDATE` gap — consistent with the existing `GuardedTransition`-style helpers.
- On success, append a `workspace_activity_events` row in the same transaction: `action = 'recovered'`, optional `note`, and `from`/`to` describing the transition actually taken (for the conflict-resolving branch, `from`/`to` describe the conflict-state values, e.g. `"resolving"`/`"conflicted"` — not task status).
- Response shape mirrors `UnblockTaskResult`: `{ task_id, from, to }`.
- Must not modify the existing `/unblock` endpoint, its guard, or its tests.
- No `workflow-bff` changes are needed or in scope for this task — the BFF's existing longest-prefix-match routing already forwards this new path automatically (confirmed in technical-design.md).

### Required skills
- go-best-practices

### Subtasks
- [ ] Add the new route registration in `internal/handler/workspace.go` (`RegisterRoutes`)
- [ ] Implement the handler + service method (`WorkspaceService.RecoverTask` or equivalent) following the same shape as `UnblockTask`
- [ ] Implement the guarded, prioritized 3-branch DB transition in `database.Reader` (parallel to `UnblockTask`)
- [ ] Append the `workspace_activity_events` row (`action='recovered'`) in the same transaction
- [ ] Add unit tests: each of the three success branches, the 409 case (task in a non-recoverable state), 404 (unknown workspace/feature/task), and that `/unblock`'s existing tests still pass unmodified
- [ ] Run full test suite + lint clean

---

## T3 — Task tab: status display, explicit Unblock action, and stuck-task recover action

### Description
Combines the full Task tab detail panel work for this feature into one task: status display (product-spec.md Goal 1), the explicit "Unblock" action for `blocked` tasks (Goal 2), and the "Task is stuck? Unblock it" recover action for stuck processing tasks (Goal 3). All three land in `SpecPanel` (`src/components/tasks/task-review-view.tsx`) and depend on the new backend surface from T1 and T2.

**Types** (`src/services/workflow-backend/types.ts`)
- Add `dispatched_at?: string`, `conflict_state?: "none" | "conflicted" | "resolving" | "resolved"`, `blocked_details?: string`, `blocked_from_status?: string` to `TaskSummary`; ensure `TaskDetail` inherits them.

**Status display**
- Keep the existing `StatusBadge` as the primary status display (already explicit text, unchanged).
- Add a conflict-state indicator rendered only when `task.conflict_state` is present and not `"none"` — explicit text (e.g. "Conflict: Resolving"), rendered as a separate element from `StatusBadge`, not merged into it and not icon-only.
- Add a "Dispatched at: `<formatted timestamp>`" line rendered only when the task is in a processing state (`status === "in_progress" || status === "reviewing" || conflict_state === "resolving"`) and `dispatched_at` is present. Reuse the existing `formatTime` helper already in this file.
- Extend the existing "Blocked" card to also render `blocked_details` (when present) under `blocked_reason`.
- All other statuses (`todo`, `ready`, `done`, `cancelled`, `change_requested`, `review_incomplete`, `review_passed`) continue to show only the plain status with no additional fields and no action buttons.

**Explicit unblock action**
- New "Unblock" button rendered only when `task.status === "blocked"`.
- Clicking opens a confirmation dialog showing a preview of the resume target, computed client-side using `task.blocked_from_status`: `"reviewing"` or `"in_review"` → preview "In Review", anything else → preview "Ready" (mirrors the backend's `deriveUnblockTarget` logic documented in technical-design.md).
- On confirm, call the existing `POST .../tasks/:taskId/unblock` endpoint, then refetch task detail using the existing query-invalidation/`reload()` pattern already used by `useWorkspaceTask`/`useFeatureTask`.
- This button must not be shown for any status other than `blocked`.

**Stuck-task recover action**
- New button labeled **"Task is stuck? Unblock it"**, rendered only when the task is in one of the three processing sub-cases: `status === "in_progress"`, `status === "reviewing"`, or `conflict_state === "resolving"`.
- This button must **not** be shown when `status === "blocked"` (that's the Unblock action above) or for any idle/terminal status.
- Clicking opens a confirmation dialog with:
  - Warning copy: *"Resetting will let the task re-dispatch. Please make sure the task is actually stuck to avoid dispatching multiple jobs at the same time for the same task. Confirm to continue?"*
  - A client-computed preview of the target, using the same three-branch mapping as the backend (T2): `conflict_state === "resolving"` → preview "Conflict: Conflicted" (task status unchanged); `status === "reviewing"` → preview "In Review"; `status === "in_progress"` → preview "Ready".
- On confirm, call the new `POST .../tasks/:taskId/recover` endpoint, then refetch task detail using the same pattern.

**Shared UX**
- Both dialogs are simple confirm/cancel modals — reuse whatever confirmation-dialog primitive already exists elsewhere in `digital-factory-ui` (e.g. the delete-workspace confirmation flow) rather than introducing a new modal framework.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Add the four new fields to `TaskSummary`/`TaskDetail` in `types.ts`
- [ ] Add the conflict-state indicator element to `SpecPanel`
- [ ] Add the "Dispatched at" line, gated on the three processing sub-cases
- [ ] Extend the Blocked card to show `blocked_details`
- [ ] Add the `unblock` and `recover` API call sites in the workflow-backend service client
- [ ] Add the "Unblock" button (gated on `status === "blocked"`) with its confirmation dialog and client-computed preview
- [ ] Add the "Task is stuck? Unblock it" button (gated on the three processing sub-cases, excluded for `blocked`/idle/terminal statuses) with its confirmation dialog, warning copy, and client-computed preview
- [ ] Wire both confirm flows → API call → refetch task detail
- [ ] Add/update tests: status-display gating for all statuses, both buttons' visibility gating (including mutual exclusivity), preview computation for both actions, successful calls trigger refetch, error handling (e.g. 409 from `/recover` when task already resolved)
- [ ] Run full test suite + lint clean
