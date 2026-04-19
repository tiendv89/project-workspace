# Technical Design

## Feature
- Feature ID: `agent-pr-response`
- Title: Agent PR response

## Current State

Tasks move to `in_review` when the agent opens a PR. After that, the runtime has no further involvement — the task sits and waits for a human to merge. There is no polling of PR mergeability, no re-check after sibling merges, and no defined recovery path if the PR becomes conflicted.

## Constraints

- Agents cannot merge PRs — humans retain that boundary
- The workflow must not require humans to manually rebase every conflicted PR
- Resolution commits must land on the task's feature branch and be visible in the task log
- The protocol must be executable by any agent with no task-specific knowledge

## Options Considered

### Option A — Human resolves manually
Leave conflict resolution entirely to the human: they rebase, force-push, and re-request review.
- Pros: simple, no new automation
- Cons: breaks the autonomous delivery promise; scales poorly with parallel agents

### Option B — Agent detects conflict on PR open, blocks immediately
At PR-open time, check if the base branch has diverged. If yes, block before raising the PR.
- Pros: catches the problem early
- Cons: doesn't help when the conflict appears *after* PR is open (sibling merges asynchronously)

### Option C — Polling + agent-driven rebase on conflict detection (chosen)
The runtime polls open `in_review` PRs for mergeability. When a conflict is detected, it re-assigns the PR to an agent that rebases the implementation branch, resolves conflicts, force-pushes, and updates the task log. The PR is then re-raised for human review.

- Pros: fully autonomous for routine conflicts; human only sees the re-review request
- Cons: requires a new polling loop and conflict-resolution protocol

## Chosen Design

### Polling loop architecture

`in_review` checks run in the **same loop** as `ready` task pickup, but at an independently configurable interval.

Within each cycle, the order is:
1. Pull workspaces
2. Check `ready` tasks (existing eligibility → claim → run Claude)
3. Check `in_review` tasks for PR status (mergeability + draft state)

`ready` is checked first so task execution is not delayed by PR polling. If a `ready` task is found and claimed, the cycle still completes the `in_review` pass before returning — both checks happen every cycle.

A new field `pr_poll_interval_seconds` in `agent.yaml` controls how often step 3 fires. The runtime skips the `in_review` pass if it ran within that window. Default: same as `idle_sleep_seconds` (1 min initially). Long-term target: 5 min, since PR conflicts are low-urgency compared to task pickup.

```yaml
# agent.yaml
idle_sleep_seconds: 60
pr_poll_interval_seconds: 60   # default; raise to 300 in production
```

### Detection

At the start of each polling cycle, for every task in `in_review`, check the implementation repo PR's mergeability via the GitHub API:

```
GET /repos/{owner}/{repo}/pulls/{pull_number}
→ mergeable: true | false | null
```

If `mergeable: false`, transition the task to a new sub-state: `in_review_conflicted` (stored as `conflict_state: conflicted` on the task YAML — no new lifecycle status required).

### Recovery protocol

When conflict is detected, the runtime claims the rebase work by writing a `rebase_started` log entry to the task YAML on the feature branch, then:

1. In the **implementation repo**: checkout the PR branch, `git fetch origin`, `git rebase origin/<base_branch>`.
   - If rebase is clean: force-push, update `conflict_state: resolved`.
   - If rebase has conflicts: apply auto-resolvable hunks, commit. If unresolvable conflicts remain, commit the conflict markers, set `status: blocked`, write `blocked_reason` + `blocked_suggestion` (file:line pointers), push — human resolves.
2. In the **management repo**: append a `rebase_completed` or `blocked` log entry to the task YAML on the feature branch.

### Task YAML additions

```yaml
conflict_state: none | conflicted | resolving | resolved
rebase_log:
  - at: <timestamp>
    action: rebase_started | rebase_completed | rebase_blocked
    by: <agent>
    note: <detail>
```

### Scope of automation

| Conflict type | Agent action |
|---|---|
| Clean rebase (no conflicts) | Rebase, force-push, mark resolved |
| Conflicts in files the agent authored | Attempt resolution, commit, re-review |
| Conflicts in files the agent did not touch | Block with `blocked_suggestion` pointing to conflicting lines |

## Dependency Analysis

- Depends on GitHub API access (`GITHUB_TOKEN`) — already required
- Requires the agent runtime to pull implementation repos each cycle (already done)
- No new external dependencies

## Parallelization / Blocking Analysis

- Detection is read-only and can run in parallel across all `in_review` tasks
- Rebase work is per-task and per-branch — no contention
- A task in `resolving` state should not be claimed by a second agent (lock via log entry + push, same as claim protocol)
