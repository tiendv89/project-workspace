# Product Specification

## Feature
- Feature ID: `agent-runtime-pr-merge`
- Title: Agent runtime PR merge — close the loop when an implementation PR is merged

## Problem

Today a task completes in two separate steps that both require human action:

1. **The human merges the implementation PR** in the implementation repo.
2. **The human also must separately handle the workspace PR** — update the task YAML to `done` and merge the management-repo PR.

There is no automation bridging these two events. After merging the implementation PR the human must remember to find the corresponding workspace PR, verify the task YAML reflects the right status, and merge a second PR. This is mechanical bookkeeping that is easy to forget, easy to get wrong, and scales badly as more tasks run concurrently.

The result in practice:
- Workspace PRs pile up unmerged after their implementation PRs are closed.
- `main` on the management repo drifts behind the feature branches.
- Task status YAMLs on `main` show `in_review` indefinitely — the dashboard is stale.
- A human reviewing workspace history must cross-reference GitHub PR state manually to understand what is actually done.

## Goals

1. **Detect when an implementation PR is merged.** The runtime polls the GitHub REST API for every open task in `in_review` state. When a task's `pr.url` (implementation PR) is found to have `merged: true`, the merge event is acted on automatically.

2. **Mark the task `done` in the task YAML on the feature branch.** Upon detecting the implementation PR merge, the runtime commits a `done` log entry and status update to the task YAML on the task's feature branch in the management repo. The human's merge of the implementation PR is treated as the approval signal — no second explicit approval step is required.

3. **Merge the management-repo PR automatically.** After updating the task YAML, the runtime calls the GitHub REST API to merge the open management-repo PR for that task's feature branch. This completes the "branch merge rule" (management repo PR merged when task is `done`) without requiring any additional human action.

4. **The polling loop runs as a persistent process inside the agent runtime.** It is not a one-shot script. It wakes on a configurable interval (default 60 s), checks all open tasks in `in_review`, and acts on any that are newly merged since the last check.

5. **Idempotent operation.** If the loop runs twice before the first commit propagates, the second run must not double-commit or attempt to re-merge an already-merged PR. All writes are guarded by pre-condition checks.

## Non-goals

- Handling implementation PR *closure without merge* (abandoned PRs) — that is a separate blocked/cancelled flow.
- Merging the workspace PR before the implementation PR is merged — the workspace PR stays open until the implementation PR is confirmed merged.
- Detecting merges via GitHub webhooks — polling is sufficient for the current fleet size and avoids webhook infrastructure.
- Auto-approving GitHub PR reviews — the implementation PR merge itself is the approval; the workspace PR is merged directly via the merge API endpoint without a separate review approval.
- Notifying humans after merge — out of scope; the task YAML and GitHub PR history are the record.

## User stories

1. **As a tech lead**, I merge an implementation PR on GitHub and — within one polling interval — the task YAML on `main` in the management repo updates to `done` and the workspace PR is merged automatically. I never touch the workspace repo to close out the task.

2. **As a product owner**, I open the feature status dashboard and see tasks flip from `in_review` to `done` within a minute of the implementation PR being merged — without anyone manually updating YAML files.

3. **As an operator**, I configure the polling interval via an env var (`PR_MERGE_POLL_INTERVAL_SECONDS`) and see the loop start automatically when the agent runtime boots alongside the task watcher.

4. **As a developer**, I can see exactly what the loop did in the runtime logs: which task was detected as merged, what commit was pushed to the management repo, and whether the workspace PR merge succeeded or failed.

## Architectural direction

The merge-detection loop sits inside the agent runtime alongside the existing task watcher:

| Component | Role |
|---|---|
| Task watcher | Watches `status: ready` tasks and dispatches agents |
| **PR merge loop** | Watches `status: in_review` tasks and closes them when implementation PR is merged |

### Detection flow

```
every PR_MERGE_POLL_INTERVAL_SECONDS:
  for each task with status: in_review and pr.url set:
    fetch GitHub PR state via REST API
    if PR merged:
      1. git pull task feature branch (management repo)
      2. update task YAML: status → done, append done log entry
      3. git commit + push to feature branch
      4. call GitHub merge API on workspace PR (management-repo PR for this task's branch)
      5. log result
```

### Workspace PR identification

Each task YAML already carries `pr.url` (implementation PR) and `workspace_pr` (management-repo PR). The merge loop uses `workspace_pr` to identify which management-repo PR to merge. If `workspace_pr` is null the loop logs a warning and skips the workspace merge step (the task YAML `done` update still proceeds).

### Required env vars

| Variable | Description |
|---|---|
| `GITHUB_TOKEN` | GitHub PAT with `repo` scope — used for PR state checks and merge calls |
| `PR_MERGE_POLL_INTERVAL_SECONDS` | Polling interval in seconds (default: `60`) |
| `WORKSPACE_MGMT_LOCAL_PATH` | Local path to the management repo clone |

### Failure handling

- **GitHub API error on PR state check**: log and skip this task on this iteration; retry on next poll.
- **git push rejected (non-fast-forward)**: log and skip; another process updated the branch. Do not force-push.
- **Workspace PR merge API error**: log with full response; leave workspace PR open; the task YAML `done` commit is not rolled back. Human intervention required to merge the PR manually.
