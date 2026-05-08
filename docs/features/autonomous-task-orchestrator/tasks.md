# Task Breakdown — Autonomous Task Orchestrator

> Feature status: [status.yaml](../status.yaml) | Stage: tasks
> Machine-mutable state (status, PR, log) lives in `tasks/T<n>.yaml` — do not add those fields here.

## Index

| ID | Wave | Title | Repo | Depends on |
|---|---|---|---|---|
| T1 | 1 | Schema — `change_requested` status + CLAUDE.md transitions + status.yaml fields | management-repo | — |
| T7 | 1 | Orchestrator config in workspace.yaml | management-repo | — |
| T2 | 2 | Orchestrator dispatch controller | workflow | T1 |
| T3 | 2 | `review-pr` skill | workflow | T1 |
| T8 | 2 | Feature Branch Lifecycle Manager | workflow | T1 |
| T4 | 3 | Fix agent briefing + dispatch | workflow | T2 |
| T5 | 3 | Auto-done writer | workflow | T2 |
| T6 | 3 | Escalation handler | workflow | T2 |
| T9 | 4 | Handoff Trigger + document generation | workflow | T5, T8 |

---

## T1 — Schema: `change_requested` status + CLAUDE.md transitions + status.yaml fields

### Description
Adds the `change_requested` task status, all supporting schema changes, and the new `status.yaml` feature-branch fields to the management repo. This is the foundation that T2, T3, and T8 depend on — all need the status enum, log actions, and status.yaml schema settled before writing orchestrator code that reads and writes them.

Changes are confined to `CLAUDE.md` and `.env.template` in the management repo. No code changes.

### Required skills

### Subtasks
- [ ] Add `change_requested` to the valid task status values list in CLAUDE.md
- [ ] Add transition rules to the "Task status transition rules" section:
  - `in_review → change_requested` (reviewer agent, when `REQUEST_CHANGES` posted)
  - `in_review → done` (human, or reviewer agent when CI + rubric pass)
  - `change_requested → in_progress` (fix agent — same first-push-wins claim as `ready → in_progress`)
- [ ] Add `reviewer_started`, `fix_started`, `retried` to the task log actions vocabulary in CLAUDE.md
- [ ] Document the new `status.yaml` feature-branch fields in CLAUDE.md (schema reference section):
  - `feature_branch: feature/{feature_id}` — written by orchestrator at start; read by drift daemon
  - `feature_branch_base_sha: <sha>` — merge-base at branch creation; never overwritten on restart
  - `handoff_pr_url: null` — written by Handoff Trigger when feature PR is opened
  - `drift_detected: false` — written by `autonomous-feature-reviewer` daemon
  - `drift_reason: null` — written by `autonomous-feature-reviewer` daemon
- [ ] Add entries to `.env.template`:
  - `REVIEWER_MAX_CYCLES=3` — max review+fix cycles before escalation
  - `EXECUTOR_MAX_RETRIES=3` — max max-turns retries before blocking
  - `SLACK_WEBHOOK_URL=` — escalation webhook (blank default)

---

## T7 — Orchestrator config in workspace.yaml

### Description
Adds an `orchestrator` configuration block to `workspace.yaml` documenting the runtime-tunable parameters introduced by this feature. The block is read by agents to understand operator intent; the actual env vars are resolved from the environment at runtime.

No changes to CLAUDE.md (that is T1's scope). No code changes.

### Required skills

### Subtasks
- [ ] Add `orchestrator` config block to `workspace.yaml`:
  ```yaml
  orchestrator:
    poll_interval_seconds: 30
    reviewer_max_cycles: $REVIEWER_MAX_CYCLES   # default 3
    executor_max_retries: $EXECUTOR_MAX_RETRIES # default 3
    escalation:
      channel: slack
      webhook_url: $SLACK_WEBHOOK_URL
  ```
- [ ] Verify the new keys do not conflict with any existing workspace.yaml fields

---

## T2 — Orchestrator dispatch controller

### Description
Core orchestrator changes in `runtime/orchestrator/`. Adds the three-way routing table (ready→impl, change_requested→fix, in_review→reviewer), claim log actions for each agent kind, max-turns retry logic in `dispatchExecutorResult`, and a skeleton `dispatchReviewResult` handler wired into the reap loop with `kind=review`.

Also removes `handleDraftReviews` and deletes `dispatch-draft-review.ts` — the `change_requested` status replaces draft-PR signalling entirely.

T4, T5, and T6 all depend on the `dispatchReviewResult` skeleton this task creates.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Update `main.ts` `runOneCycle` to add routing for `change_requested` tasks (fix agent dispatch) and `in_review` tasks (reviewer dispatch) alongside the existing `ready` dispatch
- [ ] Add `reviewer_started` claim log entry write before reviewer executor submit
- [ ] Add `fix_started` claim log entry write before fix executor submit; set task status to `in_progress`
- [ ] Extend `dispatchExecutorResult` with max-turns retry logic:
  - Detect `terminal_status: blocked` + `blocked_reason` starting with `max_turns`
  - Count `retried` log entries; if < `EXECUTOR_MAX_RETRIES` (env, default 3): append `retried` log entry, reset status to `ready`, push
  - If ≥ limit: fall through to existing `blocked` write
- [ ] Add `kind=review` routing in `reap-loop.ts` → call new skeleton `dispatchReviewResult()`
- [ ] Create `runtime/orchestrator/src/side-effects/dispatch-review-result.ts` with skeleton that accepts `terminal_status: passed | change_requested | escalate` and emits events (bodies filled by T5 and T6)
- [ ] Remove `handleDraftReviews` call from `main.ts`; delete `src/pr-response/dispatch-draft-review.ts`
- [ ] Update `check-in-review-prs.ts` to remove `hasOpenComments` logic if it is only used by `handleDraftReviews`
- [ ] Add / update unit tests for the new routing branches and retry logic

---

## T3 — `review-pr` skill

### Description
Creates the `review-pr` skill under `workflow/technical_skills/review-pr/`. The orchestrator reviewer briefing instructs the executor to run `/review-pr`, exactly as respond-to-review briefings instruct `/respond-to-review`. The skill encapsulates all reviewer logic so it can also be run manually.

Includes the full evaluation criteria in `references/review_criteria.md` and the reviewer executor briefing template in the orchestrator.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Create `workflow/technical_skills/review-pr/SKILL.md` with:
  - When to use
  - Protocol: read PR diff + task spec + technical design → evaluate rubric → post GitHub review → write result.json
  - Cycle limit: read `MAX_REVIEW_CYCLES` from env (default 3); count `in_review` log entries; escalate if limit reached
  - Decision table: 0 🔴/🟡 findings → APPROVE; any 🔴/🟡 → REQUEST_CHANGES; CI fail → REQUEST_CHANGES; limit hit → escalate
  - result.json schema: `{ terminal_status: passed | change_requested | escalate, verdict, confidence, notes, review_url? }`
- [ ] Create `workflow/technical_skills/review-pr/references/review_criteria.md` with the full rubric (priority-ordered: correctness → security → performance → design → style; feedback severity markers 🔴/🟡/🟢)
- [ ] Create `runtime/orchestrator/src/briefing/reviewer-briefing.ts` — generates the reviewer executor briefing (reads task context, instructs `/review-pr`, specifies result.json path)
- [ ] Wire reviewer briefing into the reviewer dispatch path added in T2
- [ ] Add tests for the briefing generator

---

## T4 — Fix agent briefing + dispatch

### Description
Adds the fix agent executor to the orchestrator. When a task is `change_requested`, the orchestrator dispatches a fix agent briefed to read the `REQUEST_CHANGES` review from the URL recorded in the task log, address each comment in code, push the fixes, mark comments resolved via GitHub API, and write `terminal_status: in_review` to result.json.

The fix agent result routes through `dispatchExecutorResult` (same `kind=impl` contract as the impl agent) — no new result handler needed.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Create `runtime/orchestrator/src/briefing/fix-briefing.ts` — generates the fix agent briefing:
  - Read task log to find the latest log entry with `action: change_requested` and extract the GitHub review URL
  - Instruct agent to fetch `REQUEST_CHANGES` review comments from that URL via GitHub API
  - For each comment: address in code, push fix commit, resolve via GitHub API
  - Write `result.json` with `terminal_status: in_review`
- [ ] Wire fix briefing into the `change_requested` dispatch path in T2's routing table
- [ ] Confirm `dispatchExecutorResult` correctly handles the `in_review` terminal status from a fix agent (it should — same path as impl agent)
- [ ] Add tests for the fix briefing generator

---

## T5 — Auto-done writer

### Description
Implements the `terminal_status: passed` branch of `dispatchReviewResult` (the skeleton created in T2). When the reviewer approves, the orchestrator writes a `done` log entry to the task YAML, runs the auto-ready cascade for dependent tasks, and pushes all changes to the management repo feature branch.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Implement `passed` branch in `dispatch-review-result.ts`:
  - Follow branch checkout + sync protocol on the management repo
  - Mutate task YAML: `status: done`, append `done` log entry (`action: done`, `by: orchestrator email`, real timestamp, note with PR URL)
  - Run auto-ready cascade: scan all tasks in the feature; for each task with `status: todo` whose entire `depends_on` list is now `done`, set `status: ready` and append `ready` log entry
  - Commit all changed task YAMLs and push to the task's feature branch
- [ ] Emit `task_auto_done` and `auto_ready_cascade` events
- [ ] Add tests covering: single task done with no dependents; task done with one dependent that becomes ready; task done with a dependent that still has unmet deps

---

## T8 — Feature Branch Lifecycle Manager

### Description
Implements the pre-loop orchestrator step that creates or syncs the feature branch before any task dispatch begins. The orchestrator must be idempotent — the branch may already exist from a previous run or manual creation.

On first run: checks out the base branch, records the tip SHA as `feature_branch_base_sha` in `status.yaml`, creates `feature/{feature_id}`, pushes to origin. On subsequent runs: re-checks out the existing branch; handles the force-push recovery case (remote diverged) by saving local work, resetting, and re-applying only missing changes.

Also configures the orchestrator to pass `base: feature/{feature_id}` when creating task PRs via the GitHub API — task branches merge into the feature branch, not directly into main.

`feature_branch_base_sha` is the baseline the `autonomous-feature-reviewer` drift daemon uses to detect base-branch divergence. It must never be overwritten on restart.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Create `runtime/orchestrator/src/feature-branch/lifecycle-manager.ts`:
  - `git fetch origin`
  - If `origin/feature/{feature_id}` exists: checkout, pull; on non-fast-forward: save patch, reset to origin branch, re-apply only missing changes
  - If `origin/feature/{feature_id}` does not exist: checkout base branch, pull, capture `BASE_SHA=$(git rev-parse HEAD)`, create and push feature branch
  - Read `status.yaml`; if `feature_branch_base_sha` is unset, compute via `git merge-base` and write it; never overwrite if already set
  - Write `feature_branch: feature/{feature_id}` into `status.yaml` if unset; commit and push to feature branch
- [ ] Call `lifecycle-manager` at orchestrator start in `main.ts`, before `runOneCycle` begins
- [ ] Update PR creation in the dispatch controller to pass `base: feature/{feature_id}` instead of the repo's default base branch
- [ ] Add tests: fresh start (branch doesn't exist); restart (branch exists, clean); restart after force-push (branch diverged)

---

## T6 — Escalation handler

### Description
Implements the `terminal_status: escalate` branch of `dispatchReviewResult`. Posts a Slack webhook message with actionable context and writes `blocked` to the task YAML. The human resolves the block; the orchestrator resumes on the next poll when the task is manually reset.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Implement `escalate` branch in `dispatch-review-result.ts`:
  - POST to `SLACK_WEBHOOK_URL` (skip gracefully if env var is unset — emit `escalation_slack_skipped` event)
  - Slack message fields: feature ID, task ID, task title, PR URL, escalation reason (from reviewer notes), suggested action
  - Mutate task YAML: `status: blocked`, `blocked_reason` from reviewer notes, `blocked_suggestion: "Human review required — reviewer confidence exhausted or hard CI failure"`
  - Commit and push to the task's feature branch
- [ ] Emit `task_escalated` event
- [ ] Add tests: escalation with Slack configured; escalation with Slack URL absent (graceful skip)

---

## T9 — Handoff Trigger + document generation

### Description
Implements the final step of the orchestrator lifecycle: when the Auto-Done Writer (T5) marks the last task `done`, the orchestrator generates a handoff document, promotes the feature branch PR from draft to ready-for-review, and transitions the feature to `in_handoff`.

T9 also extends the Feature Branch Lifecycle Manager (T8) to open a **draft PR** when the feature branch is first created — giving stakeholders visibility throughout the implementation, not just at handoff. T8 is already merged; this task adds the draft PR step as an additive change to `lifecycle-manager.ts`.

Depends on T8 (feature branch must exist) and T5 (all-tasks-done detection must be in place). Activates inside the Auto-Done Writer after the auto-ready cascade — if no tasks remain in a non-terminal state, the Handoff Trigger fires.

### Required skills
- typescript-best-practices
- backend-engineer

### Subtasks
- [ ] Extend `runtime/orchestrator/src/feature-branch/lifecycle-manager.ts` to open a draft PR on first branch creation (idempotent — skip if `status.yaml.handoff_pr_url` is already set):
  - After pushing the feature branch, call `POST /repos/{owner}/{repo}/pulls` with `{ draft: true, head: feature/{feature_id}, base: {base_branch} }`
  - Write `handoff_pr_url` into `status.yaml`; commit and push to the feature branch
  - `GITHUB_TOKEN` is required; skip gracefully (emit `draft_pr_skipped` event) if absent
- [ ] Add all-tasks-done detection in `dispatch-review-result.ts` (passed branch, after auto-ready cascade):
  - After committing the cascade, re-read all task YAMLs for the feature
  - If every task is `done` or `cancelled` (and at least one is `done`): invoke Handoff Trigger
- [ ] Create `runtime/orchestrator/src/handoff/handoff-trigger.ts`:
  - Generate `docs/features/{feature_id}/handoffs/handoff.md` from the template in the technical design:
    - Summary (from product-spec.md goals)
    - Tasks Completed table (task ID, title, PR URL, reviewer notes from task log)
    - Deviations from Technical Design (from reviewer notes)
    - Files Changed (aggregate from all task PRs via GitHub API)
    - Follow-up Items
    - Audit Trail (from task YAML logs)
  - Commit `handoff.md` to the feature branch; push to management repo
  - Convert draft PR to ready-for-review: read `handoff_pr_url` from `status.yaml`, extract PR number, call `PATCH /repos/{owner}/{repo}/pulls/{number}` with `{"draft": false}`. Safety net: if `handoff_pr_url` is null or the PR no longer exists, create a fresh non-draft PR and write the URL into `status.yaml`
  - Transition `feature_status: in_handoff`, `current_stage: handoff`, record `stages.handoff.pr_url` in `status.yaml`
  - Commit and push `status.yaml` changes to feature branch
  - Notify operator via `SLACK_WEBHOOK_URL` (if set): feature ID, handoff PR URL, summary
- [ ] Emit `feature_handoff_triggered`, `handoff_pr_opened`, and `draft_pr_skipped` events
- [ ] Add tests: all tasks done triggers handoff; some tasks cancelled + rest done still triggers; one task still in_progress does not trigger; draft PR created on first branch setup; draft PR skipped on restart when handoff_pr_url already set
