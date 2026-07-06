
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

**Verification task required** (not a code change, a validation step during implementation): confirm via `workflow-backend` handler tests (e.g. extend/inspect `internal/handler/diff_test.go`, `internal/handler/workspace_test.go::TestGoOwnedFeatureAndTasks_SurfaceInReadAPI`) that a go task's `pr.status` values match exactly `"open"` / `"merged"` (not e.g. `"OPEN"`/`"MERGED"` or additional states like `"conflicted"` bleeding through) so the frontend's merged-badge check (`task.pr.status === "merged"`) is correct. If additional PR states exist for go tasks beyond open/merged, the frontend should treat any non-`"merged"` status as the default (non-badged) pill — no need to enumerate every status per the spec's non-goals.

## Dependency Analysis
- Depends on `task.pr: PullRequestRef | undefined` already being populated correctly for go tasks by `workflow-backend` (existing, not part of this feature — the go-task PR write path already exists per `insertGoTask`/`pr_merge_poll.go`).
- Depends on `feature.owner` already being available at the `TaskDiffTab` call site (existing — same field used by `feature-initialization-compatible`'s `InitPRBanner`/badges).
- No new backend endpoints, no new database columns, no new GitHub API calls beyond what `GetTaskDiff` already performs.
- No changes to `useTaskDiff`, `getTaskDiff` client, or `DiffPanel`.

## Parallelization / Blocking Analysis
- **T1 (frontend-only, `digital-factory-ui`)**: implement `parsePRRefLabel`, update `TaskDiffTab` header rendering (owner-gated branch/PR display + merged badge), thread `owner` prop from the call site. Fully self-contained; no backend dependency since the required data (`task.pr`, `feature.owner`) already exists in the API surface.
- **T2 (verification-only, `workflow-backend`)**: confirm `pr.status` value set for go tasks matches `"open"`/`"merged"` expectations via existing/extended handler tests. Can run in parallel with T1; only blocks final sign-off if a status-value mismatch is found (in which case a small backend normalization fix would be needed before T1's merged-badge check is correct in production).
- No sequencing dependency between T1 and T2 for implementation, but T1's merged-badge logic should be validated against T2's findings before merge.
