# Product Specification

## Feature
- Feature ID: `blocked-task-recovery`
- Title: Blocked task recovery — artifact preservation and re-entry flow

## Problem

When an automated agent gets stuck and cannot complete a task, it currently sets
`status: blocked`, writes a `blocked_reason` + `suggested_next_step` to the task
YAML, and exits — without pushing any code or opening a PR.

The "do not open a PR for broken work" rule was intended to keep the PR queue
clean, but it has an unintended side effect: **a blocked agent leaves zero
recoverable artifact**. The next agent or human picking up the task has only the
`blocked_reason` text to work from — no branch, no partial commits, no code
context. Recovery requires starting from scratch.

This gap becomes more severe as task complexity grows. A task that ran for 20
minutes before blocking may have produced substantial partial work that is simply
lost.

## Goals

- A blocked agent always pushes its partial work to the feature branch before
  exiting, so the work can be inspected, resumed, or built upon.
- The next agent (or human) picking up a blocked task can see exactly where the
  previous attempt stopped and why.
- The re-entry flow for `blocked` tasks is explicit and safe — the recovering
  agent does not clobber the partial work from the previous attempt.
- The distinction between "not ready to review" and "nothing to see" is clear:
  a blocked task may have a pushed branch but no open PR.

## Non-goals

- Autonomous recovery without human involvement. A blocked task requires a
  human to review the `blocked_reason` and decide whether to re-activate it.
- Automatic retries. The timer/cron re-entry already handles idle retries;
  this feature is about the manual recovery path after a genuine block.
- Changing the claim protocol for unblocked tasks.

## User stories

**As a human operator**, when an agent blocks on a task, I want to see the
partial code it produced so I can understand what it tried, fix the blocker,
and re-activate the task without starting from zero.

**As a recovering agent**, when I pick up a `blocked` task, I want to know
what the previous agent already committed so I don't repeat the same work or
conflict with it.

## Proposed behaviour

1. Before exiting with `status: blocked`, the agent commits any staged/unstaged
   work-in-progress to the feature branch with a `wip:` commit message, and
   pushes the branch.
2. The task YAML records the pushed branch SHA in `blocked_context.last_wip_sha`
   so the next agent knows exactly where to resume.
3. The `start-implementation` skill gains a **blocked re-do mode**: when a task
   is `blocked` and has a pushed branch, the re-do path checks out that branch
   (instead of resetting to base), reads `blocked_reason` and
   `suggested_next_step`, and continues from the existing state.
4. A human re-activates a blocked task by setting `status: ready` (optionally
   updating `suggested_next_step`) and pushing to the management repo. The next
   agent activation picks it up via the normal claim flow.

## Acceptance criteria

- A blocked agent always leaves a pushed branch with at least one WIP commit.
- The task YAML records `blocked_context` with the branch and last WIP SHA.
- The `start-implementation` blocked re-do mode checks out the existing branch
  rather than creating a fresh one.
- A human can re-activate a blocked task by setting status back to `ready`.
- End-to-end: simulate a blocking scenario; verify the WIP branch is pushed,
  the re-activating agent picks up the correct branch state, and completes
  the task.
