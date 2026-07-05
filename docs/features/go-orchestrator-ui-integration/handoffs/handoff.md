# Handoff — Go orchestrator — Hermes tasks-stage approve pipeline (merge docs PR + create tasks via API)

## Summary
## Feature - Feature ID: `go-orchestrator-ui-integration` - Title: Go orchestrator — Hermes tasks-stage approve pipeline (merge docs PR + create tasks via API) - Tracked with: `ts` flow (per-task YAML state in `tasks/`). Note this is about how *this feature's own* tasks are tracked — the go orchestrator it builds is still in development, so this feature is not itself `owner: go`. The functionality being built is entirely for the `go` flow.

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — Thread user_id + org_id into tool execution context | [PR](https://github.com/tiendv89/hermes-agent/pull/32) | Reviewer approved. |
| T2 — write_tasks — go branch stops at tasks.md (remove DB insert) | [PR](https://github.com/tiendv89/hermes-agent/pull/33) | Reviewer approved. |
| T3 — CreateTasks server-side guard + structured reason codes | [PR](https://github.com/tiendv89/workflow-backend/pull/55) | Reviewer approved. |
| T4 — workflow-backend service client (bulk create, service-to-service) | [PR](https://github.com/tiendv89/hermes-agent/pull/34) | Reviewer approved. |
| T5 — Tasks-stage approve orchestration — resumable a->b->c->d (incl. ensure-docs-on-base + PR merge) | [PR](https://github.com/tiendv89/hermes-agent/pull/35) | Reviewer approved. |
| T6 — Backup /create-tasks (hermes-internal, step-d only) + guard-error relay | [PR](https://github.com/tiendv89/hermes-agent/pull/36) | Reviewer approved. |
| T7 — End-to-end verification (approve pipeline + backup path) | [PR](https://github.com/tiendv89/hermes-agent/pull/37) | Reviewer approved. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `internal/app/api/response/http_response.go`
- `internal/domain/errors.go`
- `internal/handler/task_create_test.go`
- `internal/service/task_create.go`
- `internal/service/task_create_test.go`
- `plugins/__init__.py`
- `plugins/context.py`
- `plugins/tools/approve.py`
- `plugins/tools/create_tasks.py`
- `plugins/tools/tasks_write.py`
- `src/api/agent_dispatch.py`
- `src/api/routers/chat.py`
- `src/services/workflow_backend_client.py`
- `tests/plugins/test_approve_t5.py`
- `tests/plugins/test_context.py`
- `tests/plugins/test_create_tasks_t6.py`
- `tests/plugins/test_e2e_t7.py`
- `tests/plugins/test_workflow_plugin_t3.py`
- `tests/plugins/test_write_tasks_t2.py`
- `tests/src/test_stream_chat.py`
- `tests/src/test_workflow_backend_client.py`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: ready | batu4404@gmail.com | 2026-07-03 04:32:12+00:00 |
| T3: ready | batu4404@gmail.com | 2026-07-03 04:32:12+00:00 |
| T1: claimed | tiendv.52@gmail.com | 2026-07-03 04:42:23.643000+00:00 |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-07-03 04:42:32.156000+00:00 |
| T3: claimed | tiendv.52@gmail.com | 2026-07-03 04:45:55.726000+00:00 |
| T3: rag_pre_flight | tiendv.52@gmail.com | 2026-07-03 04:46:04.091000+00:00 |
| T4: ready | tiendv.52@gmail.com | 2026-07-03 05:03:42.504000+00:00 |
| T4: claimed | tiendv.52@gmail.com | 2026-07-03 05:05:21.402000+00:00 |
| T4: rag_pre_flight | tiendv.52@gmail.com | 2026-07-03 05:05:29.628000+00:00 |
| T2: ready | batu4404@gmail.com | 2026-07-03T04:32:12Z |
| T2: claimed | tiendv.52@gmail.com | 2026-07-03T04:44:16.232Z |
| T2: rag_pre_flight | tiendv.52@gmail.com | 2026-07-03T04:44:24.318Z |
| T1: started | tiendv.52@gmail.com | 2026-07-03T04:45:56+0000 |
| T2: started | tiendv.52@gmail.com | 2026-07-03T04:49:13+0000 |
| T3: started | tiendv.52@gmail.com | 2026-07-03T04:50:21+0000 |
| T1: run_completed | tiendv.52@gmail.com | 2026-07-03T04:56:02.023Z |
| T2: run_completed | tiendv.52@gmail.com | 2026-07-03T04:56:15.975Z |
| T1: reviewer_started | tiendv.52@gmail.com | 2026-07-03T04:57:30.537Z |
| T2: reviewer_started | tiendv.52@gmail.com | 2026-07-03T04:59:13.816Z |
| T1: reviewer_complete | tiendv.52@gmail.com | 2026-07-03T05:02:21.434Z |
| T3: run_completed | tiendv.52@gmail.com | 2026-07-03T05:02:32.464Z |
| T1: done | tiendv.52@gmail.com | 2026-07-03T05:03:42.414Z |
| T2: reviewer_complete | tiendv.52@gmail.com | 2026-07-03T05:04:17.258Z |
| T2: done | tiendv.52@gmail.com | 2026-07-03T05:07:08.873Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-07-03T05:08:56.920Z |
| T4: started | tiendv.52@gmail.com | 2026-07-03T05:12:07+0000 |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-07-03T05:16:18.346Z |
| T3: done | tiendv.52@gmail.com | 2026-07-03T05:17:26.960Z |
| T4: run_completed | tiendv.52@gmail.com | 2026-07-03T05:21:52.827Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-07-03T05:23:02.011Z |
| T4: reviewer_complete | tiendv.52@gmail.com | 2026-07-03T05:28:36.692Z |
| T4: done | tiendv.52@gmail.com | 2026-07-03T05:29:43.281Z |
| T5: ready | tiendv.52@gmail.com | 2026-07-03T05:29:43.341Z |
| T4: workspace_pr_merge_failed | orchestrator | 2026-07-03T05:29:54.068Z |
| T5: claimed | tiendv.52@gmail.com | 2026-07-03T05:39:45.918Z |
| T5: rag_pre_flight | tiendv.52@gmail.com | 2026-07-03T05:39:54.074Z |
| T5: run_completed | tiendv.52@gmail.com | 2026-07-03T06:06:50.644Z |
| T5: reviewer_started | tiendv.52@gmail.com | 2026-07-03T06:08:00.291Z |
| T5: reviewer_complete | tiendv.52@gmail.com | 2026-07-03T06:15:06.893Z |
| T5: done | tiendv.52@gmail.com | 2026-07-03T06:16:14.873Z |
| T6: ready | tiendv.52@gmail.com | 2026-07-03T06:16:14.953Z |
| T6: claimed | tiendv.52@gmail.com | 2026-07-03T06:17:42.078Z |
| T6: rag_pre_flight | tiendv.52@gmail.com | 2026-07-03T06:17:49.911Z |
| T6: run_completed | tiendv.52@gmail.com | 2026-07-03T06:35:04.861Z |
| T6: reviewer_started | tiendv.52@gmail.com | 2026-07-03T06:36:17.006Z |
| T6: reviewer_complete | tiendv.52@gmail.com | 2026-07-03T06:41:42.981Z |
| T6: done | tiendv.52@gmail.com | 2026-07-03T06:42:48.606Z |
| T7: ready | tiendv.52@gmail.com | 2026-07-03T06:42:48.674Z |
| T7: claimed | tiendv.52@gmail.com | 2026-07-03T06:44:17.162Z |
| T7: rag_pre_flight | tiendv.52@gmail.com | 2026-07-03T06:44:25.273Z |
| T7: run_completed | tiendv.52@gmail.com | 2026-07-03T07:03:17.943Z |
| T7: reviewer_started | tiendv.52@gmail.com | 2026-07-03T07:04:29.937Z |
| T7: reviewer_complete | tiendv.52@gmail.com | 2026-07-03T07:12:53.317Z |
| T7: done | tiendv.52@gmail.com | 2026-07-03T07:13:59.423Z |
| T1: created | batu4404@gmail.com | 2026-07-03T11:12:24+0700 |
| T2: created | batu4404@gmail.com | 2026-07-03T11:12:24+0700 |
| T3: created | batu4404@gmail.com | 2026-07-03T11:12:24+0700 |
| T4: created | batu4404@gmail.com | 2026-07-03T11:12:24+0700 |
| T5: created | batu4404@gmail.com | 2026-07-03T11:12:24+0700 |
| T6: created | batu4404@gmail.com | 2026-07-03T11:12:24+0700 |
| T7: created | batu4404@gmail.com | 2026-07-03T11:12:24+0700 |