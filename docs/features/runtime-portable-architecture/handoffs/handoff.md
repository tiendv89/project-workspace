# Handoff — Portable runtime architecture — extract today's bundled orchestrator/executor into ports, adapters, and profiles

## Summary
## Feature - Feature ID: `runtime-portable-architecture` - Title: Portable runtime architecture — extract today's bundled orchestrator/executor into ports, adapters, and profiles

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — Port interfaces + types + fake adapters | [PR](https://github.com/tiendv89/agent-workflow/pull/66) | — |
| T10 — Portability spec doc + fake-orchestrator harness + CLAUDE.md updates | [PR](https://github.com/tiendv89/agent-workflow/pull/75) | — |
| T2 — Extract today's adapters; wire `local-subprocess` profile | [PR](https://github.com/tiendv89/agent-workflow/pull/67) | — |
| T3 — CompletionBrokerPort + InMemoryBrokerAdapter + HTTP receiver | [PR](https://github.com/tiendv89/agent-workflow/pull/68) | — |
| T4 — Runner wrapper script (D6c) | [PR](https://github.com/tiendv89/agent-workflow/pull/69) | — |
| T5 — SubProcessAdapter async submit/reap with broker integration | [PR](https://github.com/tiendv89/agent-workflow/pull/71) | — |
| T6 — Refactor orchestrator concerns + shared reap loop | [PR](https://github.com/tiendv89/agent-workflow/pull/72) | — |
| T7 — Redis-backed broker service (Go) + container | [PR](https://github.com/tiendv89/agent-workflow/pull/70) | — |
| T8 — DockerRunAdapter | [PR](https://github.com/tiendv89/agent-workflow/pull/73) | — |
| T9 — docker-compose template + bridge network | [PR](https://github.com/tiendv89/agent-workflow/pull/74) | — |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `.codex`
- `.env.template`
- `docs/features/agent-runtime-split/logs/T1/2026-05-01T16-09-57.934Z.jsonl`
- `docs/features/agent-runtime-split/logs/T1/2026-05-01T16-50-20.067Z.jsonl`
- `docs/features/agent-runtime-split/logs/T2/2026-05-01T16-57-45.468Z.jsonl`
- `docs/features/agent-runtime-split/logs/T2/2026-05-01T17-38-58.700Z.jsonl`
- `docs/features/agent-runtime-split/logs/T2/2026-05-01T17-54-59.561Z.jsonl`
- `docs/features/agent-runtime-split/logs/T2/2026-05-01T18-28-53.044Z.jsonl`
- `docs/features/agent-runtime-split/logs/T2/2026-05-01T18-40-24.410Z.jsonl`
- `docs/features/agent-runtime-split/logs/T2/2026-05-01T18-48-16.542Z.jsonl`
- `docs/features/agent-runtime-split/product-spec.md`
- `docs/features/agent-runtime-split/tasks.md`
- `docs/features/agent-runtime-split/tasks/T1.yaml`
- `docs/features/agent-runtime-split/tasks/T2.yaml`
- `docs/features/agent-runtime-split/tasks/T3.yaml`
- `docs/features/agent-runtime-split/tasks/T4.yaml`
- `docs/features/agent-runtime-split/tasks/T5.yaml`
- `docs/features/agent-runtime-split/technical-design.md`
- `docs/features/check-status-across-all-branches/product-spec.md`
- `docs/features/check-status-across-all-branches/status.yaml`
- `docs/features/check-status-across-all-branches/tasks.md`
- `docs/features/check-status-across-all-branches/tasks/T1.yaml`
- `docs/features/check-status-across-all-branches/tasks/T2.yaml`
- `docs/features/check-status-across-all-branches/tasks/T3.yaml`
- `docs/features/check-status-across-all-branches/tasks/T4.yaml`
- `docs/features/check-status-across-all-branches/technical-design.md`
- `docs/features/feature-status-dashboard-check-status-across-all-branches/product-spec.md`
- `docs/features/feature-status-dashboard-check-status-across-all-branches/status.yaml`
- `docs/features/feature-status-dashboard-check-status-across-all-branches/tasks.md`
- `docs/features/feature-status-dashboard-check-status-across-all-branches/tasks/T1.yaml`
- `docs/features/feature-status-dashboard-check-status-across-all-branches/tasks/T2.yaml`
- `docs/features/feature-status-dashboard-check-status-across-all-branches/tasks/T3.yaml`
- `docs/features/feature-status-dashboard-check-status-across-all-branches/tasks/T4.yaml`
- `docs/features/feature-status-dashboard-check-status-across-all-branches/tasks/T5.yaml`
- `docs/features/feature-status-dashboard-check-status-across-all-branches/tasks/T6.yaml`
- `docs/features/feature-status-dashboard-check-status-across-all-branches/tasks/T7.yaml`
- `docs/features/feature-status-dashboard-check-status-across-all-branches/technical-design.md`
- `docs/features/feature-status-dashboard-v2/logs/T5/2026-04-28T08-16-01.534Z.jsonl`
- `docs/features/feature-status-dashboard-v2/logs/T6/2026-04-28T08-32-18.303Z.jsonl`
- `docs/features/feature-status-dashboard-v2/tasks/T5.yaml`
- `docs/features/feature-status-dashboard-v2/tasks/T6.yaml`
- `docs/features/feature-status-dashboard-v2/tasks/T7.yaml`
- `docs/features/feature-status-dashboard-v2/tasks/T8.yaml`
- `docs/features/feature-status-dashboard-v2/tasks/T9.yaml`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: ready | matthew@liquid-labs.xyz | 2026-05-03T19:21:32Z |
| T1: created | matthew@liquid-labs.xyz | 2026-05-04T02:05:33+0700 |
| T10: created | matthew@liquid-labs.xyz | 2026-05-04T02:05:33+0700 |
| T2: created | matthew@liquid-labs.xyz | 2026-05-04T02:05:33+0700 |
| T3: created | matthew@liquid-labs.xyz | 2026-05-04T02:05:33+0700 |
| T4: created | matthew@liquid-labs.xyz | 2026-05-04T02:05:33+0700 |
| T5: created | matthew@liquid-labs.xyz | 2026-05-04T02:05:33+0700 |
| T6: created | matthew@liquid-labs.xyz | 2026-05-04T02:05:33+0700 |
| T7: created | matthew@liquid-labs.xyz | 2026-05-04T02:05:33+0700 |
| T8: created | matthew@liquid-labs.xyz | 2026-05-04T02:05:33+0700 |
| T9: created | matthew@liquid-labs.xyz | 2026-05-04T02:05:33+0700 |
| T1: claimed | tiendv.52@gmail.com | 2026-05-04T03:07:04.082Z |
| T1: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T03:07:16.999Z |
| T1: done | tiendv.52@gmail.com | 2026-05-04T03:34:59.209Z |
| T2: ready | tiendv.52@gmail.com | 2026-05-04T03:34:59.254Z |
| T4: ready | tiendv.52@gmail.com | 2026-05-04T03:34:59.259Z |
| T2: claimed | tiendv.52@gmail.com | 2026-05-04T03:36:48.946Z |
| T2: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T03:37:02.953Z |
| T4: claimed | pentative@gmail.com | 2026-05-04T03:50:01.578Z |
| T4: rag_pre_flight | pentative@gmail.com | 2026-05-04T03:50:10.278Z |
| T2: in_review | tiendv.52@gmail.com | 2026-05-04T03:54:19.503Z |
| T2: review_started | pentative@gmail.com | 2026-05-04T03:56:31.296Z |
| T2: comments_addressed | pentative@gmail.com | 2026-05-04T04:01:20+0000 |
| T2: done | pentative@gmail.com | 2026-05-04T04:51:21.840Z |
| T3: ready | pentative@gmail.com | 2026-05-04T04:51:21.848Z |
| T3: claimed | tiendv.52@gmail.com | 2026-05-04T04:52:23.306Z |
| T3: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T04:52:36.584Z |
| T4: claimed | pentative@gmail.com | 2026-05-04T04:54:41.891Z |
| T4: rag_pre_flight | pentative@gmail.com | 2026-05-04T04:54:46.138Z |
| T3: in_review | tiendv.52@gmail.com | 2026-05-04T05:05:12.180Z |
| T3: done | tiendv.52@gmail.com | 2026-05-04T05:23:46.508Z |
| T7: ready | tiendv.52@gmail.com | 2026-05-04T05:23:46.534Z |
| T7: claimed | tiendv.52@gmail.com | 2026-05-04T05:27:24.426Z |
| T7: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T05:27:40.899Z |
| T4: claimed | tiendv.52@gmail.com | 2026-05-04T05:29:13.525Z |
| T4: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T05:29:21.107Z |
| T4: in_review | tiendv.52@gmail.com | 2026-05-04T05:33:58.969Z |
| T7: in_review | tiendv.52@gmail.com | 2026-05-04T05:45:40.505Z |
| T4: done | tiendv.52@gmail.com | 2026-05-04T05:45:53.960Z |
| T5: ready | tiendv.52@gmail.com | 2026-05-04T05:45:53.990Z |
| T5: claimed | tiendv.52@gmail.com | 2026-05-04T05:47:25.922Z |
| T7: done | pentative@gmail.com | 2026-05-04T06:01:07.839Z |
| T5: done | pentative@gmail.com | 2026-05-04T06:50:29.767Z |
| T6: ready | pentative@gmail.com | 2026-05-04T06:50:29.786Z |
| T5: done | tiendv.52@gmail.com | 2026-05-04T06:50:30.118Z |
| T6: ready | tiendv.52@gmail.com | 2026-05-04T06:50:30.186Z |
| T6: claimed | tiendv.52@gmail.com | 2026-05-04T06:59:19.796Z |
| T6: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T06:59:34.902Z |
| T6: started | agent@workflow.local | 2026-05-04T07:30:23+0000 |
| T6: blocked | tiendv.52@gmail.com | 2026-05-04T07:32:59.705Z |
| T6: claimed | pentative@gmail.com | 2026-05-04T07:44:25.483Z |
| T6: rag_pre_flight | pentative@gmail.com | 2026-05-04T07:44:31.283Z |
| T6: in_review | pentative@gmail.com | 2026-05-04T07:55:09.280Z |
| T6: review_started | tiendv.52@gmail.com | 2026-05-04T08:16:19.522Z |
| T6: comments_addressed | tiendv.52@gmail.com | 2026-05-04T08:24:38+0000 |
| T6: done | tiendv.52@gmail.com | 2026-05-04T08:40:54.183Z |
| T8: ready | tiendv.52@gmail.com | 2026-05-04T08:40:54.216Z |
| T8: claimed | tiendv.52@gmail.com | 2026-05-04T08:42:37.226Z |
| T8: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T08:42:51.818Z |
| T8: in_review | tiendv.52@gmail.com | 2026-05-04T09:05:48.300Z |
| T8: done | tiendv.52@gmail.com | 2026-05-04T09:20:10.536Z |
| T9: ready | tiendv.52@gmail.com | 2026-05-04T09:20:10.592Z |
| T9: claimed | tiendv.52@gmail.com | 2026-05-04T09:21:05.017Z |
| T9: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T09:21:19.088Z |
| T1: in_review | matthew@liquid-labs.xyz | 2026-05-04T10:33:45+0700 |
| T9: done | tiendv.52@gmail.com | 2026-05-04T10:47:34.091Z |
| T10: ready | tiendv.52@gmail.com | 2026-05-04T10:47:34.132Z |
| T10: claimed | tiendv.52@gmail.com | 2026-05-04T10:48:35.096Z |
| T10: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T10:48:48.854Z |
| T10: claimed | tiendv.52@gmail.com | 2026-05-04T11:20:56.449Z |
| T10: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T11:21:04.987Z |
| T10: claimed | tiendv.52@gmail.com | 2026-05-04T11:24:04.864Z |
| T10: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T11:24:15.464Z |
| T4: ready | matthew@liquid-labs.xyz | 2026-05-04T11:52:58+0700 |
| T4: ready | matthew@swellnetwork.io | 2026-05-04T12:27:48+0700 |
| T10: claimed | tiendv.52@gmail.com | 2026-05-04T12:51:32.973Z |
| T10: claimed | tiendv.52@gmail.com | 2026-05-04T12:53:36.595Z |
| T10: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T12:53:46.525Z |
| T5: in_review | matthew@swellnetwork.io | 2026-05-04T13:48:11+0700 |
| T6: ready | matthew@swellnetwork.io | 2026-05-04T14:39:52+0700 |
| T10: claimed | tiendv.52@gmail.com | 2026-05-04T16:52:24.965Z |
| T10: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T16:52:33.494Z |
| T9: in_review | matthew@swellnetwork.io | 2026-05-04T17:46:00+0700 |
| T10: claimed | tiendv.52@gmail.com | 2026-05-04T18:02:46.821Z |
| T10: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T18:02:55.397Z |
| T10: ready | matthew@swellnetwork.io | 2026-05-04T18:18:13+0700 |
| T10: ready | matthew@swellnetwork.io | 2026-05-04T18:22:57+0700 |
| T10: ready | matthew@swellnetwork.io | 2026-05-04T18:30:45+0700 |
| T10: claimed | tiendv.52@gmail.com | 2026-05-04T18:32:09.395Z |
| T10: rag_pre_flight | tiendv.52@gmail.com | 2026-05-04T18:32:17.259Z |
| T10: ready | matthew@swellnetwork.io | 2026-05-04T23:49:46+0700 |
| T10: ready | matthew@swellnetwork.io | 2026-05-05T00:30:40+0700 |
| T10: ready | matthew@swellnetwork.io | 2026-05-05T01:29:20+0700 |
| T10: blocked | tiendv.52@gmail.com | 2026-05-05T03:08:41.521Z |
| T10: claimed | tiendv.52@gmail.com | 2026-05-05T03:31:43.898Z |
| T10: rag_pre_flight | tiendv.52@gmail.com | 2026-05-05T03:31:52.379Z |
| T10: claimed | tiendv.52@gmail.com | 2026-05-05T03:59:09.510Z |
| T10: rag_pre_flight | tiendv.52@gmail.com | 2026-05-05T03:59:17.670Z |
| T10: in_review | tiendv.52@gmail.com | 2026-05-05T04:09:51.075Z |
| T10: done | tiendv.52@gmail.com | 2026-05-05T05:29:40.445Z |
| T10: ready | matthew@swellnetwork.io | 2026-05-05T10:29:33+0700 |
| T10: ready | matthew@swellnetwork.io | 2026-05-05T10:54:16+0700 |