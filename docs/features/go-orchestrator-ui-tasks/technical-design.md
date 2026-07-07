
# Technical Design

## Feature
- Feature ID: `go-orchestrator-ui-tasks`
- Title: Display Branch/PR Info in Task Diff View for Go-Owned Features

## Current State

The task diff view lives in `digital-factory-ui`:

- **`src/components/features/task-diff-tab.tsx`** — `TaskDiffTab` renders the diff panel's header bar. Today the header shows a status glyph, task label, task title, and — only when `task.branch` is truthy — a `GitBranch` icon + branch name pinned to the top-right (`ml-auto`) of the header:
  ```tsx
  {task.branch && (
    <div className="ml-auto flex shrink-0 items-center gap-1.5">
      <GitBranch size={12} .../>
      <span ...>{task.branch}</span>
    </div>
  )}
  ```
  Below the header it renders `<DiffPanel hasPr={hasPr} diffResult={diffResult} />` from `src/components/tasks/task-review-view.tsx`, where `hasPr = task.pr != null || task.workspace_pr != null`.
- **`src/components/tasks/task-review-view.tsx`** — `DiffPanel` fetches and renders the actual file tree + unified diff. It is owner-agnostic already: it only cares about `hasPr` and the `useTaskDiff` result (file list, patches). No changes needed here.
- **`src/hooks/tasks/use-task-diff.ts`** — `useTaskDiff(workspaceId, taskId, repo)` calls `getTaskDiff` (`src/services/workflow-backend/client.ts`), which hits `workflow-backend`'s `GET /api/workspaces/:workspaceId/tasks/:taskId/diff?repo=<repo_id>`.
- **`workflow-backend`'s `internal/handler/diff.go`** — `DiffHandler.GetTaskDiff` loads the task (`domain.TaskDetail`), calls `selectPRRef(task.PRRefs, repoParam)` to pick a `domain.PullRequestRef` (has `.URL`, `.Repo`), parses `owner/repo/prNumber` out of the URL via `parsePRURL`, then calls `GetPRFiles` / `GetPRDiff` on the GitHub client. This is **repo-agnostic between ts and go** — it operates purely on `PullRequestRef.URL`, which any task (ts or go) can populate. **This confirms the diff-fetch endpoint already works unmodified for go tasks**, as long as the go task's PR ref is exposed in the same `TaskDetail.PRRefs` / `TaskSummary.pr` shape ts tasks use.
- **`src/utils/workspaces/workspace-adapter.ts`** — `adaptPullRequestRef(ref: PullRequestRef | null | undefined)` already normalizes `{ url, status }` from the backend `PullRequestRef` type into `task.pr` / `task.workspace_pr` on the frontend `ParsedTask`. This is **owner-agnostic infrastructure already in place** — it does not care whether the task is ts- or go-owned.
- **`workflow-orchestrator`** (go orchestrator) — task PR state lives in Postgres. `internal/orchestrator/pr_merge_poll.go` (`extractPRURL`, `processPRPoll`) and helpers like `setTaskPR` (test helper pattern) manage a task's PR URL + status (`open`/`merged`) as the go orchestrator polls GitHub. `internal/database/queries.go` (`insertGoTask`, `Reader.GetWorkspaceTask`) reads/writes go task rows, which `workflow-backend`'s service layer (`internal/service/workspace.go`, tested via `TestGetWorkspaceTask_Success`) already surfaces as part of `TaskDetail`/`TaskSummary`.
- **Feature `owner`** (`ts` | `go`) is already a first-class field on `FeatureSummary`/`FeatureDetail` (confirmed via `feature-initialization-compatible` feature: `owner` field, `InitPRBanner`, badges in `FeatureIDEDocsPanel`). The frontend already branches UI on `owner` elsewhere.

## Bug Found During Verification (blocks this feature)

While verifying the go flow manually, opening a task's diff in the UI returned:
```json
{"success": false, "error": {"code": "DATABASE_NOT_FOUND", "message": "task not found: a3001d08-...", "source": "database", "retryable": false}}
```

**Root cause (traced end-to-end, not go-specific — affects any task, ts or go):**

- `workspace_tasks` has two independently-generated UUID columns: `id` (row primary key) and `task_id` (business key). They are not guaranteed equal (confirmed via `scanTask`/`WorkspaceTask` in `internal/database/queries.go`, which scans both as distinct fields, and the frontend `TaskSummary` type in `src/services/workflow-backend/types.ts`, which likewise exposes both `id` and `task_id` separately).
- `TaskDiffTab` (`src/components/features/task-diff-tab.tsx`) calls `useTaskDiff(..., task.id, ...)` — passing the row **primary key** `task.id`.
- `getTaskDiff` (`src/services/workflow-backend/client.ts`) builds `GET /api/workspaces/:workspaceId/tasks/:taskId/diff` using that value.
- The backend route resolves via `DiffHandler.GetTaskDiff` → `WorkspaceService.GetWorkspaceTask` → `Reader.GetWorkspaceTaskByID`, whose query is:
  ```sql
  SELECT ... FROM workspace_tasks t
  WHERE t.workspace_id = $1 AND t.task_id = $2
  ```
  — it matches on the **business-key `task_id` column**, not `id`.
- Whenever a task's `id` ≠ `task_id` (the general case — nothing in the schema or insert path guarantees they match), the lookup finds zero rows and returns `DATABASE_NOT_FOUND`, surfaced verbatim by the frontend as "Failed to load diff: task not found: `<id>`".
- **`useTaskReviewThread`** (`src/hooks/tasks/use-task-review-thread.ts`) has the identical call pattern (`task.id` passed as `taskId`) and very likely has the same defect against its backend route — flagged here for the implementing task to verify and fix alongside the diff endpoint, since both live in the same task-review view and share the same task-identity bug class.

**Fix (frontend-only, minimal, no backend/schema change):** `TaskDiffTab` and `useTaskReviewThread`'s call sites must pass **`task.task_id`** (the business key the backend actually looks up on), not `task.id`, when calling `useTaskDiff` / `useTaskReviewThread`. This is consistent with how the rest of the task-review UI already treats `task.task_id` as the externally-meaningful identifier (e.g. `SpecPanel` already renders `task.task_id?.toUpperCase()` as the task's displayed label). No backend change is required — `GetWorkspaceTaskByID`'s `task_id`-based lookup is correct and shared by both ts and go tasks; the bug is purely in which frontend field gets passed as the URL param.

This fix is orthogonal to (and must land alongside, in the same task) the owner-gated PR-header work below — without it, the go-owned task diff view this feature adds will never load any diff data to display next to the new PR link.

## Constraints
- Must not change `DiffPanel`'s diff-body rendering — it is already owner-agnostic and works for both flows once `hasPr`/diff data are supplied correctly.
- Must not change ts-owned task behavior — the branch-name display and its underlying data path stay exactly as-is.
- Each go task has exactly one associated PR (per product spec) — no multi-PR list UI needed.
- `TaskDiffTab` currently receives only `task: TaskSummary` — it does not currently receive the feature's `owner`. This must be threaded in from the caller.
- PR reference label must render as `<owner>/<repo>#<number>`, parsed from `task.pr.url` (the GitHub PR URL, e.g. `https://github.com/tiendv89/project-workspace/pull/724`).

## Options Considered
### Option A — Branch purely on `task.pr` truthiness (no owner prop)
Show branch name if `task.branch` is set, else show PR link if `task.pr` is set, else show nothing.
- Pros: no new prop threading; simplest change.
- Cons: fragile — a ts task with `task.branch` unset for any transient reason would silently fall through to showing a PR link (or nothing), which doesn't match the product intent of the header being *owner-driven*, not *data-driven*. Diverges from the approved spec's explicit requirement: "Behavior must be driven by the feature's owner."

### Option B — Thread `owner: "ts" | "go"` into `TaskDiffTab` explicitly
Pass the feature's `owner` down from whichever parent already has it (`feature-workbench.tsx` holds the selected feature and calls `handleOpenTaskDiff`), and branch header rendering on `owner === "go"` vs `owner === "ts"`.
- Pros: matches the spec's explicit requirement; deterministic; consistent with how `owner` already gates UI elsewhere (`NewFeatureModal`, `InitPRBanner`, docs-panel badges); no ambiguity around missing/transient `task.branch`.
- Cons: one extra prop to thread through `TaskDiffTab` and its caller(s).

## Chosen Design

**Option B.** Feature `owner` becomes an explicit prop on `TaskDiffTab`, sourced the same way other owner-gated UI already reads it (from the currently-selected feature object held in `feature-workbench.tsx` / wherever `TaskDiffTab` is instantiated).

### Frontend changes (`digital-factory-ui`)

1. **`TaskDiffTab` (`src/components/features/task-diff-tab.tsx`)**
   - Add `owner: "ts" | "go"` (or reuse the existing feature-owner type) to the component's props.
   - Replace the current unconditional `task.branch` block with owner-gated rendering in the same top-right (`ml-auto`) slot:
     - `owner === "ts"`: unchanged — render `GitBranch` icon + `task.branch`, only if `task.branch` is truthy (existing behavior, byte-for-byte).
     - `owner === "go"`:
       - If `task.pr` is set (truthy `task.pr.url`): render a clickable pill — parse `owner/repo#number` from `task.pr.url` (reuse the same `/owner/repo/pull/<n>/` URL shape `parsePRURL` already expects on the backend; add a small frontend helper, e.g. `parsePRRefLabel(url: string): string | null`, colocated with the new rendering code or in a shared util). Label format: `tiendv89/project-workspace#724`. Wrap in an `<a href={task.pr.url} target="_blank" rel="noreferrer">` matching the existing external-link pattern already used in `ThreadPanel` (`task-review-view.tsx`) for the "View PR on GitHub" link (same `ExternalLink` icon, same styling conventions).
       - If `task.pr.status === "merged"`: render a small "Merged" badge immediately next to the pill (reuse `StatusBadge`-style badge conventions already defined in `task-review-view.tsx`, or a minimal inline badge with the same color palette: green `#5cb572` / `rgba(92,181,114,0.15)` background, consistent with existing "done"/"review_passed" badges).
       - If `task.pr` is not set (no PR yet): render nothing in this slot — the existing `DiffPanel`'s own "No pull request yet — diff will appear when a PR is opened." empty state (already present, owner-agnostic, triggered by `hasPr={false}`) covers this per the spec's "reuse existing empty/placeholder" requirement. No new empty-state markup needed in the header itself, consistent with how ts tasks with no `branch` today also render nothing in the header slot.

2. **Owner threading** — identify the actual call site(s) rendering `<TaskDiffTab task={...} />` (feature workbench / diff tab host, e.g. via `handleOpenTaskDiff` in `feature-workbench.tsx`) and pass `owner={feature.owner}` from the already-loaded `FeatureSummary`/`FeatureDetail` object held in that scope. No new API calls needed — `owner` is already fetched as part of feature data.

3. **PR ref label parsing** — add a small pure helper (unit-testable, similar to `parsePatch`/`languageFromFilename` already in `task-review-view.tsx`) that extracts `owner/repo#number` from a GitHub PR URL:
   ```ts
   export function parsePRRefLabel(prUrl: string): string | null {
     const m = prUrl.match(/^https?:\/\/github\.com\/([^/]+)\/([^/]+)\/pull\/(\d+)/);
     return m ? `${m[1]}/${m[2]}#${m[3]}` : null;
   }
   ```
   This mirrors the parsing logic already implemented server-side in `parsePRURL` (`internal/handler/diff.go`), kept independent since the frontend only needs the display label, not throwaway network calls.

### Backend changes (`workflow-backend`)

None expected. `task.pr` (`PullRequestRef { url, status }`) is already populated for go tasks via `Reader.GetWorkspaceTask` / `insertGoTask` and already flows through `adaptPullRequestRef` in `workspace-adapter.ts` to the frontend `ParsedTask.pr`. The diff-fetch endpoint (`GetTaskDiff` / `selectPRRef` / `parsePRURL`) is already ref-driven, not branch-driven, so no change is needed there either — confirming the second open question from the product spec.

**`pr.status` values confirmed (no verification task needed):** traced end-to-end in `workflow-orchestrator`:
- `internal/orchestrator/transitions.go::SetInReview` writes the task's `pr` JSONB column as `{"url": prURL, "status": "open"}` when a task moves `in_progress → in_review` (this is the only place a go task's PR is first recorded).
- `internal/orchestrator/transitions.go::SetDoneFromMergedPR` (invoked from `pr_merge_poll.go::processPRPoll` when GitHub reports `merged: true`) flips the same JSONB field's `status` key from `"open"` to `"merged"` in place, preserving `url` — confirmed by `transitions_test.go::TestSetDoneFromMergedPR_FlipsPRStatusToMerged`, which asserts `pr.status == "merged"` after the transition.
- No other code path writes a different string into `pr.status` for go tasks — the only two values that ever appear are exactly `"open"` and `"merged"` (lowercase, matching the product spec's wording). There is no `"conflicted"`/`"closed"` value written into this JSONB field — PR conflict state is tracked separately via `conflict_state` (`SetConflicted`), not via `pr.status`.
- This JSONB flows unchanged through `workflow-backend`'s `Reader.GetWorkspaceTask` / `insertGoTask` into `domain.PullRequestRef{URL, Status}`, and through `adaptPullRequestRef` in `workspace-adapter.ts` into the frontend's `task.pr.status`.

Conclusion: the frontend's merged-badge check `task.pr.status === "merged"` is correct as designed, with `"open"` (or any non-`"merged"` value, defensively) rendering the default non-badged pill. No backend change or additional verification step is required for this feature.

## Dependency Analysis
- Depends on `task.pr: PullRequestRef | undefined` already being populated correctly for go tasks by `workflow-backend` (existing, not part of this feature — the go-task PR write path already exists per `insertGoTask`/`pr_merge_poll.go`).
- Depends on `feature.owner` already being available at the `TaskDiffTab` call site (existing — same field used by `feature-initialization-compatible`'s `InitPRBanner`/badges).
- No new backend endpoints, no new database columns, no new GitHub API calls beyond what `GetTaskDiff` already performs.
- No changes to `useTaskDiff`, `getTaskDiff` client, or `DiffPanel`.

## Parallelization / Blocking Analysis
- **T1 (frontend-only, `digital-factory-ui`)**: implement `parsePRRefLabel`, update `TaskDiffTab` header rendering (owner-gated branch/PR display + merged badge), thread `owner` prop from the call site. Fully self-contained; no backend dependency since the required data (`task.pr`, `feature.owner`) already exists in the API surface, and `pr.status`'s value set (`"open"` / `"merged"`) is confirmed above — no backend verification step remains.

Single-task breakdown: this feature is frontend-only. There is no backend task (T2) — the diff-fetch endpoint and `pr.status` semantics are both confirmed unchanged/correct for go tasks without any code modification.
