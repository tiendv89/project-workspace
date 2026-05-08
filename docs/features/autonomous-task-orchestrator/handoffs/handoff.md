# Handoff — autonomous-task-orchestrator

**Feature:** Autonomous Task Orchestrator
**Completed:** 2026-05-09
**All tasks:** T1–T12 (12/12) done

---

## What was built

The orchestrator now drives the full task lifecycle autonomously — from a `ready` task through implementation, review, and fix cycles, all the way to `done` and feature handoff — without requiring a human to approve each transition. Humans remain in the loop only for escalated tasks and final handoff approval.

### High-level lifecycle after this feature

```
ready task
  └─ orchestrator dispatches impl agent (start-implementation)
       └─ in_review → orchestrator dispatches reviewer agent (review-pr)
            ├─ passed → auto-done writer marks done + dep cascade
            │     └─ all done → handoff trigger fires
            ├─ change_requested → orchestrator dispatches fix agent
            │     └─ impl agent runs again → in_review (cycle repeats up to REVIEWER_MAX_CYCLES)
            └─ escalate → slack alert + task blocked (human resolves)
```

---

## Tasks completed

| ID | Wave | Title | Impl PR |
|---|---|---|---|
| T1 | 1 | Schema — `change_requested` status + CLAUDE.md transitions + status.yaml fields | management-repo |
| T7 | 1 | Orchestrator config in workspace.yaml | management-repo |
| T2 | 2 | Orchestrator dispatch controller | [#96](https://github.com/tiendv89/agent-workflow/pull/96) |
| T3 | 2 | `review-pr` skill | [#93](https://github.com/tiendv89/agent-workflow/pull/93) |
| T8 | 2 | Feature Branch Lifecycle Manager | [#95](https://github.com/tiendv89/agent-workflow/pull/95) |
| T4 | 3 | Fix agent briefing + dispatch | [#98](https://github.com/tiendv89/agent-workflow/pull/98) |
| T5 | 3 | Auto-done writer | [#99](https://github.com/tiendv89/agent-workflow/pull/99) |
| T6 | 3 | Escalation handler | [#100](https://github.com/tiendv89/agent-workflow/pull/100) |
| T9 | 4 | Handoff Trigger + document generation + task PR draft lifecycle | [#102](https://github.com/tiendv89/agent-workflow/pull/102) |
| T10 | 5 | Fix self-review failure in reviewer agent | wave 5 gap fix |
| T11 | 5 | Write workspace PR status back after successful merge | wave 5 gap fix |
| T12 | 5 | Handoff trigger symmetry + state invariant checker | [#106](https://github.com/tiendv89/agent-workflow/pull/106) |

---

## New and changed components

### Schema additions (T1, management-repo)

- `change_requested` added to valid task status values in CLAUDE.md
- New transitions: `in_review → change_requested`, `in_review → done` (reviewer agent), `change_requested → in_progress` (fix agent, first-push-wins claim)
- New log actions: `reviewer_started`, `fix_started`, `retried`
- New `status.yaml` feature-branch fields documented: `feature_branch`, `feature_branch_base_sha`, `handoff_pr_url`, `drift_detected`, `drift_reason`
- `.env.template` gains: `REVIEWER_MAX_CYCLES`, `EXECUTOR_MAX_RETRIES`, `SLACK_WEBHOOK_URL`

### Orchestrator config (T7, management-repo)

`workspace.yaml` gains an `orchestrator` block with `poll_interval_seconds`, `reviewer_max_cycles`, `executor_max_retries`, and `escalation.channel` / `escalation.webhook_url`.

### Dispatch controller (T2, `runtime/orchestrator/`)

`main.ts` `runOneCycle` now routes three task statuses:

| Status | Dispatch |
|---|---|
| `ready` | impl agent (unchanged) |
| `in_review` | reviewer agent via `dispatchReviewResult` skeleton |
| `change_requested` | fix agent; sets status → `in_progress`, appends `fix_started` log |

Max-turns retry: if `terminal_status: blocked` with `blocked_reason` starting `max_turns`, the orchestrator appends a `retried` log entry and resets to `ready` until `EXECUTOR_MAX_RETRIES` is exhausted.

`handleDraftReviews` removed; `dispatch-draft-review.ts` deleted.

### `review-pr` skill (T3, `workflow/technical_skills/review-pr/`)

New skill encapsulating the full reviewer protocol:

- Reads PR diff + task spec + technical design
- Evaluates rubric from `references/review_criteria.md` (priority order: correctness → security → performance → design → style; severity markers 🔴/🟡/🟢)
- Decision: 0 🔴/🟡 → APPROVE; any 🔴/🟡 → REQUEST_CHANGES; CI fail → REQUEST_CHANGES; cycle limit → escalate
- Self-review handling (T10): posts review narrative as issue comment first (`POST /issues/{n}/comments`, always executes); review event (`POST /pulls/{n}/reviews`) attempted separately; HTTP 422 → `reviewer_self_review_skipped` emitted, continues
- `result.json`: `{ terminal_status: passed | change_requested | escalate, verdict, confidence, notes, review_url? }`

Reviewer briefing template in `runtime/orchestrator/src/briefing/reviewer-briefing.ts`.

### Fix agent briefing (T4, `runtime/orchestrator/src/briefing/fix-briefing.ts`)

Generates briefing for fix agent dispatched on `change_requested`. Instructs agent to: read `REQUEST_CHANGES` review comments from the URL in the task log; address each in code; push fix commits; resolve via GitHub API; write `result.json` with `terminal_status: in_review`. Routes through the same `dispatchExecutorResult` as the impl agent (`kind=impl`).

### Auto-done writer (T5, `runtime/orchestrator/src/side-effects/dispatch-review-result.ts` — `passed` branch)

On `passed` from reviewer: follows branch checkout + sync protocol on management repo; mutates task YAML to `done`; appends `done` log entry; runs auto-ready cascade (scans feature tasks — any `todo` task whose entire `depends_on` list is now `done` transitions to `ready`); commits and pushes all changed YAMLs.

### Escalation handler (T6, `dispatch-review-result.ts` — `escalate` branch)

On `escalate` from reviewer: POSTs to `SLACK_WEBHOOK_URL` (feature ID, task ID, PR URL, escalation reason, suggested action); graceful skip if URL unset (`escalation_slack_skipped`); mutates task YAML to `blocked` with reason and suggestion; commits and pushes.

### Feature Branch Lifecycle Manager (T8, `runtime/orchestrator/src/feature-branch/lifecycle-manager.ts`)

Pre-loop orchestrator step (runs before `runOneCycle`):

- **First run**: checks out base branch, records tip SHA as `feature_branch_base_sha` in `status.yaml` (never overwritten), creates `feature/{feature_id}`, pushes. Opens a **draft PR** and writes `handoff_pr_url` into `status.yaml`.
- **Subsequent runs**: re-checks out existing branch; handles force-push recovery (save patch → reset → re-apply missing changes).
- Task PRs created by dispatch use `base: feature/{feature_id}` (not the repo's default base).

`feature_branch_base_sha` is the baseline for the `autonomous-feature-reviewer` drift daemon.

### Handoff Trigger + task PR draft lifecycle (T9, `runtime/orchestrator/src/handoff/handoff-trigger.ts`)

**Handoff Trigger** — fires when auto-done writer detects all tasks are `done`/`cancelled`:
- Generates `docs/features/{feature_id}/handoffs/handoff.md` from task logs, PR URLs, and product-spec goals
- Converts feature branch draft PR → ready-for-review (`PATCH /pulls/{n}` with `draft: false`)
- Transitions `feature_status: in_handoff` in `status.yaml`; commits and pushes
- Notifies via Slack if `SLACK_WEBHOOK_URL` set

**Task PR draft lifecycle**:
- `pr-create` skill opens PRs as `draft: true`
- On `in_review` (impl agent complete): orchestrator promotes PR draft → ready (`PATCH draft: false`); non-fatal on error
- On `change_requested` (reviewer requested changes): orchestrator demotes PR → draft (`PATCH draft: true`); non-fatal on error

### Workspace PR status write-back (T11, `handle-merged-prs.ts`)

After a successful `mergeWorkspacePrViaApi`, orchestrator now writes `task.workspace_pr.status = "merged"` back to the task YAML, commits, and pushes (retry-once on non-fast-forward). Eliminates noisy `workspace_pr_status_write_failed` events and redundant recovery-loop API calls on subsequent cycles.

### Handoff trigger symmetry + state invariant checker (T12)

Two gaps closed:

1. **Handoff trigger symmetry** (`handle-merged-prs.ts`): after a task is marked `done` via the PR-merge loop, `checkAllTasksDone` is called; if all tasks are done, `fireHandoffTrigger` is invoked. Previously, the handoff only fired via `dispatchReviewResult`.

2. **State invariant checker** (`src/poll/state-invariant-checker.ts`): runs every `STATE_INVARIANT_CHECK_INTERVAL` cycles (env, default 5). Checks two invariants:
   - **Stuck dependent**: `done` task with a sibling whose `depends_on` are all now `done` but status is still `todo` → transitions to `ready`
   - **Stuck handoff**: all tasks `done`/`cancelled`, `feature_status` not `in_handoff`, `handoff_pr_url` null → fires handoff trigger

---

## Operational notes

### Environment variables (all optional, have defaults)

| Variable | Default | Description |
|---|---|---|
| `REVIEWER_MAX_CYCLES` | 3 | Max review+fix cycles before escalation |
| `EXECUTOR_MAX_RETRIES` | 3 | Max max-turns retries before blocking |
| `SLACK_WEBHOOK_URL` | (empty) | Escalation and handoff Slack webhook |
| `STATE_INVARIANT_CHECK_INTERVAL` | 5 | Cycles between invariant checker runs |

### Removed files

- `runtime/orchestrator/src/pr-response/dispatch-draft-review.ts` — removed in T2; `change_requested` status replaces draft-PR signalling

### No migration required

Task YAMLs with no `change_requested` entries are unaffected. The new routing branches only activate when a task reaches `in_review` or `change_requested`. Existing `ready` → impl dispatch is unchanged.

---

## Wave 5 gap fixes (Appendix A)

Three gaps discovered after the initial T1–T9 implementation and addressed before handoff:

| Task | Gap | Fix |
|---|---|---|
| T10 | Reviewer agent (same bot account as impl agent) got HTTP 422 on self-review, losing the review comment entirely | Split into two API calls: issue comment always posts; review event 422 is non-fatal |
| T11 | `handleMergedPrs` never wrote `workspace_pr.status: merged` back to task YAML, causing noisy recovery-loop retries | Write-back added after successful merge with retry-once on push conflict |
| T12 | Handoff trigger only fired via `dispatchReviewResult`; tasks done via PR-merge loop silently skipped handoff | Trigger added in `handle-merged-prs.ts`; state invariant checker added as safety net |

---

## Follow-on features

| Feature | Notes |
|---|---|
| `autonomous-feature-reviewer` | Drift daemon that reads `feature_branch_base_sha` from `status.yaml` and detects base-branch divergence. Sets `drift_detected: true` when base has advanced. |
| `agent-runtime-selector` | Multi-executor routing. Builds on the `ExecutorAdapter` interface. The orchestrator's dispatch controller is already adapter-aware. |
| Cost tracking dashboard | `token_usage` and `cost_usd` fields are recorded per task log entry by the orchestrator. A reporting layer consuming these fields is a natural follow-on. |
