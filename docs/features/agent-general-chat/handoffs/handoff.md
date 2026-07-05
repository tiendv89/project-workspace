# Handoff — agent-general-chat

## Summary
## Feature - Feature ID: `agent-general-chat` - Title: General Chat, Direct Messages, Cross-Feature Agent Context, and a Unified Chat Hub

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — hermes-agent: kind='dm' migration + create_dm/list store functions + /dms routes | [PR](https://github.com/tiendv89/hermes-agent/pull/44) | Reviewer approved. |
| T2 — hermes-agent: dispatch gate — DM follows Channel bare-message rule | [PR](https://github.com/tiendv89/hermes-agent/pull/47) | Reviewer approved. |
| T3 — hermes-agent: workflow_lookup_feature read-only cross-feature tool | [PR](https://github.com/tiendv89/hermes-agent/pull/45) | Reviewer approved. |
| T4 — hermes-agent: metering-parity regression tests (G6) | [PR](https://github.com/tiendv89/hermes-agent/pull/49) | — |
| T5 — digital-factory-ui: new Chat nav entry + Slack-style sidebar shell | [PR](https://github.com/tiendv89/digital-factory-ui/pull/162) | Reviewer approved. |
| T6 — digital-factory-ui: in-chat read-only Board panel | [PR](https://github.com/tiendv89/digital-factory-ui/pull/163) | Reviewer approved. |
| T7 — digital-factory-ui: DM member picker + Direct Messages section wired to /dms | [PR](https://github.com/tiendv89/digital-factory-ui/pull/164) | Reviewer approved. |
| T8 — digital-factory-ui: retire /channels + Team Chat standalone routes to redirects | [PR](https://github.com/tiendv89/digital-factory-ui/pull/165) | Reviewer approved. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `migrations/007_add_dm_session_kind.sql`
- `plugins/__init__.py`
- `plugins/hooks.py`
- `plugins/tools/lookup_feature.py`
- `src/__tests__/app/redirects/channel-redirects.test.ts`
- `src/__tests__/components/agent-chat/board-panel.test.tsx`
- `src/__tests__/components/chat/chat-sidebar.test.tsx`
- `src/__tests__/components/shell/nav-rail.test.tsx`
- `src/__tests__/utils/board/feature-id-heuristic.test.ts`
- `src/api/router.py`
- `src/api/routers/dms.py`
- `src/api/routers/messages.py`
- `src/app/(shell)/channels/[channelId]/page.tsx`
- `src/app/(shell)/channels/page.tsx`
- `src/app/(shell)/chat/[sessionId]/page.tsx`
- `src/app/(shell)/chat/layout.tsx`
- `src/app/(shell)/chat/page.tsx`
- `src/app/(shell)/team-threads/[threadId]/page.tsx`
- `src/app/(shell)/team-threads/page.tsx`
- `src/components/agent-chat/agent-chat-panel.tsx`
- `src/components/agent-chat/board-panel.tsx`
- `src/components/chat/chat-session-view.tsx`
- `src/components/chat/chat-sidebar.tsx`
- `src/components/chat/create-channel-modal.tsx`
- `src/components/chat/dm-member-picker.tsx`
- `src/components/chat/index.ts`
- `src/components/features/feature-workbench.tsx`
- `src/components/shell/nav-rail.tsx`
- `src/db/__init__.py`
- `src/db/store.py`
- `src/services/hermes-agent/chat.ts`
- `src/utils/board/feature-id-heuristic.ts`
- `tests/plugins/test_workflow_lookup_feature.py`
- `tests/src/test_dms.py`
- `tests/src/test_metering_parity.py`
- `tests/src/test_send_service.py`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: ready | agent | 2026-07-05T07:43:37+0000 |
| T3: ready | agent | 2026-07-05T07:43:37+0000 |
| T5: ready | agent | 2026-07-05T07:43:37+0000 |
| T6: ready | agent | 2026-07-05T07:43:37+0000 |
| T1: claimed | tiendv.52@gmail.com | 2026-07-05T07:45:49.456Z |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T07:45:57.397Z |
| T3: claimed | tiendv.52@gmail.com | 2026-07-05T07:47:33.588Z |
| T3: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T07:47:41.405Z |
| T1: started | tiendv.52@gmail.com | 2026-07-05T07:49:02+0000 |
| T3: started | tiendv.52@gmail.com | 2026-07-05T07:50:50+0000 |
| T1: claimed | tiendv.52@gmail.com | 2026-07-05T08:15:46.253Z |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T08:15:49.976Z |
| T3: claimed | tiendv.52@gmail.com | 2026-07-05T08:17:26.745Z |
| T3: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T08:17:30.459Z |
| T1: started | tiendv.52@gmail.com | 2026-07-05T08:22:57+0000 |
| T3: started | tiendv.52@gmail.com | 2026-07-05T08:23:57+0000 |
| T1: run_completed | tiendv.52@gmail.com | 2026-07-05T08:26:04.313Z |
| T3: run_completed | tiendv.52@gmail.com | 2026-07-05T08:26:17.700Z |
| T1: reviewer_started | tiendv.52@gmail.com | 2026-07-05T08:27:32.819Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-07-05T08:29:06.069Z |
| T1: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T08:47:39.842Z |
| T1: done | tiendv.52@gmail.com | 2026-07-05T08:48:50.544Z |
| T2: ready | tiendv.52@gmail.com | 2026-07-05T08:48:50.611Z |
| T2: claimed | tiendv.52@gmail.com | 2026-07-05T08:50:23.873Z |
| T2: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T08:50:31.786Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-07-05T09:23:16.656Z |
| T3: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T09:28:26.674Z |
| T3: done | tiendv.52@gmail.com | 2026-07-05T09:29:42.354Z |
| T2: claimed | tiendv.52@gmail.com | 2026-07-05T09:31:25.807Z |
| T2: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T09:31:29.885Z |
| T2: run_completed | tiendv.52@gmail.com | 2026-07-05T09:44:05.575Z |
| T2: reviewer_started | tiendv.52@gmail.com | 2026-07-05T09:47:18.318Z |
| T2: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T09:53:41.953Z |
| T2: done | tiendv.52@gmail.com | 2026-07-05T09:55:38.502Z |
| T4: ready | tiendv.52@gmail.com | 2026-07-05T09:55:38.632Z |
| T4: claimed | tiendv.52@gmail.com | 2026-07-05T10:01:53.062Z |
| T4: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T10:02:03.216Z |
| T4: started | tiendv.52@gmail.com | 2026-07-05T10:12:51+0000 |
| T4: run_completed | tiendv.52@gmail.com | 2026-07-05T10:21:04.880Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-07-05T10:22:45.761Z |
| T5: claimed | tiendv.52@gmail.com | 2026-07-05T11:18:16.918Z |
| T5: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T11:18:24.779Z |
| T6: claimed | tiendv.52@gmail.com | 2026-07-05T11:20:05.530Z |
| T6: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T11:20:13.762Z |
| T5: started | tiendv.52@gmail.com | 2026-07-05T11:21:47+0000 |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-07-05T11:22:28.325Z |
| T6: started | tiendv.52@gmail.com | 2026-07-05T11:26:21+0000 |
| T5: run_completed | tiendv.52@gmail.com | 2026-07-05T11:37:54.605Z |
| T6: run_completed | tiendv.52@gmail.com | 2026-07-05T11:38:07.701Z |
| T5: reviewer_started | tiendv.52@gmail.com | 2026-07-05T11:39:30.798Z |
| T6: reviewer_started | tiendv.52@gmail.com | 2026-07-05T11:46:29.886Z |
| T5: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T11:46:55.646Z |
| T5: fix_started | tiendv.52@gmail.com | 2026-07-05T11:50:27.619Z |
| T5: run_completed | tiendv.52@gmail.com | 2026-07-05T12:02:01.138Z |
| T5: reviewer_started | tiendv.52@gmail.com | 2026-07-05T12:04:31.803Z |
| T5: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T12:13:47.824Z |
| T5: fix_started | tiendv.52@gmail.com | 2026-07-05T12:14:59.466Z |
| T5: run_completed | pye@swellnetwork.io | 2026-07-05T12:40:54.000Z |
| T4: done | tiendv.52@gmail.com | 2026-07-05T12:49:43.768Z |
| T5: reviewer_started | tiendv.52@gmail.com | 2026-07-05T12:51:52.004Z |
| T6: reviewer_started | tiendv.52@gmail.com | 2026-07-05T12:54:24.921Z |
| T5: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T13:00:03.021Z |
| T6: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T13:00:09.002Z |
| T5: done | tiendv.52@gmail.com | 2026-07-05T13:01:29.964Z |
| T7: ready | tiendv.52@gmail.com | 2026-07-05T13:01:30.047Z |
| T6: done | tiendv.52@gmail.com | 2026-07-05T13:02:01.174Z |
| T7: claimed | tiendv.52@gmail.com | 2026-07-05T13:03:42.908Z |
| T7: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T13:03:51.308Z |
| T7: started | tiendv.52@gmail.com | 2026-07-05T13:06:11+0000 |
| T7: run_completed | tiendv.52@gmail.com | 2026-07-05T13:16:34.482Z |
| T7: reviewer_started | tiendv.52@gmail.com | 2026-07-05T13:18:03.138Z |
| T7: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T13:22:48.379Z |
| T7: done | tiendv.52@gmail.com | 2026-07-05T13:24:10.454Z |
| T8: ready | tiendv.52@gmail.com | 2026-07-05T13:24:10.542Z |
| T8: claimed | tiendv.52@gmail.com | 2026-07-05T13:26:06.378Z |
| T8: rag_pre_flight | tiendv.52@gmail.com | 2026-07-05T13:26:14.078Z |
| T8: started | tiendv.52@gmail.com | 2026-07-05T13:30:22+0000 |
| T8: run_completed | tiendv.52@gmail.com | 2026-07-05T13:45:24.406Z |
| T8: reviewer_started | tiendv.52@gmail.com | 2026-07-05T13:47:31.531Z |
| T8: reviewer_complete | tiendv.52@gmail.com | 2026-07-05T13:51:32.061Z |
| T8: done | tiendv.52@gmail.com | 2026-07-05T13:53:03.849Z |
| T1: retried | pye | 2026-07-05T15:13:26+0700 |
| T3: retried | pye | 2026-07-05T15:15:00+0700 |
| T3: retried | pye | 2026-07-05T16:22:23+0700 |
| T2: blocked | pye@swellnetwork.io | 2026-07-05T16:28:14+0700 |
| T2: ready | pye@swellnetwork.io | 2026-07-05T16:28:14+0700 |
| T4: manual_override | pye@swellnetwork.io | 2026-07-05T18:19:59+0700 |
| T6: manual_override | pye | 2026-07-05T19:38:23+0700 |
| T4: manual_override | pye@swellnetwork.io | 2026-07-05T19:42:54+0700 |