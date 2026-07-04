# Handoff — Remove backward-compatible single-workspace paths from RAG/GitNexus

## Summary
## Feature - Feature ID: `multi-workspace-rag-gitnexus-remove-backward` - Title: Remove backward-compatible single-workspace paths from RAG/GitNexus

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — rag-service — indexer: remove legacy WORKSPACE_URL/WORKSPACE_ID path | [PR](https://github.com/tiendv89/rag-service/pull/19) | Reviewer approved. |
| T2 — rag-service — RAG server: remove default /sse route + DEFAULT_WORKSPACE_ID | [PR](https://github.com/tiendv89/rag-service/pull/20) | Reviewer approved. |
| T3 — git-nexus — indexer: remove legacy WORKSPACE_URL path | [PR](https://github.com/tiendv89/git-nexus/pull/7) | — |
| T4 — git-nexus — server: remove legacy /sse route, eager legacy subprocess, DEFAULT_WORKSPACE_ID, legacy health fields | [PR](https://github.com/tiendv89/git-nexus/pull/8) | — |
| T5 — workflow — executor: remove buildMcpSseUrl legacy fallback | [PR](https://github.com/tiendv89/agent-workflow/pull/282) | — |
| T6 — hermes-agent — connection-scope the RAG tool; close GitNexus fallback gap | [PR](https://github.com/tiendv89/hermes-agent/pull/41) | Reviewer approved. |
| T7 — workflow — deployment: drop DEFAULT_WORKSPACE_ID from compose templates + init-agent docs | [PR](https://github.com/tiendv89/agent-workflow/pull/283) | — |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `claude/workflow_skills/init-agent/SKILL.md`
- `plugins/mcp_client.py`
- `plugins/tools/gitnexus.py`
- `plugins/tools/rag.py`
- `runtime/executors/claude/src/index.ts`
- `runtime/executors/claude/src/mcp-endpoint-binding.test.ts`
- `runtime/executors/claude/src/mcp-endpoint-binding.ts`
- `runtime/orchestrator/templates/docker-compose.local-docker.yml`
- `runtime/orchestrator/templates/docker-compose.yml`
- `services/gitnexus_indexer/__tests__/index.test.js`
- `services/gitnexus_indexer/__tests__/workspace.test.js`
- `services/gitnexus_indexer/index.js`
- `services/gitnexus_indexer/src/workspace.js`
- `services/gitnexus_server/main.py`
- `services/gitnexus_server/server.py`
- `services/gitnexus_server/tests/test_server.py`
- `services/indexer/main.py`
- `services/indexer/workspace_resolver.py`
- `services/rag_server/server.py`
- `tests/indexer/test_main.py`
- `tests/indexer/test_workspace_resolver.py`
- `tests/plugins/test_workflow_plugin_t3.py`
- `tests/plugins/test_workflow_plugin_t7.py`
- `tests/rag_server/test_query_endpoint.py`
- `tests/rag_server/test_sse_transport.py`
- `tests/rag_server/test_workspace_resolution.py`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: ready | pentative@gmail.com | 2026-07-04 07:54:31+00:00 |
| T1: claimed | tiendv.52@gmail.com | 2026-07-04 08:12:52.368000+00:00 |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-07-04 08:13:00.941000+00:00 |
| T2: ready | tiendv.52@gmail.com | 2026-07-04 09:08:34.801000+00:00 |
| T2: claimed | tiendv.52@gmail.com | 2026-07-04 09:10:04.672000+00:00 |
| T2: rag_pre_flight | tiendv.52@gmail.com | 2026-07-04 09:10:12.833000+00:00 |
| T7: ready | tiendv.52@gmail.com | 2026-07-04 10:50:10.979000+00:00 |
| T7: claimed | tiendv.52@gmail.com | 2026-07-04 10:51:51.105000+00:00 |
| T7: claimed | tiendv.52@gmail.com | 2026-07-04 11:21:48.704000+00:00 |
| T7: rag_pre_flight | tiendv.52@gmail.com | 2026-07-04 11:21:54.432000+00:00 |
| T3: ready | pentative@gmail.com | 2026-07-04T07:54:31.000Z |
| T5: ready | pentative@gmail.com | 2026-07-04T07:54:31Z |
| T6: ready | pentative@gmail.com | 2026-07-04T07:54:31Z |
| T3: claimed | tiendv.52@gmail.com | 2026-07-04T08:14:45.952Z |
| T3: rag_pre_flight | tiendv.52@gmail.com | 2026-07-04T08:14:53.991Z |
| T1: started | tiendv.52@gmail.com | 2026-07-04T08:16:53+0000 |
| T5: claimed | tiendv.52@gmail.com | 2026-07-04T08:17:09.508Z |
| T5: rag_pre_flight | tiendv.52@gmail.com | 2026-07-04T08:17:18.126Z |
| T3: started | tiendv.52@gmail.com | 2026-07-04T08:18:59+0000 |
| T6: claimed | tiendv.52@gmail.com | 2026-07-04T08:19:20.199Z |
| T6: rag_pre_flight | tiendv.52@gmail.com | 2026-07-04T08:19:29.189Z |
| T3: run_completed | tiendv.52@gmail.com | 2026-07-04T08:22:41.111Z |
| T3: reviewer_started | tiendv.52@gmail.com | 2026-07-04T08:24:46.698Z |
| T5: run_completed | tiendv.52@gmail.com | 2026-07-04T08:25:16.589Z |
| T5: reviewer_started | tiendv.52@gmail.com | 2026-07-04T08:26:50.440Z |
| T6: started | tiendv.52@gmail.com | 2026-07-04T08:29:05+0000 |
| T1: claimed | tiendv.52@gmail.com | 2026-07-04T08:34:07.695Z |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-07-04T08:34:12.007Z |
| T6: claimed | tiendv.52@gmail.com | 2026-07-04T08:43:59.927Z |
| T6: rag_pre_flight | tiendv.52@gmail.com | 2026-07-04T08:44:04.373Z |
| T1: started | tiendv.52@gmail.com | 2026-07-04T08:45:13+0000 |
| T3: done | tiendv.52@gmail.com | 2026-07-04T08:50:05.199Z |
| T5: done | tiendv.52@gmail.com | 2026-07-04T08:50:32.752Z |
| T1: run_completed | tiendv.52@gmail.com | 2026-07-04T08:55:33.086Z |
| T1: reviewer_started | tiendv.52@gmail.com | 2026-07-04T08:56:46.255Z |
| T6: run_completed | tiendv.52@gmail.com | 2026-07-04T08:59:25.275Z |
| T6: reviewer_started | tiendv.52@gmail.com | 2026-07-04T09:00:31.005Z |
| T1: reviewer_complete | tiendv.52@gmail.com | 2026-07-04T09:04:30.331Z |
| T1: done | tiendv.52@gmail.com | 2026-07-04T09:05:34.478Z |
| T6: reviewer_complete | tiendv.52@gmail.com | 2026-07-04T09:07:31.777Z |
| T6: done | tiendv.52@gmail.com | 2026-07-04T09:08:34.743Z |
| T4: ready | tiendv.52@gmail.com | 2026-07-04T09:08:34.805Z |
| T4: claimed | tiendv.52@gmail.com | 2026-07-04T09:11:46.832Z |
| T4: rag_pre_flight | tiendv.52@gmail.com | 2026-07-04T09:11:55.609Z |
| T4: started | tiendv.52@gmail.com | 2026-07-04T09:14:52+0000 |
| T2: started | tiendv.52@gmail.com | 2026-07-04T09:15:43+0000 |
| T4: run_completed | tiendv.52@gmail.com | 2026-07-04T09:19:54.524Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-07-04T09:21:01.552Z |
| T2: claimed | tiendv.52@gmail.com | 2026-07-04T09:22:17.465Z |
| T2: rag_pre_flight | tiendv.52@gmail.com | 2026-07-04T09:22:21.466Z |
| T4: review_blocked | tiendv.52@gmail.com | 2026-07-04T09:24:27.244Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-07-04T09:25:32.700Z |
| T2: run_completed | tiendv.52@gmail.com | 2026-07-04T09:26:04.943Z |
| T2: blocked | tiendv.52@gmail.com | 2026-07-04T09:26:16.645Z |
| T4: review_blocked | tiendv.52@gmail.com | 2026-07-04T09:28:44.724Z |
| T4: reviewer_started | tiendv.52@gmail.com | 2026-07-04T09:29:50.778Z |
| T4: review_blocked | tiendv.52@gmail.com | 2026-07-04T09:32:46.976Z |
| T2: reviewer_started | tiendv.52@gmail.com | 2026-07-04T10:43:31.369Z |
| T4: done | tiendv.52@gmail.com | 2026-07-04T10:48:13.628Z |
| T2: reviewer_complete | tiendv.52@gmail.com | 2026-07-04T10:48:58.172Z |
| T2: done | tiendv.52@gmail.com | 2026-07-04T10:50:10.876Z |
| T7: started | tiendv.52@gmail.com | 2026-07-04T11:24:19+0000 |
| T7: claimed | tiendv.52@gmail.com | 2026-07-04T12:16:57.487Z |
| T7: rag_pre_flight | tiendv.52@gmail.com | 2026-07-04T12:17:01.840Z |
| T7: blocked | tiendv.52@gmail.com | 2026-07-04T12:20:09.026Z |
| T7: reviewer_started | tiendv.52@gmail.com | 2026-07-04T12:46:00.530Z |
| T7: review_blocked | tiendv.52@gmail.com | 2026-07-04T12:49:01.055Z |
| T7: reviewer_started | tiendv.52@gmail.com | 2026-07-04T12:50:04.958Z |
| T7: review_blocked | tiendv.52@gmail.com | 2026-07-04T12:55:43.931Z |
| T7: reviewer_started | tiendv.52@gmail.com | 2026-07-04T12:57:42.285Z |
| T7: done | tiendv.52@gmail.com | 2026-07-04T13:17:43.802Z |
| T1: created | pentative@gmail.com | 2026-07-04T14:49:56+0700 |
| T2: created | pentative@gmail.com | 2026-07-04T14:49:56+0700 |
| T3: created | pentative@gmail.com | 2026-07-04T14:49:56+0700 |
| T4: created | pentative@gmail.com | 2026-07-04T14:49:56+0700 |
| T5: created | pentative@gmail.com | 2026-07-04T14:49:56+0700 |
| T6: created | pentative@gmail.com | 2026-07-04T14:49:56+0700 |
| T7: created | pentative@gmail.com | 2026-07-04T14:49:56+0700 |
| T1: blocked | pye@swellnetwork.io | 2026-07-04T15:32:01+0700 |
| T1: ready | pye@swellnetwork.io | 2026-07-04T15:32:01+0700 |
| T3: review_blocked | pye@swellnetwork.io | 2026-07-04T15:34:07+0700 |
| T3: blocked | pye@swellnetwork.io | 2026-07-04T15:34:07+0700 |
| T3: unblocked | pye@swellnetwork.io | 2026-07-04T15:34:07+0700 |
| T5: review_blocked | pye@swellnetwork.io | 2026-07-04T15:35:58+0700 |
| T5: blocked | pye@swellnetwork.io | 2026-07-04T15:35:58+0700 |
| T5: unblocked | pye@swellnetwork.io | 2026-07-04T15:35:58+0700 |
| T6: blocked | pye@swellnetwork.io | 2026-07-04T15:37:37+0700 |
| T6: ready | pye@swellnetwork.io | 2026-07-04T15:37:37+0700 |
| T2: ready | pye@swellnetwork.io | 2026-07-04T16:21:07+0700 |
| T2: in_review | pye@swellnetwork.io | 2026-07-04T17:40:44+0700 |
| T4: in_review | pye@swellnetwork.io | 2026-07-04T17:46:05+0700 |
| T7: ready | pye@swellnetwork.io | 2026-07-04T18:17:28+0700 |
| T7: ready | pye@swellnetwork.io | 2026-07-04T19:15:26+0700 |
| T7: ready | pye@swellnetwork.io | 2026-07-04T19:41:18+0700 |
| T7: claimed | pye@swellnetwork.io | 2026-07-04T19:41:53+0700 |
| T7: work_phase_complete | pye@swellnetwork.io | 2026-07-04T19:43:25+0700 |
| T7: work_phase_complete | pye@swellnetwork.io | 2026-07-04T20:11:57+0700 |