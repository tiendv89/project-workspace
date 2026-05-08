# Handoff — agent-runtime-split

**Feature:** Split agent runtime into orchestration and execution layers
**Completed:** 2026-05-09
**All tasks:** T1–T7 (7/7) done

---

## What was built

The monolithic `workflow/agent-runtime/` (~6.7k LOC, single process, single image) was split into three distinct packages under a new `workflow/runtime/` tree, with a clean ABI contract between the orchestration layer and any executor.

### New package layout

```
workflow/runtime/
  abi/                          # ABI contract package — shared types, schema, fake adapter
    src/types.ts                # ExecutorInput, ExecutorResult, ExecutorAdapter
    src/schema.ts               # JSON Schema validator for result.json
    src/fake-executor.ts        # FakeAdapter — used in orchestrator tests
    docs/abi-spec.md            # Third-party runtime author contract
  orchestrator/                 # Polling loop, claim, side-effects — no LLM
    src/main.ts                 # Entry point; dispatch loop
    src/adapter/spawn.ts        # SubProcessAdapter — spawns executor, reads result.json
    src/briefing/               # Briefing template generator
    src/claim/                  # Git-SHA atomic claim protocol
    src/side-effects/           # mutate-task-yaml, unblock-deps, append-log, dispatch
    src/poll/                   # Workspace pulls, PR-merge poll, conflict handler
    Dockerfile                  # Lean: Node + git + GH token
    docs/OPERATOR-GUIDE.md
  executors/
    claude/                     # Claude Code executor — reads ABI env vars, writes result.json
      src/index.ts              # ABI-conformant entrypoint
      src/recovery.ts           # Layer 1 post-hoc recovery (termination safety)
      Dockerfile                # Node + Claude CLI + task toolchains
```

The old `workflow/agent-runtime/` directory and all its K8s CronJob and GH Actions templates were deleted in T2.

### Key behaviours after this feature

| Concern | Before | After |
|---|---|---|
| Executor abstraction | None — only Claude could run | `ExecutorAdapter` interface; `SubProcessAdapter` is the only concrete impl today |
| Workflow-state writes | Split: orchestrator wrote claim; Claude wrote task YAML, PR open, dep unblock | Orchestrator owns all workflow-state writes from `result.json`; executor never touches management repo |
| Impl PR ownership | Ambiguous — orchestrator had an `openImplPr` no-op, executor opened it via `pr-create` | Formalized: executor opens impl PR (rich body + test plan); orchestrator opens workspace PR at claim time |
| PR as lifecycle artifact | Gated on test outcome | Both PRs are part of the task lifecycle — opened independently of test outcome |
| Termination safety | No record on `--max-turns` or crash | Layer 1 (always-on recovery), Layer 2 (briefing checkpoint discipline), Layer 3 (handover prepend on re-claim) |
| Skill/briefing contract | T6 briefing rewrite dropped `/start-implementation` invocation | Restored: executor briefing invokes `/start-implementation`; skill has `CLAUDE_AGENT_RUNTIME=1` guards for management-repo side effects |

---

## Design decisions

**D1 — Logical split first, same-pod default:** No topology change on day 1. Orchestrator and executor run inside the same container; the `SubProcessAdapter` spawns the executor as a child process. Container-per-executor or remote execution is a follow-on.

**D2 — Container ABI as the contract:** Env vars in (`ExecutorInput` fields), `result.json` out (`ExecutorResult`). Every executor (Claude, future Hermes, GPT-4o) implements the same contract.

**D3 — Workflow protocol owned entirely by orchestration:** Executors are workflow-unaware. They implement and produce output; the orchestrator interprets the result and performs all state transitions.

**D4 — Orchestrator is pure deterministic code:** No LLM call in the orchestrator. Test-outcome inspection does not happen at the orchestrator layer — `terminal_status` is the executor's verdict.

**D5 (revised 2026-05-02) — PR ownership split:** Executor owns the impl PR (opened via `pr-create` skill, with rich body and test plan). Orchestrator owns the workspace PR (opened at claim time). Both PRs are task-lifecycle infrastructure — opened independently of implementation outcome. `result.json` gains `pr_url` (reported across all `terminal_status` values whenever a PR exists). `open-pr.ts` was deleted from the orchestrator.

**D6 — Runtime parity:** One ABI contract for every executor. No executor-specific dispatch branches in the orchestrator.

**D7 — Explicit failure semantics:** `terminal_status` has three values: `in_review`, `blocked`, `failed`. `failed` is for unrecoverable orchestrator-side failures (schema invalid, executor crash with no result). `blocked` is for executor-reported blocks (tests failed, handover).

**D8 — Budget semantics:** `budgetTokens` in `ExecutorInput`; `token_usage` in `ExecutorResult`. Orchestrator records usage but does not gate on it.

**D9 — Single-cutover migration:** Alpha stage; no dual-run or feature flag. T2 was a big-bang PR.

**D10 — Top-level `workflow/runtime/` tree:** Not nested under `agent-runtime/`.

---

## Termination safety (T6)

Three layers protect against `--max-turns` cap and other abnormal exits:

**Layer 1 — Post-hoc recovery (`recovery.ts`, always-on):** A `try/finally` block wraps the Claude spawn in `index.ts`. If Claude exits without a valid `result.json`, the recovery routine: detects terminal reason (max_turns, signal, crash, timeout); commits any dirty working tree as `wip(<task_id>): incomplete — agent terminated unexpectedly`; pushes branch; opens a draft impl PR if none exists; writes `handover.md`; produces a valid `result.json` with `terminal_status: "blocked"` + `blocked_reason` + `pr_url` + `handover_path`. Recovery is idempotent and non-throwing.

**Layer 2 — Briefing checkpoint discipline (best-effort):** Every briefing includes a checkpoint discipline section instructing Claude to commit/push after each substantial action and to perform a graceful checkpoint (open draft PR, write rich `handover.md`, exit cleanly with `terminal_status: "blocked"`, `blocked_reason: "handover_for_continuation"`) when it senses the budget is running out.

**Layer 3 — Handover prepend on re-claim:** When an agent re-claims a task with an existing `handover.md` on the impl repo branch, the briefing generator prepends its contents under `## Continuing previous run` so the next agent has full context.

---

## CLAUDE_AGENT_RUNTIME guard pattern (T7)

Skills loaded by the executor can have side effects that conflict with orchestrator-owned workflow state. The `CLAUDE_AGENT_RUNTIME=1` env var (injected into every Claude subprocess) is the guard:

- **`start-implementation`:** When `CLAUDE_AGENT_RUNTIME=1`, skip management-repo side effects (task YAML status writes, log entries). Still implements, writes tests, runs test plan, creates impl PR, posts test-plan comment, and writes `result.json` to `$RESULT_PATH`.
- **`pr-create`:** When `CLAUDE_AGENT_RUNTIME=1`, skip task YAML PR metadata update, log entry, and `status → in_review` transition. Still pushes branch and creates GitHub PR. Returns PR URL.

The executor briefing now invokes `/start-implementation <taskId>` rather than duplicating inline steps.

---

## Orchestrator code quality pass (T5)

Seven focused refactors landed in T5 against `runtime/orchestrator/`:
- `workspace-config.ts` — extracted five workspace-resolver helpers from `main.ts`
- `curl-json.ts` — de-duplicated across `open-workspace-pr.ts` and `side-effects/`
- `task-yaml-io.ts` — extracted `readTask` / `writeTask` pattern
- Removed `adapter.ts` re-export barrel
- `write-briefing.ts` — extracted briefing-write step from `main.ts`
- `briefing-template.ts` — consolidated duplicate section builders
- `resolveTaskContext()` — wrapped the task-resolution block in the dispatch loop

---

## Operational notes

### Deployment

Same docker-compose entry point. `docker-compose` template updated in T2 to point at the new orchestrator image. On day 1 both orchestrator and Claude executor binaries are baked into the same image; split-image deployment is a follow-on.

### Deleted paths

- `workflow/agent-runtime/` — fully removed (source, Dockerfile, templates)
- `workflow/agent-runtime/templates/k8s-cronjob.yaml`
- `workflow/agent-runtime/templates/gh-actions.yaml`
- `runtime/orchestrator/src/side-effects/open-pr.ts` (T6)

K8s CronJob and GH Actions templates are not re-introduced in this feature. That work is a follow-on.

### Tests

- ABI package: JSON Schema validator unit tests; `FakeAdapter` unit tests
- Orchestrator: side-effects unit tests (open-pr, mutate-task-yaml, unblock-deps, append-log); seam tests against `FakeAdapter` covering in_review, blocked, failed, schema-invalid, executor_timeout
- Executor: PR URL extraction unit tests; smoke test driving `index.ts` with fixture briefing
- Recovery: dirty-tree commit, clean-tree + no-PR → draft PR, recovery idempotence on existing in_review result, step-failure resilience

---

## Follow-on features

| Feature | Status | Notes |
|---|---|---|
| `agent-runtime-selector` | in_design (paused) | Multi-executor selection and routing. Builds on the `ExecutorAdapter` interface introduced in T1. Context from this feature's D1–D10 was propagated into the selector spec. |
| K8s CronJob / GH Actions templates | Not started | Templates were deleted in T2. Re-introduction is a dedicated follow-on feature. |
| Container-per-executor topology | Not started | Today orchestrator and executor run in the same pod. The ABI enables split containers; that deployment topology is a follow-on. |
