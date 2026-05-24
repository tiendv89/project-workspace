# Technical Design

## Feature
- Feature ID: `feature-branch-pr-review-gate`
- Title: Feature branch PR review gate — reviewer approves but never merges

## Current State

The orchestrator's Handoff Trigger (`handoff-trigger.ts`) promotes the feature branch PR from draft when all tasks are done. After promotion, the Feature Done Watcher polls `handoff_pr_url` for a human merge. No reviewer agent is dispatched for the feature branch PR.

Task PRs with `execution.requires_human_review: true` already implement the correct pattern:
- Reviewer posts APPROVE or REQUEST_CHANGES on GitHub
- Orchestrator does not merge — it waits for the human to merge
- Only after the human merges does the task transition to `done`

The feature branch PR currently has no equivalent gate.

## Constraints

- The reviewer must never merge the feature branch PR — human merge is mandatory.
- The review trigger must be idempotent: re-running the orchestrator cycle must not dispatch a second reviewer if one is already in flight or has completed.
- The existing Feature Done Watcher merge-detection logic must not change — it already correctly waits for human merge.
- `status.yaml` is the authoritative state store for the feature branch PR review status (not a task YAML, since this is feature-level, not task-level).

## Options Considered

### Option A — Reuse task reviewer dispatch path with a synthetic feature-level task
Create a virtual T_final task that represents the feature branch PR review. Route it through the existing task reviewer machinery.

- Pros: No new orchestrator code paths; reuses all existing reviewer logic.
- Cons: Pollutes the task namespace with a non-implementation task; complicates `depends_on` graphs; the task YAML model doesn't fit (no `repo`, no `branch` in the implementation sense).

### Option B — Add a dedicated feature PR reviewer dispatch step to the poll cycle
Add a new orchestrator step (`dispatch-feature-pr-reviewer`) that fires after `runFeatureBranchLifecycle` detects `handoff_pr_promoted: true` and `handoff_pr_review_status` is absent or `pending`.

- Pros: Clean separation; feature-level review state lives in `status.yaml` where it belongs; no task model pollution.
- Cons: New code path in the orchestrator; reviewer briefing template needs a feature-scope variant.

## Chosen Design

**Option B.** A dedicated feature PR reviewer dispatch step.

### New `status.yaml` fields

| Field | Type | Written by | Description |
|---|---|---|---|
| `handoff_pr_review_status` | string | orchestrator | `pending` \| `in_review` \| `approved` \| `changes_requested` \| `blocked` |
| `handoff_pr_reviewer_started_at` | string or null | orchestrator | ISO timestamp when reviewer was dispatched |
| `handoff_pr_review_incomplete_count` | integer | orchestrator | Number of reviewer exits without a valid result |

### Orchestrator poll cycle change

After the existing `runFeatureBranchLifecycle` step, add:

```
dispatchFeaturePrReviewer(feature)
  eligible when:
    handoff_pr_promoted = true
    handoff_pr_url is set
    handoff_pr_review_status in [absent, "pending"]
    no reviewer currently in_flight (handoff_pr_reviewer_started_at check + TTL)

  actions:
    1. Set handoff_pr_review_status = "in_review"
    2. Set handoff_pr_reviewer_started_at = now
    3. Commit status.yaml to feature branch
    4. Submit reviewer executor (adapter.submit) — fire-and-forget
```

### Reviewer briefing (feature scope)

The reviewer receives:
- PR diff via `gh pr diff <handoff_pr_url>`
- `product-spec.md`, `technical-design.md`, `tasks.md` for the feature
- Instruction: evaluate cumulative diff against acceptance criteria; post APPROVE or REQUEST_CHANGES; do not merge

### Post-review state transitions

| Reviewer result | `handoff_pr_review_status` |
|---|---|
| APPROVE posted on GitHub | `approved` |
| REQUEST_CHANGES posted | `changes_requested` |
| Exit without valid result | increment `handoff_pr_review_incomplete_count`; retry up to `MAX_REVIEW_INCOMPLETES`; then `blocked` |

### Feature Done Watcher (unchanged)

The existing poll that detects human merge of `handoff_pr_url` is unchanged. Feature transitions to `done` when the human merges — regardless of `handoff_pr_review_status`. The review gate is advisory by default; branch protection rules are an operator concern.

## Dependency Analysis

- Depends on: Feature Branch Lifecycle Manager (T8 of `task-branch-lifecycle`) — `handoff_pr_promoted` field must already be written to `status.yaml`.
- Depends on: existing reviewer executor ABI — the feature PR reviewer reuses the same `result.json` contract, with `scope: feature_pr` added to distinguish from task reviews.

## Parallelization / Blocking Analysis

- The feature PR reviewer dispatch is a new sequential step in the poll cycle — it does not block any existing step.
- Only one feature PR reviewer may be in flight per feature at a time (TTL guard).
- The human merge detection (Feature Done Watcher) runs independently in the same cycle and is not blocked by review state.
