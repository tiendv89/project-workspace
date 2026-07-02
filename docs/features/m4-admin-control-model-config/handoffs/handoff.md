# Handoff — Admin-Configurable Model Catalog & Pricing

## Summary
## Feature - Feature ID: `m4-admin-control-model-config` - Title: Admin-Configurable Model Catalog & Pricing

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — hermes-agent — model_catalog migration | [PR](https://github.com/tiendv89/hermes-agent/pull/29) | Reviewer approved. |
| T2 — user-service — model_pricing versioning migration | [PR](https://github.com/tiendv89/user-service/pull/19) | Reviewer approved. |
| T3 — user-service — admin/pricing API + internal platform-roles/check | [PR](https://github.com/tiendv89/user-service/pull/20) | Reviewer approved. |
| T4 — hermes-agent — admin/models API + platform-admin gate + catalog-backed dispatch | [PR](https://github.com/tiendv89/hermes-agent/pull/30) | Reviewer approved. |
| T5 — digital-factory-ui — admin Models page | [PR](https://github.com/tiendv89/digital-factory-ui/pull/158) | Reviewer approved. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `internal/billing/export_test.go`
- `internal/billing/service.go`
- `internal/billing/service_pricing_test.go`
- `internal/billing/store.go`
- `internal/billing/store_test.go`
- `internal/handler/admin_pricing.go`
- `internal/handler/admin_pricing_test.go`
- `internal/handler/billing_test.go`
- `internal/handler/platform_role.go`
- `internal/handler/platform_role_check_test.go`
- `internal/handler/router.go`
- `migrations/00007_model_pricing_versioning.sql`
- `migrations/006_model_catalog.sql`
- `src/__tests__/components/tasks/task-review-view.states.test.tsx`
- `src/__tests__/hooks/admin/use-admin-models-merge.test.ts`
- `src/__tests__/services/hermes-agent/admin-types.test.ts`
- `src/__tests__/services/user-service/admin-pricing.test.ts`
- `src/api/agent_dispatch.py`
- `src/api/identity.py`
- `src/api/model_catalog.py`
- `src/api/router.py`
- `src/api/routers/admin_models.py`
- `src/api/routers/chat.py`
- `src/api/routers/messages.py`
- `src/api/routers/models.py`
- `src/app/(shell)/admin/layout.tsx`
- `src/app/(shell)/admin/models/page.tsx`
- `src/app/(shell)/admin/orgs/page.tsx`
- `src/components/agent-chat/agent-chat-panel.tsx`
- `src/components/settings/usage-tab.tsx`
- `src/components/shell/nav-rail.tsx`
- `src/db/models.py`
- `src/db/store.py`
- `src/hooks/admin/use-admin-models.ts`
- `src/services/hermes-agent/admin.ts`
- `src/services/platform_role_client.py`
- `src/services/user-service/client.ts`
- `src/services/user-service/index.ts`
- `src/services/user-service/types.ts`
- `tests/src/test_admin_models.py`
- `tests/src/test_model_catalog.py`
- `tests/src/test_sessions.py`
- `tests/src/test_stream_chat.py`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T3: ready | tiendv.52@gmail.com | 2026-07-01 10:32:24.765000+00:00 |
| T3: claimed | tiendv.52@gmail.com | 2026-07-01 10:33:54.779000+00:00 |
| T3: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01 10:34:04.407000+00:00 |
| T4: ready | tiendv.52@gmail.com | 2026-07-01 11:02:08.005000+00:00 |
| T4: claimed | tiendv.52@gmail.com | 2026-07-01 11:03:23.580000+00:00 |
| T4: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01 11:03:31.362000+00:00 |
| T1: claimed | tiendv.52@gmail.com | 2026-07-01T10:02:33.053Z |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T10:02:41.458Z |
| T2: claimed | tiendv.52@gmail.com | 2026-07-01T10:05:56.528Z |
| T2: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T10:06:06.912Z |
| T1: started | tiendv.52@gmail.com | 2026-07-01T10:08:35+0000 |
| T2: started | tiendv.52@gmail.com | 2026-07-01T10:09:06+0000 |
| T1: run_completed | tiendv.52@gmail.com | 2026-07-01T10:13:52.892Z |
| T1: reviewer_started | tiendv.52@gmail.com | 2026-07-01T10:15:43.409Z |
| T1: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T10:21:10.948Z |
| T1: done | tiendv.52@gmail.com | 2026-07-01T10:22:33.641Z |
| T2: run_completed | tiendv.52@gmail.com | 2026-07-01T10:25:56.490Z |
| T2: reviewer_started | tiendv.52@gmail.com | 2026-07-01T10:27:04.871Z |
| T2: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T10:31:17.661Z |
| T2: done | tiendv.52@gmail.com | 2026-07-01T10:32:24.720Z |
| T3: started | tiendv.52@gmail.com | 2026-07-01T10:37:13+0000 |
| T3: run_completed | tiendv.52@gmail.com | 2026-07-01T10:54:04.726Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-07-01T10:55:14.745Z |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T11:01:02.617Z |
| T3: done | tiendv.52@gmail.com | 2026-07-01T11:02:07.954Z |
| T4: started | tiendv.52@gmail.com | 2026-07-01T11:06:41+0000 |
| T4: run_completed | tiendv.52@gmail.com | 2026-07-01T11:24:22.361Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-07-01T11:25:31.491Z |
| T4: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T11:32:55.914Z |
| T4: done | tiendv.52@gmail.com | 2026-07-01T11:34:01.097Z |
| T5: ready | tiendv.52@gmail.com | 2026-07-01T11:34:01.159Z |
| T5: claimed | tiendv.52@gmail.com | 2026-07-01T11:35:18.709Z |
| T5: rag_pre_flight | tiendv.52@gmail.com | 2026-07-01T11:35:26.550Z |
| T5: started | tiendv.52@gmail.com | 2026-07-01T11:37:42+0000 |
| T5: run_completed | tiendv.52@gmail.com | 2026-07-01T11:50:35.915Z |
| T5: reviewer_started | tiendv.52@gmail.com | 2026-07-01T11:51:42.856Z |
| T5: reviewer_complete | tiendv.52@gmail.com | 2026-07-01T11:56:34.251Z |
| T5: done | tiendv.52@gmail.com | 2026-07-01T11:57:38.712Z |
| T1: created | pentative@gmail.com | 2026-07-01T16:26:06+0700 |
| T2: created | pentative@gmail.com | 2026-07-01T16:26:06+0700 |
| T3: created | pentative@gmail.com | 2026-07-01T16:26:06+0700 |
| T4: created | pentative@gmail.com | 2026-07-01T16:26:06+0700 |
| T5: created | pentative@gmail.com | 2026-07-01T16:26:06+0700 |
| T1: ready | pentative@gmail.com | 2026-07-01T16:30:49+0700 |
| T2: ready | pentative@gmail.com | 2026-07-01T16:30:49+0700 |