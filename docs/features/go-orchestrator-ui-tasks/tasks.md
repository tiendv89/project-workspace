
# Tasks — go-orchestrator-ui-tasks

## Dependency Diagram

```
T1 (digital-factory-ui)
```

Single-task feature — no dependencies. Per the technical design, this is a frontend-only change: `workflow-backend`'s diff-fetch endpoint and go tasks' `pr.status` semantics are already confirmed correct without any code modification.

## Index

| ID | Title | Repo | Depends On | Actor |
|----|-------|------|------------|-------|
| T1 | Show PR reference (owner/repo#number + merged badge) in task diff header for go-owned features | digital-factory-ui | | agent |

## T1 — Show PR reference in task diff header for go-owned features

### Description
Today `TaskDiffTab` (`src/components/features/task-diff-tab.tsx`) renders the task's git branch name in the top-right of the diff view header, but only ts-owned features have a meaningful branch to show. Go-owned tasks track a single associated GitHub PR (`task.pr: { url, status }`) instead of a branch. This task makes the header owner-aware:

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
- [ ] Add `owner: "ts" | "go"` prop to `TaskDiffTab` and thread it from the call site (feature workbench) using the already-loaded `feature.owner`.
- [ ] Implement `parsePRRefLabel` helper (colocated with `TaskDiffTab` or a shared util) and unit tests covering valid/invalid PR URLs.
- [ ] Replace the unconditional branch-name block with owner-gated rendering: ts → unchanged branch display; go + PR present → `owner/repo#number` link; go + merged → add "Merged" badge; go + no PR → render nothing (rely on existing `DiffPanel` empty state).
- [ ] Verify ts-owned task diff view is visually and functionally unchanged (regression check).
- [ ] Verify go-owned task diff view shows the correct PR link / merged badge / empty state across all three data states (no PR, open PR, merged PR).
- [ ] Run full test suite and lint; fix any failures before opening the PR.
