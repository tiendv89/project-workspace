# Technical Design

## Feature
- Feature ID: `ui-go-owned-task-status-and-block`
- Title: Task Status Visibility & Stuck/Blocked Task Recovery (Go-owned tasks)

## Current State

**Frontend (`digital-factory-ui`)**
- The Task tab detail panel is `SpecPanel` in `src/components/tasks/task-review-view.tsx`. It currently renders: task ID, a `StatusBadge` (icon + label, e.g. "In Review", "Blocked"), title, description, depends-on chips, repo/branch, and — only when `task.blocked_reason` is truthy — a "Blocked" card showing the reason text.
- `StatusBadge` already maps several statuses to icon+label pairs (`in_review`, `reviewing`, `review_passed`, `in_progress`, `done`, `todo`, `ready`, `blocked`) but has no concept of a secondary conflict indicator, a dispatch timestamp, or any action buttons.
- The task data types consumed by the UI (`src/services/workflow-backend/types.ts`): `TaskSummary` exposes `status`, `is_blocked`, `blocked_reason`, `blocked_context` (untyped), `execution` (`actor_type`, `last_updated_by`, `last_updated_at`), but **no** `dispatched_at`, `conflict_state`, or `blocked_details` fields. `TaskDetail` extends `TaskSummary` with `next_action`, `pr_refs`, `activity` — same gap.
- There is currently no unblock/reset action anywhere in the UI. No component calls the existing `/unblock` endpoint.

**Backend (`workflow-backend`)**
- `workspace_tasks` already has the DB columns this feature needs (added across migrations `00019`/`00021`): `dispatched_at`, `dispatch_kind`, `blocked_reason`, `blocked_details`, `blocked_from_status`, `conflict_state`, `rebase_attempts`. Confirmed directly in `internal/orchestrator/transitions.go` (`dispatchInExtra`/`dispatchOutExtra` set/clear `dispatched_at`; `SetBlockedWithDetails` writes `blocked_details`/`blocked_from_status`) and `internal/orchestrator/conflict.go` (`conflict_state` FSM: `none|conflicted|resolving|resolved`).
- However, the **read path does not surface these columns to the API today**. `internal/database/queries.go` `scanTask`/`GetWorkspaceTask`/`ListFeatureTasks`/etc. SELECT only `id, workspace_id, feature_id, feature_name, task_id, task_name, title, repo, status, depends_on, blocked_reason, branch, execution, pr, workspace_pr, source_path, source_hash, owner, created_at, updated_at` — no `dispatched_at`, `conflict_state`, or `blocked_details`. `internal/service/workspace.go` `toTaskSummary`/`taskDetailFromRow` correspondingly never populate them on `domain.TaskSummary`/`domain.TaskDetail`. **This is a gap this feature must close** — the UI cannot show what the API doesn't return.
- `POST /api/workspaces/:workspaceId/features/:featureId/tasks/:taskId/unblock` (`internal/handler/workspace.go` → `WorkspaceService.UnblockTask` → `database.Reader.UnblockTask`) already implements the explicit-block recovery path end to end: it guards on `status = 'blocked'` (409 `ErrTaskNotBlocked` otherwise), derives the resume target via `deriveUnblockTarget(blocked_from_status)` (`reviewing`/`in_review` → `in_review`, else → `ready`), resets `review_incomplete_count`/`max_turns_retry_count`, clears `conflict_state`/`rebase_attempts` when `blocked_reason = 'rebase_failed'`, and logs a `workspace_activity_events` row with `action='unblocked'`. This fully satisfies Goal 2 of the product spec as-is — no backend change needed for the explicit-unblock path itself, only for exposing its result/preview data (see below).
- There is **no existing backend capability for Goal 3** (force-reset a stuck **processing** task: `in_progress`→`ready`, `reviewing`→`in_review`, conflict `resolving`→`conflicted`). The existing `/unblock` endpoint's guard (`status = 'blocked'`) explicitly rejects any task not already `blocked`, so it cannot be reused unmodified for the processing sub-cases.

**BFF (`workflow-bff`)**
- The proxy routing (`internal/app/api/handler/proxy/routing.go`) already resolves the `.../tasks/:taskId/unblock` route to `workflow-backend` and injects identity headers (`TestProxyInjectsIdentityHeadersForUnblock`, `TestUnblockRouteResolvesToWorkflowBackend`). A new force-reset route needs the equivalent routing table entry, added the same way as the existing `unblock` entry — no new test is required for this addition; the generic proxy/routing mechanism is already covered and the new route is not expected to need special-cased behavior beyond registering the path.

## Constraints
- Per the approved product spec: UI/UX and status-transition *rules* are in scope; underlying orchestrator dispatch/claim mechanics, DB schema, and full API contract shapes are explicitly deferred/owned by this design only insofar as needed to unblock the UI — i.e. this design proposes the minimal backend surface needed, but detailed orchestrator-side atomicity work is implementation detail for the backend task(s).
- Must not regress the existing `/unblock` endpoint's behavior or its guard semantics (`status='blocked'` only) — Goal 3's mechanism must be additive, not a widening of that guard, so a stuck-processing reset can never be confused with (or accidentally trigger) the blocked-task resume path.
- Any new server-side transition must not race an in-flight dispatch in a way that lets two executors work the same task simultaneously. Since the button is explicitly framed to the user as "I confirm this looks stuck" (product spec confirmation copy), the design accepts that correctness rests on the *human* attesting the task is actually stuck; the backend's job is to make the transition atomic and guarded (no double-application), not to detect staleness itself.
- Conflict-state reset (`resolving`→`conflicted`) must not touch the task's primary `status` column, per product spec.
- `review_incomplete` and `change_requested` must never be treated as processing states — no force-reset control for them.

## Options Considered

### Option A — Extend the existing `/unblock` endpoint to also accept processing statuses
- Widen `UnblockTask`'s guard from `status = 'blocked'` to `status IN ('blocked', 'in_progress', 'reviewing')` (plus a `conflict_state = 'resolving'` branch), and extend `deriveUnblockTarget` to branch on the *current* status instead of only `blocked_from_status`.
- Pros: one endpoint, one UI call site.
- Cons: conflates two conceptually distinct operations (resuming an already-halted task vs. force-interrupting a believed-dead in-flight one) behind one guard and one derivation function, which is exactly the ambiguity the product spec's two-button design was written to avoid. Silently changes the meaning/blast-radius of a shipped, tested endpoint. Response shape (`from: "blocked"` hardcoded today) would need to change for callers already integrated against it.

### Option B — New dedicated endpoint for the stuck-processing reset, existing `/unblock` untouched
- Add `POST /api/workspaces/:workspaceId/features/:featureId/tasks/:taskId/force-reset` (name TBD at implementation) with its own guard and its own derivation:
  - `status = 'in_progress'` → `status = 'ready'` (clears dispatch columns, same shape as `SetReadyFromMaxTurns`/`dispatchOutExtra`)
  - `status = 'reviewing'` → `status = 'in_review'` (clears dispatch columns)
  - `conflict_state = 'resolving'` → `conflict_state = 'conflicted'` (uses the same guarded pattern as `MarkRebaseRetry`/`rollbackResolving`; task `status` untouched)
  - Each branch is a guarded, single-row `UPDATE ... WHERE ... AND <current-state predicate>` (no `SELECT-then-UPDATE` gap), consistent with the existing `GuardedTransition`/`SetTaskResolving`-style helpers already in `workflow-orchestrator`. Reader-side, this is implemented in `workflow-backend`'s `database.Reader` (parallel to `UnblockTask`) so it is available synchronously to the UI, not routed through the async orchestrator reap loop.
  - Logs a `workspace_activity_events` row with a distinct action (e.g. `force_reset`) so it is auditable and distinguishable from `unblocked` in the activity feed.
- Pros: keeps the two user-facing actions backed by two clearly separated, independently guarded operations, matching the product spec's explicit two-button model. Existing `/unblock` semantics, tests, and callers are untouched. New endpoint can be scoped/rejected independently (e.g. future role gating) without touching the blocked-task path.
- Cons: one more endpoint + one more BFF route entry to add and test.

### Option C — Client-side only: reuse `/unblock` by first client-side "simulating" a block
- Have the UI call some other status-mutation path to flip the task to `blocked` first, then call `/unblock`.
- Pros: no backend change.
- Cons: not a real option — there is no existing endpoint to force a task to `blocked` from the client, and inventing one to launder through `/unblock` is a worse hack than Option B's dedicated endpoint. Also breaks the audit trail (`blocked_reason` would be synthetic) and violates the "guard must be atomic" constraint above (two round trips = race window). Rejected.

## Chosen Design
**Option B.** Two independent backend capabilities, two independent UI actions, matching the product spec's two-button model 1:1:

1. **Explicit unblock** (existing, no backend change) — UI adds a call site for the existing `POST .../tasks/:taskId/unblock`.
2. **Force-reset stuck processing task** (new) — a new guarded endpoint in `workflow-backend`, proxied by `workflow-bff`, called by a new UI action.

### 1. Backend: expose the missing read fields (`workflow-backend`)
Required so the UI can render Goal 1 (status display) at all:
- Extend the SQL SELECT list in `internal/database/queries.go` (`GetWorkspaceTask`, `GetWorkspaceTaskByID`, `ListFeatureTasks`, `ListWorkspaceTasks`, `searchTasks`) to include `dispatched_at`, `conflict_state`, `blocked_details`.
- Extend `database2.WorkspaceTask` struct and `scanTask`/`scanTask`-equivalent scan calls to read the three new columns (nullable: `dispatched_at *time.Time`, `conflict_state *string`, `blocked_details *string`).
- Extend `domain.TaskSummary` / `domain.TaskDetail` (`internal/domain`) with `DispatchedAt *time.Time`, `ConflictState string` (default `"none"` when null), `BlockedDetails string`.
- Extend `toTaskSummary`/`taskDetailFromRow` (`internal/service/workspace.go`) to populate these new fields.
- JSON field names: `dispatched_at`, `conflict_state`, `blocked_details` (snake_case, consistent with existing fields).

### 2. Backend: new force-reset endpoint (`workflow-backend`)
- Route: `POST /api/workspaces/:workspaceId/features/:featureId/tasks/:taskId/force-reset` (proxied through `workflow-bff` identically to `/unblock`).
- Request body: optional `note` (same shape as `/unblock`'s body), for parity and future audit use.
- Server-side guard logic (mutually exclusive, in priority order — a task can only match one, since `conflict_state='resolving'` can co-occur with `status IN {in_review, review_passed}` but never with `in_progress`/`reviewing` per the orchestrator's rebase-dispatch invariants):
  1. If `conflict_state = 'resolving'` → guarded `UPDATE ... SET conflict_state = 'conflicted' WHERE conflict_state = 'resolving'` (task `status` untouched). Clears rebase dispatch columns (handle/nonce) the same way `rollbackResolving` does.
  2. Else if `status = 'reviewing'` → guarded `UPDATE ... SET status = 'in_review' WHERE status = 'reviewing'`, clearing dispatch columns (mirrors `dispatchOutExtra()`).
  3. Else if `status = 'in_progress'` → guarded `UPDATE ... SET status = 'ready' WHERE status = 'in_progress'`, clearing dispatch columns.
  4. Else → 409 (task is not in a resettable processing state); UI should not have shown the button, but the backend must not silently no-op.
- On success, append a `workspace_activity_events` row: `action = 'force_reset'`, `note` (optional), `from`/`to` derived from the branch taken, in the same transaction as the guarded update (matching `UnblockTask`'s existing transaction pattern).
- Response shape mirrors `UnblockTaskResult`: `{ task_id, from, to }` (for the conflict-resolving branch, `from`/`to` describe the conflict-state transition, e.g. `"resolving"`/`"conflicted"`, not the task status, since status doesn't change — UI must not assume `to` is always a task `status` value).
- `workflow-bff`: add the matching routing-table entry so `force-reset` resolves to `workflow-backend` with identity headers injected, following the same registration pattern already used for `unblock`. No dedicated route test is required for this addition — there is no special routing requirement beyond what the existing generic proxy mechanism already handles and already covers via its existing tests.

### 3. Frontend (`digital-factory-ui`)
- **Types** (`src/services/workflow-backend/types.ts`): add `dispatched_at?: string`, `conflict_state?: "none" | "conflicted" | "resolving" | "resolved"`, `blocked_details?: string` to `TaskSummary`; ensure `TaskDetail` inherits them.
- **Status display** (`SpecPanel` in `task-review-view.tsx`):
  - Keep `StatusBadge` for the primary status (explicit text, already present).
  - Add a conflict-state row/badge rendered only when `task.conflict_state` is present and `!== "none"` — explicit text (e.g. "Conflict: Resolving"), separate element from the primary `StatusBadge`, not merged into it and not icon-only.
  - Add a "Dispatched at: `<formatted timestamp>`" line rendered only when task is in a processing state (`status === "in_progress" || status === "reviewing" || conflict_state === "resolving"`) and `dispatched_at` is present. Reuse the existing `formatTime` helper already in this file.
  - Extend the existing "Blocked" card to also render `blocked_details` under `blocked_reason` when present.
- **Explicit unblock action**: new button "Unblock" rendered only when `task.status === "blocked"`. Clicking opens a confirmation dialog that calls the `/unblock` endpoint in preview mode conceptually — since the backend does not offer a dry-run, the dialog computes/display the preview client-side using the same `deriveUnblockTarget`-equivalent mapping documented in the product spec (`blocked_from_status` in `{reviewing, in_review}` → preview "in_review", else → preview "ready"). This requires `blocked_from_status` to also be exposed on `TaskSummary`/`TaskDetail` (add alongside the other new fields above) so the client can compute the same preview the server will apply. On confirm, call `POST .../unblock`, then refetch task detail (existing `reload()`/query invalidation pattern already used by `useWorkspaceTask`/`useFeatureTask` per the T3 cache-migration work).
- **Force-reset action**: new button, label **"Task is stuck? Unblock it"**, rendered only when task is in a processing state as defined above (`in_progress`, `reviewing`, or `conflict_state === "resolving"`) — explicitly not shown for `blocked` or any idle/terminal status. Clicking opens a confirmation dialog with the specified warning copy and a client-computed preview of the target (same three-branch mapping as the backend, computed client-side for display only — the backend is the source of truth for what actually happens). On confirm, call the new `force-reset` endpoint, then refetch task detail.
- Both dialogs are simple confirm/cancel modals (no new modal framework needed — reuse whatever confirmation-dialog primitive already exists elsewhere in `digital-factory-ui`, e.g. the delete-workspace confirmation flow, to keep this consistent with existing UX patterns in the app).

## Dependency Analysis
- Frontend status-display work (Goal 1) is **blocked on** the backend read-path extension (dispatched_at/conflict_state/blocked_details/blocked_from_status must be in the API response before the UI can render them) — this must land first or be developed against a contract-frozen mock.
- The explicit-unblock UI action (Goal 2) has **no backend blocker** — the `/unblock` endpoint already exists and is stable; only the client-side preview computation needs `blocked_from_status` to be exposed (same read-path extension as above).
- The force-reset UI action (Goal 3) is **blocked on** the new `force-reset` endpoint existing in `workflow-backend` and being routed in `workflow-bff`.
- `workflow-bff` routing change is a small, independent addition once the `workflow-backend` route exists (path/method are known upfront, so the BFF routing-table entry can be written in parallel and stubbed against the not-yet-live backend route, then verified once backend lands).

## Parallelization / Blocking Analysis
- **Can proceed immediately, in parallel:**
  - `workflow-backend`: read-path extension (SELECT columns, struct fields, domain mapping) — no dependency on anything else in this feature.
  - `workflow-backend`: new `force-reset` endpoint + guarded transitions — no dependency on the read-path extension (different code paths), though both touch the same `workspace_tasks` table and same files (`queries.go`, `workspace.go`, `handler/workspace.go`) so should be sequenced as two commits/PRs to avoid merge conflicts, not run as fully independent parallel workstreams within the same repo.
  - `workflow-bff`: routing-table entry for `force-reset` — only needs the *path/method contract* agreed upfront, not the working backend implementation, so can be written in parallel and validated against a stub.
- **Blocked / sequenced:**
  - `digital-factory-ui` status-display changes (Goal 1) — blocked until `workflow-backend`'s read-path extension is merged (or a frozen mock contract is agreed for parallel development, then integrated).
  - `digital-factory-ui` explicit-unblock button (Goal 2) — blocked only on `blocked_from_status` being exposed (part of the same read-path extension), not on any new endpoint.
  - `digital-factory-ui` force-reset button (Goal 3) — blocked on both the new `workflow-backend` endpoint and its `workflow-bff` route being live.
- **Suggested sequencing for the tasks phase:** (1) `workflow-backend` read-path extension, (2) `workflow-backend` force-reset endpoint, (3) `workflow-bff` routing entry (depends on 2 for the real path, but can be scaffolded in parallel with 2), (4) `digital-factory-ui` all three UI changes (depends on 1–3, can be split into sub-tasks for status-display vs. the two action buttons if desired, since status-display only depends on task 1).
