# Product Specification

## Feature
- Feature ID: `reviewer-dispatch-hardening`
- Title: Reviewer dispatch hardening — reviewing status guard + executor env separation

## Problem

Two separate issues in the current reviewer dispatch path need to be addressed:

**Problem 1 — The orchestrator uses log-entry scans to make dispatch decisions.**

Three places in the orchestrator read `reviewer_started` or `fix_started` log entries to control dispatch logic:

1. **`eligibility/match.ts` — `findReviewableTasks`**: filters eligible tasks with the predicate `last log entry ≠ reviewer_started`. This is the primary eligibility gate that decides whether a reviewer should be dispatched for a given task.

2. **`dispatch-reviewer.ts` — duplicate-claim guard**: after fetching the latest task YAML, checks `if (lastEntry?.action === "reviewer_started")` and returns `claim_lost` to prevent double-dispatch.

3. **`claim-fix.ts` — fix-claim guard**: checks `if (last?.action === "fix_started")` to prevent a second fix agent from claiming a task that is already `in_progress`.

All three are log scans — they depend on the last log entry having a specific value rather than reading authoritative task state. This is fragile:
- Log ordering is not guaranteed under concurrent orchestrator instances.
- A log entry appended slightly out of order can allow two reviewers or two fix agents to claim the same task.
- The status field already changes atomically (first-push-wins commit); log entries are appended in the same commit but are advisory, not authoritative.

The correct fix is to use status as the guard. `reviewing` is the missing status value that closes the reviewer-dispatch race. For fix dispatch, `claim-fix.ts` already sets `status = "in_progress"` in the same commit — the log-scan guard is entirely redundant there.

The task status values list in `CLAUDE.md` does not include `reviewing`. The transition `in_review → reviewing` (set atomically by the orchestrator before dispatch) is missing from the workflow rules.

**Problem 2 — Orchestrator redundantly passes executor-owned environment variables.**

`SubProcessAdapter.submit()` builds the child environment as:
```
childEnv = { ...process.env, ...extraEnv, ...abivars }
```

Because `...process.env` is spread first, the executor already inherits every variable set in the orchestrator's environment — including `MAX_TURNS`. The orchestrator then explicitly re-passes `MAX_TURNS: String(maxTurns)` via `extraEnv` in `dispatchReviewer`, which is redundant.

More broadly, any per-executor-kind configuration (like a `max_turns_multiplier` for feature reviewers) could be read by the executor itself from `workspace.yaml` at startup, rather than having the orchestrator compute and inject it. The orchestrator passing computed values couples it to executor-internal concerns.

## Goals

1. **Add `reviewing` task status** to the workflow rules in `CLAUDE.md`. Replace all three log-scan guards with status checks:
   - `findReviewableTasks` eligibility: `status === "in_review" || status === "review_incomplete"` (drop the `last log ≠ reviewer_started` predicate)
   - `dispatchReviewer` duplicate-claim guard: check `task.status === "reviewing"` (drop `lastEntry?.action === "reviewer_started"`)
   - `claim-fix.ts` fix-claim guard: check `task.status === "in_progress"` (drop `last?.action === "fix_started"`)

   The orchestrator must not perform any dispatch decision based on log entry values. Log entries (`reviewer_started`, `fix_started`) are retained as audit-only entries in the same claim commit.

2. **Remove `MAX_TURNS` from all orchestrator `extraEnv` blocks.** The executor already reads `process.env.MAX_TURNS ?? "200"` and already inherits the full orchestrator environment via `SubProcessAdapter`'s `{ ...process.env, ...extraEnv }` spread. The orchestrator re-passing it explicitly is redundant. `MAX_TURNS` is documented in `docker-compose.yml` as an env var on the orchestrator service — the executor picks it up automatically through inheritance. No executor code changes needed.

3. **Document the separation of concerns** in the ABI spec and operator guide: orchestrator injects ABI-required variables (task routing, repo URLs, credentials); executor-operational config (`MAX_TURNS`, etc.) is set at the service level in docker-compose and inherited — not computed or injected by the orchestrator.

## Non-goals

- Not removing `EXECUTOR_KIND` or other dispatch-routing env vars that are genuinely orchestrator-owned decisions (the orchestrator decides *what kind* of executor to run; the executor decides *how* to run it).
- Not implementing per-kind turn multipliers in this feature — that belongs in `feature-branch-pr-review-gate`. This feature establishes the clean env-inheritance pattern that makes multipliers easy to add later (orchestrator can still compute and inject a specific value for feature reviewers when that feature ships).
- Not changing the task log actions (`reviewer_started`, `fix_started`) — they remain as audit entries.

## Behaviour specification

### reviewing status

**`findReviewableTasks` (eligibility filter — `match.ts`):**
- Current: `status in [in_review, review_incomplete] AND last log ≠ reviewer_started`
- New: `status in [in_review, review_incomplete]` — no log scan

**`dispatchReviewer` (claim guard — `dispatch-reviewer.ts`):**
1. Check `task.status === "reviewing"` → if true, return `claim_lost` immediately (already claimed).
2. Set `task.status = "reviewing"`.
3. Append `reviewer_started` log entry (audit only).
4. Commit and push (first-push-wins). If push rejected → `claim_lost`.
5. Submit reviewer executor.

**`claimFix` (fix-claim guard — `claim-fix.ts`):**
- Current: `if (last?.action === "fix_started") return already_claimed`
- New: `if (task.status === "in_progress") return already_claimed` — claim-fix already sets `status = "in_progress"` in the same commit; the log scan is redundant.

**CLAUDE.md additions:**
- `reviewing` added to task status values list.
- `in_review → reviewing` added to transition table: `(orchestrator, when reviewer executor is dispatched)`.
- `reviewing → done`, `reviewing → change_requested`, `reviewing → review_incomplete` added.
- `review_incomplete → reviewing` replaces `review_incomplete → in_review`.
- Explicit note: the orchestrator must not use `reviewer_started` or `fix_started` log entry values to make any dispatch decision — these are audit-only.

### Executor env separation — `MAX_TURNS`

`SubProcessAdapter.submit()` builds the child env as `{ ...process.env, ...extraEnv, ...abivars }`. Because `process.env` is spread first, any env var set on the orchestrator service is already present in the executor's environment without the orchestrator explicitly re-passing it.

Changes:
- **`dispatch-reviewer.ts`**: remove `MAX_TURNS: String(maxTurns)` from `extraEnv`; remove `maxTurns` from `DispatchReviewerOptions`.
- **All other dispatch paths** (`dispatchExecutor`, fix-executor): audit and remove `MAX_TURNS` from `extraEnv` blocks identically.
- **`docker-compose.yml`**: add `MAX_TURNS` to the orchestrator service `environment` block with a documented default (e.g. `200`). This is the canonical place operators set the turn budget — the executor inherits it automatically.
- **No executor code changes** — `process.env.MAX_TURNS ?? "200"` remains as-is.
- **ABI spec + operator guide**: document that `MAX_TURNS` is an operator-level env var set on the orchestrator service; it is not injected by the orchestrator into individual executor spawns.

## Success criteria

- Task transitions `in_review → reviewing` atomically in `dispatchReviewer` before executor is submitted.
- `findReviewableTasks` eligibility check contains no log-entry predicate.
- `dispatchReviewer` duplicate-claim guard checks `task.status === "reviewing"` — no log scan.
- `claimFix` guard checks `task.status === "in_progress"` — no log scan.
- No orchestrator code reads `reviewer_started` or `fix_started` to make a dispatch decision (grep confirms zero such usages outside test fixtures and log-write lines).
- `MAX_TURNS` is not present in any `extraEnv` block in the orchestrator dispatch paths (grep confirms zero usages outside test fixtures).
- `docker-compose.yml` orchestrator service has `MAX_TURNS` in its `environment` block with a documented default.
- No executor code changes — `process.env.MAX_TURNS ?? "200"` reads it transparently via env inheritance.
- `CLAUDE.md` task status list includes `reviewing`; transition table is complete; explicit note that log entries are audit-only.
- Existing tests pass; new unit tests cover the `reviewing` guard path, the fix `in_progress` guard path, and the duplicate-dispatch-skip paths for both.
