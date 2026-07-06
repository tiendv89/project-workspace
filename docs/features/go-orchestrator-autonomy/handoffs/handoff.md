# Handoff — Go Orchestrator — Autonomous Parity (reviewer cycle, handoff, error recovery, unblock)

## Summary
## Feature - Feature ID: `go-orchestrator-autonomy` - Title: Go Orchestrator — Autonomous Parity (reviewer cycle, handoff, error recovery, unblock)

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — Schema migration — workspace_tasks columns + handoffs/handoff_prs + indexes | [PR](https://github.com/tiendv89/workflow-backend/pull/51) | Reviewer approved. |
| T10 — Unblock bff proxy | [PR](https://github.com/tiendv89/workflow-bff/pull/9) | Reviewer approved. |
| T11 — unblock_task MCP tool | [PR](https://github.com/batu4404/workflow-mcp/pull/6) | Recovering stuck task state: GitHub shows an APPROVE review was posted on PR #6 (batu4404/workflow-mcp) at 2026-07-01T16:48:50Z ("All subtasks implemented. Tests/build/lint pass. APPROVE."), and the human merged PR #6 directly at 2026-07-01T16:49:07Z — but the task file was never updated past reviewer_started. Recording the verdict here for the audit trail before closing out. |
| T12 — Feature lifecycle — in_implementation, handoff trigger, handoff-PR rebase, finalize | [PR](https://github.com/tiendv89/workflow-orchestrator/pull/25) | Reviewer approved. |
| T13 — unblock-task agent skill | [PR](https://github.com/tiendv89/agent-workflow/pull/276) | Reviewer approved. |
| T14 — Soft-claim throttle (derived in-flight) + cycle ordering | [PR](https://github.com/tiendv89/workflow-orchestrator/pull/26) | Reviewer approved. |
| T15 — E2E autonomous-run test (parallel with a legacy TS feature) | [PR](https://github.com/tiendv89/workflow-orchestrator/pull/27) | Reviewer approved. |
| T2 — Adapter owner-scope — stop clobbering go feature_status | [PR](https://github.com/tiendv89/workspace-github-adapter/pull/31) | Reviewer approved. |
| T3 — Orchestrator README/AGENTS — state-machine reference | [PR](https://github.com/tiendv89/workflow-orchestrator/pull/19) | Reviewer approved. |
| T4 — Unblock API endpoint | [PR](https://github.com/tiendv89/workflow-backend/pull/52) | Reviewer approved. |
| T5 — Orchestrator DB foundation — mirror schema.sql + sqlc models | [PR](https://github.com/tiendv89/workflow-orchestrator/pull/20) | Reviewer approved. |
| T6 — Error/stuck recovery — reconciler, DLQ-failed reap, redis, max-turns | [PR](https://github.com/tiendv89/workflow-orchestrator/pull/22) | Reviewer approved. |
| T7 — Reviewer cluster — dispatch, verdict routing, fix loop, review_incomplete | [PR](https://github.com/tiendv89/workflow-orchestrator/pull/24) | Reviewer approved. |
| T8 — Conflict resolution — conflict_state, rebase, cap, merged-is-truth, terminal guard | [PR](https://github.com/tiendv89/workflow-orchestrator/pull/23) | Reviewer approved. |
| T9 — blocked_from_status recording + unblock-resume handling | [PR](https://github.com/tiendv89/workflow-orchestrator/pull/21) | Reviewer approved. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `AGENTS.md`
- `README.md`
- `claude/workflow_skills/unblock-task/SKILL.md`
- `cmd/orchestrator/main.go`
- `cmd/orchestrator/main_test.go`
- `database/queries/workspace_features.sql`
- `db/queries/handoff_prs.sql`
- `db/queries/handoffs.sql`
- `db/queries/tasks.sql`
- `db/schema/schema.sql`
- `db/testdata/schema.sql`
- `internal/adapter/db/adapter_test.go`
- `internal/app/api/handler/proxy/proxy_handler_test.go`
- `internal/app/api/handler/proxy/routing_test.go`
- `internal/app/api/response/http_response.go`
- `internal/config/config.go`
- `internal/config/config_test.go`
- `internal/database/migrate_test.go`
- `internal/database/models.go`
- `internal/database/queries.go`
- `internal/database/queries/handoff_prs.sql.go`
- `internal/database/queries/handoffs.sql.go`
- `internal/database/queries/models.go`
- `internal/database/queries/tasks.sql.go`
- `internal/database/queries_test.go`
- `internal/database/reader_integration_test.go`
- `internal/database/workspace_features.sql.go`
- `internal/domain/dto.go`
- `internal/domain/errors.go`
- `internal/github/client.go`
- `internal/github/client_test.go`
- `internal/handler/workspace.go`
- `internal/handler/workspace_test.go`
- `internal/orchestrator/blocked_from_status_test.go`
- `internal/orchestrator/conflict.go`
- `internal/orchestrator/conflict_test.go`
- `internal/orchestrator/dispatch.go`
- `internal/orchestrator/dispatch_test.go`
- `internal/orchestrator/eligibility.go`
- `internal/orchestrator/feature_lifecycle.go`
- `internal/orchestrator/feature_lifecycle_test.go`
- `internal/orchestrator/handle_store.go`
- `internal/orchestrator/handoff_pr.go`
- `internal/orchestrator/pr_merge_poll.go`
- `internal/orchestrator/reap.go`
- `internal/orchestrator/reap_test.go`
- `internal/orchestrator/reconciler.go`
- `internal/orchestrator/reconciler_test.go`
- `internal/orchestrator/reviewer.go`
- `internal/orchestrator/reviewer_integration_test.go`
- `internal/orchestrator/reviewer_test.go`
- `internal/orchestrator/throttle.go`
- `internal/orchestrator/throttle_test.go`
- `internal/orchestrator/transitions.go`
- `internal/orchestrator/transitions_test.go`
- `internal/service/workspace.go`
- `internal/service/workspace_test.go`
- `migrations/00019_go_orchestrator_autonomy.sql`
- `pkg/testhelpers/fixtures.go`
- `src/tools.test.ts`
- `src/tools.ts`
- `test/e2e/coexistence_test.go`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: ready | batu4404@gmail.com | 2026-07-01 07:59:02+00:00 |
| T3: ready | batu4404@gmail.com | 2026-07-01 07:59:02+00:00 |
| T1: claimed | tiendv.52@gmail.com | 2026-07-01 08:18:34.878000+00:00 |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01 08:18:43.309000+00:00 |
| T3: claimed | tiendv.52@gmail.com | 2026-07-01 08:21:23.447000+00:00 |
| T3: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01 08:21:31.452000+00:00 |
| T7: ready | tiendv.52@gmail.com | 2026-07-01 09:33:27.437000+00:00 |
| T7: claimed | tiendv.52@gmail.com | 2026-07-01 09:36:12.853000+00:00 |
| T7: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01 09:36:21.153000+00:00 |
| T2: ready | batu4404@gmail.com | 2026-07-01T07:59:02Z |
| T2: claimed | tiendv.52@gmail.com | 2026-07-01T08:19:56.836Z |
| T2: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T08:20:05.218Z |
| T2: started | tiendv.52@gmail.com | 2026-07-01T08:23:26+0000 |
| T3: started | tiendv.52@gmail.com | 2026-07-01T08:24:27+0000 |
| T1: started | tiendv.52@gmail.com | 2026-07-01T08:24:39+0000 |
| T3: run_completed | tiendv.52@gmail.com | 2026-07-01T08:38:13.126Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-07-01T08:40:12.002Z |
| T2: run_completed | tiendv.52@gmail.com | 2026-07-01T08:46:53.804Z |
| T2: reviewer_started | tiendv.52@gmail.com | 2026-07-01T08:47:56.617Z |
| T1: run_completed | tiendv.52@gmail.com | 2026-07-01T08:49:20.420Z |
| T1: reviewer_started | tiendv.52@gmail.com | 2026-07-01T08:50:23.327Z |
| T2: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T08:53:54.709Z |
| T2: done | tiendv.52@gmail.com | 2026-07-01T08:54:53.333Z |
| T1: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T08:55:20.618Z |
| T1: done | tiendv.52@gmail.com | 2026-07-01T08:56:24.160Z |
| T4: ready | tiendv.52@gmail.com | 2026-07-01T08:56:24.290Z |
| T5: ready | tiendv.52@gmail.com | 2026-07-01T08:56:24.292Z |
| T4: claimed | tiendv.52@gmail.com | 2026-07-01T08:57:40.120Z |
| T4: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T08:57:47.985Z |
| T5: claimed | tiendv.52@gmail.com | 2026-07-01T08:59:03.041Z |
| T5: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T08:59:11.669Z |
| T5: started | tiendv.52@gmail.com | 2026-07-01T09:06:19+0000 |
| T5: run_completed | tiendv.52@gmail.com | 2026-07-01T09:24:12.642Z |
| T5: reviewer_started | tiendv.52@gmail.com | 2026-07-01T09:25:41.855Z |
| T4: run_completed | tiendv.52@gmail.com | 2026-07-01T09:28:00.244Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-07-01T09:29:04.313Z |
| T5: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T09:32:26.708Z |
| T5: done | tiendv.52@gmail.com | 2026-07-01T09:33:27.311Z |
| T6: ready | tiendv.52@gmail.com | 2026-07-01T09:33:27.436Z |
| T8: ready | tiendv.52@gmail.com | 2026-07-01T09:33:27.439Z |
| T9: ready | tiendv.52@gmail.com | 2026-07-01T09:33:27.440Z |
| T6: claimed | tiendv.52@gmail.com | 2026-07-01T09:34:42.059Z |
| T6: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T09:34:50.151Z |
| T4: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T09:35:06.522Z |
| T8: claimed | tiendv.52@gmail.com | 2026-07-01T09:37:33.438Z |
| T8: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T09:37:41.268Z |
| T9: claimed | tiendv.52@gmail.com | 2026-07-01T09:38:54.207Z |
| T9: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T09:39:02.609Z |
| T4: fix_started | tiendv.52@gmail.com | 2026-07-01T09:40:20.183Z |
| T7: started | tiendv.52@gmail.com | 2026-07-01T09:41:39+0000 |
| T8: started | tiendv.52@gmail.com | 2026-07-01T09:44:58+0000 |
| T9: run_completed | tiendv.52@gmail.com | 2026-07-01T10:01:28.593Z |
| T6: run_completed | tiendv.52@gmail.com | 2026-07-01T10:04:53.954Z |
| T6: reviewer_started | tiendv.52@gmail.com | 2026-07-01T10:08:40.690Z |
| T9: reviewer_started | tiendv.52@gmail.com | 2026-07-01T10:10:43.660Z |
| T6: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T10:17:40.965Z |
| T6: fix_started | tiendv.52@gmail.com | 2026-07-01T10:18:58.523Z |
| T9: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T10:19:23.606Z |
| T9: done | tiendv.52@gmail.com | 2026-07-01T10:20:32.733Z |
| T6: run_completed | tiendv.52@gmail.com | 2026-07-01T10:27:22.978Z |
| T6: rebase_completed | tiendv.52@gmail.com | 2026-07-01T10:38:52.011Z |
| T6: reviewer_started | tiendv.52@gmail.com | 2026-07-01T10:40:01.332Z |
| T6: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T10:46:40.504Z |
| T6: done | tiendv.52@gmail.com | 2026-07-01T10:47:55.852Z |
| T1: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T10: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T11: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T12: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T13: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T14: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T15: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T2: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T3: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T4: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T5: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T6: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T7: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T8: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T9: created | batu4404@gmail.com | 2026-07-01T14:54:39+0700 |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-07-01T15:11:02.625Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-07-01T15:14:39.237Z |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T15:16:02.417Z |
| T3: done | tiendv.52@gmail.com | 2026-07-01T15:17:09.072Z |
| T4: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T15:21:15.064Z |
| T4: done | tiendv.52@gmail.com | 2026-07-01T15:22:23.434Z |
| T10: ready | tiendv.52@gmail.com | 2026-07-01T15:22:23.563Z |
| T11: ready | tiendv.52@gmail.com | 2026-07-01T15:22:23.564Z |
| T10: claimed | tiendv.52@gmail.com | 2026-07-01T15:23:46.020Z |
| T10: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T15:23:54.353Z |
| T11: claimed | tiendv.52@gmail.com | 2026-07-01T15:25:14.973Z |
| T11: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T15:25:22.867Z |
| T10: started | tiendv.52@gmail.com | 2026-07-01T15:26:39+0000 |
| T11: run_completed | tiendv.52@gmail.com | 2026-07-01T15:36:04.546Z |
| T11: reviewer_started | tiendv.52@gmail.com | 2026-07-01T15:37:17.232Z |
| T10: run_completed | tiendv.52@gmail.com | 2026-07-01T15:37:46.379Z |
| T10: reviewer_started | tiendv.52@gmail.com | 2026-07-01T15:38:57.051Z |
| T10: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T15:42:43.948Z |
| T10: done | tiendv.52@gmail.com | 2026-07-01T15:43:49.822Z |
| T7: reviewer_started | tiendv.52@gmail.com | 2026-07-01T15:58:22.244Z |
| T7: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T16:06:03.661Z |
| T7: done | tiendv.52@gmail.com | 2026-07-01T16:07:09.598Z |
| T8: reviewer_started | tiendv.52@gmail.com | 2026-07-01T16:45:43.527Z |
| T8: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T16:56:34.491Z |
| T8: fix_started | tiendv.52@gmail.com | 2026-07-01T16:57:32.277Z |
| T8: run_completed | tiendv.52@gmail.com | 2026-07-01T17:14:24.087Z |
| T8: reviewer_started | tiendv.52@gmail.com | 2026-07-01T17:15:37.233Z |
| T8: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T17:24:34.385Z |
| T8: fix_started | tiendv.52@gmail.com | 2026-07-01T17:25:34.392Z |
| T8: run_completed | tiendv.52@gmail.com | 2026-07-01T17:34:47.259Z |
| T8: reviewer_started | tiendv.52@gmail.com | 2026-07-01T17:35:57.414Z |
| T8: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T17:43:14.919Z |
| T8: done | tiendv.52@gmail.com | 2026-07-01T17:44:25.204Z |
| T12: ready | tiendv.52@gmail.com | 2026-07-01T17:44:25.364Z |
| T12: claimed | tiendv.52@gmail.com | 2026-07-01T17:45:53.645Z |
| T12: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T17:46:02.815Z |
| T12: started | tiendv.52@gmail.com | 2026-07-01T17:53:22+0000 |
| T12: run_completed | tiendv.52@gmail.com | 2026-07-01T18:15:51.081Z |
| T12: reviewer_started | tiendv.52@gmail.com | 2026-07-01T18:17:01.395Z |
| T12: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T18:21:54.964Z |
| T12: fix_started | tiendv.52@gmail.com | 2026-07-01T18:22:54.391Z |
| T12: run_completed | tiendv.52@gmail.com | 2026-07-01T18:41:04.563Z |
| T12: reviewer_started | tiendv.52@gmail.com | 2026-07-01T18:42:16.001Z |
| T12: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T18:51:11.359Z |
| T12: fix_started | tiendv.52@gmail.com | 2026-07-01T18:52:13.171Z |
| T12: run_completed | tiendv.52@gmail.com | 2026-07-01T18:57:30.641Z |
| T12: reviewer_started | tiendv.52@gmail.com | 2026-07-01T18:58:40.675Z |
| T12: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T19:06:25.633Z |
| T12: done | tiendv.52@gmail.com | 2026-07-01T19:07:34.016Z |
| T14: ready | tiendv.52@gmail.com | 2026-07-01T19:07:34.150Z |
| T14: claimed | tiendv.52@gmail.com | 2026-07-01T19:08:59.855Z |
| T14: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T19:09:08.364Z |
| T14: run_completed | tiendv.52@gmail.com | 2026-07-01T19:25:15.423Z |
| T14: reviewer_started | tiendv.52@gmail.com | 2026-07-01T19:26:27.613Z |
| T14: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T19:34:08.821Z |
| T14: fix_started | tiendv.52@gmail.com | 2026-07-01T19:35:10.842Z |
| T14: run_completed | tiendv.52@gmail.com | 2026-07-01T19:45:03.119Z |
| T14: reviewer_started | tiendv.52@gmail.com | 2026-07-01T19:46:17.683Z |
| T14: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T19:52:28.261Z |
| T14: done | tiendv.52@gmail.com | 2026-07-01T19:53:59.004Z |
| T15: ready | tiendv.52@gmail.com | 2026-07-01T19:53:59.189Z |
| T15: claimed | tiendv.52@gmail.com | 2026-07-01T19:55:26.639Z |
| T15: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T19:55:34.512Z |
| T15: run_completed | tiendv.52@gmail.com | 2026-07-01T20:10:16.285Z |
| T15: reviewer_started | tiendv.52@gmail.com | 2026-07-01T20:11:29.223Z |
| T15: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T20:18:56.286Z |
| T15: fix_started | tiendv.52@gmail.com | 2026-07-01T20:19:57.662Z |
| T15: run_completed | tiendv.52@gmail.com | 2026-07-01T20:34:51.894Z |
| T15: reviewer_started | tiendv.52@gmail.com | 2026-07-01T20:36:02.634Z |
| T15: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T20:39:49.217Z |
| T15: done | tiendv.52@gmail.com | 2026-07-01T20:40:56.778Z |
| T3: review_blocked | batu4404@gmail.com | 2026-07-01T22:07:33+0700 |
| T4: run_completed | batu4404@gmail.com | 2026-07-01T22:12:46+0700 |
| T7: run_completed | batu4404@gmail.com | 2026-07-01T22:56:01+0700 |
| T8: run_completed | batu4404@gmail.com | 2026-07-01T23:43:13+0700 |
| T11: reviewer_complete | batu4404@gmail.com | 2026-07-01T23:56:37+0700 |
| T11: done | batu4404@gmail.com | 2026-07-01T23:56:37+0700 |
| T13: claimed | tiendv.52@gmail.com | 2026-07-02 00:32:22.910000+00:00 |
| T13: rag_pre_flight | tiendv.52@gmail.com | 2026-07-02 00:32:30.997000+00:00 |
| T13: started | tiendv.52@gmail.com | 2026-07-02T00:35:58+0000 |
| T13: run_completed | tiendv.52@gmail.com | 2026-07-02T00:40:31.823Z |
| T13: reviewer_started | tiendv.52@gmail.com | 2026-07-02T00:41:34.378Z |
| T13: reviewer_started | tiendv.52@gmail.com | 2026-07-02T01:31:30.714Z |
| T13: reviewer_complete | tiendv.52@gmail.com | 2026-07-02T01:35:40.547Z |
| T13: done | tiendv.52@gmail.com | 2026-07-02T01:36:41.397Z |
| T13: ready | batu4404@gmail.com | 2026-07-02T07:24:51+0700 |
| T13: review_blocked | batu4404@gmail.com | 2026-07-02T08:29:11+0700 |