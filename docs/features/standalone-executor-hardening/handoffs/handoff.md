# Handoff — Standalone Executor Hardening — Harden local-docker Spawn-on-the-Fly for Concurrent Topologies

## Summary
## Feature - Feature ID: `standalone-executor-hardening` - Title: Standalone Executor Hardening — Harden `local-docker` Spawn-on-the-Fly for Concurrent Topologies

## Tasks Completed
| Task | PR | Reviewer Notes |
|---|---|---|
| T1 — ABI: DispatchJob payload + dispatch-stream contract + LOG_SINK env | [PR](https://github.com/tiendv89/agent-workflow/pull/238) | All T1 acceptance criteria met. CI passed (4/4 checks). DispatchJob interface correct with no secret fields; three dispatch-stream constants defined as named exports; LOG_SINK documented in runner env contract with git default; ExecutorResult unchanged (ABI-neutral, explicitly documented). One 🟢 nit only (redundant runtime secret-field checks in tests). PR squash-merged. |
| T2 — Broker: GET /registry-size (completion-only; no dispatch state) | [PR](https://github.com/tiendv89/agent-workflow/pull/239) | CI passed (4 checks). Implementation is narrowly scoped to GET /registry-size, adds RegistrySize to the Store interface implemented by both MemoryStore and RedisStore, uses correct key pattern broker:reg:* matching regKey(handle). No dispatch state or endpoints added. Tests cover empty, N-registered, and post-ack cases for both backends. Squash-merged. |
| T3 — Executors: gate flushLog on LOG_SINK (claude + hermes) | [PR](https://github.com/tiendv89/agent-workflow/pull/240) | All T3 subtasks implemented. CI green (4 checks: vitest unit + hermes integration, all success). No 🔴/🟡 findings. LOG_SINK=none guard added identically in both claude and hermes flush-log.ts. All 4 acceptance criteria met: none→no git ops, git→flush, absent→flush, no result.json change. |
| T4 — Dispatcher service: own dispatch stream, spawn, credentials, idempotency | [PR](https://github.com/tiendv89/agent-workflow/pull/241) | All T4 acceptance criteria met. Previous cycle 🟡 finding (DLQ test not exercising HTTP POST to /callback) resolved by direct _moveToDlq test with module-level node:http mock. All 10 tests pass. Only 🟢 nits remain (non-atomic lock release in error path; any cast for xAutoClaim). |
| T5 — Orchestrator: QueueDispatchAdapter, drop socket/creds, dispatch reconciler | [PR](https://github.com/tiendv89/agent-workflow/pull/242) | All T5 subtasks implemented. CI passed (4/4 checks success). No 🔴/🟡 findings. Two 🟢 nits: dead `fields` array in queue-dispatch.ts; redundant broker.register in reconciler (idempotent, acknowledged in comments). |
| T6 — Compose + dev wiring: local-docker stack + .env templates | [PR](https://github.com/tiendv89/agent-workflow/pull/243) | All T6 subtasks implemented. CI passed (4/4 checks). Dispatcher service added with Docker socket; orchestrator-1 stripped of socket privilege; .env.template updated with dispatcher/LOG_SINK/dispatch-stream vars (no MinIO); concurrent-bundled profile provides bundled ∥ standalone coexistence for T7. One 🟢 nit (unused socket mount on orchestrator-bundled dev profile — does not block). No 🔴/🟡 findings. |
| T7 — Integration + concurrent-coexistence parity test | [PR](https://github.com/tiendv89/agent-workflow/pull/244) | All T7 subtasks implemented. CI 4/4 passed. Cycle 1 finding (missing blockedEventEmitted assertion in reconciler MAX_RETRIES test D.3) verified fixed and correct. No 🔴/🟡 findings remaining. |

## Deviations from Technical Design
_See reviewer notes in Tasks Completed table above._

## Files Changed
- `.env.template`
- `runtime/abi/docs/abi-spec.md`
- `runtime/abi/src/index.ts`
- `runtime/abi/src/types.ts`
- `runtime/abi/tests/dispatch-job.test.ts`
- `runtime/broker/internal/server/server.go`
- `runtime/broker/internal/server/server_test.go`
- `runtime/broker/internal/store/memory.go`
- `runtime/broker/internal/store/redis.go`
- `runtime/broker/internal/store/redis_test.go`
- `runtime/broker/internal/store/store.go`
- `runtime/dispatcher/Dockerfile`
- `runtime/dispatcher/package-lock.json`
- `runtime/dispatcher/package.json`
- `runtime/dispatcher/src/config.ts`
- `runtime/dispatcher/src/consumer.ts`
- `runtime/dispatcher/src/credential.ts`
- `runtime/dispatcher/src/index.ts`
- `runtime/dispatcher/src/spawner.ts`
- `runtime/dispatcher/tests/consumer.test.ts`
- `runtime/dispatcher/tests/dispatcher-integration.test.ts`
- `runtime/dispatcher/tsconfig.json`
- `runtime/dispatcher/vitest.unit.config.ts`
- `runtime/executors/claude/src/flush-log.test.ts`
- `runtime/executors/claude/src/flush-log.ts`
- `runtime/executors/hermes/src/flush-log.test.ts`
- `runtime/executors/hermes/src/flush-log.ts`
- `runtime/orchestrator/src/executor/queue-dispatch.ts`
- `runtime/orchestrator/src/loop/dispatch-reconciler.ts`
- `runtime/orchestrator/src/main.ts`
- `runtime/orchestrator/src/profiles/local-docker.ts`
- `runtime/orchestrator/templates/.projects/.env.example`
- `runtime/orchestrator/templates/QUICKSTART-local-docker.md`
- `runtime/orchestrator/templates/docker-compose.local-docker.yml`
- `runtime/orchestrator/tests/dispatch-reconciler.test.ts`
- `runtime/orchestrator/tests/integration/standalone-executor-hardening.integration.test.ts`
- `runtime/orchestrator/tests/queue-dispatch-adapter.test.ts`

## Follow-up Items
_None identified._

## Audit Trail
| Action | Actor | Timestamp |
|---|---|---|
| T1: ready | tiendv.52@gmai.com | 2026-05-30T17:09:10Z |
| T2: ready | tiendv.52@gmai.com | 2026-05-30T17:09:10Z |
| T1: claimed | norepy@tiendv.dev | 2026-05-30T17:18:19.718Z |
| T1: rag_pre_flight | norepy@tiendv.dev | 2026-05-30T17:18:34.386Z |
| T2: claimed | norepy@tiendv.dev | 2026-05-30T17:21:15.823Z |
| T1: started | norepy@tiendv.dev | 2026-05-30T17:21:19+0000 |
| T2: rag_pre_flight | norepy@tiendv.dev | 2026-05-30T17:21:32.993Z |
| T2: started | norepy@tiendv.dev | 2026-05-30T17:25:14+0000 |
| T1: run_completed | norepy@tiendv.dev | 2026-05-30T17:29:39.500Z |
| T1: reviewer_started | noreply@tiendv.dev | 2026-05-30T17:32:46.107Z |
| T1: reviewer_complete | norepy@tiendv.dev | 2026-05-30T17:39:10.620Z |
| T2: run_completed | norepy@tiendv.dev | 2026-05-30T17:39:43.386Z |
| T1: done | norepy@tiendv.dev | 2026-05-30T17:41:28.874Z |
| T3: ready | norepy@tiendv.dev | 2026-05-30T17:41:29.341Z |
| T5: ready | norepy@tiendv.dev | 2026-05-30T17:41:29.345Z |
| T3: claimed | norepy@tiendv.dev | 2026-05-30T17:44:06.898Z |
| T3: rag_pre_flight | norepy@tiendv.dev | 2026-05-30T17:44:21.100Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-30T17:44:30.280Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-30T17:44:44.559Z |
| T5: started | norepy@tiendv.dev | 2026-05-30T17:48:41+0000 |
| T3: started | norepy@tiendv.dev | 2026-05-30T17:48:42+0000 |
| T2: reviewer_started | noreply@tiendv.dev | 2026-05-30T17:58:24.311Z |
| T3: claimed | norepy@tiendv.dev | 2026-05-30T18:02:47.199Z |
| T3: rag_pre_flight | norepy@tiendv.dev | 2026-05-30T18:02:54.093Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-30T18:03:34.633Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-30T18:03:41.600Z |
| T2: reviewer_complete | norepy@tiendv.dev | 2026-05-30T18:04:13.314Z |
| T3: started | norepy@tiendv.dev | 2026-05-30T18:06:37+0000 |
| T2: done | norepy@tiendv.dev | 2026-05-30T18:13:06.698Z |
| T4: ready | norepy@tiendv.dev | 2026-05-30T18:13:07.090Z |
| T3: run_completed | norepy@tiendv.dev | 2026-05-30T18:14:00.167Z |
| T4: claimed | norepy@tiendv.dev | 2026-05-30T18:15:43.521Z |
| T4: rag_pre_flight | norepy@tiendv.dev | 2026-05-30T18:15:55.579Z |
| T4: started | norepy@tiendv.dev | 2026-05-30T18:18:53+0000 |
| T3: reviewer_started | noreply@tiendv.dev | 2026-05-30T18:39:38.411Z |
| T4: run_completed | norepy@tiendv.dev | 2026-05-30T18:40:13.061Z |
| T4: reviewer_started | noreply@tiendv.dev | 2026-05-30T18:44:33.601Z |
| T3: reviewer_complete | norepy@tiendv.dev | 2026-05-30T18:44:58.917Z |
| T3: done | norepy@tiendv.dev | 2026-05-30T18:47:00.508Z |
| T4: reviewer_complete | norepy@tiendv.dev | 2026-05-30T18:53:55.119Z |
| T4: fix_started | norepy@tiendv.dev | 2026-05-30T18:55:38.921Z |
| T4: run_completed | norepy@tiendv.dev | 2026-05-30T19:04:13.883Z |
| T4: reviewer_started | noreply@tiendv.dev | 2026-05-30T19:06:19.365Z |
| T5: claimed | norepy@tiendv.dev | 2026-05-30T19:08:29.529Z |
| T5: rag_pre_flight | norepy@tiendv.dev | 2026-05-30T19:08:35.772Z |
| T5: started | norepy@tiendv.dev | 2026-05-30T19:12:46+0000 |
| T4: reviewer_complete | norepy@tiendv.dev | 2026-05-30T19:13:29.510Z |
| T4: done | norepy@tiendv.dev | 2026-05-30T19:15:25.782Z |
| T5: run_completed | norepy@tiendv.dev | 2026-05-30T19:38:00.756Z |
| T5: reviewer_started | noreply@tiendv.dev | 2026-05-30T19:40:05.049Z |
| T5: reviewer_complete | norepy@tiendv.dev | 2026-05-30T19:46:21.311Z |
| T5: done | norepy@tiendv.dev | 2026-05-30T19:48:16.388Z |
| T6: ready | norepy@tiendv.dev | 2026-05-30T19:48:16.711Z |
| T6: claimed | norepy@tiendv.dev | 2026-05-30T19:50:30.116Z |
| T6: rag_pre_flight | norepy@tiendv.dev | 2026-05-30T19:50:42.388Z |
| T6: started | norepy@tiendv.dev | 2026-05-30T19:53:37+0000 |
| T6: run_completed | norepy@tiendv.dev | 2026-05-30T20:16:37.631Z |
| T6: reviewer_started | noreply@tiendv.dev | 2026-05-30T20:18:41.272Z |
| T6: reviewer_complete | norepy@tiendv.dev | 2026-05-30T20:24:12.453Z |
| T6: done | norepy@tiendv.dev | 2026-05-30T20:25:17.862Z |
| T7: ready | norepy@tiendv.dev | 2026-05-30T20:25:18.215Z |
| T7: claimed | norepy@tiendv.dev | 2026-05-30T20:27:30.655Z |
| T7: rag_pre_flight | norepy@tiendv.dev | 2026-05-30T20:27:42.364Z |
| T7: started | norepy@tiendv.dev | 2026-05-30T20:38:30+0000 |
| T7: run_completed | norepy@tiendv.dev | 2026-05-30T20:50:48.455Z |
| T7: reviewer_started | noreply@tiendv.dev | 2026-05-30T20:51:38.621Z |
| T7: reviewer_complete | norepy@tiendv.dev | 2026-05-30T20:58:36.898Z |
| T7: fix_started | norepy@tiendv.dev | 2026-05-30T21:00:20.308Z |
| T7: run_completed | norepy@tiendv.dev | 2026-05-30T22:04:57.451Z |
| T7: reviewer_started | noreply@tiendv.dev | 2026-05-30T22:06:47.557Z |
| T7: reviewer_complete | norepy@tiendv.dev | 2026-05-30T22:13:43.906Z |
| T7: done | norepy@tiendv.dev | 2026-05-30T22:15:57.476Z |
| T1: created | matthew@swellnetwork.io | 2026-05-31T00:05:23+0700 |
| T2: created | matthew@swellnetwork.io | 2026-05-31T00:05:23+0700 |
| T3: created | matthew@swellnetwork.io | 2026-05-31T00:05:23+0700 |
| T4: created | matthew@swellnetwork.io | 2026-05-31T00:05:23+0700 |
| T5: created | matthew@swellnetwork.io | 2026-05-31T00:05:23+0700 |
| T6: created | matthew@swellnetwork.io | 2026-05-31T00:05:23+0700 |
| T7: created | matthew@swellnetwork.io | 2026-05-31T00:05:23+0700 |
| T3: ready | matthew@swellnetwork.io | 2026-05-31T01:00:25+0700 |
| T5: ready | matthew@swellnetwork.io | 2026-05-31T01:01:23+0700 |
| T5: ready | matthew@swellnetwork.io | 2026-05-31T01:45:25+0700 |