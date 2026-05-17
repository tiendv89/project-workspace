# Handoff — Hermes Executor — ABI-conformant executor image for Hermes Agent

## Summary
## Feature - Feature ID: `adding-hermes-executor` - Title: Hermes Executor — ABI-conformant executor image for Hermes Agent

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — EXECUTOR_TYPE / EXECUTOR_PROFILE adapter wiring | [PR](https://github.com/tiendv89/agent-workflow/pull/175) | — |
| T2 — Hermes executor scaffolding + phases 1–5 | [PR](https://github.com/tiendv89/agent-workflow/pull/174) | 🟡 Race condition in resolve-ssh-key.ts:5 — TEMP_SSH_KEY_PATH is a fixed path (~/.ssh/agent_id_rsa) shared across parallel executor instances. Product spec requires parallel-task isolation. Fix: derive key path from EXECUTOR_WORKDIR (per-handle). |
| T3 — Docker image — Hermes CLI installation | [PR](https://github.com/tiendv89/agent-workflow/pull/176) | — |
| T4 — Phase 6 — post-execution workflow protocol | [PR](https://github.com/tiendv89/agent-workflow/pull/177) | — |
| T5 — Layer 1 recovery | [PR](https://github.com/tiendv89/agent-workflow/pull/178) | — |
| T6 — Tests + integration | [PR](https://github.com/tiendv89/agent-workflow/pull/179) | 🟡 Missing npm test step for hermes executor unit tests in CI (.github/workflows/ci-orchestrator.yml test-hermes job). Unit tests (briefing.test.ts, recovery.test.ts, etc.) are type-checked but never executed. T6 subtask 'All tests pass in CI before PR is opened' not fully satisfied. Fix: add npm test step in runtime/executors/hermes between typecheck and orchestrator npm ci. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `.github/workflows/ci-orchestrator.yml`
- `runtime/executors/hermes/package-lock.json`
- `runtime/executors/hermes/package.json`
- `runtime/executors/hermes/src/briefing.test.ts`
- `runtime/executors/hermes/src/briefing.ts`
- `runtime/executors/hermes/src/clone-or-pull.test.ts`
- `runtime/executors/hermes/src/git-env.ts`
- `runtime/executors/hermes/src/hermes-config.test.ts`
- `runtime/executors/hermes/src/index.ts`
- `runtime/executors/hermes/src/phase6.test.ts`
- `runtime/executors/hermes/src/recovery.test.ts`
- `runtime/executors/hermes/src/recovery.ts`
- `runtime/executors/hermes/src/resolve-ssh-key.ts`
- `runtime/executors/hermes/tsconfig.json`
- `runtime/executors/hermes/vitest.config.ts`
- `runtime/orchestrator/Dockerfile`
- `runtime/orchestrator/src/adapters/executor-factory.ts`
- `runtime/orchestrator/src/adapters/index.ts`
- `runtime/orchestrator/tests/executor-factory.test.ts`
- `runtime/orchestrator/tests/run-hermes.test.ts`
- `runtime/orchestrator/vitest.unit.config.ts`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: ready | tiendv.52@gmai.com | 2026-05-17T08:53:40Z |
| T2: ready | tiendv.52@gmai.com | 2026-05-17T08:53:40Z |
| T3: ready | tiendv.52@gmai.com | 2026-05-17T08:53:40Z |
| T1: claimed | norepy@tiendv.dev | 2026-05-17T09:11:38.235Z |
| T1: rag_pre_flight | norepy@tiendv.dev | 2026-05-17T09:11:51.079Z |
| T2: claimed | norepy@tiendv.dev | 2026-05-17T09:13:38.050Z |
| T2: rag_pre_flight | norepy@tiendv.dev | 2026-05-17T09:13:51.009Z |
| T2: started | norepy@tiendv.dev | 2026-05-17T09:16:28+0000 |
| T1: started | norepy@tiendv.dev | 2026-05-17T09:16:51+0000 |
| T3: claimed | norepy@tiendv.dev | 2026-05-17T09:27:55.505Z |
| T3: rag_pre_flight | norepy@tiendv.dev | 2026-05-17T09:28:07.804Z |
| T2: run_completed | norepy@tiendv.dev | 2026-05-17T09:28:44.280Z |
| T3: started | norepy@tiendv.dev | 2026-05-17T09:32:07+0000 |
| T2: reviewer_started | norepy@tiendv.dev | 2026-05-17T09:33:02.673Z |
| T1: run_completed | norepy@tiendv.dev | 2026-05-17T09:33:35.002Z |
| T1: reviewer_started | norepy@tiendv.dev | 2026-05-17T09:41:15.253Z |
| T2: reviewer_complete | norepy@tiendv.dev | 2026-05-17T09:41:41.608Z |
| T2: fix_started | norepy@tiendv.dev | 2026-05-17T09:44:59.174Z |
| T3: run_completed | norepy@tiendv.dev | 2026-05-17T09:45:28.412Z |
| T1: done | norepy@tiendv.dev | 2026-05-17T09:46:25.218Z |
| T3: reviewer_started | norepy@tiendv.dev | 2026-05-17T09:48:52.028Z |
| T2: run_completed | norepy@tiendv.dev | 2026-05-17T09:49:50.859Z |
| T2: reviewer_started | norepy@tiendv.dev | 2026-05-17T09:51:41.632Z |
| T3: done | norepy@tiendv.dev | 2026-05-17T09:53:49.829Z |
| T2: done | norepy@tiendv.dev | 2026-05-17T09:58:06.807Z |
| T4: ready | norepy@tiendv.dev | 2026-05-17T09:58:07.083Z |
| T5: ready | norepy@tiendv.dev | 2026-05-17T09:58:07.085Z |
| T4: claimed | norepy@tiendv.dev | 2026-05-17T10:00:03.798Z |
| T4: rag_pre_flight | norepy@tiendv.dev | 2026-05-17T10:00:15.450Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-17T10:00:40.284Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-17T10:00:52.256Z |
| T4: started | norepy@tiendv.dev | 2026-05-17T10:03:22+0000 |
| T5: started | norepy@tiendv.dev | 2026-05-17T10:03:59+0000 |
| T4: run_completed | norepy@tiendv.dev | 2026-05-17T10:09:25.245Z |
| T4: reviewer_started | norepy@tiendv.dev | 2026-05-17T10:11:08.197Z |
| T5: run_completed | norepy@tiendv.dev | 2026-05-17T10:11:37.495Z |
| T5: reviewer_started | norepy@tiendv.dev | 2026-05-17T10:13:11.530Z |
| T4: done | norepy@tiendv.dev | 2026-05-17T10:17:08.517Z |
| T5: done | norepy@tiendv.dev | 2026-05-17T10:19:36.443Z |
| T6: ready | norepy@tiendv.dev | 2026-05-17T10:19:36.722Z |
| T6: claimed | norepy@tiendv.dev | 2026-05-17T10:22:01.729Z |
| T6: rag_pre_flight | norepy@tiendv.dev | 2026-05-17T10:22:13.743Z |
| T6: started | norepy@tiendv.dev | 2026-05-17T10:36:14+0000 |
| T6: run_completed | norepy@tiendv.dev | 2026-05-17T10:50:19.902Z |
| T6: reviewer_started | norepy@tiendv.dev | 2026-05-17T10:52:08.694Z |
| T6: reviewer_complete | norepy@tiendv.dev | 2026-05-17T10:57:57.252Z |
| T6: fix_started | norepy@tiendv.dev | 2026-05-17T10:59:26.848Z |
| T6: run_completed | norepy@tiendv.dev | 2026-05-17T11:14:03.253Z |
| T6: reviewer_started | norepy@tiendv.dev | 2026-05-17T11:14:32.980Z |
| T6: reviewer_complete | norepy@tiendv.dev | 2026-05-17T11:23:07.292Z |
| T6: fix_started | norepy@tiendv.dev | 2026-05-17T11:24:42.831Z |
| T6: run_completed | norepy@tiendv.dev | 2026-05-17T11:29:09.052Z |
| T6: reviewer_started | norepy@tiendv.dev | 2026-05-17T11:30:32.948Z |
| T6: done | norepy@tiendv.dev | 2026-05-17T11:38:25.774Z |
| T1: created | tiendv.52@gmai.com | 2026-05-17T15:49:49+0700 |
| T2: created | tiendv.52@gmai.com | 2026-05-17T15:49:49+0700 |
| T3: created | tiendv.52@gmai.com | 2026-05-17T15:49:49+0700 |
| T4: created | tiendv.52@gmai.com | 2026-05-17T15:49:49+0700 |
| T5: created | tiendv.52@gmai.com | 2026-05-17T15:49:49+0700 |
| T6: created | tiendv.52@gmai.com | 2026-05-17T15:49:49+0700 |