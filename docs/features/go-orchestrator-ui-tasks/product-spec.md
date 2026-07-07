
# Product Specification

## Feature
- Feature ID: `go-orchestrator-ui-tasks`
- Title: Display Branch/PR Info in Task Diff View for Go-Owned Features

## Problem
In the feature workbench's task diff view (`task-review-view.tsx` in `digital-factory-ui`), users reviewing a **ts-owned** feature's task can see the task's git branch name in the top-right of the diff panel, alongside the code diff itself. This gives the user quick context on which branch the changes live on.

For **go-owned** features, this top-right info area is not populated at all today — the diff view either shows nothing or an inconsistent state in that position. Go-owned tasks are tracked differently from ts-owned tasks: instead of working directly against a git branch the UI can name, each go task is associated with a single GitHub Pull Request (with a URL and a status such as open/merged), stored via the go orchestrator (`workflow-orchestrator`) and surfaced through `workflow-backend`.

As a result, a user reviewing a go-owned feature's task in the feature details page has no equivalent way to jump to the actual code changes — there is no branch name to show (it wouldn't be meaningful to the user for go-owned tasks), and no link to the PR either.

## Goals
- For a task belonging to a **go-owned** feature, show the task's associated **PR reference** in the same top-right position of the task diff view where ts-owned tasks show their branch name.
- The PR reference must be clickable and open the actual GitHub PR in a new browser tab.
- The PR reference label must include the repo and PR number, e.g. `tiendv89/project-workspace#724`.
- If the go task's PR has been merged, visually indicate this with a "merged" badge next to the PR reference.
- If a go task does not yet have a PR (e.g. work hasn't produced a PR yet), reuse the same empty/placeholder treatment already used for ts-owned tasks with no branch/no diff available, so the two flows feel consistent.
- The code diff content itself (the main body of the diff view) must look and behave identically for go-owned and ts-owned tasks — this feature does not change diff rendering, only the top-right branch/PR info area.
- Behavior must be driven by the feature's owner (`ts` vs `go`) so the correct info (branch name vs PR reference) is shown automatically without user action.

## Non-goals
- No changes to the Kanban/task board, feature list view, or the handoff UI — this is scoped strictly to the task diff/review view within the feature details page.
- No changes to how ts-owned tasks display their branch name — existing ts behavior is unchanged.
- No support for multiple PRs per go task — each go task has exactly one associated PR, and this spec assumes that stays true.
- No changes to review/approve/merge actions (approve, request changes, merge buttons) — those already exist or are out of scope per prior task-review work.
- No changes to the underlying diff-fetching mechanism/data source — how the diff content itself is retrieved and rendered is unchanged; only the info displayed in the top-right header differs based on feature owner.

## User Story
As a user reviewing a task that belongs to a go-owned feature, I want to see a link to the task's GitHub PR (with repo name, PR number, and merged status if applicable) in the same place I'd see a branch name for a ts-owned task, so that I can quickly navigate to the actual code changes on GitHub, consistent with how I already review ts-owned tasks.

## UI/UX
- **Location**: top-right of the task diff view panel (`task-review-view.tsx`), same position currently used to show the branch name for ts-owned tasks.
- **Go-owned task, PR exists**: display a clickable pill/link with the label format `<owner>/<repo>#<pr_number>` (e.g. `tiendv89/project-workspace#724`). Clicking opens the PR on GitHub in a new tab.
- **Go-owned task, PR merged**: same link as above, plus a "merged" badge/indicator rendered alongside it.
- **Go-owned task, no PR yet**: reuse the existing empty/placeholder UI already shown for ts-owned tasks lacking a branch or diff (no new empty-state design needed).
- **Ts-owned task**: unchanged — continues to show the branch name as it does today.
- The rest of the diff view (file list, diff body, review thread, Spec tab) is unaffected and renders identically regardless of feature owner.

## Open Questions (for Technical Design)
- Confirm the exact field name(s) and JSON shape for a go task's PR info as returned by `workflow-backend` (e.g. `pr.url`, `pr.status`) — need to verify against `workflow-orchestrator`'s task PR model (`setTaskPR`, `pr_merge_poll.go`) and `workflow-backend`'s `internal/handler/diff.go` / `document.go` (`resolvePRState`, `selectPRRef`, `parsePRURL`).
- Confirm whether the git-diff-fetching endpoint (`GetTaskDiff` / `internal/handler/diff.go`) already works correctly for go-owned tasks (since it resolves via PR ref rather than branch), or whether backend changes are needed to support diff fetching for go tasks.
- Confirm how to parse `owner/repo#number` cleanly from the stored PR URL for display purposes.
