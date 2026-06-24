# Handoff — m3-agent-cta

## Summary
## Feature - Feature ID: `m3-agent-cta` - Title: Agent CTA Suggestions — Context-Aware Action Cards After Agent Replies

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — Hermes agent: suggest_next_actions tool + DB migration | [PR](https://github.com/tiendv89/workflow-backend/pull/45) | Reviewer requested changes. |
| T2 — BFF: workspace capabilities endpoint | [PR](https://github.com/tiendv89/workflow-bff/pull/3) | Reviewer approved. |
| T3 — Frontend: CTA card components + integration | [PR](https://github.com/tiendv89/digital-factory-ui/pull/147) | Reviewer approved. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `go.mod`
- `internal/app/api/handler/proxy/sse_passthrough_test.go`
- `internal/app/api/handler/workspace/workspace_handler.go`
- `internal/app/api/handler/workspace/workspace_handler_test.go`
- `internal/app/api/server/server.go`
- `internal/hermes/bus/bus.go`
- `internal/hermes/bus/bus_test.go`
- `internal/hermes/executor/handler.go`
- `internal/hermes/executor/handler_test.go`
- `internal/hermes/executor/integration_test.go`
- `internal/hermes/prompt/system_prompt.go`
- `internal/hermes/tools/suggest_next_actions.go`
- `internal/hermes/tools/suggest_next_actions_test.go`
- `migrations/00019_messages_cta_suggestions.sql`
- `src/__tests__/components/agent-chat/cta-components.test.tsx`
- `src/__tests__/components/agent-chat/cta-integration.test.tsx`
- `src/components/agent-chat/agent-chat-panel.tsx`
- `src/components/agent-chat/channel-message-list.tsx`
- `src/components/agent-chat/cta-card.tsx`
- `src/components/agent-chat/cta-suggestion-row.tsx`
- `src/components/agent-chat/empty-state-cta-row.tsx`
- `src/components/agent-chat/message-thread.tsx`
- `src/components/agent-chat/types.ts`
- `src/components/features/feature-workbench.tsx`
- `src/services/hermes-agent/chat.ts`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: created | pentative@gmail.com | 2026-06-23T18:36:54Z |
| T2: created | pentative@gmail.com | 2026-06-23T18:36:54Z |
| T3: created | pentative@gmail.com | 2026-06-23T18:36:54Z |
| T1: ready | pentative@gmail.com | 2026-06-23T18:37:42Z |
| T2: ready | pentative@gmail.com | 2026-06-23T18:37:42Z |
| T1: claimed | tiendv.52@gmail.com | 2026-06-23T18:40:03.406Z |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-06-23T18:40:11.612Z |
| T2: claimed | tiendv.52@gmail.com | 2026-06-23T18:41:33.940Z |
| T2: rag_pre_flight | tiendv.52@gmail.com | 2026-06-23T18:41:41.933Z |
| T2: started | tiendv.52@gmail.com | 2026-06-23T18:43:51+0000 |
| T1: started | tiendv.52@gmail.com | 2026-06-23T18:49:30+0000 |
| T2: run_completed | tiendv.52@gmail.com | 2026-06-23T18:53:40.390Z |
| T2: reviewer_started | tiendv.52@gmail.com | 2026-06-23T18:55:59.406Z |
| T1: run_completed | tiendv.52@gmail.com | 2026-06-23T19:02:19.116Z |
| T1: reviewer_started | tiendv.52@gmail.com | 2026-06-23T19:03:46.971Z |
| T2: reviewer_complete | tiendv.52@gmail.com | 2026-06-23T19:05:06.625Z |
| T2: fix_started | tiendv.52@gmail.com | 2026-06-23T19:06:22.809Z |
| T1: reviewer_complete | tiendv.52@gmail.com | 2026-06-23T19:12:52.223Z |
| T1: fix_started | tiendv.52@gmail.com | 2026-06-23T19:14:10.340Z |
| T2: run_completed | tiendv.52@gmail.com | 2026-06-23T19:19:10.616Z |
| T2: reviewer_started | tiendv.52@gmail.com | 2026-06-23T19:20:31.317Z |
| T1: run_completed | tiendv.52@gmail.com | 2026-06-23T19:26:05.063Z |
| T2: reviewer_complete | tiendv.52@gmail.com | 2026-06-23T19:26:14.339Z |
| T2: done | tiendv.52@gmail.com | 2026-06-23T19:29:15.887Z |
| T1: reviewer_started | tiendv.52@gmail.com | 2026-06-23T19:31:52.783Z |
| T1: review_blocked | tiendv.52@gmail.com | 2026-06-23T19:33:37.053Z |
| T1: reviewer_started | tiendv.52@gmail.com | 2026-06-23T19:34:53.775Z |
| T1: review_blocked | tiendv.52@gmail.com | 2026-06-23T19:36:45.238Z |
| T1: done | tiendv.52@gmail.com | 2026-06-24T03:10:12.059Z |
| T3: ready | tiendv.52@gmail.com | 2026-06-24T03:10:12.089Z |
| T3: claimed | tiendv.52@gmail.com | 2026-06-24T03:11:40.612Z |
| T3: rag_pre_flight | tiendv.52@gmail.com | 2026-06-24T03:11:49.150Z |
| T3: started | tiendv.52@gmail.com | 2026-06-24T03:15:47+0000 |
| T3: run_completed | tiendv.52@gmail.com | 2026-06-24T03:33:26.970Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-06-24T03:35:01.800Z |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-06-24T03:41:04.907Z |
| T3: fix_started | tiendv.52@gmail.com | 2026-06-24T03:42:14.898Z |
| T3: run_completed | tiendv.52@gmail.com | 2026-06-24T03:51:33.289Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-06-24T03:52:54.449Z |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-06-24T04:00:25.012Z |
| T3: fix_started | tiendv.52@gmail.com | 2026-06-24T04:01:35.184Z |
| T3: run_completed | tiendv.52@gmail.com | 2026-06-24T04:08:45.924Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-06-24T04:10:23.741Z |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-06-24T04:16:45.645Z |
| T3: done | tiendv.52@gmail.com | 2026-06-24T04:18:10.347Z |
| T1: retried | pye@swellnetwork.io | 2026-06-24T10:08:18+0700 |