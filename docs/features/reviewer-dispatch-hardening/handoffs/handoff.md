# Handoff — Reviewer dispatch hardening — reviewing status guard + executor env separation

## Summary
## Feature - Feature ID: `reviewer-dispatch-hardening` - Title: Reviewer dispatch hardening — reviewing status guard + executor env separation

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — CLAUDE.md — reviewing status + transitions | [PR](https://github.com/tiendv89/project-workspace/pull/331) | — |
| T2 — ABI types — ExecutorAudit + reviewing in TaskStatus | [PR](https://github.com/tiendv89/agent-workflow/pull/223) | REQUEST_CHANGES — cost_usd must move from ClaudeExecutorAudit to ExecutorAudit top level (executor-agnostic field shared across all executor kinds). Review posted at https://github.com/tiendv89/agent-workflow/pull/223#issuecomment-4532809214 |
| T3 — Log-scan guard removal | [PR](https://github.com/tiendv89/agent-workflow/pull/229) | 🔴 CI failure (vitest unit): TypeScript narrowing error TS2367 in dispatch-reviewer.ts:141 — `reviewing` guard placed after `in_review|review_incomplete` narrowing guard, making it unreachable dead code. Duplicate-claim guard is non-functional. Fix: move `reviewing` check before the `in_review|review_incomplete` guard. |
| T4 — Token/MCP audit — executor_audit propagation | [PR](https://github.com/tiendv89/agent-workflow/pull/226) | — |
| T5 — MAX_TURNS env separation | [PR](https://github.com/tiendv89/agent-workflow/pull/224) | — |
| T6 — Tests — reviewing guard + audit + MAX_TURNS | [PR](https://github.com/tiendv89/agent-workflow/pull/230) | missing_tool |
| T7 — executor_audit — Hermes executor output | [PR](https://github.com/tiendv89/agent-workflow/pull/227) | APPROVE — CI passed. All T7 subtasks implemented. No 🔴/🟡 findings. |
| T8 — openImplPR fallback — derive PR title from task YAML | [PR](https://github.com/tiendv89/agent-workflow/pull/225) | APPROVE — CI passed. All T8 subtasks implemented and tested. No 🔴/🟡 findings. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `CLAUDE.md`
- `docker-compose.platform.yml`
- `docs/features/reviewer-dispatch-hardening/logs/T1/2026-05-25T07-30-01-571Z.jsonl`
- `docs/features/reviewer-dispatch-hardening/tasks/T1.yaml`
- `runtime/abi/docs/abi-spec.md`
- `runtime/abi/src/index.ts`
- `runtime/abi/src/types.ts`
- `runtime/executors/claude/src/executor-audit.test.ts`
- `runtime/executors/claude/src/index.ts`
- `runtime/executors/hermes/src/briefing.test.ts`
- `runtime/executors/hermes/src/briefing.ts`
- `runtime/executors/hermes/src/index.ts`
- `runtime/executors/hermes/src/phase6.test.ts`
- `runtime/orchestrator/docs/OPERATOR-GUIDE.md`
- `runtime/orchestrator/package-lock.json`
- `runtime/orchestrator/src/eligibility/match.ts`
- `runtime/orchestrator/src/main.ts`
- `runtime/orchestrator/src/pr/dispatch-reviewer.ts`
- `runtime/orchestrator/src/task/claim-fix.ts`
- `runtime/orchestrator/src/task/dispatch-review-result.ts`
- `runtime/orchestrator/src/task/dispatch.ts`
- `runtime/orchestrator/src/task/types.ts`
- `runtime/orchestrator/templates/docker-compose.local-docker.yml`
- `runtime/orchestrator/templates/docker-compose.yml`
- `runtime/orchestrator/tests/claim-fix-task.test.ts`
- `runtime/orchestrator/tests/dispatch-controller.test.ts`
- `runtime/orchestrator/tests/dispatch-review-result.test.ts`
- `runtime/orchestrator/tests/dispatch-reviewer.test.ts`
- `runtime/orchestrator/tests/match-branch-state.test.ts`
- `runtime/orchestrator/tests/match.test.ts`
- `runtime/orchestrator/tests/max-turns-env.test.ts`
- `runtime/orchestrator/tests/seam-executor-dispatch.test.ts`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: created | tiendv.52@gmai.com | 2026-05-25T05:35:08Z |
| T2: created | tiendv.52@gmai.com | 2026-05-25T05:35:08Z |
| T3: created | tiendv.52@gmai.com | 2026-05-25T05:35:08Z |
| T4: created | tiendv.52@gmai.com | 2026-05-25T05:35:08Z |
| T5: created | tiendv.52@gmai.com | 2026-05-25T05:35:08Z |
| T6: created | tiendv.52@gmai.com | 2026-05-25T05:35:08Z |
| T1: ready | tiendv.52@gmai.com | 2026-05-25T05:36:28Z |
| T2: ready | tiendv.52@gmai.com | 2026-05-25T05:36:28Z |
| T5: ready | tiendv.52@gmai.com | 2026-05-25T05:36:28Z |
| T1: claimed | norepy@tiendv.dev | 2026-05-25T05:40:25.175Z |
| T1: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T05:40:38.252Z |
| T2: claimed | norepy@tiendv.dev | 2026-05-25T05:42:27.946Z |
| T2: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T05:42:39.885Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-25T05:42:59.262Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T05:43:10.855Z |
| T1: blocked | norepy@tiendv.dev | 2026-05-25T05:43:46.614Z |
| T2: blocked | norepy@tiendv.dev | 2026-05-25T05:45:30.766Z |
| T1: ready | tiendv.52@gmai.com | 2026-05-25T05:50:45Z |
| T2: ready | tiendv.52@gmai.com | 2026-05-25T05:50:45Z |
| T5: ready | tiendv.52@gmai.com | 2026-05-25T05:50:45Z |
| T1: claimed | norepy@tiendv.dev | 2026-05-25T05:52:10.398Z |
| T1: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T05:52:18.146Z |
| T2: claimed | norepy@tiendv.dev | 2026-05-25T05:52:31.459Z |
| T2: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T05:52:37.935Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-25T05:57:44.841Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T05:57:51.443Z |
| T1: blocked | norepy@tiendv.dev | 2026-05-25T05:58:33.942Z |
| T2: blocked | norepy@tiendv.dev | 2026-05-25T06:02:18.841Z |
| T2: claimed | norepy@tiendv.dev | 2026-05-25T06:38:55.542Z |
| T2: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T06:39:01.833Z |
| T2: blocked | norepy@tiendv.dev | 2026-05-25T06:49:37.439Z |
| T1: claimed | norepy@tiendv.dev | 2026-05-25T07:29:45.196Z |
| T1: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T07:29:51.729Z |
| T2: claimed | norepy@tiendv.dev | 2026-05-25T07:36:30.113Z |
| T2: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T07:36:36.361Z |
| T1: run_completed | norepy@tiendv.dev | 2026-05-25T07:37:15.535Z |
| T1: reviewer_started | noreply@tiendv.dev | 2026-05-25T07:48:28.701Z |
| T2: run_completed | norepy@tiendv.dev | 2026-05-25T07:49:02.780Z |
| T2: reviewer_started | noreply@tiendv.dev | 2026-05-25T07:51:04.914Z |
| T1: review_blocked | norepy@tiendv.dev | 2026-05-25T07:51:35.823Z |
| T1: reviewer_started | noreply@tiendv.dev | 2026-05-25T07:56:33.823Z |
| T1: review_blocked | norepy@tiendv.dev | 2026-05-25T07:59:05.281Z |
| T1: reviewer_started | noreply@tiendv.dev | 2026-05-25T08:01:02.508Z |
| T1: review_blocked | norepy@tiendv.dev | 2026-05-25T08:03:35.827Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-25T08:11:24.771Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T08:11:30.879Z |
| T5: run_completed | norepy@tiendv.dev | 2026-05-25T08:24:52.450Z |
| T5: reviewer_started | noreply@tiendv.dev | 2026-05-25T08:26:52.607Z |
| T2: fix_started | norepy@tiendv.dev | 2026-05-25T08:41:26.462Z |
| T8: claimed | norepy@tiendv.dev | 2026-05-25T08:50:53.446Z |
| T8: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T08:51:05.985Z |
| T2: run_completed | norepy@tiendv.dev | 2026-05-25T08:51:41.913Z |
| T5: done | norepy@tiendv.dev | 2026-05-25T09:01:49.159Z |
| T2: reviewer_started | noreply@tiendv.dev | 2026-05-25T09:12:19.189Z |
| T8: blocked | norepy@tiendv.dev | 2026-05-25T09:12:48.685Z |
| T8: claimed | norepy@tiendv.dev | 2026-05-25T09:26:11.911Z |
| T8: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T09:26:20.159Z |
| T8: claimed | norepy@tiendv.dev | 2026-05-25T09:37:24.875Z |
| T8: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T09:37:31.769Z |
| T2: done | norepy@tiendv.dev | 2026-05-25T09:50:22.957Z |
| T3: ready | norepy@tiendv.dev | 2026-05-25T09:50:23.265Z |
| T4: ready | norepy@tiendv.dev | 2026-05-25T09:50:23.268Z |
| T8: run_completed | norepy@tiendv.dev | 2026-05-25T09:51:17.906Z |
| T3: claimed | norepy@tiendv.dev | 2026-05-25T09:53:01.386Z |
| T3: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T09:53:13.691Z |
| T4: claimed | pentative@gmail.com | 2026-05-25T10:03:25.305Z |
| T4: rag_pre_flight | pentative@gmail.com | 2026-05-25T10:03:35.392Z |
| T8: reviewer_started | noreply@anthropic.com | 2026-05-25T10:03:39.863Z |
| T4: started | pentative@gmail.com | 2026-05-25T10:09:00+0000 |
| T3: blocked | norepy@tiendv.dev | 2026-05-25T10:10:37.704Z |
| T8: reviewer_complete | pentative@gmail.com | 2026-05-25T10:12:35.121Z |
| T8: fix_started | pentative@gmail.com | 2026-05-25T10:14:26.074Z |
| T8: run_completed | pentative@gmail.com | 2026-05-25T10:19:11.163Z |
| T8: reviewer_started | noreply@anthropic.com | 2026-05-25T10:21:05.400Z |
| T4: run_completed | pentative@gmail.com | 2026-05-25T10:23:33.304Z |
| T4: reviewer_started | noreply@anthropic.com | 2026-05-25T10:25:29.875Z |
| T8: reviewer_complete | noreply@anthropic.com | 2026-05-25T10:29:25+0000 |
| T3: claimed | norepy@tiendv.dev | 2026-05-25T10:31:05.891Z |
| T3: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T10:31:13.968Z |
| T8: fix_started | pentative@gmail.com | 2026-05-25T10:31:24.908Z |
| T8: reviewer_complete | pentative@gmail.com | 2026-05-25T10:32:30.905Z |
| T8: fix_started | pentative@gmail.com | 2026-05-25T10:34:19.194Z |
| T8: run_completed | pentative@gmail.com | 2026-05-25T10:37:31.133Z |
| T8: reviewer_started | noreply@anthropic.com | 2026-05-25T10:39:25.506Z |
| T8: reviewer_complete | tiendv89 | 2026-05-25T10:44:00Z |
| T8: run_completed | pentative@gmail.com | 2026-05-25T10:50:07.691Z |
| T3: blocked | norepy@tiendv.dev | 2026-05-25T10:52:40.591Z |
| T4: done | pentative@gmail.com | 2026-05-25T10:57:29.966Z |
| T7: ready | pentative@gmail.com | 2026-05-25T10:57:29.994Z |
| T7: claimed | pentative@gmail.com | 2026-05-25T10:58:32.837Z |
| T7: rag_pre_flight | pentative@gmail.com | 2026-05-25T10:58:42.367Z |
| T7: started | pentative@gmail.com | 2026-05-25T11:03:43+0000 |
| T8: rebase_completed | norepy@tiendv.dev | 2026-05-25T11:06:32.875Z |
| T7: run_completed | pentative@gmail.com | 2026-05-25T11:12:45.464Z |
| T3: claimed | norepy@tiendv.dev | 2026-05-25T12:23:43.025Z |
| T3: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T12:23:49.113Z |
| T3: run_completed | norepy@tiendv.dev | 2026-05-25T12:37:40.174Z |
| T3: reviewer_started | noreply@tiendv.dev | 2026-05-25T12:39:42.472Z |
| T3: reviewer_complete | norepy@tiendv.dev | 2026-05-25T12:46:45.717Z |
| T3: fix_started | norepy@tiendv.dev | 2026-05-25T12:48:26.105Z |
| T3: run_completed | norepy@tiendv.dev | 2026-05-25T13:01:09.920Z |
| T3: reviewer_started | noreply@tiendv.dev | 2026-05-25T13:03:12.187Z |
| T7: reviewer_started | noreply@tiendv.dev | 2026-05-25T13:11:20.325Z |
| T2: ready | matthew@swellnetwork.io | 2026-05-25T13:37:48+0700 |
| T1: ready | matthew@swellnetwork.io | 2026-05-25T14:27:44+0700 |
| T2: ready | matthew@swellnetwork.io | 2026-05-25T14:30:39+0700 |
| T7: created | matthew@swellnetwork.io | 2026-05-25T14:50:39+0700 |
| T5: ready | matthew@swellnetwork.io | 2026-05-25T15:09:33+0700 |
| T2: reviewer_complete | matthew@swellnetwork.io | 2026-05-25T15:39:50+0700 |
| T8: created | matthew@swellnetwork.io | 2026-05-25T15:41:44+0700 |
| T8: ready | matthew@swellnetwork.io | 2026-05-25T15:41:44+0700 |
| T3: done | norepy@tiendv.dev | 2026-05-25T16:16:06.593Z |
| T8: ready | matthew@swellnetwork.io | 2026-05-25T16:20:39+0700 |
| T8: ready | matthew@swellnetwork.io | 2026-05-25T16:23:00+0700 |
| T7: reviewer_complete | matthew@swellnetwork.io | 2026-05-25T16:31:00Z |
| T6: claimed | norepy@tiendv.dev | 2026-05-25T17:13:12.784Z |
| T6: rag_pre_flight | norepy@tiendv.dev | 2026-05-25T17:13:25.355Z |
| T3: ready | matthew@swellnetwork.io | 2026-05-25T17:17:00+0700 |
| T6: run_completed | norepy@tiendv.dev | 2026-05-25T17:29:55.363Z |
| T6: reviewer_started | noreply@tiendv.dev | 2026-05-25T17:31:53.717Z |
| T6: reviewer_complete | norepy@tiendv.dev | 2026-05-25T17:40:56.881Z |
| T6: fix_started | norepy@tiendv.dev | 2026-05-25T17:42:36.392Z |
| T6: run_completed | norepy@tiendv.dev | 2026-05-25T17:55:08.132Z |
| T6: reviewer_started | noreply@tiendv.dev | 2026-05-25T18:13:16.922Z |
| T6: reviewer_complete | norepy@tiendv.dev | 2026-05-25T18:17:09.653Z |
| T6: done | norepy@tiendv.dev | 2026-05-25T18:52:45.604Z |
| T3: ready | matthew@swellnetwork.io | 2026-05-25T19:21:00+0700 |
| T8: done | matthew@swellnetwork.io | 2026-05-25T20:05:09+0700 |
| T7: done | matthew@swellnetwork.io | 2026-05-26T00:01:01+0700 |
| T1: done | matthew@swellnetwork.io | 2026-05-26T00:11:17+0700 |
| T6: ready | matthew@swellnetwork.io | 2026-05-26T00:12:05+0700 |
| T6: unblocked | matthew@swellnetwork.io | 2026-05-26T01:37:56+0700 |
| T6: unblocked | matthew@swellnetwork.io | 2026-05-26T01:50:43+0700 |