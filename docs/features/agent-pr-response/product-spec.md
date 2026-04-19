# Product Specification

## Feature
- Feature ID: `agent-pr-response`
- Title: Agent PR response

## Problem

Once a task reaches `in_review`, the current workflow treats the agent's job as done. But open PRs need ongoing attention:

1. **Merge conflicts** — when a sibling task merges first, the remaining PR may become unmergeable. This happened with `agent-rag-mcp` T2 and T3 running in parallel: T2 merged, T3's PR is now conflicted. No agent is watching it and no protocol exists to recover it.

2. **Review comments** — a human reviewer may leave feedback on the PR. Currently there is no defined path for an agent to pick up that feedback and address it.

In both cases, the task stalls in `in_review` indefinitely unless a human intervenes manually.

## Goals

- Agents watch `in_review` tasks each polling cycle — not just `ready` tasks
- Merge conflicts are resolved automatically: agent detects conflict, rebases, resolves clean hunks, force-pushes, updates the task log
- Review comment resolution is human-triggered: a human (or agent acting on human instruction) moves the PR back to **draft** state, which is the signal for an agent to pick up the feedback and address it
- Only one agent handles a given `in_review` task at a time — concurrency is controlled the same way as task claiming
- All PR response actions are recorded in the task log for auditability

## Non-goals

- Automatic merging — humans still approve and merge PRs
- Unsolicited comment resolution — an agent must not start addressing review comments unless the PR has been moved to draft first
- Preventing parallel task execution — parallel tasks on the same repo remain intentional and desirable
- Resolving semantic conflicts that require understanding intent — if auto-rebase leaves unresolvable conflicts, the agent blocks with context

## Key behaviours

### Conflict detection and auto-rebase

Each polling cycle, for tasks in `in_review`, check the PR's mergeability via the GitHub API. If `mergeable: false`:
- Claim the rebase work (log entry + push, same concurrency model as task claiming)
- Checkout the implementation branch, rebase onto base branch
- If clean: force-push, log `rebase_completed`
- If conflicts remain: commit conflict markers, set `status: blocked`, log `blocked_reason` + `blocked_suggestion` with file:line pointers

### Comment-driven rework

When a human moves an `in_review` PR to **draft**:
- The agent detects `draft: true` on the PR during polling
- The agent reads the open review comments, addresses them on the implementation branch, pushes, converts the PR back to ready-for-review
- Task log records `comments_addressed`

### Concurrency

Watching `in_review` tasks is lightweight (read-only GitHub API calls). The actual response work (rebase or comment addressing) uses the existing claim protocol: write a log entry to the task's feature branch and push — first push wins, others skip this cycle.
