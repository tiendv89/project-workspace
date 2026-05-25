# Tasks — reviewer-dispatch-hardening

Feature status: `in_tdd` → tasks approved → `ready_for_implementation`.
Stage: `tasks` (awaiting approval).
Machine state lives in `tasks/T<n>.yaml` — do not edit status, PR, or log fields here.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | CLAUDE.md — reviewing status + transitions | — |
| T2 | 1 | ABI types — ExecutorAudit + reviewing in TaskStatus | — |
| T3 | 2 | Log-scan guard removal | T2 |
| T4 | 2 | Token/MCP audit — executor_audit propagation | T2 |
| T5 | 1 | MAX_TURNS env separation | — |
| T6 | 3 | Tests — reviewing guard + audit + MAX_TURNS | T3, T4, T5, T7 |
| T7 | 3 | executor_audit — Hermes executor output | T2, T4 |

---

## T1 — CLAUDE.md — reviewing status + transitions

### Description

Add `reviewing` to the task status values list in `CLAUDE.md` (management-repo). Update the transition table with all `reviewing` transitions. Add an explicit note to the log actions table marking `reviewer_started` and `fix_started` as audit-only entries that the orchestrator must never use to make dispatch decisions.

This is a documentation-only change in the management repo. It must land before or alongside the implementation tasks so that any agent executing T3 sees the correct workflow rules.

Specific changes to `CLAUDE.md`:
- Add `reviewing` to the "Task status values" list.
- Add the following transitions:
  - `in_review → reviewing` (orchestrator, when reviewer executor is dispatched)
  - `reviewing → in_review` (orchestrator, when reviewer completes with `passed` — PR poll detects merge)
  - `reviewing → change_requested` (orchestrator, when reviewer completes with `change_requested`)
  - `reviewing → review_incomplete` (orchestrator, when reviewer exits without a valid result)
  - `review_incomplete → reviewing` (orchestrator, when re-dispatching reviewer on next cycle — replaces `review_incomplete → in_review`)
- Add audit-only note to the log actions table: `reviewer_started` and `fix_started` are retained as audit entries only; the orchestrator must not read these to make any dispatch decision.

### Required skills

_No technical skills required — CLAUDE.md is a markdown document._

### Subtasks

- [ ] Open `CLAUDE.md` (management-repo root), locate "Task status values" section
- [ ] Add `reviewing` to the status list
- [ ] Locate "Task status transition rules" table, add `in_review → reviewing` and all `reviewing →` transitions
- [ ] Replace `review_incomplete → in_review` with `review_incomplete → reviewing`
- [ ] Locate "Valid task log action names" table, add audit-only note for `reviewer_started` and `fix_started`
- [ ] Verify no other references to `reviewer_started` or `fix_started` describe them as dispatch guards
- [ ] Run any lint/format checks for the management repo if configured

---

## T2 — ABI types — ExecutorAudit + reviewing in TaskStatus

### Description

Extend the ABI type definitions in the `workflow` repo with the types required by T3 and T4. This task is a pure TypeScript type-only change — no runtime logic.

Files:
- **`runtime/abi/src/types.ts`** (or equivalent `TaskStatus` union location):
  - Add `"reviewing"` to the `TaskStatus` union.
  - Add `ClaudeExecutorAudit` interface: `{ token_usage?: { input: number; output: number; model?: string }; cost_usd?: number; mcp_usage?: { rag_queries: Array<{ query: string; result_length: number }>; gitnexus_queries: Array<{ tool: string; arguments: Record<string, unknown>; result_length: number }> }; }`.
  - Add `ExecutorAudit` interface: `{ claude?: ClaudeExecutorAudit; }` with a comment stub for future executor kinds.
  - Add `executor_audit?: ExecutorAudit` to `ReviewerResult`.
  - Add `executor_audit?: ExecutorAudit` to `ExecutorResult`.
- **`runtime/orchestrator/src/task/types.ts`** — if `TaskStatus` is defined separately here, add `"reviewing"` there as well.

No runtime behaviour changes. Compile check: `npx tsc --noEmit` must pass.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Locate `TaskStatus` union — check both `abi/src/types.ts` and `orchestrator/src/task/types.ts`
- [ ] Add `"reviewing"` to `TaskStatus` union (both locations if split)
- [ ] Add `ClaudeExecutorAudit` interface with `token_usage`, `cost_usd`, `mcp_usage` fields
- [ ] Add `ExecutorAudit` interface with `claude?: ClaudeExecutorAudit` and a `hermes?` stub comment
- [ ] Add `executor_audit?: ExecutorAudit` to `ReviewerResult`
- [ ] Add `executor_audit?: ExecutorAudit` to `ExecutorResult`
- [ ] Run `npx tsc --noEmit` — zero errors
- [ ] Run `golangci-lint run` if any Go files are touched (unlikely — TypeScript only)

---

## T3 — Log-scan guard removal

### Description

Remove the three log-scan predicates that currently drive reviewer and fix dispatcher decisions, replacing each with a status check. This is the core correctness fix — after this lands, no orchestrator code reads `reviewer_started` or `fix_started` to make any dispatch decision.

**`eligibility/match.ts` — `findReviewableTasks`:**
Remove the last-log-entry predicate. The new filter is:
```ts
(t) => (t.status === "in_review" || t.status === "review_incomplete") && !!t.pr?.url
```

**`pr/dispatch-reviewer.ts` — claim guard:**
Replace the `lastEntry?.action === "reviewer_started"` check with a `task.status === "reviewing"` check after fetching latest YAML. Both `reviewing` (already claimed — skip) and `in_review`/`review_incomplete` (claimable) must be handled distinctly. Before push, set `task.status = "reviewing"` in the claim commit (alongside the existing `reviewer_started` audit log entry).

Also update the `passed` result branch in `dispatch-review-result.ts` or its caller: when the reviewer finishes with `passed`, the task was `reviewing` — reset it to `in_review` so the PR poll can detect the merge. This status write goes in the `passed` case of `dispatchReviewResult`.

**`task/claim-fix.ts` — fix-claim guard:**
Replace:
```ts
if (last?.action === "fix_started") return { won: false, reason: "already_claimed" };
```
with:
```ts
if (task.status === "in_progress") return { won: false, reason: "already_claimed" };
```

Grep verification: after this task, `grep -r "reviewer_started\|fix_started" runtime/orchestrator/src/` should return zero results outside of log-write lines and audit-only comments.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Read `eligibility/match.ts` — locate `findReviewableTasks`, remove the log-scan predicate
- [ ] Read `pr/dispatch-reviewer.ts`:
  - [ ] Locate the post-fetch guard block (around line 134–145)
  - [ ] Replace `lastEntry?.action === "reviewer_started"` check with `task.status === "reviewing"` → emit `reviewer_already_claimed` event → return `claim_lost`
  - [ ] In the claim commit block: set `task.status = "reviewing"` before push
  - [ ] Remove `maxTurns` from `DispatchReviewerOptions` (handled jointly with T5 if not already done)
- [ ] Read `task/dispatch-review-result.ts`:
  - [ ] In the `passed` branch: add status reset to `in_review` in the log entry write (task was `reviewing` during review)
- [ ] Read `task/claim-fix.ts` — replace log-scan guard with `task.status === "in_progress"` check
- [ ] Grep for `reviewer_started` and `fix_started` outside log-write lines — confirm zero dispatch uses
- [ ] Run `npx tsc --noEmit` — zero errors
- [ ] Run full test suite — all passing

---

## T4 — Token/MCP audit — executor_audit propagation

### Description

Propagate `executor_audit` from `result.json` into every orchestrator completion log entry. After this task, every reviewer session and fix-executor run will have per-session token usage and MCP query data visible in the task YAML.

**`executors/claude/src/index.ts`:**
After the existing `extractRagQueries` / `extractGitNexusQueries` calls, build a `ClaudeExecutorAudit` object and attach it as `executor_audit: { claude: claudeAudit }` to `claudeResult` before writing `result.json`. The existing `token_usage` and `cost_usd` fields move inside `claudeAudit` (keep them flat on `claudeResult` for backward compat if other code reads them directly, but also include in `executor_audit.claude`).

**`task/dispatch-review-result.ts`:**
In all three branches (`change_requested`, default/`review_incomplete`, `passed`), spread `executor_audit` from `result` onto the log entry when present:
```ts
...(result.executor_audit && { executor_audit: result.executor_audit })
```

**`task/dispatch.ts`:**
In the `run_completed` and `blocked` log entry writes, add `executor_audit` spread in the same pattern. The existing flat `token_usage`/`cost_usd` spreads may be kept for backward compatibility or migrated to `executor_audit.claude` — match the approach taken by the executor.

**`abi/docs/abi-spec.md`:**
Add `executor_audit` as an optional field on `result.json`. Document the `ExecutorAudit` / `ClaudeExecutorAudit` shapes and the extensibility intent (future executor kinds add their own key).

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Read `executors/claude/src/index.ts` — locate `extractRagQueries`/`extractGitNexusQueries` usage
- [ ] Build `claudeAudit` from `token_usage`, `cost_usd`, and MCP query results
- [ ] Attach `executor_audit: { claude: claudeAudit }` to `claudeResult` before `writeFile(result.json)`
- [ ] Read `task/dispatch-review-result.ts` — add `executor_audit` spread to `change_requested`, `review_incomplete`, and `passed` log entries
- [ ] Read `task/dispatch.ts` — add `executor_audit` spread to `run_completed` and `blocked` log entries
- [ ] Update `abi/docs/abi-spec.md` with `executor_audit` field documentation
- [ ] Run `npx tsc --noEmit` — zero errors
- [ ] Run full test suite — all passing

---

## T5 — MAX_TURNS env separation

### Description

Remove `MAX_TURNS` from all orchestrator `extraEnv` injection points. The executor already inherits `MAX_TURNS` via `{ ...process.env }` in `SubProcessAdapter.submit()`. Explicit re-injection by the orchestrator is redundant and couples the orchestrator to executor-internal turn budget concerns.

**`runtime/orchestrator/src/main.ts`** (line ~441):
Remove `MAX_TURNS: String(config.budget.max_iterations)` from the `extraEnv` block.

**`runtime/orchestrator/src/pr/dispatch-reviewer.ts`:**
Remove `MAX_TURNS: String(maxTurns)` from `extraEnv`; remove `maxTurns` from `DispatchReviewerOptions` (if not already done in T3).

**Audit all dispatch paths** — grep for `MAX_TURNS` in orchestrator source; remove every instance from `extraEnv` blocks:
```bash
grep -rn "MAX_TURNS" runtime/orchestrator/src/
```

**`docker-compose.platform.yml`** and **`runtime/orchestrator/templates/docker-compose.local-docker.yml`** — add `MAX_TURNS` to the orchestrator service `environment` block:
```yaml
MAX_TURNS: ${MAX_TURNS:-200}   # executor turn budget; inherited by all executor subprocesses
```

**`runtime/orchestrator/docs/OPERATOR-GUIDE.md`:**
Document `MAX_TURNS` as an operator-level env var set on the orchestrator service. State explicitly that it is not injected per-executor-spawn — executors read it directly from the inherited environment.

**`runtime/abi/docs/abi-spec.md`:**
Add a note that `MAX_TURNS` is not an orchestrator-injected ABI variable — it is set by the operator and inherited by executor subprocesses via environment.

No executor code changes. `process.env.MAX_TURNS ?? "200"` in `executors/claude/src/index.ts` stays as-is.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Run `grep -rn "MAX_TURNS" runtime/orchestrator/src/` — list all occurrences
- [ ] Remove `MAX_TURNS` from `extraEnv` in `main.ts`
- [ ] Remove `MAX_TURNS` from `extraEnv` and `DispatchReviewerOptions` in `dispatch-reviewer.ts`
- [ ] Audit and remove any other `MAX_TURNS` in `extraEnv` blocks
- [ ] Update `docker-compose.platform.yml` — add `MAX_TURNS: ${MAX_TURNS:-200}` to orchestrator environment
- [ ] Update `docker-compose.local-docker.yml` template — same addition
- [ ] Update `OPERATOR-GUIDE.md` — document `MAX_TURNS` as operator env var, not per-executor-spawn
- [ ] Update `abi-spec.md` — note `MAX_TURNS` is environment-inherited, not ABI-injected
- [ ] Confirm `grep -rn "MAX_TURNS" runtime/orchestrator/src/` returns zero results outside comments
- [ ] Run `npx tsc --noEmit` — zero errors

---

## T7 — executor_audit — Hermes executor output

### Description

Bring Hermes executor to parity with the Claude executor for `executor_audit` output. T4 wires `executor_audit.claude` into result.json for the Claude executor — every Hermes run currently produces no audit entry in the task YAML cost trail.

**`runtime/abi/src/types.ts`:**
Extend the `ExecutorAudit` interface (added in T2) with a `hermes` key:
```ts
export interface HermesExecutorAudit {
  token_usage?: { input?: number; output?: number };
  turns?: number;
}
export interface ExecutorAudit {
  claude?: ClaudeExecutorAudit;
  hermes?: HermesExecutorAudit;  // add this
}
```
Fields are all optional — populate only what Hermes actually exposes in its output.

**`runtime/executors/hermes/src/index.ts`:**
After Phase 5 completes (`spawnResult` available), extract whatever token/turn data Hermes emits to stdout. Build a `HermesExecutorAudit` object and merge it into result.json:

- If Hermes wrote its own result.json (Phase 6 short-circuit path): read it, add `executor_audit: { hermes: hermesAudit }`, write it back before emitting `phase_done`.
- If the wrapper is writing result.json itself (fallback path): include `executor_audit: { hermes: hermesAudit }` directly in the object written.

To discover what Hermes exposes, inspect `spawnResult.stdout` for structured JSON lines or summary output. If nothing structured is available, emit `turns` only (count newlines or session turns from stdout). Do not leave `executor_audit` absent — write `{ hermes: {} }` as a minimum so the orchestrator knows the session ran under Hermes.

**`runtime/abi/docs/abi-spec.md`:**
Document `HermesExecutorAudit` shape alongside `ClaudeExecutorAudit`. Note that `hermes.token_usage` fields are populated only when the Hermes CLI exposes them.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Read `runtime/abi/src/types.ts` — add `HermesExecutorAudit` interface; add `hermes?` to `ExecutorAudit`
- [ ] Read `runtime/executors/hermes/src/index.ts` — inspect `spawnResult` shape; identify available stdout data
- [ ] Build `hermesAudit` from available stdout/result data after Phase 5
- [ ] Phase 6 short-circuit path: augment result.json with `executor_audit.hermes` before `phase_done` emit
- [ ] Fallback path: include `executor_audit.hermes` in wrapper-written result.json
- [ ] Update `abi/docs/abi-spec.md` — document `HermesExecutorAudit` shape
- [ ] Run `npx tsc --noEmit` — zero errors
- [ ] Run full test suite — all passing

---

## T6 — Tests — reviewing guard + audit + MAX_TURNS

### Description

Write or update unit and integration tests covering all changes from T3, T4, T5, and T7. This task must land after all of those are complete so tests can exercise the final code.

**`eligibility/match.ts` tests:**
- `findReviewableTasks` returns `in_review` tasks regardless of last log entry value.
- `findReviewableTasks` does NOT return `reviewing` tasks.
- `findReviewableTasks` returns `review_incomplete` tasks regardless of last log entry value.

**`pr/dispatch-reviewer.ts` tests:**
- Task already `reviewing` after fetch → returns `claim_lost` without attempting a push.
- Task `in_review` → claim sets `status: reviewing`, pushes, submits executor successfully.
- Push rejected (non-fast-forward) → returns `claim_lost`.

**`task/claim-fix.ts` tests:**
- Task `in_progress` after fetch → returns `already_claimed`.
- Task `change_requested` → fix agent wins the claim.

**`task/dispatch-review-result.ts` tests:**
- `change_requested` result with `executor_audit` populated → log entry contains `executor_audit`.
- `review_incomplete` result with `executor_audit` → log entry contains `executor_audit`.
- `passed` result → task status reset to `in_review`; log entry contains `executor_audit` if present.

**Executor `executor_audit` tests:**
- When RAG and GitNexus calls present in stdout: `result.json` contains `executor_audit.claude.mcp_usage`.
- When no MCP calls: `executor_audit` absent from `result.json`.
- `token_usage` and `cost_usd` appear in `executor_audit.claude` when present.

**`MAX_TURNS` static check:**
- Test (or CI check) that `grep -r "MAX_TURNS" runtime/orchestrator/src/` returns zero results outside expected comment lines.

**Hermes `executor_audit` tests (T7):**
- Phase 6 short-circuit path: when Hermes writes result.json with `terminal_status: in_review`, wrapper augments it with `executor_audit.hermes` before emitting `phase_done`.
- Fallback path: wrapper-written result.json includes `executor_audit.hermes`.
- `executor_audit.hermes` is never absent — minimum `{}` when no structured stdout available.
- `HermesExecutorAudit` type compiles cleanly alongside `ClaudeExecutorAudit` under `ExecutorAudit`.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Identify existing test files for `match.ts`, `dispatch-reviewer.ts`, `claim-fix.ts`, `dispatch-review-result.ts`, `dispatch.ts`, `executors/claude/src/index.ts`, `executors/hermes/src/index.ts`
- [ ] Add/update `findReviewableTasks` tests — log-scan independence + `reviewing` exclusion
- [ ] Add/update `dispatchReviewer` claim guard tests — skip on `reviewing`; claim on `in_review`; push-rejected
- [ ] Add/update `claimFixTask` tests — `in_progress` guard; `change_requested` win
- [ ] Add/update `dispatchReviewResult` tests — `executor_audit` on all branches; `passed` → `in_review` reset
- [ ] Add/update Claude executor tests — `executor_audit.claude` in `result.json` when MCP calls present/absent
- [ ] Add Hermes executor tests — `executor_audit.hermes` present in both short-circuit and fallback paths
- [ ] Add static grep check for `MAX_TURNS` in `extraEnv` (as test or CI lint step)
- [ ] Run full test suite — all passing
- [ ] Run `npx tsc --noEmit` — zero errors
