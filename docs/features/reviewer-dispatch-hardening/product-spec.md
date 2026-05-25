# Product Specification

## Feature
- Feature ID: `reviewer-dispatch-hardening`
- Title: Reviewer dispatch hardening — reviewing status guard + executor env separation

## Problem

Two separate issues in the current reviewer dispatch path need to be addressed:

**Problem 1 — Log-scan deduplication guard is fragile.**

`dispatchReviewer` currently prevents duplicate reviewer dispatch by checking whether the last task log entry is `reviewer_started`. This log-scan guard is fragile:
- It relies on log ordering and the specific value of the last entry — not on authoritative state.
- If the log is appended out of order (e.g. concurrent orchestrator instances, replay), the guard can be bypassed.
- Adding a `reviewing` task status was proposed in the `feature-branch-pr-review-gate` technical design as the correct deduplication mechanism — the status field is the authoritative, atomic claim guard.

The task status values list in `CLAUDE.md` does not include `reviewing`. The transition `in_review → reviewing` (set atomically by the orchestrator before dispatch) is missing from the workflow rules.

**Problem 2 — Orchestrator redundantly passes executor-owned environment variables.**

`SubProcessAdapter.submit()` builds the child environment as:
```
childEnv = { ...process.env, ...extraEnv, ...abivars }
```

Because `...process.env` is spread first, the executor already inherits every variable set in the orchestrator's environment — including `MAX_TURNS`. The orchestrator then explicitly re-passes `MAX_TURNS: String(maxTurns)` via `extraEnv` in `dispatchReviewer`, which is redundant.

More broadly, any per-executor-kind configuration (like a `max_turns_multiplier` for feature reviewers) could be read by the executor itself from `workspace.yaml` at startup, rather than having the orchestrator compute and inject it. The orchestrator passing computed values couples it to executor-internal concerns.

## Goals

1. **Add `reviewing` task status** to the workflow rules in `CLAUDE.md` and to `dispatchReviewer`. The transition `in_review → reviewing` is written to the task YAML and pushed (first-push-wins) before the reviewer executor is dispatched. This status field replaces the log-scan guard — if the task is already `reviewing`, dispatch is skipped.

2. **Remove redundant `MAX_TURNS` pass-through** from `dispatchReviewer` and other dispatch paths. Executor-owned configuration (`MAX_TURNS`, and any future per-kind multipliers) is read by the executor from its inherited environment or from `workspace.yaml` directly. The orchestrator does not compute or inject these values.

3. **Document the separation of concerns** in the ABI spec and operator guide: orchestrator injects ABI-required variables; executor reads its own operational config from the environment it inherits.

## Non-goals

- Not changing how `MAX_TURNS` is set by the operator (still an env var at orchestrator startup — the executor inherits it automatically).
- Not removing `EXECUTOR_KIND` or other dispatch-routing env vars that are genuinely orchestrator-owned decisions.
- Not implementing per-feature-kind multipliers in this feature — that belongs in `feature-branch-pr-review-gate`. This feature only removes the pattern of the orchestrator re-injecting what the executor already inherits.
- Not changing the task log actions (`reviewer_started`, `fix_started`) — they remain as audit entries.

## Behaviour specification

### reviewing status

When `dispatchReviewer` is about to submit a reviewer executor:
1. Check task status: if already `reviewing`, skip dispatch (no-op return).
2. Set `task.status = "reviewing"` in the task YAML.
3. Append `reviewer_started` log entry (audit only — status is now the guard).
4. Commit and push to `origin/<taskBranch>` (first-push-wins). If push rejected → `claim_lost`.
5. Submit reviewer executor.

CLAUDE.md additions:
- `reviewing` added to task status values list.
- `in_review → reviewing` added to transition table with annotation: `(orchestrator, when reviewer executor is dispatched)`.
- `reviewing → done`, `reviewing → change_requested`, `reviewing → review_incomplete` added.
- `review_incomplete → reviewing` replaces `review_incomplete → in_review`.
- Note: `reviewer_started` log action is audit-only — status is the deduplication guard.

### Executor env separation

`dispatchReviewer` `extraEnv` block:
- Remove `MAX_TURNS: String(maxTurns)` — executor inherits `MAX_TURNS` from `process.env` via `SubProcessAdapter`'s `{ ...process.env, ...extraEnv }` spread.
- `maxTurns` parameter removed from `DispatchReviewerOptions` (or deprecated).
- Other dispatch paths (`dispatchExecutor`, fix executor dispatch) audited and cleaned up identically.

ABI spec updated: note that `MAX_TURNS` is an executor-read env var (operator-set, inherited), not an orchestrator-injected ABI var.

## Success criteria

- Task transitions `in_review → reviewing` atomically in `dispatchReviewer` before executor is submitted.
- If task status is already `reviewing` when `dispatchReviewer` is called, dispatch is skipped — no log scan needed.
- `MAX_TURNS` is not present in any `extraEnv` block in the orchestrator dispatch paths.
- `CLAUDE.md` task status list includes `reviewing`; transition table is complete.
- Existing tests pass; new unit tests cover the `reviewing` guard path and the duplicate-dispatch-skip path.
