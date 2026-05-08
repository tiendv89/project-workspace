# Product Specification

## Feature
- Feature ID: `autonomous-task-orchestrator`
- Title: Autonomous Task Orchestrator

## Problem

Today, once a technical design and task breakdown are approved, a human must review and approve every individual task as it completes. For a feature with 10 tasks, this means 10 separate review cycles — each requiring context-switching, reading a PR, and manually marking a task `done`.

This bottleneck means agents can execute work much faster than humans can process approvals. The system is agent-capable but human-gated at the wrong granularity.

The goal is to shift the human role from **per-task reviewer** to **feature-level approver**: approve the design once, let agents run the full task graph autonomously, and only involve humans for exceptions.

## Goals

1. After a technical design is approved, the orchestrator executes all tasks in the feature's dependency graph without requiring per-task human intervention.
2. The orchestrator creates a feature branch (`feature/{feature_id}`) at start; task PRs target this branch, not the base branch directly.
3. A quality gate (CI pass + reviewer agent sign-off) replaces per-task human PR review for the common case.
4. Humans are notified only for genuine exceptions: blocked tasks, repeated CI failures, or low-confidence reviewer verdicts.
5. When all tasks complete, the orchestrator auto-generates a handoff document and opens a feature-level PR (feature branch → base branch) for human review.
6. All existing workflow rules (branch management, management repo governance, auto-ready cascade, rebase-before-PR) are respected by the orchestrator.
7. PR state reflects task state at all times: task PRs are **draft** while work is in progress and **ready-for-review** only when a reviewer should act — preventing premature review noise and making WIP state visible to the whole team.

## Non-goals

- Removing human approval from product spec or technical design stages — those gates remain.
- Full autonomous shipping without any human review — a feature-level review still occurs.
- Cross-feature orchestration — this feature orchestrates one feature's task graph at a time.
- Replacing the existing task YAML state machine — the orchestrator reads and writes task YAMLs using the existing schema.
- Building a new agent runtime — executor agents continue to use the existing `start-implementation` skill.
- Drift detection for in-handoff features — that responsibility belongs to `autonomous-feature-reviewer`.

## User Stories

**As a product owner / tech lead**, after I approve a technical design, I want the entire task graph to execute autonomously so I can focus on the next feature rather than babysitting individual PRs.

**As an operator**, I want to receive a Slack notification only when a task is genuinely blocked or a quality gate fails — not for every task completion.

**As a human reviewer**, I want one consolidated feature-level review when all tasks are done, not ten individual PR reviews.

## Functional Requirements

### Orchestrator

- Creates a feature branch (`feature/{feature_id}`) from the base branch at start, if it does not already exist.
- Polls the feature's task YAML files at a configurable interval (default: 30 seconds).
- Identifies tasks in `ready` state whose `depends_on` list is fully `done`.
- Dispatches an executor agent for each eligible task, respecting the existing `start-implementation` contract.
- Configures task PRs to target `feature/{feature_id}`, not the base branch.
- Tracks which agent owns which task to prevent double-dispatch.
- Runs the auto-ready cascade when a task transitions to `done`.
- When all tasks are `done`: auto-generates a handoff document, opens a feature-level PR (feature branch → base branch), and transitions the feature to `in_handoff`.

### PR Draft Lifecycle

Task PRs and the feature-branch PR follow the same draft/ready convention — PR state mirrors task state:

| Task state | PR state | Trigger |
|---|---|---|
| `in_progress` | **draft** | `pr-create` skill always opens as draft |
| `in_review` | **ready-for-review** | Orchestrator promotes draft → ready when executor reports `terminal_status: in_review` |
| `change_requested` | **draft** | Orchestrator demotes ready → draft when reviewer posts REQUEST_CHANGES |
| `in_progress` (fix) | **draft** (already) | Fix agent pushes to the existing draft PR; no state change needed |
| `in_review` (fix) | **ready-for-review** | Orchestrator promotes draft → ready again when fix agent reports `in_review` |
| `done` | merged | PR merged as part of auto-done writer flow |

Feature-branch PR follows the same pattern: opened as draft when the feature branch is created; converted to ready-for-review at handoff.

### Quality Gate

- After an executor agent sets a task to `in_review` (PR opened), the orchestrator promotes the PR from draft to ready-for-review, then the quality gate activates.
- Polls CI status on the PR until it resolves (pass or fail).
- Invokes the reviewer agent to evaluate the PR against the task spec and technical design.
- On gate pass (CI pass + reviewer `pass`): auto-merges the PR, writes a `done` log entry (actor: `orchestrator`), and commits the state change to the management repo.
- On gate fail: demotes the PR back to draft, retries up to a configurable limit, then escalates to human.

### Reviewer Agent

- Fetches the PR diff via GitHub API.
- Reads the task spec from `tasks.md` and `technical-design.md`.
- Returns a structured verdict: `pass | flag | fail`, confidence score (0–1), and freetext notes.
- A `flag` verdict always escalates to human — the orchestrator does not auto-merge.

### Escalation

- Triggers on: task `blocked` after max retries, CI failing consistently, reviewer `flag` or `fail`, confidence below threshold.
- Delivers a notification with task ID, reason, and a direct link to the PR or task YAML.
- Escalation channel is configurable per feature (default: Slack webhook).

### Per-task Human Review Override

Individual tasks can opt out of auto-merge by setting `requires_human_review: true` in their execution block:

```yaml
execution:
  actor_type: agent
  requires_human_review: true
```

When set, the orchestrator skips the auto-merge path for that task's PR and routes it to a human regardless of quality gate results. Useful for tasks touching security-sensitive code, infra changes, or anything requiring explicit sign-off.

### Actor Type Extension

- The task YAML schema gains a new valid actor: `orchestrator`.
- `done` log entries written by the orchestrator are auditable and distinguishable from human approvals.

## Configuration (per feature)

```yaml
orchestrator:
  enabled: true
  poll_interval_seconds: 30
  max_retries: 2
  quality_gate:
    require_ci: true
    require_reviewer_agent: true
    reviewer_confidence_threshold: 0.85
  escalation:
    channel: slack
    webhook_url: $SLACK_WEBHOOK_URL
```

## Success Metrics

- A 10-task feature completes end-to-end with zero per-task human actions (only one feature-level review).
- Escalation rate: < 20% of tasks require human escalation in steady state.
- Time from technical design approval to feature-level review is reduced by at least 60% compared to manual task-by-task flow.

## Dependencies

- `autonomous-feature-reviewer` extends the orchestrator's output: it watches features the orchestrator moves to `in_handoff` and handles drift detection while the human reviews the feature PR.
- These two features should be built and deployed together.

## Open Questions

1. ~~Should the feature-level review be a generated summary PR or a manual human step triggered by notification?~~ Resolved: orchestrator opens a feature branch PR and generates a handoff document. Human reviews the PR.
2. What is the right confidence threshold for the reviewer agent out of the box? (Default: 0.85)
3. ~~Should the orchestrator support partial features?~~ Resolved: yes, via `requires_human_review: true` on individual tasks.
