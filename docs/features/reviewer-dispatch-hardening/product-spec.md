# Product Specification

## Feature
- Feature ID: `reviewer-dispatch-hardening`
- Title: Reviewer dispatch hardening — reviewing status guard + executor env separation

## Problem

Three issues in the current reviewer dispatch path need to be addressed:

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

**Problem 2 — Token usage is only recorded for the implementation executor.**

`dispatch.ts` writes a `run_completed` log entry with `token_usage` and `cost_usd` from `result.json` when an implementation executor finishes. However `dispatch-review-result.ts` (reviewer path) and `claim-fix.ts` / the fix executor reap path never write these fields — even though reviewer and fix executors also produce `result.json` with `token_usage`.

This means the task log only shows token cost for the first implementation run. Every subsequent reviewer session and fix-executor run is invisible in the audit trail, making cumulative cost per task impossible to compute from the log alone.

**Problem 3 — Orchestrator redundantly passes executor-owned environment variables.**

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

2. **Record `token_usage` and `cost_usd` on every executor completion**, not just the implementation run. Every log entry appended when an executor completes — `run_completed` (impl), `reviewer_complete` / `review_incomplete` (reviewer), and the fix-executor completion entry — must carry `token_usage` and `cost_usd` from `result.json` when present. This gives a complete per-task cost audit trail across all sessions.

3. **Remove `MAX_TURNS` from all orchestrator `extraEnv` blocks.** The executor already reads `process.env.MAX_TURNS ?? "200"` and already inherits the full orchestrator environment via `SubProcessAdapter`'s `{ ...process.env, ...extraEnv }` spread. The orchestrator re-passing it explicitly is redundant. `MAX_TURNS` is documented in `docker-compose.yml` as an env var on the orchestrator service — the executor picks it up automatically through inheritance. No executor code changes needed.

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
1. `git fetch + checkout` to get latest state from origin.
2. Read task YAML. If `task.status === "reviewing"` → **skip** (return silently — another orchestrator already claimed; nothing to do this cycle).
3. Set `task.status = "reviewing"`.
4. Append `reviewer_started` log entry (audit only).
5. Commit and push (first-push-wins). If push rejected → `claim_lost` (concurrent orchestrator won the race between step 1 and step 5).
6. Submit reviewer executor.

The two-tier protection:
- **Eligibility filter** (`findReviewableTasks`): `reviewing` tasks are never returned — the dispatch is not even attempted.
- **Post-fetch check** (step 2): catches the race window where two orchestrators both read `in_review`, one commits first and pushes `reviewing`, then the second fetches and sees it before trying to commit.

**`claimFix` (fix-claim guard — `claim-fix.ts`):**
- Current: `if (last?.action === "fix_started") return already_claimed`
- New: `if (task.status === "in_progress") return already_claimed` — claim-fix already sets `status = "in_progress"` in the same commit; the log scan is redundant.

**CLAUDE.md additions:**
- `reviewing` added to task status values list.
- `in_review → reviewing` added to transition table: `(orchestrator, when reviewer executor is dispatched)`.
- `reviewing → done`, `reviewing → change_requested`, `reviewing → review_incomplete` added.
- `review_incomplete → reviewing` replaces `review_incomplete → in_review`.
- Explicit note: the orchestrator must not use `reviewer_started` or `fix_started` log entry values to make any dispatch decision — these are audit-only.

### Token usage audit — all executor paths

Every reap path appends a log entry with `token_usage` and `cost_usd` when the fields are present in `result.json`:

- **`dispatch-review-result.ts`**: `reviewer_complete` (on `change_requested`) and `review_incomplete` (on incomplete exit) entries gain `token_usage` / `cost_usd`.
- **Fix executor reap path**: the log entry written when a fix executor completes (whether it returns `in_review` or `blocked`) gains `token_usage` / `cost_usd`.
- **`dispatch.ts`** (impl path): already correct — no change needed.

The `TaskLogEntry` type in the ABI / task types must allow `token_usage` and `cost_usd` as optional fields on any log entry, not only `run_completed`.

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
- Every reviewer completion (`reviewer_complete`, `review_incomplete`) log entry includes `token_usage` and `cost_usd` when present in `result.json`.
- Every fix-executor completion log entry includes `token_usage` and `cost_usd` when present.
- A task that goes through impl → review → fix → review has `token_usage` recorded on each of those four log entries.
- `MAX_TURNS` is not present in any `extraEnv` block in the orchestrator dispatch paths (grep confirms zero usages outside test fixtures).
- `docker-compose.yml` orchestrator service has `MAX_TURNS` in its `environment` block with a documented default.
- No executor code changes — `process.env.MAX_TURNS ?? "200"` reads it transparently via env inheritance.
- `CLAUDE.md` task status list includes `reviewing`; transition table is complete; explicit note that log entries are audit-only.
- Existing tests pass; new unit tests cover the `reviewing` guard path, the fix `in_progress` guard path, and the duplicate-dispatch-skip paths for both.
