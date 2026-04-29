# Product Spec — Check Status Across All Branches

## Feature
- Feature ID: `check-status-across-all-branches`
- Title: Check status across all branches

## Problem

The workflow dashboard reads task state from the management repo working tree. That
working tree usually represents the base branch, while active task execution writes
task updates to per-task branches such as:

```text
feature/feature-status-dashboard-v2-T1
```

Because task branches are not always merged immediately, the dashboard can show a
stale task status even though the task branch already contains a newer
`docs/features/<feature_id>/tasks/T<n>.yaml` file.

## Goal

Add a branch-aware task status sync flow that uses git commands to fetch current
task YAML state from each task branch and update the task status in the management
repo so dashboard views reflect active task progress.

## Requirements

1. Scan all task YAML files under the active workspace:
   `docs/features/*/tasks/T<n>.yaml`.
2. Resolve each task branch from `task.branch` when present. If missing, derive it
   from the workspace branch pattern:
   `feature/<feature_id>-<task_id>`.
3. Fetch remote task branches from `origin` using git commands before reading
   status.
4. Read each remote branch's task YAML without checking out the branch.
5. Update the local task YAML only when the remote branch contains newer task
   runtime state.
6. Sync the fields that represent runtime state:
   - `status`
   - `blocked_reason`
   - `blocked_context`
   - `execution`
   - `pr`
   - `workspace_pr`
   - `log`
   - `branch`
7. Do not rewrite task definition fields such as `title`, `repo`, or
   `depends_on`.
8. Commit and push sync updates through git so the management repo remains the
   source of truth.
9. Poll automatically every 15 seconds while the dashboard is open and an active
   workspace is selected.
10. Skip safely when a branch is missing, a task YAML is missing on the branch, the
    branch YAML is invalid, or the local repo has conflicting uncommitted changes.

## Non-Goals

- Do not execute or claim agent tasks.
- Do not mark tasks `done` unless the task branch YAML already says `done`.
- Do not merge task branches or implementation PRs.
- Do not use GitHub PR API status as the task status source.
- Do not change the task YAML schema.
- Do not scan arbitrary branches unrelated to existing task YAML files.

## Acceptance Criteria

- Given `docs/features/feature-status-dashboard-v2/tasks/T1.yaml`, the sync flow
  resolves branch `feature/feature-status-dashboard-v2-T1`.
- When `origin/feature/feature-status-dashboard-v2-T1` contains a newer task YAML
  with `status: in_review`, the local task YAML is updated to `status: in_review`
  and the change is committed and pushed.
- When the branch YAML is older than the current base-branch YAML, the sync flow
  does not regress the local task status.
- When the sync flow runs repeatedly with no task changes, it creates no commits.
- The dashboard refreshes after a successful sync that changed at least one task.
- Polling does not overlap concurrent sync runs for the same workspace.

