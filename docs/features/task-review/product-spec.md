# Product Specification

## Feature
- Feature ID: `task-review`
- Title: Task Review page — real task review experience

## Problem

The task detail route `/task/{taskId}` (in `digital-factory-ui`) is currently a
**visual mockup**. The page shell, routing, and task-metadata binding are real,
but the core review experience is hardcoded:

- The **diff panel** renders a static `PLACEHOLDER_DIFF` against a hardcoded
  filename (`src/routes/sessions.ts`); per-repo additions/deletions always show `0`.
- The **"Spec" tab** exists but renders nothing.
- The **Review Thread** (reviewer comment, inline comment, "✓ APPROVED" badge) is
  entirely hardcoded prose unrelated to the actual task or PR.
- The **"Merge PR"** and **"Request changes"** buttons have no behavior — no
  click handler, no API call.

As a result, a human opening a task to review the agent's work sees fabricated
content instead of the real PR diff, the real reviewer verdict, or the real
review conversation — and cannot take any review action from the page. The page
looks finished but carries no decision-making value.

This feature replaces the mockup with a data-backed Task Review page that shows
the real change set and review history for a task and (where in scope) lets a
human act on it.

## Goals

- **Real diff:** show the actual file changes for the task's PR(s) — file list
  with real paths and per-file/per-repo additions and deletions, and real diff
  hunks — replacing `PLACEHOLDER_DIFF` and the hardcoded filename.
- **Multi-repo aware:** when a task has both an implementation `pr` and a
  `workspace_pr` (or multiple repo PRs), the repo selector switches the diff and
  thread to the selected repo's real PR.
- **Real review thread:** render the actual review state and conversation for the
  selected PR — reviewer verdict (approved / changes requested / pending), review
  summary comment, and inline/line comments — sourced from real data rather than
  hardcoded strings.
- **Spec tab:** the "Spec" tab shows the task's real specification/description
  (e.g. the task narrative and acceptance criteria) instead of rendering nothing.
- **Honest empty/loading/error states:** when a task has no PR yet, no diff, or no
  review thread, show a clear empty state — never fabricated content. Loading and
  error states match the existing page conventions.
- **Review actions (subject to scoping in Open Questions):** the "Merge PR" and
  "Request changes" controls either perform the real action against the PR, or are
  removed/disabled with a clear reason — they must not appear actionable while
  doing nothing.

## Non-goals

- Redesigning the visual layout or theme of the page. The existing two-pane
  layout (diff left, review thread right), color tokens, and component structure
  are kept; this feature changes the **data and behavior**, not the look.
- Building a general-purpose code-review tool (multi-file side-by-side review,
  suggestions, threaded replies, reactions). Scope is the existing single-file /
  PR-diff presentation, extended to real data.
- Changing the agent orchestration / review workflow itself (reviewer dispatch,
  verdict semantics, task lifecycle). This page **reflects** that state; it does
  not change how reviews are produced.
- Authoring net-new task lifecycle states or task YAML schema changes.
- Mobile / responsive redesign beyond what the current page already supports.

## Current state (for reference)

- Route: `src/app/(shell)/task/[taskId]/page.tsx` — resolves the task from
  `useWorkspaceContext().activeWorkspace.tasks` by `taskId`; handles loading /
  error / not-found; renders `<TaskReviewView task={task} />`.
- View: `src/components/tasks/task-review-view.tsx` — real task fields are bound
  (id, title, status, branch, `pr`/`workspace_pr`); diff content, review thread,
  and action buttons are mocked.
- Data layer: `src/services/workflow-backend/*` exposes workspace/feature/task
  listing and feature **document** content (product spec / technical design /
  handoff). There is **no** endpoint today for PR diffs, PR review threads/
  comments, or merge actions.
- Backend: `workflow-backend` (Go) has a GitHub client that can list PRs, create
  PRs, and detect merged state, but does not currently fetch diffs or review
  comments, nor expose a merge endpoint for this use case.

## Open questions (need product/tech decisions)

1. **Diff source:** fetch the diff live from GitHub (via a new backend/BFF
   endpoint proxying the GitHub API) per page load, or have the orchestrator
   persist diff metadata when a PR is opened? Live-from-GitHub is simpler and
   always current; persisted is faster and works without GitHub round-trips.
2. **Review thread source:** GitHub PR reviews + review comments, the
   orchestrator's own reviewer `result`/verdict, or both merged into one thread?
3. **Merge / Request-changes actions:** are these in scope for this feature, or
   should they be removed/disabled for now? If in scope, who is authorized
   (human reviewer only?), and do they call GitHub directly or go through the
   orchestrator so task state stays consistent?
4. **Auth / token:** which credential performs GitHub reads (and writes, if merge
   is in scope) — the existing backend GitHub token, or a per-user token?

## Notes

- No Figma design was provided for this feature. If a design is added later, a
  Figma link must be included here so it propagates to the technical design and
  UI tasks per the workspace Figma propagation rule.
