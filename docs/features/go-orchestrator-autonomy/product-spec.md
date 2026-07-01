# Product Specification

## Feature
- Feature ID: `go-orchestrator-autonomy`
- Title: Go Orchestrator — Autonomous Parity (reviewer cycle, handoff, error recovery, unblock)

## Problem
`workflow-db` shipped the Go/Postgres orchestrator as a **human-merge slice**: it can atomically
claim tasks in the DB, dispatch executors, reap completions to `in_review`, auto-ready dependents,
and reach `done` **only when a human merges the implementation PR**. It is not autonomous — a human
must review and merge every PR, and features never advance past task-level `done`.

To let the Go orchestrator actually *drive a feature end-to-end* (and eventually replace the TS
orchestrator), it must run the same autonomous loops the TS orchestrator runs beyond basic task
lifecycle: reviewing PRs and merging them, recovering from executor/infra failures, resolving merge
conflicts, and completing the feature via a handoff. Today none of that exists on the Go path, so
go-owned features stall the moment they need a review, hit a failure, or finish their tasks.

The goal is **feature-level behavioural parity with the TS orchestrator** — "same behaviour, not the
same code": a faithful Go/DB reimplementation, not a line-for-line port.

## Background / dependency
Builds directly on `workflow-db`, which established in the DB the primitives this feature reuses:
the guarded-`UPDATE` claim (every transition here is the same shape), the owner-partitioned broker
(`owner='go'` completion queue), the PR-merge poll (`in_review → done`), and dependency auto-ready.
This feature adds the reviewer, error-recovery, conflict, handoff, and unblock automation on top — it
does not redo the write path.

The full technical design (state machines, schema columns, reconciler, soft-claim throttle, adapter
coexistence fix) is captured in the approved planning document and will be formalized in
`technical-design.md` during the tech-lead phase.

## Goals
- **Reviewer cycle.** Dispatch a reviewer agent for `in_review` tasks, route its verdict through the
  guarded DB FSM (`in_review → reviewing → review_passed | change_requested | review_incomplete`),
  and let the reviewer agent merge the approved PR (honouring `requires_human_review`).
- **Fix loop.** `change_requested → in_progress`: dispatch a fix agent to address review comments (or
  resolve a merge conflict), then re-review.
- **Review-incomplete retry + escalation.** Retry a reviewer that returns no valid verdict up to a
  cap, then escalate to `blocked`.
- **Conflict resolution.** Detect conflicting PRs via GitHub `mergeable` and auto-rebase both task
  PRs (task→feature) and, at handoff, feature→main PRs — with a bounded retry cap that escalates.
- **Handoff.** When every task of a feature is `done`/`cancelled`, mark the feature `in_handoff`, open
  draft feature→main PRs for each touched implementation repo plus the management-repo status PR, and
  finalize the feature to `done` once those PRs are merged.
- **Error / stuck observability & recovery.** Persist failure context on the task
  (`blocked_reason` + details) and recover from executor crashes, spawn failures, redis-dispatch
  failures, and max-turns exhaustion, escalating to `blocked` only after bounded retries.
- **Human-unblock.** A human (via UI or an agent) can unblock a `blocked` task; the task resumes at
  the correct state based on why/where it blocked. Exposed through a backend API, a bff proxy, and a
  workflow-mcp tool + agent skill (UI itself out of scope).
- **End-to-end autonomous run.** Drive a go feature from `ready` to feature-level `done` with no human
  merge of task PRs (reviewer APPROVE → merge → feature handoff), in parallel with a legacy TS
  feature, preserving the single-owner-per-feature invariant.
- **Multiple orchestrator instances** run safely against one workspace (guarded first-write-wins).

## Non-goals
- Re-implementing the `workflow-db` write path, atomic claim, broker partitioning, or PR-merge poll.
- **Slack notifications** — deferred to a separate `go-orchestrator-slack-notifications` feature; this feature only
  leaves `// TODO(slack)` markers at the notification points.
- The **drift daemon** — dropped; conflict detection uses GitHub `mergeable` at PR/merge time instead
  of base-SHA tracking.
- Changes to the **broker, dispatcher, executor, or existing agent skills** (`review-pr`,
  `respond-to-review`) — reused as-is. (Exceptions are additive: schema migrations, the unblock API
  surface, and a new `unblock-task` skill.)
- Building the **unblock UI** — only the backend/bff/mcp/skill surface is in scope.
- Retiring the TS orchestrator — this brings the Go orchestrator to parity so retirement becomes
  possible later; the cutover itself is out of scope.

## Open questions
1. Feature→main conflict auto-resolve needs a working-tree rebase; confirm whether the existing
   `respond-to-review` skill covers feature-branch (not just task-branch) rebases, or whether we
   flag-for-human. (Resolve in technical design.)
2. Whether the cause-aware unblock target mapping warrants a refinement to the shared `CLAUDE.md`
   unblock rule (surface to human before changing shared rules).
3. Broker completion drain semantics under multiple orchestrator instances (guarded transitions make
   re-processing idempotent regardless; confirm during design).
