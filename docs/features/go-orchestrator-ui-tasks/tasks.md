
# Tasks — go-orchestrator-ui-tasks

## Dependency Diagram

```
T1 (digital-factory-ui)
```

Single-task feature — no dependencies. Per the technical design, this is a frontend-only change: `workflow-backend`'s diff-fetch endpoint and go tasks' `pr.status` semantics are already confirmed correct without any code modification. The task-id lookup bug fix (discovered during verification) is folded into this same task as a prerequisite step, since the owner-gated PR-header work cannot be manually verified without it.

## Index

| ID | Title | Repo | Depends On | Actor |
|----|-------|------|------------|-------|
| T1 | Fix task-id lookup bug + show PR reference (owner/repo#number + merged badge) in task diff header for go-owned features | digital-factory-ui | | agent |

## T1 — Fix task-id lookup bug + show PR reference in task diff header for go-owned features

### Description

**Part A — Prerequisite bug fix: `task.id` → `task.task_id` in diff/thread hook call sites**

`workspace_tasks` has two independently-generated UUID columns: `id` (row primary key) and `task_id` (business key). For ts-owned tasks these are always identical by construction (`workspace-github-adapter`'s `UpsertWorkspaceTask` query sets both to the same generated `task_uuid` in the same INSERT). For go-owned tasks they are **not** identical — `workflow-backend`'s `insertGoTask` does not set `task_id` explicitly, so it takes its own independent column default, diverging from `id`.

The backend's task-lookup query (`Reader.GetWorkspaceTaskByID`, used by `GetTaskDiff` and the review-thread endpoint) matches on the **`task_id`** column:
```sql
WHERE t.workspace_id = $1 AND t.task_id = $2
```

But the frontend currently passes **`task.id`** (the row PK) as the URL param in two places:
- `TaskDiffTab` (`src/components/features/task-diff-tab.tsx`): `useTaskDiff(hasPr ? selectedWorkspaceId : null, hasPr ? task.id : null, task.repo || undefined)`
- Wherever `useTaskReviewThread` (`src/hooks/tasks/use-task-review-thread.ts`) is invoked with a task id (same `task.id` → `taskId` pattern).

This works by coincidence for ts tasks (`id === task_id` always) but 404s (`DATABASE_NOT_FOUND`) for go tasks whenever `id !== task_id` — which is the general case for go.

**Fix**: change both call sites to pass `task.task_id` instead of `task.id`. This is proven to be a no-op for ts-owned tasks (identical value, identical URL, identical backend behavior — see technical design "Safety of the fix for ts-owned tasks") and fixes the lookup for go-owned tasks. No backend change is required.

**Part B — Owner-gated PR/branch header (the feature's primary goal)**

Once diff data loads correctly for go tasks, extend `TaskDiffTab`'s header to show the right info based on feature ownership:

- Add an explicit `owner: "ts" | "go"` prop to `TaskDiffTab`.
- Thread `owner={feature.owner}` from the call site that renders `<TaskDiffTab task={...} />` (the feature workbench / diff tab host, e.g. via `handleOpenTaskDiff` in `feature-workbench.tsx`) — `feature.owner` is already available on the loaded feature object, no new fetch needed.
- Replace the current unconditional `task.branch` block in the header's top-right (`ml-auto`) slot with owner-gated rendering:
  - `owner === "ts"`: unchanged — keep the existing `GitBranch` icon + `task.branch` display exactly as it is today (byte-for-byte, only rendered when `task.branch` is truthy).
  - `owner === "go"`:
    - If `task.pr?.url` is set: render a clickable pill/link labeled `<owner>/<repo>#<number>` (e.g. `tiendv89/project-workspace#724`), parsed from `task.pr.url` via a new `parsePRRefLabel(url: string): string | null` helper. Wrap in `<a href={task.pr.url} target="_blank" rel="noreferrer">`, reusing the existing external-link (`ExternalLink` icon) styling convention already used in `ThreadPanel`'s "View PR on GitHub" link (`task-review-view.tsx`).
    - If `task.pr.status === "merged"`: render a small "Merged" badge immediately next to the pill, using the same green color palette (`#5cb572` / `rgba(92,181,114,0.15)`) already used for "done"/"review_passed" badges in `StatusBadge` (`task-review-view.tsx`).
    - If `task.pr` is not set (no PR yet): render nothing new in this header slot — rely on `DiffPanel`'s existing "No pull request yet — diff will appear when a PR is opened." empty state (already triggered by `hasPr={false}`), matching how ts tasks with no `branch` today also show nothing in the header.
- Do not modify `DiffPanel`, `useTaskDiff`, `getTaskDiff`, or any backend code — the diff-fetch mechanism and `task.pr` data are already confirmed correct for go tasks per the technical design (no backend task in this breakdown).
- Add a `parsePRRefLabel` unit-testable pure helper:
  ```ts
  export function parsePRRefLabel(prUrl: string): string | null {
    const m = prUrl.match(/^https?:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/);
    return m ? `${m[1]}/${m[2]}#${m[3]}` : null;
  }
  ```

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Change `TaskDiffTab`'s `useTaskDiff` call from `task.id` to `task.task_id`.
- [ ] Audit and fix the equivalent `task.id` → `task.task_id` call in whichever component wires up `useTaskReviewThread`.
- [ ] Verify ts-owned task diff view and review thread are unaffected by the id-field change (regression check — should be a true no-op).
- [ ] Verify go-owned task diff view now loads diff data successfully (no more `DATABASE_NOT_FOUND`).
- [ ] Add `owner: "ts" | "go"` prop to `TaskDiffTab` and thread it from the call site (feature workbench) using the already-loaded `feature.owner`.
- [ ] Implement `parsePRRefLabel` helper (colocated with `TaskDiffTab` or a shared util) and unit tests covering valid/invalid PR URLs.
- [ ] Replace the unconditional branch-name block with owner-gated rendering: ts → unchanged branch display; go + PR present → `owner/repo#number` link; go + merged → add "Merged" badge; go + no PR → render nothing (rely on existing `DiffPanel` empty state).
- [ ] Verify go-owned task diff view shows the correct PR link / merged badge / empty state across all three data states (no PR, open PR, merged PR).
- [ ] Run full test suite and lint; fix any failures before opening the PR.
