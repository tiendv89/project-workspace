# Handoff — M3 Agent Chat v4

## Summary
## Feature - Feature ID: `m3-agent-chat-v4` - Title: Agent Chat v4 — The Thread: Team Chat, Channels, @mention, and a Triggered Agent

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — hermes-agent: conversation data model + store (members, authorship, mentions, channels) | [PR](https://github.com/tiendv89/hermes-agent/pull/13) | Reviewer approved. |
| T2 — hermes-agent: @mention parse/resolve + @agent-gated dispatch + send service | [PR](https://github.com/tiendv89/hermes-agent/pull/15) | Reviewer approved. |
| T3 — hermes-agent: real-time SSE fan-out (pub/sub, stream, send, typing, agent republish) | [PR](https://github.com/tiendv89/hermes-agent/pull/16) | Reviewer requested changes. |
| T4 — hermes-agent: channels API (member create, admin delete, list, join) | [PR](https://github.com/tiendv89/hermes-agent/pull/14) | Reviewer approved. |
| T5 — user-service: list workspace members + caller workspace-role endpoints | [PR](https://github.com/tiendv89/user-service/pull/9) | Reviewer approved. |
| T6 — digital-factory-ui: persistent subscription transport + per-message attribution | [PR](https://github.com/tiendv89/digital-factory-ui/pull/135) | Reviewer requested changes. |
| T7 — digital-factory-ui: @mention typeahead composer + mention tokens + unread indicator | [PR](https://github.com/tiendv89/digital-factory-ui/pull/137) | Reviewer approved. |
| T8 — digital-factory-ui: Channels nav + list + create/admin-delete + member UI | [PR](https://github.com/tiendv89/digital-factory-ui/pull/136) | Reviewer approved. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `.env.example`
- `internal/handler/router.go`
- `internal/handler/workspace.go`
- `internal/handler/workspace_test.go`
- `internal/organizations/organizations.go`
- `internal/organizations/workspace_test.go`
- `migrations/00003_workspace_membership_role.sql`
- `migrations/002_team_chat_v4.sql`
- `pyproject.toml`
- `src/__tests__/agent-chat/channels-api.test.ts`
- `src/__tests__/agent-chat/mention-picker-logic.test.ts`
- `src/__tests__/agent-chat/message-attribution.test.ts`
- `src/__tests__/agent-chat/subscription-transport.test.ts`
- `src/__tests__/agent-chat/unread-mentions.test.ts`
- `src/__tests__/workspace-members-api.test.ts`
- `src/api/agent_dispatch.py`
- `src/api/identity.py`
- `src/api/mentions.py`
- `src/api/router.py`
- `src/api/routers/channels.py`
- `src/api/routers/chat.py`
- `src/api/routers/documents.py`
- `src/api/routers/messages.py`
- `src/api/routers/models.py`
- `src/api/routers/sessions.py`
- `src/api/routers/stages.py`
- `src/api/routers/stream.py`
- `src/api/routers/tools.py`
- `src/app.py`
- `src/app/(shell)/channels/[channelId]/page.tsx`
- `src/app/(shell)/channels/page.tsx`
- `src/components/agent-chat/agent-chat-panel.tsx`
- `src/components/agent-chat/mention-picker.tsx`
- `src/components/agent-chat/message.tsx`
- `src/components/agent-chat/prompt-input.tsx`
- `src/components/agent-chat/session-history-list.tsx`
- `src/components/agent-chat/types.ts`
- `src/components/channels/channel-chat-page.tsx`
- `src/components/channels/channels-page.tsx`
- `src/components/channels/create-channel-modal.tsx`
- `src/components/channels/thread-members-panel.tsx`
- `src/components/features/feature-workbench.tsx`
- `src/components/shell/nav-rail.tsx`
- `src/db/__init__.py`
- `src/db/models.py`
- `src/db/session_db_proxy.py`
- `src/db/store.py`
- `src/db/store_v4.py`
- `src/realtime/__init__.py`
- `src/realtime/bus.py`
- `src/services/__init__.py`
- `src/services/hermes-agent/chat.ts`
- `src/services/user-service/client.ts`
- `src/services/user-service/index.ts`
- `src/services/user-service/types.ts`
- `src/services/user_service_client.py`
- `src/streaming/__init__.py`
- `src/streaming/bus_translator.py`
- `src/streaming/sse.py`
- `tests/src/test_channels.py`
- `tests/src/test_realtime_stream.py`
- `tests/src/test_send_service.py`
- `tests/src/test_store_v4.py`
- `tests/src/test_stream_chat.py`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T2: ready | tiendv.52@gmail.com | 2026-06-14 08:08:29.374000+00:00 |
| T2: claimed | tiendv.52@gmail.com | 2026-06-14 08:09:53.055000+00:00 |
| T2: rag_pre_flight | tiendv.52@gmail.com | 2026-06-14 08:10:01.267000+00:00 |
| T3: ready | tiendv.52@gmail.com | 2026-06-14 08:41:22.286000+00:00 |
| T3: claimed | tiendv.52@gmail.com | 2026-06-14 08:42:37.014000+00:00 |
| T3: rag_pre_flight | tiendv.52@gmail.com | 2026-06-14 08:42:44.744000+00:00 |
| T1: ready | pentative@gmail.com | 2026-06-14T07:25:56Z |
| T5: ready | pentative@gmail.com | 2026-06-14T07:25:56Z |
| T1: claimed | tiendv.52@gmail.com | 2026-06-14T07:34:44.120Z |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-06-14T07:34:52.271Z |
| T5: claimed | tiendv.52@gmail.com | 2026-06-14T07:36:24.265Z |
| T5: rag_pre_flight | tiendv.52@gmail.com | 2026-06-14T07:36:39.307Z |
| T1: started | tiendv.52@gmail.com | 2026-06-14T07:38:06+0000 |
| T5: started | tiendv.52@gmail.com | 2026-06-14T07:40:43+0000 |
| T1: run_completed | tiendv.52@gmail.com | 2026-06-14T07:44:11.104Z |
| T1: reviewer_started | tiendv.52@gmail.com | 2026-06-14T07:45:19.665Z |
| T1: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T07:50:45.879Z |
| T1: fix_started | tiendv.52@gmail.com | 2026-06-14T07:51:52.447Z |
| T5: run_completed | tiendv.52@gmail.com | 2026-06-14T07:55:30.811Z |
| T5: reviewer_started | tiendv.52@gmail.com | 2026-06-14T07:56:35.241Z |
| T1: run_completed | tiendv.52@gmail.com | 2026-06-14T07:59:20.506Z |
| T1: reviewer_started | tiendv.52@gmail.com | 2026-06-14T08:00:25.562Z |
| T5: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T08:01:42.473Z |
| T5: done | tiendv.52@gmail.com | 2026-06-14T08:02:44.928Z |
| T1: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T08:07:26.940Z |
| T1: done | tiendv.52@gmail.com | 2026-06-14T08:08:29.302Z |
| T4: ready | tiendv.52@gmail.com | 2026-06-14T08:08:29.377Z |
| T4: claimed | tiendv.52@gmail.com | 2026-06-14T08:11:20.351Z |
| T4: rag_pre_flight | tiendv.52@gmail.com | 2026-06-14T08:11:28.201Z |
| T2: started | tiendv.52@gmail.com | 2026-06-14T08:13:02+0000 |
| T4: started | tiendv.52@gmail.com | 2026-06-14T08:16:46+0000 |
| T4: run_completed | tiendv.52@gmail.com | 2026-06-14T08:21:46.501Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-06-14T08:22:50.845Z |
| T2: run_completed | tiendv.52@gmail.com | 2026-06-14T08:28:39.684Z |
| T4: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T08:28:48.568Z |
| T4: done | tiendv.52@gmail.com | 2026-06-14T08:29:57.148Z |
| T2: rebase_completed | tiendv.52@gmail.com | 2026-06-14T08:33:44.811Z |
| T2: reviewer_started | tiendv.52@gmail.com | 2026-06-14T08:34:45.284Z |
| T2: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T08:40:18.453Z |
| T2: done | tiendv.52@gmail.com | 2026-06-14T08:41:22.211Z |
| T3: started | tiendv.52@gmail.com | 2026-06-14T08:47:48+0000 |
| T3: run_completed | tiendv.52@gmail.com | 2026-06-14T09:05:35.211Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-06-14T09:06:40.079Z |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T09:14:06.426Z |
| T3: fix_started | tiendv.52@gmail.com | 2026-06-14T09:15:02.273Z |
| T3: run_completed | tiendv.52@gmail.com | 2026-06-14T09:19:34.346Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-06-14T09:20:38.098Z |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T09:27:55.170Z |
| T3: fix_started | tiendv.52@gmail.com | 2026-06-14T09:28:50.080Z |
| T3: run_completed | tiendv.52@gmail.com | 2026-06-14T09:35:29.037Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-06-14T09:36:33.201Z |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T09:44:55.416Z |
| T3: fix_started | tiendv.52@gmail.com | 2026-06-14T09:45:49.425Z |
| T3: run_completed | tiendv.52@gmail.com | 2026-06-14T09:54:41.662Z |
| T3: done | tiendv.52@gmail.com | 2026-06-14T11:13:37.224Z |
| T6: ready | tiendv.52@gmail.com | 2026-06-14T11:13:37.310Z |
| T6: claimed | tiendv.52@gmail.com | 2026-06-14T11:14:52.141Z |
| T6: rag_pre_flight | tiendv.52@gmail.com | 2026-06-14T11:15:00.334Z |
| T6: started | tiendv.52@gmail.com | 2026-06-14T11:17:03+0000 |
| T6: run_completed | tiendv.52@gmail.com | 2026-06-14T11:26:42.095Z |
| T6: reviewer_started | tiendv.52@gmail.com | 2026-06-14T11:27:46.420Z |
| T6: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T11:34:39.000Z |
| T6: fix_started | tiendv.52@gmail.com | 2026-06-14T11:35:33.323Z |
| T6: run_completed | tiendv.52@gmail.com | 2026-06-14T11:45:30.964Z |
| T6: reviewer_started | tiendv.52@gmail.com | 2026-06-14T11:46:34.838Z |
| T6: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T11:54:58.393Z |
| T6: fix_started | tiendv.52@gmail.com | 2026-06-14T11:55:52.996Z |
| T6: run_completed | tiendv.52@gmail.com | 2026-06-14T12:01:36.912Z |
| T6: reviewer_started | tiendv.52@gmail.com | 2026-06-14T12:02:40.792Z |
| T6: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T12:11:34.308Z |
| T6: fix_started | tiendv.52@gmail.com | 2026-06-14T12:12:29.053Z |
| T6: run_completed | tiendv.52@gmail.com | 2026-06-14T12:15:48.688Z |
| T1: created | tech_lead | 2026-06-14T13:43:50+0700 |
| T2: created | tech_lead | 2026-06-14T13:43:50+0700 |
| T3: created | tech_lead | 2026-06-14T13:43:50+0700 |
| T4: created | tech_lead | 2026-06-14T13:43:50+0700 |
| T5: created | tech_lead | 2026-06-14T13:43:50+0700 |
| T6: created | tech_lead | 2026-06-14T13:43:50+0700 |
| T7: created | tech_lead | 2026-06-14T13:43:50+0700 |
| T8: created | tech_lead | 2026-06-14T13:43:50+0700 |
| T6: done | tiendv.52@gmail.com | 2026-06-14T15:57:15.919Z |
| T7: ready | tiendv.52@gmail.com | 2026-06-14T15:57:16.028Z |
| T8: ready | tiendv.52@gmail.com | 2026-06-14T15:57:16.031Z |
| T7: claimed | tiendv.52@gmail.com | 2026-06-14T15:58:30.414Z |
| T7: rag_pre_flight | tiendv.52@gmail.com | 2026-06-14T15:58:38.975Z |
| T8: claimed | tiendv.52@gmail.com | 2026-06-14T15:59:55.475Z |
| T8: rag_pre_flight | tiendv.52@gmail.com | 2026-06-14T16:00:04.000Z |
| T7: started | tiendv.52@gmail.com | 2026-06-14T16:02:40+0000 |
| T8: started | tiendv.52@gmail.com | 2026-06-14T16:03:37+0000 |
| T8: run_completed | tiendv.52@gmail.com | 2026-06-14T16:15:05.418Z |
| T8: reviewer_started | tiendv.52@gmail.com | 2026-06-14T16:16:17.488Z |
| T7: run_completed | tiendv.52@gmail.com | 2026-06-14T16:20:53.811Z |
| T7: reviewer_started | tiendv.52@gmail.com | 2026-06-14T16:21:57.217Z |
| T7: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T16:30:34.707Z |
| T7: fix_started | tiendv.52@gmail.com | 2026-06-14T16:31:30.437Z |
| T7: run_completed | tiendv.52@gmail.com | 2026-06-14T16:37:29.007Z |
| T7: reviewer_started | tiendv.52@gmail.com | 2026-06-14T16:38:32.082Z |
| T7: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T16:48:01.818Z |
| T7: done | tiendv.52@gmail.com | 2026-06-14T16:49:04.781Z |
| T8: reviewer_started | tiendv.52@gmail.com | 2026-06-14T17:59:59.519Z |
| T8: reviewer_complete | tiendv.52@gmail.com | 2026-06-14T18:05:30.746Z |
| T8: rebase_completed | tiendv.52@gmail.com | 2026-06-14T18:11:56.366Z |
| T8: started | pye@swellnetwork.io | 2026-06-15T00:58:23+0700 |
| T8: done | tiendv.52@gmail.com | 2026-06-15T02:48:16.091Z |