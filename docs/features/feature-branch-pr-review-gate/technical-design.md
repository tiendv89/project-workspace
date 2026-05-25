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

The `autonomous-feature-reviewer` feature (already shipped) wired the Lifecycle Manager (`runFeatureBranchLifecycle`) and Handoff Trigger into the poll cycle. The Handoff Trigger writes `handoff_pr_url`, `impl_feature_prs`, and `feature_status: in_handoff` to `status.yaml` when all tasks are done, creating the handoff PR as `draft: false` (immediately ready for review). These are the live signals this feature triggers on.

## Problem Framing

**What specifically needs to change:**
- A new `dispatchFeaturePrReviewer` step must fire when `feature_status = "in_handoff"` and `handoff_pr_url` is set — the Handoff Trigger already creates the PR as `draft: false`, so no separate promotion step exists.
- A new `dispatchFeaturePrFixExecutor` step must fire when `handoff_pr_review_status = changes_requested`.
- Three new fields must be added to `status.yaml`: `handoff_pr_review_status`, `handoff_pr_reviewer_started_at`, `handoff_pr_review_incomplete_count`.
- The task status value `reviewing` must be added to the workflow rules so the task-level reviewer dispatch no longer relies on a log-scan guard (`last log ≠ reviewer_started`). Instead, status advances `in_review → reviewing` when a reviewer is dispatched — the status field is the deduplication guard.
- `CLAUDE.md` must document the new `reviewing` status and updated transition rules.

**What must remain stable:**
- Feature Done Watcher merge-detection logic — the feature transitions to `done` when the human merges, regardless of `handoff_pr_review_status`.
- Task-level reviewer dispatch path (`findReviewableTasks`, `dispatchReviewer`) — no changes to task PR review flow.
- Human merge is mandatory — the orchestrator must never merge the feature branch PR.
- Existing `status.yaml` files without `handoff_pr_review_status` are treated as `pending` (absent = unreviewed).

**Assumptions already fixed:**
- `handoff_pr_url` and `feature_status: in_handoff` are written by the Handoff Trigger (already shipped). The PR is created as `draft: false` — no `handoff_pr_promoted` field exists or is needed.
- `impl_feature_prs` is populated by the Handoff Trigger (already shipped).
- The reviewer executor ABI (`result.json`) is unchanged; `scope: feature_pr` is added to distinguish from task reviews.

## Constraints

- The reviewer must never merge any feature branch PR — human merge is mandatory.
- The review trigger must be idempotent. `status.yaml.handoff_pr_review_status = "reviewing"` is the claim guard for reviewer dispatch — no log scan required.
- The existing Feature Done Watcher merge-detection logic must not change.
- **Concurrency scope**: this feature is scoped to single-orchestrator deployments. Concurrent multi-repo fix executor dispatch (one executor per impl repo in parallel) requires atomic state updates across multiple records — not solvable cleanly with git-file state. This is deferred to `workflow-db` (see Dependency Analysis).

## Options Considered

### Option A — Reuse task reviewer dispatch path with a synthetic feature-level task
Create a virtual T_final task that represents the feature branch PR review. Route it through the existing task reviewer machinery.

- Pros: No new orchestrator code paths; reuses all existing reviewer logic.
- Cons: Pollutes the task namespace with a non-implementation task; complicates `depends_on` graphs; the task YAML model doesn't fit (no `repo`, no `branch` in the implementation sense).

### Option B — Per-impl-repo review files (`impl_pr_review/<repo>.yaml`)
Store per-repo review state as isolated files mirroring the task YAML pattern, allowing concurrent fix executor claims per file.

- Pros: Isolated write targets; no batch claim needed.
- Cons: All files still live on the same git branch — concurrent pushes to the same branch still contend. The isolation is logical, not physical. Proper concurrent dispatch still requires a transactional state store. Adds complexity that workflow-db will make obsolete.

### Option C (chosen) — Single `status.yaml` fields, single fix executor, workflow-db dependency
Keep all review state in `status.yaml`. Dispatch one fix executor that handles all impl repos in a single pass. Defer concurrent multi-repo fix dispatch to `workflow-db`.

- Pros: Simple; consistent with existing `status.yaml` shape; no premature concurrency infrastructure that will be rewritten anyway.
- Cons: Fix executor handles multiple repos in one pass — larger briefing, higher turn budget needed.

## Chosen Design

**Option C.** Single `status.yaml` fields, single fix executor per review cycle.

### New `status.yaml` fields

| Field | Type | Written by | Description |
|---|---|---|---|
| `handoff_pr_review_status` | string | orchestrator | `pending` \| `reviewing` \| `approved` \| `changes_requested` \| `fix_in_progress` \| `blocked` |
| `handoff_pr_reviewer_started_at` | string or null | orchestrator | ISO timestamp when reviewer was dispatched |
| `handoff_pr_review_incomplete_count` | integer | orchestrator | Number of reviewer exits without a valid result |

Absent `handoff_pr_review_status` is treated as `pending` — backward compatible with existing features.

### Orchestrator poll cycle

After the existing `runFeatureBranchLifecycle` step, add two new steps:

#### Step A — `dispatchFeaturePrReviewer`

```
dispatchFeaturePrReviewer(feature)
  branch: feature/<feature_id> on management repo
    git fetch origin
    git checkout -B "feature/{id}" "origin/feature/{id}"

  eligible when (read from local FS after checkout):
    feature_status = "in_handoff"
    handoff_pr_url is set                           ← written by Handoff Trigger; PR created as draft:false
    handoff_pr_review_status in [absent, "pending"]

  actions:
    1. Set status.yaml.handoff_pr_review_status = "reviewing"   ← claim guard; no log scan needed
    2. Set status.yaml.handoff_pr_reviewer_started_at = now
    3. git commit status.yaml + push to origin/feature/<feature_id>
       (first-push-wins — rejected = another orchestrator won, skip)
    4. Submit ONE reviewer executor — fire-and-forget:
         extraEnv: {
           MAX_TURNS: String(baseTurns * multiplier),   ← same pattern as dispatchReviewer
           EXECUTOR_KIND: "feature-review",
           ...
         }
```

**Max-turns multiplier — resolved by the orchestrator, consistent with `dispatchReviewer`:**

`dispatchReviewer` already passes `MAX_TURNS: String(maxTurns)` as an env var injected at submit time (`dispatch-reviewer.ts:224`). The feature PR reviewer follows the same pattern; the orchestrator owns the calculation.

| Config | Location | Default | Meaning |
|---|---|---|---|
| `MAX_TURNS` | env var (orchestrator startup) | (workspace default) | Base limit for all executor kinds |
| `feature_review.max_turns_multiplier` | `workspace.yaml` | `2` | Read by orchestrator at startup; applied only when dispatching `kind="feature-review"` |

Effective turns injected = `MAX_TURNS × feature_review.max_turns_multiplier`.

Example: `MAX_TURNS=40`, multiplier=2 → feature reviewer receives `MAX_TURNS=80`. Task reviewers, impl agents, and fix executors are unaffected — the multiplier is not applied to their dispatch.

#### Step B — `dispatchFeaturePrFixExecutor`

```
dispatchFeaturePrFixExecutor(feature)
  branch: feature/<feature_id> on management repo
    git fetch origin
    git checkout -B "feature/{id}" "origin/feature/{id}"

  eligible when (read from local FS after checkout):
    handoff_pr_review_status = "changes_requested"

  actions:
    1. Set status.yaml.handoff_pr_review_status = "fix_in_progress"
    2. git commit status.yaml + push to origin/feature/<feature_id>
       (first-push-wins — rejected = another orchestrator won, skip)
    3. Submit ONE fix executor — fire-and-forget
       briefing includes: all impl PR REQUEST_CHANGES comments + all impl PR diffs
       fix executor pushes code changes to each impl repo's feature/<feature_id> branch
    4. On fix complete: reset handoff_pr_review_status = "pending" → re-triggers reviewer
```

**Concurrency note:** a single fix executor handles all impl repos in one pass. This avoids concurrent branch writes on the management repo. Per-repo parallel fix executors are deferred to `workflow-db` — with DB-backed state, each executor claims a row with a transaction and the branch contention problem does not exist.

### Reviewer briefing (feature scope)

The reviewer is a single executor that receives all diffs:
- PR diff for each entry in `impl_feature_prs` via `gh pr diff <url>`
- `handoff_pr_url` diff (management repo — context only)
- `product-spec.md`, `technical-design.md`, `tasks.md`
- Instruction: evaluate each impl PR diff against acceptance criteria; post APPROVE or REQUEST_CHANGES on each impl PR separately; do not merge

The reviewer posts per-impl-PR reviews on GitHub. Each impl PR's review comments are scoped to that repo's diff — the fix executor reads comments from each PR on GitHub, no routing logic needed.

### Post-review state transitions

| Reviewer result | `handoff_pr_review_status` | Next action |
|---|---|---|
| All impl PRs APPROVED | `approved` | Orchestrator waits for human merge |
| Any impl PR REQUEST_CHANGES | `changes_requested` | Orchestrator dispatches single fix executor on next cycle |
| Reviewer exits without valid result | `pending` (reset) + increment `handoff_pr_review_incomplete_count` | Retry up to `MAX_REVIEW_INCOMPLETES`; escalate to `blocked` |

### Task-level `reviewing` status (CLAUDE.md change)

The `reviewing` status is added to the task status value list and the transition table in `CLAUDE.md`:

```
in_review → reviewing         (orchestrator, when reviewer executor is dispatched)
reviewing → done              (reviewer agent, when CI + rubric pass)
reviewing → change_requested  (reviewer agent, when REQUEST_CHANGES posted)
reviewing → review_incomplete (orchestrator, when reviewer exits without a valid result)
review_incomplete → reviewing (orchestrator, when re-dispatching)
```

`reviewer_started` and `fix_started` log actions become **audit only** — the status field is the deduplication guard.

### Feature Done Watcher (unchanged)

The existing poll that detects human merge of `handoff_pr_url` + all `impl_feature_prs` entries is unchanged. Feature transitions to `done` when the human merges all — regardless of `handoff_pr_review_status`.

### Edge case — no impl PRs

If `impl_feature_prs` is absent or empty (pure management-repo feature), the reviewer reviews only `handoff_pr_url` and posts its review there. `handoff_pr_review_status` tracks the result directly.

## Dependency Analysis

- **Hard (runtime)**: Handoff Trigger — `handoff_pr_url`, `impl_feature_prs`, and `feature_status: in_handoff` are the dispatch signals. Already shipped.
- **Hard (implementation)**: existing reviewer executor ABI — `result.json` extended with `scope: feature_pr` and per-repo outcomes.
- **Hard (future — parallel fix executors)**: `workflow-db` — concurrent per-repo fix executor dispatch requires transactional state. Until `workflow-db` ships, fix dispatch is single-executor (all repos in one pass). This is a known limitation, not a bug.
- **Soft (consistency)**: CLAUDE.md `reviewing` status update (T1) should land before or alongside the orchestrator dispatch (T2).

## Parallelization / Blocking Analysis

```
T1: management-repo — CLAUDE.md: add `reviewing` status + update transitions
  └── Can begin now — no blockers

T2: workflow — dispatchFeaturePrReviewer: poll step + status.yaml schema + reviewer briefing
  └── Can begin now — no blockers
  └── T1 and T2 run in parallel

  T3: workflow — dispatchFeaturePrFixExecutor: single fix executor dispatch + post-fix reset
      └── BLOCKED on T2 (fix dispatch triggered by review outcomes written in T2's reap path)

      T4: workflow — unit + integration tests for T2 and T3
          └── BLOCKED on T2 (reviewer dispatch must be implemented)
          └── BLOCKED on T3 (fix executor dispatch must be implemented)
```

No external runtime dependencies block T1–T4 — the Handoff Trigger is already shipped.

## Repository Impact

| Repo | Why touched |
|---|---|
| `management-repo` | `CLAUDE.md`: add `reviewing` task status, update transitions, mark `reviewer_started`/`fix_started` audit-only |
| `workflow` | `dispatchFeaturePrReviewer` + `dispatchFeaturePrFixExecutor` poll steps (T2, T3); `status.yaml` schema; reviewer briefing; reap-loop result routing; tests (T4) |

`digital-factory-ui`, `workflow-backend`, `rag-service`, `git-nexus`, `workspace-github-adapter` are not touched.

## Validation and Release Impact

**Tests required (workflow repo):**
- `dispatchFeaturePrReviewer` eligibility: fires on `in_handoff` + `handoff_pr_url` set + `pending`/absent; skips on `reviewing`, `approved`, `changes_requested`, `fix_in_progress`, `blocked`.
- Reviewer claim atomicity: concurrent orchestrators — second push rejected (non-fast-forward), skips dispatch.
- Reviewer `result.json` routing: per-repo outcomes aggregated; `approved` when all approved, `changes_requested` when any requested.
- `dispatchFeaturePrFixExecutor` eligibility: fires on `changes_requested`; skips if `fix_in_progress`.
- Fix claim atomicity: concurrent orchestrators — second push rejected, skips dispatch.
- Post-fix reset: `fix_in_progress → pending`; reviewer re-triggers on next cycle.
- Incomplete reviewer: count increment; reset to `pending`; escalates at `MAX_REVIEW_INCOMPLETES`.
- Max-turns multiplier: injected as `MAX_TURNS = baseTurns × multiplier`; default multiplier=2; task reviewers unaffected.
- No-impl-PRs edge case: fallback to reviewing `handoff_pr_url` directly.
- Feature Done Watcher: merge detection unaffected by `handoff_pr_review_status`.

**Known limitation (deferred to `workflow-db`):**
- Parallel per-repo fix executors are not implemented. The single fix executor handles all impl repos in one pass — adequate for features with 1–3 impl repos; may hit turn limits on very large multi-repo features.

**Migration / config impact:**
- Existing features in `in_handoff` with no `handoff_pr_review_status`: treated as `pending` — will enter the review cycle on the next poll after this ships.
- New optional config: `feature_review.max_turns_multiplier` in `workspace.yaml` (default `2`). No action required from operators happy with the default.
- `workspace.yaml` schema addition (optional):
  ```yaml
  feature_review:
    max_turns_multiplier: 2   # default; increase for workspaces with many large impl repos
  ```

**Rollout:**
- T1 (CLAUDE.md) can ship independently ahead of the orchestrator changes.
- T2–T4 ship together in the `workflow` repo; no feature flag needed since dispatch only fires post-handoff.

**Backward compatibility:**
- Features already `done`: `feature_status: done` — dispatch guard will not fire.
- Features in `in_handoff` with no review state: enter the review cycle on next poll — intended.
