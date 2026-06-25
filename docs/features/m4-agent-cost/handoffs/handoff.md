# Handoff — Agent Cost Tracking — Token Usage and Cost Visibility

## Summary
## Feature - Feature ID: `m4-agent-cost` - Title: Agent Cost Tracking — Credits, Billing Plans, and Quota

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — user-service: billing/quota + platform-role migrations & seeds | [PR](https://github.com/tiendv89/user-service/pull/15) | Reviewer approved. |
| T2 — user-service: plan resolution + lazy quota + internal cost/quota APIs | [PR](https://github.com/tiendv89/user-service/pull/16) | Reviewer approved. |
| T3 — user-service: admin plan APIs + RequirePlatformRole guard + platform_roles in payload | [PR](https://github.com/tiendv89/user-service/pull/17) | Reviewer approved. |
| T4 — workflow-bff: cost/quota gateway handlers + forward platform_roles | [PR](https://github.com/tiendv89/workflow-bff/pull/6) | Reviewer approved. |
| T5 — hermes-agent: pre-turn quota guard + post-turn cost emission + stopped-turn tally | [PR](https://github.com/tiendv89/hermes-agent/pull/27) | Reviewer approved. |
| T6 — digital-factory-ui: chat credit badge + session header quota indicator | [PR](https://github.com/tiendv89/digital-factory-ui/pull/156) | Reviewer approved. |
| T7 — digital-factory-ui: Settings → Usage page | [PR](https://github.com/tiendv89/digital-factory-ui/pull/154) | Reviewer approved. |
| T8 — digital-factory-ui: admin Plans/Users/Orgs pages under /admin/ + platform-role guard | [PR](https://github.com/tiendv89/digital-factory-ui/pull/155) | Reviewer approved. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `cmd/api/api.go`
- `internal/app/api/constant/constants.go`
- `internal/app/api/handler/common/response.go`
- `internal/app/api/handler/cost/cost_handler.go`
- `internal/app/api/handler/cost/cost_handler_test.go`
- `internal/app/api/handler/proxy/proxy_handler.go`
- `internal/app/api/server/server.go`
- `internal/billing/export_test.go`
- `internal/billing/platform_role_store.go`
- `internal/billing/platform_role_store_test.go`
- `internal/billing/resolve_plan_test.go`
- `internal/billing/service.go`
- `internal/billing/service_test.go`
- `internal/billing/store.go`
- `internal/billing/store_test.go`
- `internal/handler/admin.go`
- `internal/handler/admin_test.go`
- `internal/handler/billing.go`
- `internal/handler/billing_test.go`
- `internal/handler/me.go`
- `internal/handler/platform_role.go`
- `internal/handler/router.go`
- `internal/pkg/model/session.go`
- `internal/pkg/service/session/session_service.go`
- `internal/pkg/serviceclient/userservice/client.go`
- `migrations/00006_billing_quota_platform_roles.sql`
- `package-lock.json`
- `src/__tests__/components/agent-chat/message-credit-badge.test.tsx`
- `src/__tests__/components/agent-chat/session-cost-header.test.tsx`
- `src/__tests__/components/tasks/task-review-view.states.test.tsx`
- `src/__tests__/hooks/settings/use-quota.test.ts`
- `src/__tests__/services/user-service/admin-types.test.ts`
- `src/__tests__/services/workflow-bff/cost.test.ts`
- `src/__tests__/utils/platform-role.test.ts`
- `src/api/agent_dispatch.py`
- `src/app/admin/layout.tsx`
- `src/app/admin/orgs/page.tsx`
- `src/app/admin/page.tsx`
- `src/app/admin/plans/page.tsx`
- `src/app/admin/users/page.tsx`
- `src/components/agent-chat/agent-chat-panel.tsx`
- `src/components/agent-chat/message.tsx`
- `src/components/agent-chat/session-cost-header.tsx`
- `src/components/agent-chat/types.ts`
- `src/components/settings/settings-page.tsx`
- `src/components/settings/usage-tab.tsx`
- `src/hooks/admin/use-admin-plans.ts`
- `src/hooks/settings/use-quota.ts`
- `src/services/bff_client.py`
- `src/services/hermes-agent/chat.ts`
- `src/services/user-service/client.ts`
- `src/services/user-service/index.ts`
- `src/services/user-service/types.ts`
- `src/services/workflow-bff/cost.ts`
- `src/utils/platform-role.ts`
- `tests/src/test_quota_cost.py`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: ready | pentative@gmail.com | 2026-06-24T17:02:43Z |
| T1: claimed | tiendv.52@gmail.com | 2026-06-24T17:09:59.295Z |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-06-24T17:10:07.857Z |
| T1: started | tiendv.52@gmail.com | 2026-06-24T17:13:04+0000 |
| T1: run_completed | tiendv.52@gmail.com | 2026-06-24T17:26:21.699Z |
| T1: reviewer_started | tiendv.52@gmail.com | 2026-06-24T17:27:35.302Z |
| T1: reviewer_complete | tiendv.52@gmail.com | 2026-06-24T17:32:56.061Z |
| T1: done | tiendv.52@gmail.com | 2026-06-24T17:34:07.283Z |
| T2: ready | tiendv.52@gmail.com | 2026-06-24T17:34:07.375Z |
| T2: claimed | tiendv.52@gmail.com | 2026-06-24T17:35:32.861Z |
| T2: rag_pre_flight | tiendv.52@gmail.com | 2026-06-24T17:35:42.116Z |
| T2: started | tiendv.52@gmail.com | 2026-06-24T17:39:12+0000 |
| T2: run_completed | tiendv.52@gmail.com | 2026-06-24T17:57:34.576Z |
| T2: reviewer_started | tiendv.52@gmail.com | 2026-06-24T17:58:47.134Z |
| T2: reviewer_complete | tiendv.52@gmail.com | 2026-06-24T18:05:13.228Z |
| T2: fix_started | tiendv.52@gmail.com | 2026-06-24T18:06:18.818Z |
| T2: run_completed | tiendv.52@gmail.com | 2026-06-24T18:16:19.066Z |
| T2: reviewer_started | tiendv.52@gmail.com | 2026-06-24T18:17:33.140Z |
| T2: reviewer_complete | tiendv.52@gmail.com | 2026-06-24T18:24:27.830Z |
| T2: done | tiendv.52@gmail.com | 2026-06-24T18:25:38.558Z |
| T3: ready | tiendv.52@gmail.com | 2026-06-24T18:25:38.632Z |
| T4: ready | tiendv.52@gmail.com | 2026-06-24T18:25:38.634Z |
| T3: claimed | tiendv.52@gmail.com | 2026-06-24T18:27:07.483Z |
| T3: rag_pre_flight | tiendv.52@gmail.com | 2026-06-24T18:27:16.406Z |
| T4: claimed | tiendv.52@gmail.com | 2026-06-24T18:28:46.198Z |
| T4: rag_pre_flight | tiendv.52@gmail.com | 2026-06-24T18:28:55.139Z |
| T3: started | tiendv.52@gmail.com | 2026-06-24T18:31:08+0000 |
| T4: started | tiendv.52@gmail.com | 2026-06-24T18:31:18+0000 |
| T3: run_completed | tiendv.52@gmail.com | 2026-06-24T18:52:51.642Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-06-24T18:54:06.113Z |
| T4: run_completed | tiendv.52@gmail.com | 2026-06-24T18:54:33.726Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-06-24T18:55:46.903Z |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-06-24T18:59:46.937Z |
| T3: done | tiendv.52@gmail.com | 2026-06-24T19:01:17.008Z |
| T4: reviewer_complete | tiendv.52@gmail.com | 2026-06-24T19:01:48.481Z |
| T4: fix_started | tiendv.52@gmail.com | 2026-06-24T19:02:51.119Z |
| T4: run_completed | tiendv.52@gmail.com | 2026-06-24T19:10:07.876Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-06-24T19:11:50.302Z |
| T4: reviewer_complete | tiendv.52@gmail.com | 2026-06-24T19:18:27.328Z |
| T4: fix_started | tiendv.52@gmail.com | 2026-06-24T19:19:29.794Z |
| T4: run_completed | tiendv.52@gmail.com | 2026-06-24T19:28:08.012Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-06-24T19:29:22.436Z |
| T4: reviewer_complete | tiendv.52@gmail.com | 2026-06-24T19:42:16.027Z |
| T4: done | tiendv.52@gmail.com | 2026-06-24T19:43:48.417Z |
| T5: ready | tiendv.52@gmail.com | 2026-06-24T19:43:48.494Z |
| T6: ready | tiendv.52@gmail.com | 2026-06-24T19:43:48.496Z |
| T7: ready | tiendv.52@gmail.com | 2026-06-24T19:43:48.498Z |
| T8: ready | tiendv.52@gmail.com | 2026-06-24T19:43:48.499Z |
| T5: claimed | tiendv.52@gmail.com | 2026-06-24T19:45:21.288Z |
| T5: rag_pre_flight | tiendv.52@gmail.com | 2026-06-24T19:45:29.968Z |
| T6: claimed | tiendv.52@gmail.com | 2026-06-24T19:46:57.675Z |
| T6: rag_pre_flight | tiendv.52@gmail.com | 2026-06-24T19:47:06.095Z |
| T7: claimed | tiendv.52@gmail.com | 2026-06-24T19:48:39.883Z |
| T7: rag_pre_flight | tiendv.52@gmail.com | 2026-06-24T19:48:47.924Z |
| T8: claimed | tiendv.52@gmail.com | 2026-06-24T19:50:17.972Z |
| T8: rag_pre_flight | tiendv.52@gmail.com | 2026-06-24T19:50:25.929Z |
| T5: started | tiendv.52@gmail.com | 2026-06-24T19:51:02+0000 |
| T7: started | tiendv.52@gmail.com | 2026-06-24T19:52:17+0000 |
| T8: started | tiendv.52@gmail.com | 2026-06-24T19:55:22+0000 |
| T5: run_completed | tiendv.52@gmail.com | 2026-06-24T20:06:24.103Z |
| T5: reviewer_started | tiendv.52@gmail.com | 2026-06-24T20:08:20.544Z |
| T7: run_completed | tiendv.52@gmail.com | 2026-06-24T20:15:28.629Z |
| T7: reviewer_started | tiendv.52@gmail.com | 2026-06-24T20:17:15.774Z |
| T5: reviewer_complete | tiendv.52@gmail.com | 2026-06-24T20:17:41.086Z |
| T5: done | tiendv.52@gmail.com | 2026-06-24T20:19:24.447Z |
| T7: reviewer_complete | tiendv.52@gmail.com | 2026-06-24T20:23:23.292Z |
| T7: fix_started | tiendv.52@gmail.com | 2026-06-24T20:24:30.403Z |
| T7: run_completed | tiendv.52@gmail.com | 2026-06-24T20:35:10.015Z |
| T7: reviewer_started | tiendv.52@gmail.com | 2026-06-24T20:36:28.745Z |
| T7: reviewer_complete | tiendv.52@gmail.com | 2026-06-24T20:42:59.337Z |
| T7: done | tiendv.52@gmail.com | 2026-06-24T20:44:10.777Z |
| T7: workspace_pr_merge_failed | orchestrator | 2026-06-24T20:44:25.271Z |
| T1: created | tech_lead | 2026-06-24T23:50:04+0700 |
| T2: created | tech_lead | 2026-06-24T23:50:04+0700 |
| T3: created | tech_lead | 2026-06-24T23:50:04+0700 |
| T4: created | tech_lead | 2026-06-24T23:50:04+0700 |
| T5: created | tech_lead | 2026-06-24T23:50:04+0700 |
| T6: created | tech_lead | 2026-06-24T23:50:04+0700 |
| T7: created | tech_lead | 2026-06-24T23:50:04+0700 |
| T8: created | tech_lead | 2026-06-24T23:50:04+0700 |
| T6: claimed | tiendv.52@gmail.com | 2026-06-25T03:25:06.495Z |
| T6: rag_pre_flight | tiendv.52@gmail.com | 2026-06-25T03:25:10.719Z |
| T8: claimed | tiendv.52@gmail.com | 2026-06-25T03:28:03.741Z |
| T8: rag_pre_flight | tiendv.52@gmail.com | 2026-06-25T03:28:10.542Z |
| T6: started | tiendv.52@gmail.com | 2026-06-25T03:35:14+0000 |
| T6: run_completed | tiendv.52@gmail.com | 2026-06-25T03:37:32.089Z |
| T8: started | tiendv.52@gmail.com | 2026-06-25T03:38:35+0000 |
| T6: reviewer_started | tiendv.52@gmail.com | 2026-06-25T03:38:49.702Z |
| T8: run_completed | tiendv.52@gmail.com | 2026-06-25T03:40:46.757Z |
| T6: reviewer_complete | tiendv.52@gmail.com | 2026-06-25T03:43:36.355Z |
| T6: done | tiendv.52@gmail.com | 2026-06-25T03:44:48.878Z |
| T8: rebase_completed | tiendv.52@gmail.com | 2026-06-25T03:45:22.120Z |
| T8: reviewer_started | tiendv.52@gmail.com | 2026-06-25T03:46:35.186Z |
| T8: reviewer_complete | tiendv.52@gmail.com | 2026-06-25T03:53:32.583Z |
| T8: done | tiendv.52@gmail.com | 2026-06-25T03:54:43.589Z |
| T6: ready | pye@swellnetwork.io | 2026-06-25T10:23:55+0700 |
| T8: ready | pye@swellnetwork.io | 2026-06-25T10:25:17+0700 |