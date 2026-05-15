# Handoff — Executor-owned briefing — move prompt construction out of the orchestrator

## Summary
## Feature - Feature ID: `executor-self-briefing` - Title: Executor-owned briefing — move prompt construction out of the orchestrator

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — ABI contract — remove briefingPath | [PR](https://github.com/tiendv89/agent-workflow/pull/154) | — |
| T2 — Orchestrator — delete briefing module | [PR](https://github.com/tiendv89/agent-workflow/pull/156) | Human reset to change_requested. Previous fix executor looped without fixing CI — it took the no-comment fast path and declared success without deleting the stale test block. CI still failing on PR #156. Fix: delete the 'briefing references prUrl and resultPath' describe block in tests/dispatch-reviewer.test.ts. |
| T3 — Adapters — remove BRIEFING_PATH env | [PR](https://github.com/tiendv89/agent-workflow/pull/155) | Review cycle limit reached. Human review required. |
| T4 — Claude executor — self-briefing module | [PR](https://github.com/tiendv89/agent-workflow/pull/157) | Review cycle limit reached (cycle 3 of 3, MAX_REVIEW_CYCLES=3). Human review required. |
| T5 — Tests — delete, update, and add | [PR](https://github.com/tiendv89/agent-workflow/pull/163) | Code quality APPROVED — all T5 subtasks implemented correctly. Merge blocked: PR has merge conflicts (GitHub HTTP 405 'Pull Request has merge conflicts', pre-check mergeable=false/dirty). Branch must be rebased onto base branch before merge can proceed. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `runtime/abi/docs/abi-spec.md`
- `runtime/abi/src/fake-ports.ts`
- `runtime/abi/src/index.ts`
- `runtime/abi/src/ports.ts`
- `runtime/abi/src/types.ts`
- `runtime/abi/tests/fake-ports.test.ts`
- `runtime/executors/claude/src/briefing/agent-context.ts`
- `runtime/executors/claude/src/briefing/briefing-template.ts`
- `runtime/executors/claude/src/briefing/fix-briefing.ts`
- `runtime/executors/claude/src/briefing/index.ts`
- `runtime/executors/claude/src/briefing/rebase-briefing.ts`
- `runtime/executors/claude/src/briefing/reviewer-briefing.ts`
- `runtime/executors/claude/src/flush-log.ts`
- `runtime/executors/claude/src/git-env.ts`
- `runtime/executors/claude/src/index.ts`
- `runtime/executors/claude/tests/briefing/agent-context.test.ts`
- `runtime/executors/claude/tests/briefing/fix-briefing.test.ts`
- `runtime/executors/claude/tests/briefing/rebase-briefing.test.ts`
- `runtime/executors/claude/tests/briefing/reviewer-briefing.test.ts`
- `runtime/executors/claude/vitest.config.ts`
- `runtime/orchestrator/src/adapters/briefing/local-file.ts`
- `runtime/orchestrator/src/adapters/executor/docker-run.ts`
- `runtime/orchestrator/src/adapters/executor/subprocess.ts`
- `runtime/orchestrator/src/adapters/index.ts`
- `runtime/orchestrator/src/briefing/agent-context.ts`
- `runtime/orchestrator/src/briefing/briefing-template.ts`
- `runtime/orchestrator/src/briefing/fix-briefing.ts`
- `runtime/orchestrator/src/briefing/reviewer-briefing.ts`
- `runtime/orchestrator/src/briefing/write-briefing.ts`
- `runtime/orchestrator/src/main.ts`
- `runtime/orchestrator/src/pr-response/dispatch-reviewer.ts`
- `runtime/orchestrator/src/profiles/local-docker.ts`
- `runtime/orchestrator/src/profiles/local-subprocess.ts`
- `runtime/orchestrator/src/runtime-ports.ts`
- `runtime/orchestrator/src/utils/task-yaml-io.ts`
- `runtime/orchestrator/tests/adapters.test.ts`
- `runtime/orchestrator/tests/agent-context.test.ts`
- `runtime/orchestrator/tests/dispatch-controller.test.ts`
- `runtime/orchestrator/tests/dispatch-review-result.test.ts`
- `runtime/orchestrator/tests/dispatch-reviewer.test.ts`
- `runtime/orchestrator/tests/fix-briefing.test.ts`
- `runtime/orchestrator/tests/reviewer-briefing.test.ts`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: ready | tiendv.52@gmai.com | 2026-05-14T10:18:42Z |
| T1: claimed | norepy@tiendv.dev | 2026-05-14T10:23:24.069Z |
| T1: rag_pre_flight | norepy@tiendv.dev | 2026-05-14T10:23:38.438Z |
| T1: started | norepy@tiendv.dev | 2026-05-14T10:29:24+0000 |
| T1: run_completed | norepy@tiendv.dev | 2026-05-14T10:51:05.305Z |
| T1: reviewer_started | norepy@tiendv.dev | 2026-05-14T10:52:23.998Z |
| T1: done | norepy@tiendv.dev | 2026-05-14T10:57:13.754Z |
| T2: ready | norepy@tiendv.dev | 2026-05-14T10:57:13.965Z |
| T3: ready | norepy@tiendv.dev | 2026-05-14T10:57:13.967Z |
| T4: ready | norepy@tiendv.dev | 2026-05-14T10:57:13.969Z |
| T2: claimed | norepy@tiendv.dev | 2026-05-14T10:58:44.266Z |
| T2: rag_pre_flight | norepy@tiendv.dev | 2026-05-14T10:58:56.991Z |
| T3: claimed | norepy@tiendv.dev | 2026-05-14T10:59:10.813Z |
| T3: rag_pre_flight | norepy@tiendv.dev | 2026-05-14T10:59:22.793Z |
| T3: started | norepy@tiendv.dev | 2026-05-14T11:01:59+0000 |
| T2: started | norepy@tiendv.dev | 2026-05-14T11:02:09+0000 |
| T4: claimed | norepy@tiendv.dev | 2026-05-14T11:32:51.833Z |
| T4: rag_pre_flight | norepy@tiendv.dev | 2026-05-14T11:33:28.323Z |
| T2: retried | norepy@tiendv.dev | 2026-05-14T11:34:47.859Z |
| T3: run_completed | norepy@tiendv.dev | 2026-05-14T11:35:26.929Z |
| T2: claimed | norepy@tiendv.dev | 2026-05-14T11:36:17.651Z |
| T3: reviewer_started | norepy@tiendv.dev | 2026-05-14T11:51:04.785Z |
| T3: reviewer_complete | norepy@tiendv.dev | 2026-05-14T11:58:46.147Z |
| T3: fix_started | norepy@tiendv.dev | 2026-05-14T12:00:19.724Z |
| T3: comments_addressed | norepy@tiendv.dev | 2026-05-14T12:02:25+0000 |
| T3: reviewer_started | norepy@tiendv.dev | 2026-05-14T12:08:18.343Z |
| T3: run_completed | norepy@tiendv.dev | 2026-05-14T12:08:53.938Z |
| T3: reviewer_started | norepy@tiendv.dev | 2026-05-14T12:15:20.832Z |
| T3: reviewer_complete | norepy@tiendv.dev | 2026-05-14T12:15:45.629Z |
| T3: fix_started | norepy@tiendv.dev | 2026-05-14T12:19:51.072Z |
| T3: reviewer_complete | norepy@tiendv.dev | 2026-05-14T12:20:17.642Z |
| T3: comments_addressed | norepy@tiendv.dev | 2026-05-14T12:22:04+0000 |
| T3: run_completed | norepy@tiendv.dev | 2026-05-14T12:28:09.449Z |
| T4: run_completed | norepy@tiendv.dev | 2026-05-14T13:07:28.578Z |
| T4: reviewer_started | norepy@tiendv.dev | 2026-05-14T13:09:27.010Z |
| T4: reviewer_complete | norepy@tiendv.dev | 2026-05-14T13:15:15.493Z |
| T4: fix_started | norepy@tiendv.dev | 2026-05-14T13:16:55.931Z |
| T4: comments_addressed | norepy@tiendv.dev | 2026-05-14T13:23:02+0000 |
| T4: run_completed | norepy@tiendv.dev | 2026-05-14T13:28:59.930Z |
| T4: reviewer_started | norepy@tiendv.dev | 2026-05-14T13:31:06.419Z |
| T4: reviewer_complete | norepy@tiendv.dev | 2026-05-14T13:39:24.302Z |
| T4: fix_started | norepy@tiendv.dev | 2026-05-14T13:40:59.677Z |
| T4: comments_addressed | norepy@tiendv.dev | 2026-05-14T13:42:32+0000 |
| T4: run_completed | norepy@tiendv.dev | 2026-05-14T13:47:13.884Z |
| T2: claimed | norepy@tiendv.dev | 2026-05-14T13:49:00.422Z |
| T2: rag_pre_flight | norepy@tiendv.dev | 2026-05-14T13:49:10.368Z |
| T4: reviewer_started | norepy@tiendv.dev | 2026-05-14T13:52:38.073Z |
| T4: reviewer_complete | norepy@tiendv.dev | 2026-05-14T14:06:26.006Z |
| T2: run_completed | norepy@tiendv.dev | 2026-05-14T14:37:20.831Z |
| T2: reviewer_started | norepy@tiendv.dev | 2026-05-14T14:43:56.807Z |
| T2: reviewer_complete | norepy@tiendv.dev | 2026-05-14T15:13:51.471Z |
| T2: fix_started | norepy@tiendv.dev | 2026-05-14T15:20:35.110Z |
| T2: comments_addressed | norepy@tiendv.dev | 2026-05-14T15:26:15+0000 |
| T2: fix_started | norepy@tiendv.dev | 2026-05-14T16:41:06.753Z |
| T2: comments_addressed | norepy@tiendv.dev | 2026-05-14T16:47:33+0000 |
| T2: run_completed | norepy@tiendv.dev | 2026-05-14T16:50:04.867Z |
| T2: reviewer_started | norepy@tiendv.dev | 2026-05-14T16:51:34.184Z |
| T2: done | norepy@tiendv.dev | 2026-05-14T16:56:35.342Z |
| T1: created | tiendv.52@gmai.com | 2026-05-14T17:15:48+0700 |
| T2: created | tiendv.52@gmai.com | 2026-05-14T17:15:48+0700 |
| T3: created | tiendv.52@gmai.com | 2026-05-14T17:15:48+0700 |
| T4: created | tiendv.52@gmai.com | 2026-05-14T17:15:48+0700 |
| T5: created | tiendv.52@gmai.com | 2026-05-14T17:15:48+0700 |
| T5: claimed | norepy@tiendv.dev | 2026-05-14T17:28:40.290Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-14T17:28:53.065Z |
| T5: started | norepy@tiendv.dev | 2026-05-14T17:31:05+0000 |
| T5: retried | norepy@tiendv.dev | 2026-05-14T17:46:32.137Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-14T17:47:50.586Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-14T17:47:56.748Z |
| T5: retried | norepy@tiendv.dev | 2026-05-14T17:50:30.921Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-14T17:51:48.916Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-14T17:51:55.119Z |
| T5: retried | norepy@tiendv.dev | 2026-05-14T17:54:29.174Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-14T17:55:47.331Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-14T17:55:53.766Z |
| T5: blocked | norepy@tiendv.dev | 2026-05-14T17:58:32.197Z |
| T2: ready | matthew@swellnetwork.io | 2026-05-14T20:46:06+0700 |
| T2: reviewer_complete | matthew@swellnetwork.io | 2026-05-14T23:32:57+0700 |
| T3: done | matthew@swellnetwork.io | 2026-05-15T00:17:40+0700 |
| T4: done | matthew@swellnetwork.io | 2026-05-15T00:26:11+0700 |
| T5: ready | matthew@swellnetwork.io | 2026-05-15T00:26:11+0700 |
| T5: claimed | norepy@tiendv.dev | 2026-05-15T07:30:31.049Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-15T07:30:38.895Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-15T07:35:23.832Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-15T07:35:32.250Z |
| T5: started | norepy@tiendv.dev | 2026-05-15T07:54:18+0000 |
| T5: blocked | norepy@tiendv.dev | 2026-05-15T07:58:46.972Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-15T08:21:08.159Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-15T08:21:14.606Z |
| T5: started | norepy@tiendv.dev | 2026-05-15T08:33:34+0000 |
| T5: run_completed | norepy@tiendv.dev | 2026-05-15T08:41:40.485Z |
| T5: reviewer_started | norepy@tiendv.dev | 2026-05-15T08:43:20.759Z |
| T5: reviewer_complete | norepy@tiendv.dev | 2026-05-15T08:51:45.890Z |
| T5: fix_started | norepy@tiendv.dev | 2026-05-15T08:53:07.587Z |
| T5: comments_addressed | norepy@tiendv.dev | 2026-05-15T09:16:45+0000 |
| T5: run_completed | norepy@tiendv.dev | 2026-05-15T09:19:31.856Z |
| T5: reviewer_started | norepy@tiendv.dev | 2026-05-15T09:21:11.082Z |
| T5: done | norepy@tiendv.dev | 2026-05-15T09:24:46.330Z |
| T5: done | norepy@tiendv.dev | 2026-05-15T09:26:43.229Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-15T10:00:45.648Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-15T10:00:59.209Z |
| T5: started | norepy@tiendv.dev | 2026-05-15T10:10:05+0000 |
| T5: run_completed | norepy@tiendv.dev | 2026-05-15T10:29:26.934Z |
| T5: done | norepy@tiendv.dev | 2026-05-15T10:30:55.380Z |
| T5: ready | matthew@swellnetwork.io | 2026-05-15T14:29:01+0700 |
| T5: ready | matthew@swellnetwork.io | 2026-05-15T14:33:41+0700 |
| T5: ready | matthew@swellnetwork.io | 2026-05-15T15:19:05+0700 |
| T5: ready | matthew@swellnetwork.io | 2026-05-15T16:54:35+0700 |