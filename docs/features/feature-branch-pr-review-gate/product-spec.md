# Product Specification

## Feature
- Feature ID: `feature-branch-pr-review-gate`
- Title: Feature branch PR review gate — reviewer approves but never merges

## Problem

Today the final feature branch PR (`feature/<id>` → `main`) is handled differently from task PRs. The orchestrator opens it and may treat it as an auto-merge artifact once all tasks are done. There is no formal reviewer pass on the feature branch PR before the human merges it.

Task PRs with `execution.requires_human_review: true` already have the correct behaviour: a reviewer agent posts APPROVE or REQUEST_CHANGES on GitHub, but the merge itself is reserved for the human. The feature branch PR has no equivalent gate — it can be promoted from draft and left waiting for a human merge with no reviewer having evaluated the cumulative diff.

This creates an asymmetry: every individual task gets reviewed, but the integration of all tasks — the final feature branch PR — gets no reviewer pass at all.

## Goals

- The feature branch PR must receive a reviewer agent pass before the human merges it.
- The reviewer posts APPROVE or REQUEST_CHANGES on GitHub (same as task review).
- The reviewer never merges the PR — the human always performs the final merge.
- The orchestrator must not mark the feature `done` until the human merges the feature branch PR (existing behaviour preserved).
- The review gate must be triggered automatically when the feature branch PR is promoted from draft (i.e. when `handoff_pr_promoted: true` is written to `status.yaml`).

## Non-goals

- Changing how individual task PRs are reviewed.
- Changing the human's ability to merge without waiting for APPROVE (the gate is informational / best-practice, not a GitHub branch protection rule — unless the operator configures one separately).
- Auto-merging the feature branch PR under any condition.

## User stories

- As a tech lead, I want the orchestrator to dispatch a reviewer agent on the feature branch PR the moment it is ready for review, so I receive a structured APPROVE or REQUEST_CHANGES before I decide to merge.
- As a human operator, I want to always be the one who presses merge on the feature branch PR, regardless of what the reviewer found.
- As a reviewer agent, I want to evaluate the full feature diff (all tasks combined) against the feature's `technical-design.md` and `tasks.md` acceptance criteria, not just a single task's scope.

## Behaviour specification

### Trigger
The orchestrator dispatches a feature branch reviewer when:
1. `status.yaml.handoff_pr_promoted` is `true`
2. `status.yaml.handoff_pr_review_status` is absent or `pending`
3. No reviewer is already in flight for the feature PR

### Reviewer scope
The reviewer receives:
- The feature branch PR diff (all tasks combined)
- `product-spec.md`, `technical-design.md`, and `tasks.md` for the feature
- Instruction: post APPROVE or REQUEST_CHANGES on GitHub; do not merge

### Post-review state
- On APPROVE: `status.yaml.handoff_pr_review_status = approved`; orchestrator waits for human merge
- On REQUEST_CHANGES: `status.yaml.handoff_pr_review_status = changes_requested`; orchestrator surfaces to human for decision
- On reviewer exit without valid result: retry up to `MAX_REVIEW_INCOMPLETES`; escalate to `blocked` after max retries

### Merge detection (unchanged)
The orchestrator's existing Feature Done Watcher polls `handoff_pr_url` for merge. When merged by the human, the feature transitions to `done` — same as today.
