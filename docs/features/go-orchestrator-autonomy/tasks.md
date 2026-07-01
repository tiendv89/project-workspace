# Tasks — `go-orchestrator-autonomy`

> Feature status: `in_tdd` — technical design approved 2026-07-01.
> Task stage: **draft** — awaiting human approval.
>
> Narrative (description + required skills + subtasks) lives here; machine-readable state (status,
> deps, branch, log, PR) lives per-task in `tasks/T<n>.yaml`. Agents mutate only the YAMLs.
>
> **ts feature** (owner absent) — executed by the TS orchestrator; the Go orchestrator is the
> subject/output. All schema changes are owned by **workflow-backend** (Migration-ownership rule);
> the orchestrator keeps a mirrored `db/testdata/schema.sql` snapshot (T5). See `technical-design.md`
> for the full design, FSMs, DB design, and unblock API contract referenced below.
>
> Task IDs are ordered topologically: every task's number is greater than all of its dependencies.

---

## Index

| ID | Wave | Title | Repo | Depends on |
|----|------|-------|------|------------|
| T1  | 1 | Schema migration — `workspace_tasks` columns + `handoffs`/`handoff_prs` + indexes | workflow-backend | — |
| T2  | 1 | Adapter owner-scope — stop clobbering go `feature_status` | workspace-github-adapter | — |
| T3  | 1 | Orchestrator README/AGENTS — state-machine reference | workflow-orchestrator | — |
| T4  | 2 | Unblock API endpoint | workflow-backend | T1 |
| T5  | 2 | Orchestrator DB foundation — mirror schema.sql + sqlc models | workflow-orchestrator | T1 |
| T6  | 3 | Error/stuck recovery — reconciler, DLQ-`failed` reap, redis, max-turns | workflow-orchestrator | T5 |
| T7  | 3 | Reviewer cluster — dispatch, verdict routing, fix loop, review_incomplete | workflow-orchestrator | T5 |
| T8  | 3 | Conflict resolution — conflict_state, rebase, cap, merged-is-truth, terminal guard | workflow-orchestrator | T5 |
| T9  | 3 | `blocked_from_status` recording + unblock-resume handling | workflow-orchestrator | T5 |
| T10 | 3 | Unblock bff proxy | workflow-bff | T4 |
| T11 | 3 | `unblock_task` MCP tool | workflow-mcp | T4 |
| T12 | 4 | Feature lifecycle — `in_implementation`, handoff trigger, handoff-PR rebase, finalize | workflow-orchestrator | T2, T8 |
| T13 | 4 | `unblock-task` agent skill | workflow | T11 |
| T14 | 5 | Soft-claim throttle (derived in-flight) + cycle ordering | workflow-orchestrator | T6, T7, T12 |
| T15 | 6 | E2E autonomous-run test (parallel with a legacy TS feature) | workflow-orchestrator | T6, T7, T8, T9, T12, T14 |

**Waves.** W1 (T1, T2, T3) start immediately. W2 (T4, T5) need the frozen schema (T1). W3 (T6, T7,
T8, T9 on T5; T10, T11 on T4) are the parallel build-out. W4 (T12 needs conflict machinery + adapter
scope; T13 needs the MCP tool). W5 (T14 wires the loops into the cycle). W6 (T15 exercises the full
autonomous path).

---

## T1 — Schema migration — `workspace_tasks` columns + `handoffs`/`handoff_prs` + indexes

### Description
Adds the DB substrate for the whole feature (see technical-design §"DB design"). Additive/backward
compatible (new columns nullable-or-defaulted). This is authored directly in the migration owner, so no
artifact-handoff is needed.

### Required skills
- go-best-practices
- postgres-best-practices

### Subtasks
- [ ] Goose migration: `ALTER workspace_tasks ADD` `dispatch_handle`, `dispatch_nonce`, `dispatched_at`, `reenqueue_attempts` (default 0), `review_incomplete_count` (0), `max_turns_retry_count` (0), `rebase_attempts` (0), `conflict_state` (default `'none'`), `blocked_from_status`, `dispatch_kind`.
- [ ] `CREATE TABLE handoffs` (`id` PK, `workspace_id`, `feature_id` `UNIQUE`, `mgmt_pr_url`, `status`, `created_at`, `finalized_at`).
- [ ] `CREATE TABLE handoff_prs` (`id` PK, `handoff_id` FK→handoffs ON DELETE CASCADE, `repo`, `pr_url`, `status`, `conflict_state`, `rebase_attempts`, dispatch cols, `created_at`; `UNIQUE(handoff_id, repo)`).
- [ ] Indexes: partial on `workspace_tasks (workspace_id) WHERE owner='go' AND (status IN ('in_progress','reviewing') OR conflict_state='resolving')`; partial on `handoff_prs WHERE conflict_state='resolving'`; `handoff_prs(handoff_id)`.
- [ ] Update `workflow-backend` `db/testdata/schema.sql` snapshot; goose Up/Down verified.

## T2 — Adapter owner-scope — stop clobbering go `feature_status`

### Description
`UpsertWorkspaceFeature` currently overwrites `feature_status` for go features (technical-design §"G").
Partition ownership so the adapter never clobbers orchestrator-owned `in_implementation`/`in_handoff`.

### Required skills
- go-best-practices
- postgres-best-practices

### Subtasks
- [ ] Guard the `ON CONFLICT` SET: `feature_status`/`current_stage`/`next_action` keep the current DB value when `owner='go'` AND current value ∈ {`in_implementation`,`in_handoff`} AND incoming ∉ {`cancelled`,`done`}; else sync.
- [ ] Regenerate sqlc for the changed query; update the adapter schema snapshot if any.
- [ ] Unit tests: adapter does not regress `in_implementation`/`in_handoff`; still syncs design-phase + `cancelled`/`done`.

## T3 — Orchestrator README/AGENTS — state-machine reference

### Description
Author the "State machines" reference (task/conflict/feature FSMs, counters + reset rules, in-flight
predicate, cycle order) verbatim from the approved design into `workflow-orchestrator/README.md` (and
`AGENTS.md` if present), for developers and agents. Docs-only; can start from the approved design.

### Required skills

### Subtasks
- [ ] README section: task status FSM table (incl. `reviewing → done` observed-merge edge).
- [ ] README section: conflict_state FSM + `resolving`-invariant; feature_status owner split.
- [ ] README section: counters + reset rules; in-flight (soft-claim) predicate; per-poll cycle order.
- [ ] Cross-link the DB design + unblock API from the design doc.

## T4 — Unblock API endpoint

### Description
`POST /api/workspaces/:ws/features/:f/tasks/:taskId/unblock` (technical-design §"API design"). Org-scoped,
guarded, derives the resume state from `blocked_from_status`, resets the causing counter, writes an
activity event. No `target` param; optional `note`.

### Required skills
- go-best-practices
- postgres-best-practices

### Subtasks
- [ ] Endpoint + org auth; body `{ note? }`.
- [ ] Derive resume state: `in_progress→ready`; `reviewing`/`in_review`→`in_review`.
- [ ] Guarded `UPDATE … WHERE status='blocked'` (409 if not); reset `review_incomplete_count`/`max_turns_retry_count`/`rebase_attempts` (+clear `conflict_state` for `rebase_failed`), keyed on `blocked_reason`.
- [ ] Append `workspace_activity_events` (`action='unblocked'`, actor, note, from→to).
- [ ] Tests: 200/409/404/403; counter reset; cause-aware target.

## T5 — Orchestrator DB foundation — mirror schema.sql + sqlc models

### Description
Bring the new schema (T1) into `workflow-orchestrator`: update its `db/testdata/schema.sql` snapshot and
regenerate sqlc models so the logic tasks (T6–T9) can query the new columns/tables. Also add the shared
guarded-transition helpers/columns plumbing the logic tasks reuse. Isolated into one task to avoid
`schema.sql` write-contention across the parallel Wave-3 tasks.

### Required skills
- go-best-practices
- postgres-best-practices

### Subtasks
- [ ] Mirror the T1 columns/tables into `db/testdata/schema.sql` (idempotent DDL, no goose markers).
- [ ] `sqlc generate` — models for the new columns + `handoffs`/`handoff_prs`.
- [ ] Extend the guarded-transition helper to set/clear the new per-dispatch columns atomically; add typed helpers (SetReviewing, SetReviewPassed, etc.) as thin wrappers.
- [ ] `TestMain` applies the updated snapshot; compile + existing tests green.

## T6 — Error/stuck recovery — reconciler, DLQ-`failed` reap, redis, max-turns

### Description
Implements technical-design §"Error/stuck recovery": the dispatch reconciler, the DLQ `"failed"` reap
case, redis-enqueue recovery, and the max-turns reset. All write failure context to task columns.

### Required skills
- go-best-practices

### Subtasks
- [ ] Dispatch reconciler: scan `in_progress`/`reviewing` past `EXECUTION_DEADLINE_MS` (2h); re-enqueue SAME `dispatch_handle`+`dispatch_nonce`; bump `reenqueue_attempts` durably **before** enqueue; block after `DISPATCH_RECONCILE_MAX_RETRIES` (3).
- [ ] Reap: add `terminal_status="failed"` case → `SetBlocked(blocked_reason)`.
- [ ] Redis enqueue failure: never roll back / re-claim; re-enqueue same handle next cycle; infra-level, no task block.
- [ ] Max-turns: `in_progress → ready` reset ≤ `EXECUTOR_MAX_RETRIES` (3), reset `max_turns_retry_count` on success exit; else block.
- [ ] Persist `blocked_reason` + `blocked_details`; unit tests for each path (incl. ambiguous-success no double-spawn).

## T7 — Reviewer cluster — dispatch, verdict routing, fix loop, review_incomplete

### Description
Implements technical-design §"Reviewer cluster": reviewer dispatch (guarded `in_review→reviewing`),
verdict routing via reap, fix loop, and review-incomplete retry/escalate. Reviewer merges the PR
(reuse `review-pr`); orchestrator observes merge via the existing poll.

### Required skills
- go-best-practices

### Subtasks
- [ ] `findReviewable` (`in_review`/`review_incomplete` + PR) → guarded `in_review→reviewing` dispatch (broker `review` kind, existing skill).
- [ ] Route reaped verdict: `passed→review_passed`; `change_requested`; no-valid-verdict→`review_incomplete` (≤ `MAX_REVIEW_INCOMPLETES`=2 then `blocked`), bump/reset `review_incomplete_count`.
- [ ] Fix loop: guarded `change_requested→in_progress` (fix dispatch, broker `impl` kind); completes `in_review`.
- [ ] Honour `requires_human_review` (reviewer approves, no merge).
- [ ] Unit tests for each verdict + retry/escalate.

## T8 — Conflict resolution — conflict_state, rebase, cap, merged-is-truth, terminal guard

### Description
Implements technical-design §"Conflict resolution" + the merge-race and terminal-state rules: the
`conflict_state` FSM, task-PR + feature→main rebase dispatch (Path A/B), rebase cap, merged-PR-is-truth,
and the `*`-guard carve-out.

### Required skills
- go-best-practices

### Subtasks
- [ ] Detect via GitHub `mergeable` at poll (`CONFLICTING`→resolve; `UNKNOWN`→skip); persisted `conflict_state`; guarded `conflicted→resolving` claim.
- [ ] Dispatch rebase (reuse `respond-to-review`); on completion exit `resolving` (`resolved`/`conflicted`/terminal) — invariant: `resolving` ⟺ in-flight.
- [ ] Rebase cap `MAX_REBASE_ATTEMPTS`=3: Path A (`in_review`)→`blocked(rebase_failed)`; Path B (`review_passed`)/handoff-PR→stay+`conflicted`+Slack-TODO.
- [ ] Merged-is-ground-truth: PR-merge poll → `done` from `in_review`/`reviewing`/`review_passed` (guarded); reviewer-dispatch + reconciler skip merged PRs.
- [ ] Terminal-state protection: `SetBlocked` (and `*`-guards) → `WHERE status NOT IN ('done','cancelled')`; reap drops terminal completions.
- [ ] Note: feature→main rebase capability depends on **D1** (see design §5) — confirm `respond-to-review` covers feature-branch rebase or flag-for-human.

## T9 — `blocked_from_status` recording + unblock-resume handling

### Description
Implements technical-design §"Human-unblock (orchestrator side)": record `blocked_from_status` on every
`→blocked` transition (context for the cause-aware unblock target), and ensure the existing loops resume
correctly after a human unblock (`ready`→claim; `in_review`→review/poll).

### Required skills
- go-best-practices

### Subtasks
- [ ] Set `blocked_from_status` = the pre-block status on every `SetBlocked` path (reconciler, DLQ-failed, max-turns cap, review-incomplete cap, rebase cap Path A, agent-reported).
- [ ] Confirm resume: unblocked `ready` re-enters claim; unblocked `in_review` re-enters reviewer/poll — add coverage where missing.
- [ ] Unit tests: each block cause records the correct `blocked_from_status`; resume path exercised.

## T10 — Unblock bff proxy

### Description
Proxy the unblock endpoint (technical-design §"API design") with identity injection, mirroring the
create-tasks proxy. Passthrough only, no business logic.

### Required skills
- backend-engineer

### Subtasks
- [ ] Route `POST …/tasks/:taskId/unblock` → backend, inject identity.
- [ ] Passthrough of status/body; test happy-path + auth propagation.

## T11 — `unblock_task` MCP tool

### Description
Add the `unblock_task` tool to the workflow-mcp server (technical-design §"API design"): resolve
feature/task names→UUIDs (reuse `get_feature`), call the bff endpoint, return structured result.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Tool input `{ workspace_id, feature, task, note? }` (no target); session-cookie auth.
- [ ] Resolve names→UUIDs; call bff `unblock`; map `409`/`404`/`403` to structured failure.
- [ ] Update MCP README/AGENTS; build (`npm run build`).

## T12 — Feature lifecycle — `in_implementation`, handoff trigger, handoff-PR rebase, finalize

### Description
Implements technical-design §"Handoff + handoff-PR rebase loop": the feature_status writes, handoff
trigger, `handoffs`/`handoff_prs` creation, draft PRs, the high-priority handoff-PR rebase loop, and
finalize. Orchestrator git-writes are REST-only (no working tree).

### Required skills
- go-best-practices

### Subtasks
- [ ] On first task dispatch: guarded `ready_for_implementation→in_implementation` (feature_status).
- [ ] Handoff trigger (all tasks `done`/`cancelled`): guarded `→in_handoff` + `UNIQUE(feature_id)` handoffs row; one `handoff_prs` row per **distinct repo referenced by the feature's tasks**; open draft feature→main PRs (REST) + mgmt status PR; missing feature branch → skip + Slack-TODO.
- [ ] Handoff-PR rebase loop (HIGH priority, before task dispatch): `CONFLICTING` handoff PR → `conflict_state` rebase (reuse T8 machinery); counts toward soft-claim; covered by reconciler.
- [ ] Finalize: all handoff PRs merged → merge mgmt PR (REST) → guarded `→done`.
- [ ] `// TODO(slack)` markers at handoff-opened / missing-branch / feature-done (for the slack feature).
- [ ] Integration test: all-done → handoff PRs → finalize.

## T13 — `unblock-task` agent skill

### Description
New `unblock-task` skill in the `workflow` repo that wraps the MCP `unblock_task` tool: reads the
blocked task's `blocked_reason`/`blocked_from_status` for the human, calls the tool with an optional
note, reports the server-derived outcome (no target choice).

### Required skills

### Subtasks
- [ ] SKILL.md: purpose, inputs, calls `unblock_task`, reports outcome.
- [ ] Embed the blocked-taxonomy context from design §4 for operator guidance.

## T14 — Soft-claim throttle (derived in-flight) + cycle ordering

### Description
Implements technical-design §"Concurrency": the derived in-flight count (spanning `workspace_tasks` +
`handoff_prs`), the `MAX_INFLIGHT` headroom throttle applied before every dispatch kind, and the
per-poll cycle order (handoff-PR rebase + finalize HIGH priority, before task dispatch). Do NOT port
`dockerInFlight`.

### Required skills
- go-best-practices
- postgres-best-practices

### Subtasks
- [ ] Derived count query (uses the T1 partial indexes): tasks dispatched + handoff_prs `resolving`.
- [ ] `headroom = MAX_INFLIGHT − inflight`; gate claim/fix/reviewer/rebase/handoff dispatch; soft (dispatcher is the hard cap).
- [ ] Cycle order: feature/handoff triggers → handoff-PR rebase + finalize (HIGH) → task dispatch (leftover headroom) → reap → reconciler.
- [ ] Tests: over-claim prevented; multi-instance overshoot bounded; ordering.

## T15 — E2E autonomous-run test (parallel with a legacy TS feature)

### Description
Integration test proving technical-design §"Validation": drive a go feature `ready → done` (reviewer
APPROVE → merge → handoff → finalize) with no human task-PR merge, **in parallel with a legacy
`owner IS NULL` TS feature**, asserting the single-owner invariant and no cross-interference. Plus the
unblock chain end-to-end.

### Required skills
- go-best-practices

### Subtasks
- [ ] Fixture: one go feature + one legacy TS feature in one workspace.
- [ ] Assert autonomous path: claim → in_review → reviewing → merge → done; handoff → finalize → feature done.
- [ ] Assert legacy TS feature untouched (owner partition).
- [ ] Unblock chain: block a task → unblock API → resume; counter reset verified.
