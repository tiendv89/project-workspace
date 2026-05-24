# Handoff — Slack Thread Notifications for Feature Runs

## Summary

Feature and task lifecycle events now post to separate Slack threads instead of
independent webhook messages. Each feature gets one top-level Slack message that
is updated in place on each lifecycle event, with replies providing an audit
trail of changes. Each task gets its own independent top-level thread managed
the same way. Thread routing state (thread_ts keyed by featureId/taskId) is
stored in Redis and deleted when the feature or task reaches a terminal state.

The legacy `SLACK_WEBHOOK_URL` webhook path was removed entirely.
`slack_channel_id` is now declared per-workspace in `workspace.yaml` under
`notifications.slack.channel_id` (synced to Postgres by workspace-github-adapter)
rather than read from an environment variable.

## Feature

Feature PR (agent-workflow): https://github.com/tiendv89/agent-workflow/pull/215
Feature PR (workspace-github-adapter): https://github.com/tiendv89/workspace-github-adapter/pull/10

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — Slack Web API client and threaded config | [PR](https://github.com/tiendv89/agent-workflow/pull/206) | — |
| T2 — Redis feature/task-thread store | [PR](https://github.com/tiendv89/agent-workflow/pull/207) | — |
| T3 — Message types and formatters | [PR](https://github.com/tiendv89/agent-workflow/pull/208) | — |
| T4 — Task and reviewer notification call-site migration | [PR](https://github.com/tiendv89/agent-workflow/pull/210) | — |
| T5 — Feature lifecycle wiring — start, summary, handoff | [PR](https://github.com/tiendv89/agent-workflow/pull/211) | 🟡 Missing test for `handoff_submitted` notification path — resolved in fix commit. 🟢 Nit: `env` parameter accepted but unused in readStatusYaml/countTaskFiles — resolved. |
| T6 — Tests, templates, and operator documentation | [PR](https://github.com/tiendv89/agent-workflow/pull/214) | — |
| T7 — Workspace notification settings migration | [PR](https://github.com/tiendv89/workspace-github-adapter/pull/10) | First attempt (PR #9) blocked; completed on retry. |
| T8 — Thread management service | [PR](https://github.com/tiendv89/agent-workflow/pull/209) | — |
| T9 — Feature completion and cleanup | [PR](https://github.com/tiendv89/agent-workflow/pull/212) | — |

## Deviations from Technical Design

**1. Orchestrator source directory restructured (unplanned)**

During T4/T6, the orchestrator source was reorganised from a flat layout
(`src/adapters/`, `src/poll/`, `src/side-effects/`, `src/types/`) into
organised subdirectories to accommodate the new notification module without
naming collisions:

| Old path | New path |
|---|---|
| `src/adapters/broker/` | `src/broker/` |
| `src/adapters/executor/` | `src/executor/` |
| `src/adapters/{clock,credential,emitter,scheduler,workflow-state,workspace-pull}/` | `src/infra/` |
| `src/poll/` | `src/loop/` |
| `src/side-effects/dispatch*.ts`, `src/side-effects/escalation-handler.ts`, `src/side-effects/unblock-deps.ts` | `src/task/` |
| `src/side-effects/dispatch-review-result.ts`, etc. | `src/pr/`, `src/task/` |
| `src/types/task.ts` | `src/task/types.ts` |
| `src/claim/`, `src/task-branch-state.ts` | `src/task/` |

**2. `NotificationPort` replaces `TaskNotifierPort`**

The technical design specified `TaskNotifierPort` with a single `notify(event)`
method. The implementation uses `NotificationPort` with four typed methods:
`postTaskMessage`, `closeTaskThread`, `postFeatureMessage`, `closeFeatureThread`.
This allows feature and task thread operations to be managed through the same
port contract.

**3. Legacy webhook adapter removed**

`SlackTaskNotifier` (webhook-based, read `SLACK_WEBHOOK_URL`) and
`src/side-effects/post-task-slack.ts` were deleted. All Slack delivery now goes
through `SlackWebApiClient` using a bot token (`SLACK_BOT_TOKEN`).

## Files Changed

### workspace-github-adapter ([PR #10](https://github.com/tiendv89/workspace-github-adapter/pull/10))
- `cmd/adapter-service/webhook_handler_test.go`
- `cmd/adapter-worker/task_sync_test.go`
- `database/migrations/00012_workspace_notification_settings.sql` _(new)_
- `database/queries/workspaces.sql`
- `internal/adapter/db/adapter.go`
- `internal/adapter/db/adapter_test.go`
- `internal/database/models.go`
- `internal/database/workspaces.sql.go`
- `internal/domain/dto.go`
- `internal/github/adapter.go`
- `internal/github/adapter_test.go`
- `internal/github/parser.go`

### agent-workflow ([PR #215](https://github.com/tiendv89/agent-workflow/pull/215))

**New notification module:**
- `runtime/orchestrator/src/notification/port.ts`
- `runtime/orchestrator/src/notification/types.ts`
- `runtime/orchestrator/src/notification/slack/client.ts`
- `runtime/orchestrator/src/notification/slack/notifier.ts`
- `runtime/orchestrator/src/notification/slack/service.ts`
- `runtime/orchestrator/src/notification/slack/formatters/feature.ts`
- `runtime/orchestrator/src/notification/slack/formatters/task.ts`
- `runtime/orchestrator/src/notification/slack/formatters/status-icon.ts`
- `runtime/orchestrator/src/notification/slack/thread-store/port.ts`
- `runtime/orchestrator/src/notification/slack/thread-store/in-memory.ts`
- `runtime/orchestrator/src/notification/slack/thread-store/redis.ts`
- `runtime/orchestrator/src/feature/notification-watcher.ts`
- `runtime/orchestrator/src/task/escalation-handler.ts`

**Removed (legacy webhook path):**
- `runtime/orchestrator/src/adapters/index.ts`
- `runtime/orchestrator/src/adapters/slack-task-notifier.ts`
- `runtime/orchestrator/src/ports/task-notifier.port.ts`
- `runtime/orchestrator/src/side-effects/post-task-slack.ts`
- `runtime/orchestrator/src/side-effects/escalation-handler.ts`

**Renamed/moved (source restructure):**
- `src/adapters/broker/` → `src/broker/`
- `src/adapters/executor/` → `src/executor/`
- `src/adapters/{clock,credential,emitter,scheduler,workflow-state,workspace-pull}/` → `src/infra/`
- `src/poll/` → `src/loop/`
- `src/side-effects/dispatch.ts` and related → `src/task/`
- `src/types/task.ts` → `src/task/types.ts`
- `src/claim/open-workspace-pr.ts` → `src/task/open-workspace-pr.ts`

**Modified:**
- `runtime/orchestrator/src/config/workspace-config.ts`
- `runtime/orchestrator/src/eligibility/match.ts`
- `runtime/orchestrator/src/main.ts`
- `runtime/orchestrator/src/profiles/local-docker.ts`
- `runtime/orchestrator/src/profiles/local-subprocess.ts`
- `runtime/orchestrator/src/utils/task-yaml-io.ts`
- `runtime/orchestrator/package.json` _(added `redis` ^5.12.1)_
- `runtime/orchestrator/docs/OPERATOR-GUIDE.md`
- `runtime/orchestrator/templates/docker-compose.local-docker.yml`
- `runtime/orchestrator/templates/docker-compose.yml`
- `runtime/orchestrator/templates/QUICKSTART-local-docker.md`
- `runtime/orchestrator/templates/QUICKSTART.md`
- `runtime/orchestrator/templates/.projects/.env.example`
- `templates/workspace/workspace.yaml`

**Tests (new or updated):**
- `runtime/orchestrator/tests/slack-web-api-client.test.ts` _(new)_
- `runtime/orchestrator/tests/feature-notification-watcher.test.ts` _(new)_
- `runtime/orchestrator/tests/notification-thread-store.test.ts` _(new)_
- Many existing test files updated for import path changes (see PR #215 for full list)

## Follow-up Items
_None identified._

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