# Product Specification

## Feature
- Feature ID: `autonomous-feature-reviewer`
- Title: Autonomous Feature Reviewer

## Problem

The current workflow has two structural gaps that become critical when autonomous task execution is introduced:

**Gap 1 — No feature branch isolation.**
Tasks currently open PRs directly against the base branch (`main`). This means partial, mid-feature work lands in `main` as each task completes. For a 10-task feature, `main` receives 10 incremental merges, none of which represents a complete, reviewable unit of work. A human reviewing the feature has no single PR to look at — the work is scattered across 10 merged commits.

**Gap 2 — No drift detection.**
When a feature is in progress and other features land on `main`, there is no mechanism to detect whether the new commits conflict with or invalidate the in-progress feature. Agents continue executing tasks based on a technical design that may now be stale. Conflicts are only discovered at merge time, by which point multiple tasks have been built on invalid assumptions.

## Goals

1. Every feature executes against its own branch, created from the base branch at feature start. Task PRs target the feature branch, not the base branch directly.
2. When all tasks in a feature are complete, a handoff document is auto-generated and a feature-level PR (feature branch → base branch) is opened for human review.
3. A feature reviewer agent watches features in the `in_handoff` stage and detects when new commits land on the base branch that may affect the in-progress feature.
4. The agent classifies each detected change as task-level (handle automatically) or feature-level (escalate to human), and acts accordingly.
5. The human's review surface shifts from many task PRs to one cohesive feature PR — a complete, reviewable unit of work.

## Non-goals

- Replacing the human's final feature-level review — the human still approves the feature branch PR before it merges to main.
- Managing cross-feature merge order or release sequencing — out of scope.
- Retroactively applying the feature branch model to features already in progress.

## User Stories

**As an operator**, once all tasks in a feature complete, I want a single PR to review that shows the full feature diff against main — not 10 individual task PRs.

**As an operator**, I want to receive an alert when a change lands on main that conflicts with a feature currently in handoff, with a clear explanation of what changed and why it matters.

**As an operator**, I want the system to handle routine drift (non-conflicting new commits on main) automatically without my involvement.

**As a tech lead**, I want the handoff document to be auto-generated so I don't have to write it — it should summarise what was built, any deviations from the technical design, and anything that needs follow-up.

## Feature Branch Model

### Branch structure

```
main (base branch)
 └── feature/{feature_id}                    ← feature branch, created at orchestrator start
      └── feature/{feature_id}-T1  →  PR → feature/{feature_id}   (auto-merged on gate pass)
      └── feature/{feature_id}-T2  →  PR → feature/{feature_id}   (auto-merged on gate pass)
      └── feature/{feature_id}-T3  →  PR → feature/{feature_id}   (auto-merged on gate pass)
      
      All tasks done → handoff doc generated → feature PR opens → in_handoff
      Human approves → feature branch merges into main
```

### What changes from today

| Today | After this feature |
|---|---|
| Task PR targets `main` | Task PR targets `feature/{feature_id}` |
| Human reviews each task PR | Human reviews one feature PR |
| No feature branch | Feature branch created at orchestrator start |
| No handoff doc auto-generation | Handoff doc auto-generated when all tasks done |
| No drift detection | Feature reviewer agent monitors base branch |

## Feature Reviewer Agent

### Trigger
Activates for every feature in `in_handoff` status. Polls the base branch for new commits at a configurable interval (default: 10 minutes).

### Classification logic

When new commits land on the base branch, the agent classifies the impact:

**Task-level (agent handles automatically):**
- No file overlap between the incoming commits and the feature's task PRs.
- Or: file overlap exists but a clean rebase of the feature branch onto the new base is possible with no semantic conflict.
- The incoming changes are purely additive — new files, new endpoints, new tables that do not touch anything in this feature.
- Action: rebase the feature branch onto the new base, update the feature PR, notify operator.

**Feature-level (human must review):**
- A file that this feature's tasks touch was also changed in the incoming commits in a way that creates a semantic conflict — not just a git conflict, but a design-level conflict.
- An API, schema, or interface this feature depends on changed in the base branch.
- The incoming change implements something that overlaps with or contradicts what this feature is building, as described in `technical-design.md`.
- The agent's confidence that "this feature still makes sense as designed" drops below a threshold (default: 0.80).
- Action: pause, generate a conflict report, escalate to human with a clear summary.

### Escalation message format

Escalations must be specific, not generic. Example:

> **Feature drift detected — autonomous-feature-reviewer**
> New commit `abc1234` on `main` modified `auth/session.py`.
> Task T3 of this feature also modifies `auth/session.py` (added `refresh_token` field).
> The incoming change restructured the `SessionStore` interface this task depends on.
> **Action required:** Review the conflict and decide whether T3's implementation needs updating.
> PR: [link] | Task: [link to task YAML]

### Handoff document

Auto-generated when all tasks transition to `done`. Contents:

- Feature summary (from product spec goals)
- List of tasks completed, with PR links and reviewer agent notes
- Any deviations from the technical design noted during execution
- Files changed (aggregate across all task PRs)
- Test coverage summary
- Open risks or follow-up items flagged during execution
- Timestamp and actor audit trail

## Per-task Human Review Override

Individual tasks can opt out of auto-merge by setting:

```yaml
execution:
  actor_type: agent
  requires_human_review: true
```

When `true`, the orchestrator skips auto-merge for that task's PR and routes it to a human regardless of quality gate results. Useful for tasks touching security-sensitive code, infra changes, or anything the tech lead wants eyes on explicitly.

## Configuration

```yaml
feature_reviewer:
  enabled: true
  poll_interval_minutes: 10
  confidence_threshold: 0.80
  escalation:
    channel: slack
    webhook_url: $SLACK_WEBHOOK_URL
```

## Dependencies

- Depends on `autonomous-task-orchestrator` being in place — the feature reviewer agent acts on features the orchestrator manages.
- The orchestrator is responsible for creating the feature branch and opening the feature PR at handoff.
- The feature reviewer agent is a separate daemon that watches existing in_handoff features.

## Success Metrics

- Human reviews one PR per feature, not one per task.
- Drift is detected within one poll cycle of landing on main.
- Task-level drift is resolved automatically with no human action in ≥ 80% of cases.
- Escalation messages contain enough context for the human to act without reading full diffs.

## Open Questions

1. Should the feature reviewer agent continue watching after the human merges the feature branch (to detect post-merge regressions), or does its responsibility end at merge?
2. Should the handoff document be committed to the management repo as a file, or generated as a GitHub PR description?
