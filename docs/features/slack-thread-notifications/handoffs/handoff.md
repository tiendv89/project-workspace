# Handoff — Slack Thread Notifications for Feature Runs

## Summary
## Feature

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — Slack Web API client and threaded config | [PR](https://github.com/tiendv89/agent-workflow/pull/206) | — |
| T2 — Redis feature/task-thread store | [PR](https://github.com/tiendv89/agent-workflow/pull/207) | — |
| T3 — Message types and formatters | [PR](https://github.com/tiendv89/agent-workflow/pull/208) | — |
| T4 — Task and reviewer notification call-site migration | [PR](https://github.com/tiendv89/agent-workflow/pull/210) | — |
| T5 — Feature lifecycle wiring — start, summary, handoff | [PR](https://github.com/tiendv89/agent-workflow/pull/211) | 🟡 Missing test for `handoff_submitted` notification path — tasks.md subtask explicitly requires 'handoff_submitted called' to be covered; the implementation in check-feature-tasks-done.ts (+222–+248) has no test. 🟢 Nit: `env` parameter accepted but unused in readStatusYaml/countTaskFiles. CI passed; all other subtasks implemented correctly. |
| T6 — Tests, templates, and operator documentation | [PR](https://github.com/tiendv89/agent-workflow/pull/214) | — |
| T7 — Workspace notification settings migration | [PR](https://github.com/tiendv89/workspace-github-adapter/pull/9) | — |
| T8 — Thread management service | [PR](https://github.com/tiendv89/agent-workflow/pull/209) | — |
| T9 — Feature completion and cleanup | [PR](https://github.com/tiendv89/agent-workflow/pull/212) | — |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `cmd/adapter-service/webhook_handler_test.go`
- `cmd/adapter-worker/task_sync_test.go`
- `database/migrations/00012_workspace_notification_settings.sql`
- `database/queries/workspaces.sql`
- `internal/adapter/db/adapter.go`
- `internal/adapter/db/adapter_test.go`
- `internal/database/models.go`
- `internal/database/workspaces.sql.go`
- `internal/domain/dto.go`
- `internal/github/adapter.go`
- `internal/github/adapter_test.go`
- `internal/github/parser.go`
- `runtime/executors/hermes/package-lock.json`
- `runtime/orchestrator/docs/OPERATOR-GUIDE.md`
- `runtime/orchestrator/package-lock.json`
- `runtime/orchestrator/package.json`
- `runtime/orchestrator/src/adapters/in-memory-thread-store.ts`
- `runtime/orchestrator/src/adapters/redis-thread-store.ts`
- `runtime/orchestrator/src/adapters/slack-task-notifier.ts`
- `runtime/orchestrator/src/adapters/threaded-slack-notifier.ts`
- `runtime/orchestrator/src/config/workspace-config.ts`
- `runtime/orchestrator/src/feature-branch/feature-notification-watcher.ts`
- `runtime/orchestrator/src/main.ts`
- `runtime/orchestrator/src/notifications/feature-formatter.ts`
- `runtime/orchestrator/src/notifications/notification.port.ts`
- `runtime/orchestrator/src/notifications/notification.types.ts`
- `runtime/orchestrator/src/notifications/status-icon.ts`
- `runtime/orchestrator/src/notifications/task-formatter.ts`
- `runtime/orchestrator/src/notifications/threaded-notification-service.ts`
- `runtime/orchestrator/src/poll/check-feature-tasks-done.ts`
- `runtime/orchestrator/src/poll/handle-feature-done.ts`
- `runtime/orchestrator/src/poll/handle-merged-prs.ts`
- `runtime/orchestrator/src/poll/reap-loop.ts`
- `runtime/orchestrator/src/ports/notification-thread-store.port.ts`
- `runtime/orchestrator/src/ports/task-notifier.port.ts`
- `runtime/orchestrator/src/side-effects/dispatch-review-result.ts`
- `runtime/orchestrator/src/side-effects/dispatch.ts`
- `runtime/orchestrator/src/side-effects/escalation-handler.ts`
- `runtime/orchestrator/src/side-effects/post-task-slack.ts`
- `runtime/orchestrator/src/slack/slack-web-api-client.ts`
- `runtime/orchestrator/templates/.projects/.env.example`
- `runtime/orchestrator/templates/QUICKSTART-local-docker.md`
- `runtime/orchestrator/templates/QUICKSTART.md`
- `runtime/orchestrator/templates/docker-compose.local-docker.yml`
- `runtime/orchestrator/templates/docker-compose.yml`
- `runtime/orchestrator/tests/check-feature-tasks-done.test.ts`
- `runtime/orchestrator/tests/dispatch-review-result.test.ts`
- `runtime/orchestrator/tests/escalation-handler.test.ts`
- `runtime/orchestrator/tests/feature-notification-watcher.test.ts`
- `runtime/orchestrator/tests/handle-feature-done.test.ts`
- `runtime/orchestrator/tests/handle-merged-prs.test.ts`
- `runtime/orchestrator/tests/notification-thread-store.test.ts`
- `runtime/orchestrator/tests/notifications/feature-formatter.test.ts`
- `runtime/orchestrator/tests/notifications/status-icon.test.ts`
- `runtime/orchestrator/tests/notifications/task-formatter.test.ts`
- `runtime/orchestrator/tests/notifications/threaded-notification-e2e.test.ts`
- `runtime/orchestrator/tests/notifications/threaded-notification-service.test.ts`
- `runtime/orchestrator/tests/post-task-slack.test.ts`
- `runtime/orchestrator/tests/reap-loop.test.ts`
- `runtime/orchestrator/tests/seam-executor-dispatch.test.ts`
- `runtime/orchestrator/tests/slack-web-api-client.test.ts`
- `templates/workspace/workspace.yaml`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T7: claimed | norepy@tiendv.dev | 2026-05-23 19:11:52.541000+00:00 |
| T7: rag_pre_flight | norepy@tiendv.dev | 2026-05-23 19:12:04.101000+00:00 |
| T1: ready | minhkienn203@gmail.com | 2026-05-23T05:47:29Z |
| T2: ready | minhkienn203@gmail.com | 2026-05-23T05:47:29Z |
| T1: created | minhkienn203@gmail.com | 2026-05-23T12:16:52+0700 |
| T2: created | minhkienn203@gmail.com | 2026-05-23T12:16:52+0700 |
| T3: created | minhkienn203@gmail.com | 2026-05-23T12:16:52+0700 |
| T4: created | minhkienn203@gmail.com | 2026-05-23T12:16:52+0700 |
| T5: created | minhkienn203@gmail.com | 2026-05-23T12:16:52+0700 |
| T6: created | minhkienn203@gmail.com | 2026-05-23T12:16:52+0700 |
| T2: scope_updated | minhkienn203@gmail.com | 2026-05-23T14:08:07+0700 |
| T5: scope_updated | minhkienn203@gmail.com | 2026-05-23T14:08:07+0700 |
| T4: scope_clarified | minhkienn203@gmail.com | 2026-05-23T15:39:57+0700 |
| T1: claimed | norepy@tiendv.dev | 2026-05-23T18:55:49.457Z |
| T1: rag_pre_flight | norepy@tiendv.dev | 2026-05-23T18:56:01.255Z |
| T2: claimed | norepy@tiendv.dev | 2026-05-23T18:57:38.886Z |
| T2: rag_pre_flight | norepy@tiendv.dev | 2026-05-23T18:57:50.438Z |
| T1: started | norepy@tiendv.dev | 2026-05-23T18:58:53+0000 |
| T2: started | norepy@tiendv.dev | 2026-05-23T19:00:14+0000 |
| T1: run_completed | norepy@tiendv.dev | 2026-05-23T19:12:33.640Z |
| T1: reviewer_started | noreply@tiendv.dev | 2026-05-23T19:14:54.909Z |
| T2: run_completed | norepy@tiendv.dev | 2026-05-23T19:15:20.811Z |
| T7: started | norepy@tiendv.dev | 2026-05-23T19:16:45+0000 |
| T1: done | norepy@tiendv.dev | 2026-05-23T19:20:52.462Z |
| T2: reviewer_started | noreply@tiendv.dev | 2026-05-23T19:37:31.152Z |
| T7: blocked | norepy@tiendv.dev | 2026-05-23T19:37:54.508Z |
| T2: done | norepy@tiendv.dev | 2026-05-23T19:41:20.364Z |
| T3: ready | norepy@tiendv.dev | 2026-05-23T19:41:20.776Z |
| T3: claimed | norepy@tiendv.dev | 2026-05-23T19:42:27.086Z |
| T3: rag_pre_flight | norepy@tiendv.dev | 2026-05-23T19:42:38.633Z |
| T3: started | norepy@tiendv.dev | 2026-05-23T19:48:36+0000 |
| T3: run_completed | norepy@tiendv.dev | 2026-05-23T19:59:06.798Z |
| T3: reviewer_started | noreply@tiendv.dev | 2026-05-23T20:00:57.788Z |
| T3: done | norepy@tiendv.dev | 2026-05-23T20:07:18.366Z |
| T8: ready | norepy@tiendv.dev | 2026-05-23T20:07:18.777Z |
| T8: claimed | norepy@tiendv.dev | 2026-05-23T20:08:13.677Z |
| T8: rag_pre_flight | norepy@tiendv.dev | 2026-05-23T20:08:25.417Z |
| T8: started | norepy@tiendv.dev | 2026-05-23T20:10:56+0000 |
| T8: run_completed | norepy@tiendv.dev | 2026-05-23T20:30:48.099Z |
| T8: reviewer_started | noreply@tiendv.dev | 2026-05-23T20:32:07.348Z |
| T8: done | norepy@tiendv.dev | 2026-05-23T20:39:54.603Z |
| T4: ready | norepy@tiendv.dev | 2026-05-23T20:39:55.029Z |
| T5: ready | norepy@tiendv.dev | 2026-05-23T20:39:55.032Z |
| T9: ready | norepy@tiendv.dev | 2026-05-23T20:39:55.035Z |
| T4: claimed | norepy@tiendv.dev | 2026-05-23T20:41:54.279Z |
| T4: rag_pre_flight | norepy@tiendv.dev | 2026-05-23T20:42:06.226Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-23T20:42:21.625Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-23T20:42:32.742Z |
| T4: started | norepy@tiendv.dev | 2026-05-23T20:48:47+0000 |
| T5: started | norepy@tiendv.dev | 2026-05-23T20:49:15+0000 |
| T9: claimed | norepy@tiendv.dev | 2026-05-23T20:56:25.017Z |
| T9: rag_pre_flight | norepy@tiendv.dev | 2026-05-23T20:56:36.996Z |
| T4: retried | norepy@tiendv.dev | 2026-05-23T20:57:03.120Z |
| T9: started | norepy@tiendv.dev | 2026-05-23T21:03:00+0000 |
| T4: claimed | norepy@tiendv.dev | 2026-05-23T21:05:13.680Z |
| T4: rag_pre_flight | norepy@tiendv.dev | 2026-05-23T21:05:19.494Z |
| T5: retried | norepy@tiendv.dev | 2026-05-23T21:05:44.026Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-23T21:19:28.204Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-23T21:19:37.419Z |
| T9: run_completed | norepy@tiendv.dev | 2026-05-23T21:20:21.505Z |
| T9: reviewer_started | noreply@tiendv.dev | 2026-05-23T21:32:52.234Z |
| T5: blocked | norepy@tiendv.dev | 2026-05-23T21:33:25.693Z |
| T9: done | norepy@tiendv.dev | 2026-05-23T21:39:05.603Z |
| T4: retried | norepy@tiendv.dev | 2026-05-23T21:44:19.070Z |
| T4: claimed | norepy@tiendv.dev | 2026-05-23T21:45:38.525Z |
| T4: rag_pre_flight | norepy@tiendv.dev | 2026-05-23T21:45:44.465Z |
| T4: started | norepy@tiendv.dev | 2026-05-23T21:49:44+0000 |
| T4: run_completed | norepy@tiendv.dev | 2026-05-23T22:07:40.750Z |
| T4: reviewer_started | noreply@tiendv.dev | 2026-05-23T22:10:02.836Z |
| T4: done | norepy@tiendv.dev | 2026-05-23T22:14:59.753Z |
| T7: created | matthew@swellnetwork.io | 2026-05-24T01:28:33+0700 |
| T7: ready | matthew@swellnetwork.io | 2026-05-24T01:28:33+0700 |
| T3: scope_clarified | matthew@swellnetwork.io | 2026-05-24T01:33:04+0700 |
| T4: scope_clarified | matthew@swellnetwork.io | 2026-05-24T01:33:04+0700 |
| T5: scope_clarified | matthew@swellnetwork.io | 2026-05-24T01:33:04+0700 |
| T8: created | matthew@swellnetwork.io | 2026-05-24T01:33:04+0700 |
| T5: scope_clarified | matthew@swellnetwork.io | 2026-05-24T01:38:31+0700 |
| T6: scope_clarified | matthew@swellnetwork.io | 2026-05-24T01:38:31+0700 |
| T9: created | matthew@swellnetwork.io | 2026-05-24T01:38:31+0700 |
| T4: scope_clarified | matthew@swellnetwork.io | 2026-05-24T01:51:47+0700 |
| T7: claimed | norepy@tiendv.dev | 2026-05-24T03:58:02.851Z |
| T7: rag_pre_flight | norepy@tiendv.dev | 2026-05-24T03:58:13.462Z |
| T7: started | norepy@tiendv.dev | 2026-05-24T04:01:05+0000 |
| T5: claimed | norepy@tiendv.dev | 2026-05-24T04:02:07.151Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-24T04:02:13.622Z |
| T5: started | norepy@tiendv.dev | 2026-05-24T04:08:20+0000 |
| T7: run_completed | norepy@tiendv.dev | 2026-05-24T04:11:46.829Z |
| T7: reviewer_started | noreply@tiendv.dev | 2026-05-24T04:14:02.270Z |
| T7: done | norepy@tiendv.dev | 2026-05-24T04:19:27.181Z |
| T5: retried | norepy@tiendv.dev | 2026-05-24T04:26:40.037Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-24T04:28:13.758Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-24T04:28:22.483Z |
| T5: started | norepy@tiendv.dev | 2026-05-24T04:37:28+0000 |
| T5: run_completed | norepy@tiendv.dev | 2026-05-24T04:44:15.846Z |
| T5: reviewer_started | noreply@tiendv.dev | 2026-05-24T04:46:04.975Z |
| T5: reviewer_complete | norepy@tiendv.dev | 2026-05-24T04:53:16.292Z |
| T5: fix_started | norepy@tiendv.dev | 2026-05-24T04:54:51.709Z |
| T5: run_completed | norepy@tiendv.dev | 2026-05-24T05:04:55.440Z |
| T5: reviewer_started | noreply@tiendv.dev | 2026-05-24T05:06:27.885Z |
| T5: done | norepy@tiendv.dev | 2026-05-24T05:10:29.697Z |
| T6: ready | norepy@tiendv.dev | 2026-05-24T05:10:30.152Z |
| T6: claimed | norepy@tiendv.dev | 2026-05-24T05:11:51.905Z |
| T6: rag_pre_flight | norepy@tiendv.dev | 2026-05-24T05:12:03.900Z |
| T6: started | norepy@tiendv.dev | 2026-05-24T05:17:03+0000 |
| T6: run_completed | norepy@tiendv.dev | 2026-05-24T05:32:32.956Z |
| T6: reviewer_started | noreply@tiendv.dev | 2026-05-24T05:34:02.577Z |
| T6: done | norepy@tiendv.dev | 2026-05-24T05:38:29.504Z |
| T7: ready | matthew@swellnetwork.io | 2026-05-24T10:56:05+0700 |
| T5: ready | matthew@swellnetwork.io | 2026-05-24T11:00:58+0700 |