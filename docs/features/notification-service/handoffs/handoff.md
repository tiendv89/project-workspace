# Handoff — notification-service

## Summary
## Feature - Feature ID: `activity-notifications-center` - Title: Activity Center — In-App Notifications for Mentions, Messages, and Feature Lifecycle Events

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — Scaffold notification-service repo (cmd/api, cmd/worker, cmd/main.go, Dockerfile) | [PR](https://github.com/tiendv89/notification-service/pull/1) | — |
| T2 — DB schema + goose migrations (notifications, notification_preferences, email_deliveries) | [PR](https://github.com/tiendv89/notification-service/pull/2) | Reviewer approved. |
| T3 — Producer-facing API + preference gating (POST /internal/notifications, /bulk) | [PR](https://github.com/tiendv89/notification-service/pull/3) | Reviewer approved. |
| T4 — User-facing API (feed, read state, preferences) | [PR](https://github.com/tiendv89/notification-service/pull/4) | Reviewer approved. |
| T5 — Email sending: Gmail/Workspace SMTP adapter + worker loop | [PR](https://github.com/tiendv89/notification-service/pull/5) | Reviewer approved. |
| T6 — hermes-agent producer wiring (mentions, DMs, channel messages) | [PR](https://github.com/tiendv89/hermes-agent/pull/52) | Reviewer approved. |
| T8 — digital-factory-ui Activity panel (All/DMs/Mentions) | [PR](https://github.com/tiendv89/digital-factory-ui/pull/168) | Reviewer approved. |
| T9 — digital-factory-ui Notification Settings page (per-category in-app/email toggles) | [PR](https://github.com/tiendv89/digital-factory-ui/pull/167) | Reviewer approved. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `.golangci.yml`
- `Dockerfile`
- `Makefile`
- `cmd/api/api.go`
- `cmd/main.go`
- `cmd/migration/migration.go`
- `cmd/worker/worker.go`
- `configs/.env.template`
- `configs/config.go`
- `configs/config_test.go`
- `database/migrations/00001_create_notifications.sql`
- `database/migrations/00002_create_notification_preferences.sql`
- `database/migrations/00003_create_email_deliveries.sql`
- `database/migrations_test.go`
- `database/schema.dbml`
- `go.mod`
- `go.sum`
- `internal/db/db.go`
- `internal/email/email.go`
- `internal/email/email_test.go`
- `internal/email/sender.go`
- `internal/email/templates.go`
- `internal/email/worker_integration_test.go`
- `internal/httpapi/handler.go`
- `internal/httpapi/handler_internal.go`
- `internal/httpapi/handler_internal_test.go`
- `internal/httpapi/handler_test.go`
- `internal/httpapi/routes.go`
- `internal/httpapi/routes_test.go`
- `internal/httpapi/sessionauth.go`
- `internal/notifications/notifications.go`
- `internal/notifications/notifications_integration_test.go`
- `internal/notifications/notifications_test.go`
- `internal/preferences/preferences.go`
- `internal/preferences/preferences_integration_test.go`
- `internal/preferences/preferences_test.go`
- `internal/serviceauth/serviceauth.go`
- `internal/serviceauth/serviceauth_test.go`
- `internal/userlookup/userlookup.go`
- `pyproject.toml`
- `src/__tests__/components/activity/notification-feed.test.tsx`
- `src/__tests__/components/settings/notifications-tab.test.tsx`
- `src/__tests__/hooks/settings/use-notification-preferences.test.ts`
- `src/__tests__/services/notification-service/client.test.ts`
- `src/api/routers/messages.py`
- `src/app/(shell)/activity/page.tsx`
- `src/components/activity/notification-feed.tsx`
- `src/components/settings/index.ts`
- `src/components/settings/notifications-tab.tsx`
- `src/components/settings/settings-page.tsx`
- `src/components/shell/nav-rail.tsx`
- `src/constants/axios.ts`
- `src/constants/query-keys.ts`
- `src/db/store.py`
- `src/hooks/notifications/use-notifications.ts`
- `src/hooks/settings/use-notification-preferences.ts`
- `src/services/notification-service/client.ts`
- `src/services/notification-service/index.ts`
- `src/services/notification-service/types.ts`
- `src/services/notification_client.py`
- `tests/src/test_notification_client.py`
- `tests/src/test_notification_wiring.py`
- `uv.lock`

## Follow-up Items
- T7 — agent-workflow producer wiring (lifecycle approvals, task done) (cancelled)

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: claimed | tiendv.52@gmail.com | 2026-07-05 09:39:06.130000+00:00 |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05 09:39:14.588000+00:00 |
| T2: ready | tiendv.52@gmail.com | 2026-07-05 11:33:36.304000+00:00 |
| T2: claimed | tiendv.52@gmail.com | 2026-07-05 11:35:29.123000+00:00 |
| T2: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05 11:35:38.276000+00:00 |
| T2: claimed | tiendv.52@gmail.com | 2026-07-05 12:47:45.479000+00:00 |
| T2: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05 12:47:49.773000+00:00 |
| T8: ready | tiendv.52@gmail.com | 2026-07-05 14:00:45.971000+00:00 |
| T8: claimed | tiendv.52@gmail.com | 2026-07-05 14:02:37.677000+00:00 |
| T8: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05 14:02:46.586000+00:00 |
| T1: ready | agent | 2026-07-05T09:37:22+0000 |
| T1: started | tiendv.52@gmail.com | 2026-07-05T09:41:26+0000 |
| T1: claimed | tiendv.52@gmail.com | 2026-07-05T09:53:00.838Z |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T09:53:05.538Z |
| T1: claimed | tiendv.52@gmail.com | 2026-07-05T10:06:42.762Z |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T10:06:47.736Z |
| T1: started | tiendv.52@gmail.com | 2026-07-05T10:22:47+0000 |
| T1: run_completed | tiendv.52@gmail.com | 2026-07-05T10:31:03.278Z |
| T1: reviewer_started | tiendv.52@gmail.com | 2026-07-05T10:32:38.675Z |
| T1: done | tiendv.52@gmail.com | 2026-07-05T11:33:36.143Z |
| T2: started | tiendv.52@gmail.com | 2026-07-05T11:38:29+0000 |
| T2: started | tiendv.52@gmail.com | 2026-07-05T12:50:01+0000 |
| T2: run_completed | tiendv.52@gmail.com | 2026-07-05T12:58:17.164Z |
| T2: reviewer_started | tiendv.52@gmail.com | 2026-07-05T12:59:39.316Z |
| T2: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T13:04:29.217Z |
| T2: done | tiendv.52@gmail.com | 2026-07-05T13:05:48.656Z |
| T3: ready | tiendv.52@gmail.com | 2026-07-05T13:05:48.739Z |
| T4: ready | tiendv.52@gmail.com | 2026-07-05T13:05:48.741Z |
| T3: claimed | tiendv.52@gmail.com | 2026-07-05T13:07:34.803Z |
| T3: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T13:07:42.728Z |
| T4: claimed | tiendv.52@gmail.com | 2026-07-05T13:09:29.268Z |
| T4: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T13:09:37.365Z |
| T3: started | tiendv.52@gmail.com | 2026-07-05T13:09:54+0000 |
| T4: started | tiendv.52@gmail.com | 2026-07-05T13:12:56+0000 |
| T3: run_completed | tiendv.52@gmail.com | 2026-07-05T13:24:52.745Z |
| T4: run_completed | tiendv.52@gmail.com | 2026-07-05T13:27:13.921Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-07-05T13:28:37.345Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-07-05T13:30:17.292Z |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T13:35:52.442Z |
| T4: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T13:35:59.330Z |
| T3: fix_started | tiendv.52@gmail.com | 2026-07-05T13:37:16.531Z |
| T4: fix_started | tiendv.52@gmail.com | 2026-07-05T13:38:52.854Z |
| T3: run_completed | tiendv.52@gmail.com | 2026-07-05T13:48:07.838Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-07-05T13:49:34.253Z |
| T4: run_completed | tiendv.52@gmail.com | 2026-07-05T13:51:42.325Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-07-05T13:55:32.042Z |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T13:57:48.965Z |
| T3: fix_started | tiendv.52@gmail.com | 2026-07-05T13:58:59.634Z |
| T4: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T13:59:26.186Z |
| T4: done | tiendv.52@gmail.com | 2026-07-05T14:00:45.882Z |
| T9: ready | tiendv.52@gmail.com | 2026-07-05T14:00:45.973Z |
| T9: claimed | tiendv.52@gmail.com | 2026-07-05T14:04:42.744Z |
| T9: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T14:04:52.539Z |
| T8: started | tiendv.52@gmail.com | 2026-07-05T14:05:51+0000 |
| T3: run_completed | tiendv.52@gmail.com | 2026-07-05T14:06:02.594Z |
| T9: started | tiendv.52@gmail.com | 2026-07-05T14:08:45+0000 |
| T9: run_completed | tiendv.52@gmail.com | 2026-07-05T14:21:16.779Z |
| T9: reviewer_started | tiendv.52@gmail.com | 2026-07-05T14:23:05.598Z |
| T3: rebase_completed | tiendv.52@gmail.com | 2026-07-05T14:23:32.893Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-07-05T14:24:53.154Z |
| T8: run_completed | tiendv.52@gmail.com | 2026-07-05T14:25:24.516Z |
| T8: reviewer_started | tiendv.52@gmail.com | 2026-07-05T14:26:49.031Z |
| T9: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T14:29:00.305Z |
| T9: done | tiendv.52@gmail.com | 2026-07-05T14:30:17.257Z |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T14:30:55.042Z |
| T3: done | tiendv.52@gmail.com | 2026-07-05T14:32:10.669Z |
| T5: ready | tiendv.52@gmail.com | 2026-07-05T14:32:10.779Z |
| T6: ready | tiendv.52@gmail.com | 2026-07-05T14:32:10.781Z |
| T7: ready | tiendv.52@gmail.com | 2026-07-05T14:32:10.783Z |
| T8: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T14:32:49.383Z |
| T5: claimed | tiendv.52@gmail.com | 2026-07-05T14:33:50.975Z |
| T5: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T14:33:58.983Z |
| T6: claimed | tiendv.52@gmail.com | 2026-07-05T14:35:37.096Z |
| T6: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T14:35:46.060Z |
| T5: started | tiendv.52@gmail.com | 2026-07-05T14:36:25+0000 |
| T8: fix_started | tiendv.52@gmail.com | 2026-07-05T14:37:29.472Z |
| T6: started | tiendv.52@gmail.com | 2026-07-05T14:38:46+0000 |
| T8: run_completed | tiendv.52@gmail.com | 2026-07-05T14:42:46.019Z |
| T8: rebase_completed | tiendv.52@gmail.com | 2026-07-05T14:48:34.526Z |
| T8: reviewer_started | tiendv.52@gmail.com | 2026-07-05T14:49:50.873Z |
| T5: run_completed | tiendv.52@gmail.com | 2026-07-05T14:51:53.953Z |
| T6: run_completed | tiendv.52@gmail.com | 2026-07-05T14:52:07.277Z |
| T5: reviewer_started | tiendv.52@gmail.com | 2026-07-05T14:53:25.537Z |
| T6: reviewer_started | tiendv.52@gmail.com | 2026-07-05T14:54:59.694Z |
| T8: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T14:55:25.902Z |
| T8: done | tiendv.52@gmail.com | 2026-07-05T14:56:41.829Z |
| T5: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T15:00:17.691Z |
| T5: fix_started | tiendv.52@gmail.com | 2026-07-05T15:01:47.070Z |
| T6: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T15:02:14.968Z |
| T6: done | tiendv.52@gmail.com | 2026-07-05T15:03:27.943Z |
| T5: run_completed | tiendv.52@gmail.com | 2026-07-05T15:07:26.047Z |
| T5: reviewer_started | tiendv.52@gmail.com | 2026-07-05T15:08:42.167Z |
| T5: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T15:14:55.586Z |
| T5: fix_started | tiendv.52@gmail.com | 2026-07-05T15:16:00.399Z |
| T5: run_completed | tiendv.52@gmail.com | 2026-07-05T15:21:27.439Z |
| T5: reviewer_started | tiendv.52@gmail.com | 2026-07-05T15:22:58.004Z |
| T5: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T15:30:34.845Z |
| T5: done | tiendv.52@gmail.com | 2026-07-05T15:31:48.063Z |
| T1: retried | pye | 2026-07-05T16:51:32+0700 |
| T1: retried | pye | 2026-07-05T17:02:25+0700 |
| T1: retried | pye | 2026-07-05T18:31:25+0700 |
| T2: manual_override | pye@swellnetwork.io | 2026-07-05T19:44:24+0700 |
| T7: claimed | tiendv.52@gmail.com | 2026-07-06T19:14:12.900Z |
| T7: rag_pre_flight | tiendv.52@gmail.com | 2026-07-06T19:14:21.410Z |
| T7: started | tiendv.52@gmail.com | 2026-07-06T19:21:41+0000 |
| T7: claimed | tiendv.52@gmail.com | 2026-07-07T03:38:54.966Z |
| T7: rag_pre_flight | tiendv.52@gmail.com | 2026-07-07T03:38:59.832Z |
| T7: started | tiendv.52@gmail.com | 2026-07-07T03:42:27+0000 |
| T7: claimed | tiendv.52@gmail.com | 2026-07-07T04:15:59.748Z |
| T7: rag_pre_flight | tiendv.52@gmail.com | 2026-07-07T04:16:04.267Z |
| T7: started | tiendv.52@gmail.com | 2026-07-07T04:26:44+0000 |
| T7: ready | pye@swellnetwork.io | 2026-07-07T10:34:48+0700 |
| T7: ready | pye@swellnetwork.io | 2026-07-07T11:11:50+0700 |
| T7: ready | pye@swellnetwork.io | 2026-07-07T11:45:54+0700 |
| T7: claimed | pentative@gmail.com | 2026-07-07T11:45:54+0700 |
| T7: work_phase_complete | pentative@gmail.com | 2026-07-07T13:04:23+0700 |
| T7: cancelled | pye@swellnetwork.io | 2026-07-07T13:16:25+0700 |