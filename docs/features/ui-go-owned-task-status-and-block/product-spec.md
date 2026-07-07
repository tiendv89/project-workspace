# Product Specification

## Feature
- Feature ID: `ui-go-owned-task-status-and-block`
- Title: Task Status Visibility & Stuck/Blocked Task Recovery (Go-owned tasks)
- Implementation repo: `digital-factory-ui`
- Related backend (already shipped, consumed read-only by this feature): `workflow-backend` (`POST /api/workspaces/:workspaceId/features/:featureId/tasks/:taskId/unblock`), `workflow-bff` (proxy)

## Problem
For go-owned tasks (tasks executed by the Go orchestrator), users currently have no way to see *why* a task is stuck or blocked, nor any way to recover it from the UI. Two distinct failure modes exist today with no UI coverage:

1. **Explicit block** (`status = blocked`) — the orchestrator or an agent explicitly blocked the task and recorded a reason/details. The backend already exposes an unblock API that derives the correct resume state, but there is no UI entry point to call it.
2. **Silently stuck in-flight work** — a task is sitting in a "processing" status (implementation in progress, under review, or resolving a rebase conflict) but the executor or infrastructure died mid-flight, so the task never completes and never surfaces as `blocked`. Today a user has no visibility into how long a task has been sitting there, and no way to force it back into the dispatch pool.

This spec covers the Task tab's detail panel in `digital-factory-ui` only: what status information is shown, and the two recovery actions (explicit unblock, and force-reset of a stuck processing task) exposed to the user. Backend/API/orchestrator mechanics are out of scope — this document assumes the existing `unblock` API contract and existing task status/columns as ground truth, and focuses purely on UI/UX and the status-transition rules the UI must enforce when invoking them.

## Goals

### 1. Status display in the Task tab detail panel
When a user clicks a task and views its detail panel (the existing Task tab / `SpecPanel` area):

- **Always show the primary task status as an explicit text value** (e.g. "In Progress", "Reviewing", "Blocked", "Done") — not merely an icon/glyph. This applies to every task regardless of status.
- **If the task's conflict state is not `none`** (i.e. `conflicted`, `resolving`, or `resolved`), show it as a **separate, explicit secondary value** alongside the primary status — e.g. primary status "In Review" + secondary conflict indicator "Resolving Conflict". Do not merge this into the primary status text and do not represent it with an icon alone. When conflict state is `none`, show nothing extra.
- **If the task is `blocked`**, show:
  - The block reason (explicit text, e.g. "rebase_failed", "max_turns_exceeded")
  - The block details, if present (explicit text)
- **If the task is in a "processing" status** — `in_progress`, `reviewing`, or conflict state `resolving` — show the dispatch start time as "Dispatched at: `<timestamp>`" (i.e. when the current in-flight attempt began). This is additive to the primary status display, not a replacement.
- For all other statuses (`todo`, `ready`, `done`, `cancelled`, `change_requested`, `review_incomplete`, `review_passed`) — show the plain status value with no additional block/processing fields and no recovery action buttons (see Goal 3 visibility rule).

**Processing statuses covered by this spec** (the three sub-cases that can "get stuck"):
| Case | How it's identified |
|---|---|
| Implementation/fix in progress | task status = `in_progress` |
| Under review | task status = `reviewing` |
| Resolving a rebase conflict | conflict state = `resolving` (this can co-occur with `in_review` or `review_passed` as the underlying task status — conflict state is an overlay, not the task status itself) |

`review_incomplete` and `change_requested` are explicitly **not** processing states for the purposes of this feature — no dispatch is in flight, so no "stuck" recovery action applies to them.

### 2. Explicit unblock action (`status = blocked`)
When a task's status is `blocked`:

- Show an **"Unblock"** action in the detail panel.
- Clicking it opens a confirmation dialog that shows a **preview of the resulting resume status** the task will transition to (derived by the backend from what state it was in before it was blocked) before the user confirms.
- On confirm, the UI calls the existing unblock API (via workflow-bff) and refreshes the task detail view to reflect the new status.
- This action is only shown when `status = blocked`. It is not shown for any other status.

### 3. Force-reset for stuck processing tasks
When a task is in one of the three processing sub-cases above (`in_progress`, `reviewing`, or conflict state `resolving`) — and only then — show a button labeled:

> **"Task is stuck? Unblock it"**

Rules:
- This button is shown **only** when the task is in a processing status as defined above. It must **not** be shown when the task is `blocked` (that case uses the separate "Unblock" action from Goal 2), and must not be shown for any non-processing, non-blocked status (`todo`, `ready`, `done`, `cancelled`, `change_requested`, `review_incomplete`, `review_passed`).
- Clicking the button opens a **confirmation dialog** with:
  - A clear warning message, e.g.: *"Resetting will let the task re-dispatch. Please make sure the task is actually stuck to avoid dispatching multiple jobs at the same time for the same task. Confirm to continue?"*
  - A preview of the target status the task will be reset to (see mapping table below), shown before the user confirms.
- On confirm, the UI issues the reset to the target status appropriate to the specific processing sub-case:

| Stuck condition detected | Resulting target on confirm |
|---|---|
| `status = in_progress` | → `ready` (orchestrator re-claims and re-dispatches implementation/fix) |
| `status = reviewing` | → `in_review` (orchestrator re-dispatches a reviewer) |
| conflict state = `resolving` | → conflict state `conflicted` (orchestrator re-dispatches the rebase); the task's underlying `status` field is **not** changed by this action |

- After confirming, refresh the task detail view to reflect the new state.

## Non-goals
- No changes to orchestrator dispatch/claim logic, retry counters, or DB schema — this is a pure UI feature consuming existing backend/API behavior.
- No bulk unblock or bulk force-reset across multiple tasks — actions apply to one task at a time, from within that task's own detail panel.
- No new alerting/notification system for stuck tasks (e.g. no proactive "this task looks stuck" banner elsewhere in the UI) — the user must open the task to see and act on its state.
- No changes to task list/board views (kanban cards, sidebar grouping, etc.) — scope is limited to the Task tab detail panel.
- Scope is limited to tasks belonging to this feature (`ui-go-owned-task-status-and-block`) for go-owned tasks; no changes to ts/git-owned task handling.
- API contract details (request/response shape, error codes, auth/role checks on the unblock endpoint) are deferred to technical design — this spec only requires that the UI (a) call the existing unblock capability for explicit `blocked` tasks and (b) call an equivalent reset-to-target-status capability for the three stuck-processing sub-cases, with the target derived per the mapping table above.

## Open questions for technical design
- Whether the same backend `unblock` endpoint (which today guards on `status = 'blocked'`) is reused/extended for the stuck-processing force-reset case, or whether a new endpoint/guard is needed to safely transition `in_progress` → `ready`, `reviewing` → `in_review`, and `conflict_state: resolving` → `conflicted` without racing an in-flight dispatch. This is a backend/API design concern, not a UI concern, but the UI's confirmation-dialog copy above assumes the backend performs this transition safely and atomically.
- Whether any role/permission restriction should gate who can see or click the force-reset button (not specified by the user in this round of scoping) — flagged for human confirmation before/at technical design.
