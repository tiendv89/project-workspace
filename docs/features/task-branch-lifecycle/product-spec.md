# Product Specification

## Feature
- Feature ID: `task-branch-lifecycle`
- Title: Task branch lifecycle — claim, execution, and blocked recovery

## Scope

This feature defines how agents interact with the **management repo** throughout
a task's lifetime. All branches, commits, and PRs described here are on the
management repo. The management repo is the source of truth for task status
(YAML files under `docs/features/<feature-id>/tasks/`). Work on the
implementation repo (cloning, coding, opening code PRs) is handled by
`start-implementation` and is out of scope here.

## Problem

The task lifecycle on the management repo — from claim to completion — has no
defined, enforced protocol. There are five concrete gaps:

1. **No branch naming convention.** There is no canonical branch name for a
   task during implementation. Agents may invent ad-hoc names or commit directly
   to a shared branch, making task isolation and attribution unclear.

2. **No defined PR timing.** It is not specified when the task PR should be
   opened. Opening too late means reviewers have no visibility until the very
   end; opening at the wrong point creates ambiguity about what "open PR" means.

3. **No commit discipline during implementation.** There is no rule requiring
   all commits during a task's lifetime to land on the same branch. An agent
   could commit claim state to one branch and implementation work to another,
   breaking traceability.

4. **Undefined behaviour when the branch already exists.** If `feature/<feature-id>/T<n>`
   already exists at claim time (crashed agent, interrupted claim, prior blocked
   attempt), agents have no defined protocol — they may clobber, reset, or abort
   inconsistently.

5. **No recoverable artifact after a block.** When an agent blocks, it exits
   without pushing code. The next agent or human has only the `blocked_reason`
   text; no branch, no partial commits, no code context. Recovery requires
   starting from scratch, discarding any partial work.

## Goals

- A task has exactly one canonical branch: `feature/<feature-id>/T<n>`.
- An agent opens a PR at claim time, not at completion.
- All commits during a task's lifetime — claim, implementation, completion —
  land on the same branch.
- The agent always pulls the latest management-repo state before any key
  decision (claim, status change) to ensure it is working from the current truth.
- The branch-already-exists case has a defined protocol that does not clobber
  prior work.
- A blocked agent always leaves a pushed WIP commit so recovery is possible
  without starting from scratch.

## Non-goals

- PR review comment resolution flow (deferred, tracked separately).
- Autonomous recovery without human involvement.
- Automatic retries on block.

## Scenarios

### S1 — Claim

Precondition: agent is watching management-repo main for tasks with
`status: ready`.

1. Agent pulls the latest management-repo main (`git pull origin main`).
2. Agent reads the task YAML and confirms `status: ready`.
3. Agent creates branch `feature/<feature-id>/T<n>` from main.
4. Agent commits the status change `ready → in_progress` to that branch and
   pushes. If the push is rejected (concurrent claim, non-fast-forward), agent
   aborts and re-scans from step 1.
5. Agent opens a PR from `feature/<feature-id>/T<n>` → main on the management repo.

All subsequent commits for this task land on the same branch.

**Branch already exists, status still `ready`**

A prior agent began the claim (created the branch) but did not complete it —
the status was never advanced to `in_progress`. The new agent:
1. Pulls main, confirms status is still `ready`.
2. Checks out the existing branch (`git fetch origin && git checkout <branch>`).
3. Commits the `ready → in_progress` status change and pushes (same push-rejection
   check — rejected push means someone else got there first).
4. Opens a PR if one does not already exist; otherwise uses the existing PR.

**Branch already exists, `blocked_context` is non-null**

A prior agent blocked with partial work pushed. The new agent enters blocked
recovery mode (see S5).

### S2 — Implementation complete

Precondition: agent has the task branch checked out (from S1 or S5).

1. Agent commits all implementation work to `feature/<feature-id>/T<n>`.
2. Agent appends a completion log entry and updates `status: in_review` in the
   task YAML.
3. Agent commits the YAML change to the same branch and pushes.
4. The PR opened in S1 now carries the full implementation — ready for human review.

### S3 — PR merged → done

Precondition: the S2 PR has been reviewed and merged by a human.

1. Human merges the PR on the management repo.
2. Human sets `status: done` in the task YAML on main and pushes.
3. Dependency propagation fires automatically: any task whose dependencies are
   now all `done` transitions `todo → ready` without human involvement.

_Note: comment-resolution flow (`in_review → in_progress → in_review`) is out
of scope for this feature and will be addressed separately._

### S4 — Blocked exit

Triggered when the agent encounters an unresolvable blocker during S1 or S2.

1. Agent commits all dirty/partial work:
   `git add -A && git commit -m "wip: partial work before block — <summary>"`.
2. Agent pushes `feature/<feature-id>/T<n>` to remote.
3. Agent records in the task YAML:
   ```yaml
   blocked_context:
     wip_branch: feature/<feature-id>/T<n>
     wip_sha: <SHA of the WIP commit>
     pushed_at: <ISO 8601 timestamp>
   ```
4. Agent sets `status: blocked`, writes `blocked_reason` + `suggested_next_step`.
5. Agent commits the YAML change to the branch and pushes.
6. Agent exits.

### S5 — Blocked recovery

Precondition: task `status` is `ready` AND `blocked_context` is non-null.
Triggered from S1 when the agent detects this condition.

1. Agent pulls main, confirms `blocked_context` is non-null.
2. Agent checks out `blocked_context.wip_branch`, reset to
   `origin/<wip_branch>`.
3. Agent reads `blocked_reason` and `suggested_next_step` as additional context.
4. Agent continues implementation on top of the existing WIP commits (does not
   reset to base, does not squash WIP commits).
5. **PR inheritance:** agent attempts to reuse the existing open PR on the
   management repo for this branch.
   - If the PR is open: continue using it. No new PR is opened.
   - If the PR was closed or cannot be found: open a new PR from a new branch
     named `feature/<feature-id>/T<n>-<attempt>` where `<attempt>` increments
     from 2 (e.g. `T3-2`, `T3-3`). Record the new branch name in
     `blocked_context.wip_branch`.
6. On successful completion (S2): agent clears `blocked_context` (sets to `null`)
   in the task YAML.

### Human re-activation (prerequisite for S5)

1. Human reads `blocked_reason` and `suggested_next_step` in the task YAML.
2. Human optionally updates `suggested_next_step` to guide the next agent.
3. Human sets `status: ready` in the task YAML and pushes to management-repo main.
4. (Optional) Human pushes a fix commit directly to the WIP branch.
5. Next agent activation picks up the task via the normal S1 claim flow.

## Acceptance criteria

- A claimed task always creates or reuses `feature/<feature-id>/T<n>` and
  opens a PR against main at claim time.
- Agent pulls the latest main before the claim status commit and before any
  other key status decision.
- The `ready → in_progress` push is atomic: a concurrent second claim results in
  a push rejection for one of the agents, which then re-scans.
- All task commits (claim, implementation, completion) land on the same branch.
- Branch-already-exists cases are handled without clobbering:
  - Status still `ready`: pull, check out, advance status, open PR if missing.
  - `blocked_context` non-null: enter blocked recovery (S5).
- A blocked agent always leaves a pushed branch with at least one WIP commit
  and a populated `blocked_context` in the task YAML.
- S5 reuses the existing PR if open; opens a new `-<attempt>` branch PR if not.
- `blocked_context` is cleared after a successful recovery completion.
- S3: human merges PR and sets `status: done`. Dependency propagation (`todo → ready`)
  fires automatically — not a human responsibility.
