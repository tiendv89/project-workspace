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

## Reviewer Identity

The GitHub account that opens implementation PRs (the executor bot) cannot post a formal `APPROVE` or `REQUEST_CHANGES` review on its own PRs — GitHub returns HTTP 422 for self-reviews. The two-call workaround introduced in `autonomous-task-orchestrator` T10 (issue comment always posts; review event 422 is swallowed) is a partial fix that loses the structured review event.

The clean fix is a dedicated reviewer identity: a second GitHub account whose PAT is used exclusively by the reviewer agent when posting GitHub reviews. This account never opens PRs, so self-review can never occur.

**Requirements:**

- A dedicated GitHub reviewer account must be created (e.g. `zbotdev-reviewer`) and added as a collaborator to each implementation repo with `write` access (minimum to post reviews).
- The following env vars must be set:
  - `REVIEWER_GITHUB_TOKEN` — PAT for the reviewer account, scoped to `repo`
  - `REVIEWER_GIT_AUTHOR_NAME` — display name for the reviewer account
  - `REVIEWER_GIT_AUTHOR_EMAIL` — email for the reviewer account
- The orchestrator's reviewer agent dispatch must inject these three vars into the reviewer executor's environment instead of the standard `GITHUB_TOKEN` / `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL`.
- The feature reviewer daemon (drift detection) must also use `REVIEWER_GITHUB_TOKEN` when posting feature-level PR comments or reviews.
- The impl executor continues to use `GITHUB_TOKEN` / `GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL` — its identity is unchanged.

**Effect on T10 workaround:**
Once the reviewer identity is in place, the two-call workaround in `review-pr` skill can be simplified: both the issue comment and the review event use the reviewer PAT and will succeed without 422. The `reviewer_self_review_skipped` fallback should be retained as a safety net but should no longer fire in normal operation.

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
  reviewer_identity:
    github_token: $REVIEWER_GITHUB_TOKEN
    git_author_name: $REVIEWER_GIT_AUTHOR_NAME
    git_author_email: $REVIEWER_GIT_AUTHOR_EMAIL
```

`.env.template` additions:
```
REVIEWER_GITHUB_TOKEN=      # PAT for dedicated reviewer GitHub account
REVIEWER_GIT_AUTHOR_NAME=   # e.g. "ZBot Reviewer"
REVIEWER_GIT_AUTHOR_EMAIL=  # e.g. "reviewer@example.com"
```

## Feature Merge Process and Done Detection

A feature is only truly `done` when **all** of the following PRs are merged:

1. **Each implementation repo's feature branch PR** — `feature/{feature_id}` → `{base_branch}` in each repo that the feature touched. These are opened by the Handoff Trigger (from `autonomous-task-orchestrator` T9) when all tasks are done.
2. **The management repo's feature branch PR** — `feature/{feature_id}` → `main` in the management repo. This is the PR that contains the handoff document, all task YAML final states, and the final `status.yaml` with `feature_status: in_handoff`.

The human reviews and merges these PRs to approve the feature. A dedicated **Feature Done Watcher** daemon detects when all feature PRs are merged and transitions `feature_status` from `in_handoff` to `done`.

### Feature Done Watcher

Analogous to the task-level `handleMergedPrs` loop, this daemon:

1. Polls all features with `feature_status: in_handoff`.
2. For each, reads the list of feature PRs from `status.yaml` — the `handoff_pr_url` field covers the management repo PR; implementation repo feature PRs are tracked in a new `impl_feature_prs` list in `status.yaml` (see below).
3. Calls the GitHub API to check the merge state of each PR.
4. When **all** PRs in the list are merged: transitions `feature_status` to `done`, commits the updated `status.yaml` to the management repo `main` branch, and emits `feature_done`.

### status.yaml additions for feature merge tracking

```yaml
handoff_pr_url: null          # management repo feature branch PR (set by Handoff Trigger)
impl_feature_prs:             # implementation repo feature branch PRs (set by Handoff Trigger)
  - repo: workflow
    url: https://github.com/org/agent-workflow/pull/123
    status: open              # open | merged
feature_status: in_handoff    # transitions to done when all above are merged
```

The Handoff Trigger (already built in `autonomous-task-orchestrator` T9) must be updated to populate `impl_feature_prs` at the time it opens the implementation repo feature branch PR.

### Handoff document

The handoff document is committed to the management repo at `docs/features/{feature_id}/handoffs/handoff.md` — the same location used by all previous features (consistent with the management repo as the authoritative record). It is committed as part of the management repo feature branch, and is visible in the management repo feature branch PR for human review alongside the final task state.

The handoff document is **not** used as the GitHub PR description — the PR description is a short summary; the full handoff document lives in the repo file.

### Feature reviewer agent scope

The feature reviewer agent's responsibility **ends when the feature branch PR is merged**. It does not continue watching after merge. Post-merge regression detection is out of scope for this feature and would be addressed by a separate monitoring layer if needed.

## Dependencies

- Depends on `autonomous-task-orchestrator` being in place — the feature reviewer agent acts on features the orchestrator manages.
- The Handoff Trigger (from `autonomous-task-orchestrator` T9) must be extended to open implementation repo feature branch PRs and populate `impl_feature_prs` in `status.yaml`.
- The Feature Done Watcher is a new daemon introduced by this feature.
- The feature reviewer agent is a separate daemon that watches existing `in_handoff` features for base-branch drift.

## Success Metrics

- Human reviews one PR per feature per repo, not one per task.
- Drift is detected within one poll cycle of landing on main.
- Task-level drift is resolved automatically with no human action in ≥ 80% of cases.
- Escalation messages contain enough context for the human to act without reading full diffs.
- Feature transitions to `done` automatically when all feature PRs are merged — no manual status update required.

## Decisions

1. **Feature reviewer scope**: ends at merge. No post-merge regression detection.
2. **Handoff document location**: committed to `docs/features/{feature_id}/handoffs/handoff.md` in the management repo, consistent with all prior features.
