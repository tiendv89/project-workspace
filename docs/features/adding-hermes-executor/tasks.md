# Task Breakdown — adding-hermes-executor

**Feature status:** `in_tdd` | **Stage:** `tasks` (awaiting approval)
Machine-mutable state (status, log, PR, branch) lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | EXECUTOR_TYPE / EXECUTOR_PROFILE adapter wiring | — |
| T2 | 1 | Hermes executor scaffolding + phases 1–5 | — |
| T3 | 1 | Docker image — Hermes CLI installation | — |
| T4 | 2 | Phase 6 — post-execution workflow protocol | T2 |
| T5 | 2 | Layer 1 recovery | T2 |
| T6 | 3 | Tests + integration | T1, T2, T3, T4, T5 |

---

## T1 — EXECUTOR_TYPE / EXECUTOR_PROFILE adapter wiring

### Description

Split the executor selection into two independent env vars in
`runtime/orchestrator/src/adapters/index.ts`:

- `EXECUTOR_PROFILE` — infrastructure topology (`local-subprocess`, `local-docker`).
  Determines which adapter class is instantiated.
- `EXECUTOR_TYPE` — which agent binary runs (`claude`, `hermes`).
  Determines `executorBinPath` and `extraEnv`.

Implement `createExecutorAdapter`, `resolveExecutorBin`, and `resolveExecutorEnv` as
described in the technical design. The orchestrator core must receive only an
`ExecutorPort` — no knowledge of which profile or type is active.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Add `EXECUTOR_PROFILE` and `EXECUTOR_TYPE` env var reads to orchestrator config
- [ ] Implement `resolveExecutorBin(type, config): string`
- [ ] Implement `resolveExecutorEnv(type, config): Record<string, string>` with hermes case
- [ ] Implement `createExecutorAdapter(config): ExecutorPort` with profile switch
- [ ] Verify existing Claude executor tests still pass with the refactored wiring

---

## T2 — Hermes executor scaffolding + phases 1–5

### Description

Create the `runtime/executors/hermes/` package and implement the executor entrypoint
`src/index.ts` covering phases 1–5 of the startup sequence:

- **Phase 1**: clone management repo (read-only)
- **Phase 2**: clone implementation repo onto `TASK_REPO_BRANCH`
- **Phase 3**: write `HERMES_HOME/config.yaml` — model stanza + optional MCP stanza
  (RAG only; no Mem0 — that is `hermes-workspace-memory` scope)
- **Phase 4**: build briefing from mgmt clone via `src/briefing.ts` — task YAML +
  tasks.md section + technical-design.md; scope is code-work only (no git, no PR,
  no result.json instructions)
- **Phase 5**: spawn `hermes chat --query "$BRIEFING" --quiet --ignore-rules` in a
  `try/finally` block (recovery fires here; implementation of recovery is T5)

The `try/finally` stub must exist after this task so T4 and T5 can attach to it.
Hermes exits after saving file changes — it does not commit, push, or open a PR.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Scaffold package: `package.json`, `tsconfig.json`, `src/index.ts`, `src/briefing.ts`
- [ ] Implement Phase 1 + 2: `cloneOrPull(url, dir, branch)`
- [ ] Implement Phase 3: `writeHermesConfig(hermesHome, config)` — model + optional MCP stanza
- [ ] Implement Phase 4: `buildBriefing(mgmtDir, featureId, taskId): string`
- [ ] Implement Phase 5: `hermes chat` spawn with correct env (`HERMES_HOME`,
  `HERMES_INFERENCE_MODEL`, `HERMES_INFERENCE_PROVIDER`, `HERMES_MAX_ITERATIONS`,
  `HERMES_YOLO_MODE=1`, `cwd: TASK_REPO_PATH`)
- [ ] Add `try/finally` stub (recovery call wired in T5)
- [ ] Confirm `hermes` binary lookup works from `process.env.PATH`

---

## T3 — Docker image — Hermes CLI installation

### Description

Add Hermes CLI installation to the orchestrator-bundled Docker image so the `hermes`
binary is on `PATH` when the executor process spawns.

Locate the Dockerfile in `runtime/orchestrator/` (or the build directory that produces
the orchestrator image). Add the Hermes install step after existing dependencies.
Verify the binary is reachable at runtime via `hermes --version`.

This task is independent of T1/T2 and can be done in parallel.

### Required skills

### Subtasks
- [ ] Locate the orchestrator Dockerfile
- [ ] Add Hermes CLI install step (follow Hermes install docs — npm global or binary release)
- [ ] Verify `hermes --version` succeeds in a local image build
- [ ] Confirm `HERMES_HOME` tmpdir creation works inside the container filesystem

---

## T4 — Phase 6 — post-execution workflow protocol

### Description

Implement Phase 6 in `runtime/executors/hermes/src/index.ts` — the wrapper steps that
run after `hermes chat` exits successfully:

1. `git add -A && git commit` in `TASK_REPO_PATH` with a conventional commit message
2. `git push origin TASK_REPO_BRANCH`
3. Open impl PR via GitHub REST API (same `curl` logic used by the Claude executor):
   - `title`: `feat(FEATURE_ID/TASK_ID): <description>`
   - `base`: `TASK_BASE_BRANCH`
   - `head`: `TASK_REPO_BRANCH`
   - `draft: true`
4. Write `result.json` to `RESULT_PATH`:
   `{ "terminal_status": "in_review", "pr_url": "<pr_url>" }`

Phase 6 runs inside the `try` block so that recovery (T5) can detect a complete Phase 6
via `terminal_status: "in_review"` in `result.json` and short-circuit.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Implement `commitAndPush(repoDir, taskId): void`
- [ ] Implement `openImplPR(featureId, taskId, head, base, githubToken): string` — returns PR URL
- [ ] Implement `writeResult(resultPath, prUrl): void`
- [ ] Wire into Phase 5 `try` block in the correct order (commit → push → PR → result.json)
- [ ] Handle the case where `git diff --cached` is empty (no changes — write blocked result)

---

## T5 — Layer 1 recovery

### Description

Implement `runtime/executors/hermes/src/recovery.ts` and wire it into the `finally`
block of Phase 5.

Recovery fires on any exit from `hermes chat` — normal or abnormal. It must be
non-throwing: every step is wrapped in `try/catch`.

Steps:
1. **Short-circuit**: if valid `result.json` with `terminal_status: "in_review"` already
   exists at `RESULT_PATH`, return immediately (Phase 6 completed normally).
2. Commit dirty tree: `git add -A && git commit -m "wip(TASK_ID): incomplete — agent terminated"`
3. Push (best-effort).
4. Find or open draft PR via GitHub REST API.
5. Write `handover.md` alongside `result.json` — task state, branch, PR URL, exit reason.
6. Write `result.json` with `terminal_status: "blocked"`, `blocked_reason`, `pr_url`,
   `handover_path`.

Mirrors `runtime/executors/claude/src/recovery.ts`.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Implement `runRecovery(ctx: RecoveryContext): Promise<void>`
- [ ] Step 1: short-circuit check — read and validate existing `result.json`
- [ ] Step 2–3: dirty-tree commit + push (best-effort, no throw)
- [ ] Step 4: `findOrOpenDraftPR(head, base, githubToken): string`
- [ ] Step 5: `writeHandover(path, ctx): void`
- [ ] Step 6: `writeBlockedResult(resultPath, reason, prUrl, handoverPath): void`
- [ ] Wire `runRecovery()` into the `finally` block in `src/index.ts` (T2 stub)
- [ ] Confirm recovery does not throw under any simulated failure mode

---

## T6 — Tests + integration

### Description

Write unit and integration tests covering the executor and orchestrator wiring.

**Unit tests (`runtime/executors/hermes/src/__tests__/`):**
- `briefing.test.ts`: given a task YAML + tasks.md + tech design, produces correctly
  scoped briefing (no git/PR instructions in output)
- `recovery.test.ts`: given an incomplete `RESULT_PATH`, recovery produces a valid
  blocked `result.json`; given a complete `result.json`, recovery short-circuits

**Integration tests (`runtime/orchestrator/src/__tests__/`):**
- Happy path: spawn the Hermes executor via the `hermes-subprocess` profile against a
  stub task; verify `result.json` with `terminal_status: "in_review"` is written
- Abnormal exit: send SIGKILL to the `hermes chat` process; verify recovery produces a
  valid blocked `result.json` and a draft PR exists
- Parallel tasks: two executor instances for the same workspace; verify no
  `HERMES_HOME` or git conflicts (each uses its own `EXECUTOR_WORKDIR`)

### Required skills
- typescript-best-practices

### Subtasks
- [ ] `briefing.test.ts` — briefing scope unit test
- [ ] `recovery.test.ts` — recovery short-circuit and full-path unit tests
- [ ] Integration: happy-path spawn test
- [ ] Integration: SIGKILL / abnormal-exit recovery test
- [ ] Integration: parallel executor isolation test
- [ ] All tests pass in CI before PR is opened
