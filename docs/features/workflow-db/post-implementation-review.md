# Post-implementation review — `workflow-db`

**Date:** 2026-06-09
**Reviewer:** matthew@swellnetwork.io (local review, no GitHub posts)
**Trigger:** Feature reached `in_handoff` (handoff PR #501 + 4 impl feature-branch PRs open). A local review of all 19 implementation PRs was run against the technical design, per-task acceptance criteria, and the `review-pr` rubric before accepting the handoff.

**Outcome:** The schema, sync-adapter scoping, broker partitioning, TS owner-guards, owner-aware skills, and most of the Go orchestrator (claim, eligibility, transitions, auto-ready, PR-merge poll) are sound and merge-worthy. **However, the Go orchestrator's dispatch + reap path — the core thing the feature exists to prove — does not function against the real broker/dispatcher as merged.** The e2e gate (T18) mocked the broker, so it did not catch this. The feature is therefore re-opened to `in_implementation`; the 5 handoff PRs are held open until the remediation tasks (T19–T22) land.

---

## Verdict summary (all 19 PRs)

| Task | Repo / PR | Verdict | Headline |
|---|---|---|---|
| T1 | workflow-backend #30 | ✅ APPROVE | Migration byte-matches v003 dbml; FK-safe destructive down |
| T15 | workflow-backend #31 | ✅ APPROVE | `owner` DTO `omitempty`; go rows surface unchanged |
| T2 | workspace-github-adapter #29 | ✅ APPROVE | All upserts + deletes scoped `owner IS NULL`; go rows safe by construction |
| T3 | agent-workflow #260 | ✅ APPROVE | Owner-partitioned completion queues; absent-owner ⇒ legacy fallback correct |
| T4 | agent-workflow #259 | ✅ APPROVE | Guards on exactly the 3 status.yaml-gated loops; legacy unchanged |
| T16 | agent-workflow #261 | ✅ APPROVE | `init-feature` truly asks go/ts, never assumes |
| T17 | agent-workflow #262 | ✅ APPROVE | `tech-lead` emits no git task YAMLs for go; materialization input correct |
| T17b | agent-workflow #258 | ✅ APPROVE | 🟢 traceability: the claude gate actually landed in PR #257, not #258 |
| T5 | workflow-orchestrator #1 | ✅ APPROVE | pgx/sqlc layer clean; correct pool lifecycle |
| T7 | workflow-orchestrator #3 | ✅ APPROVE | Eligibility correctly enforces **ALL**-deps-done (not ANY) |
| T8 | workflow-orchestrator #4 | ✅ APPROVE | Guarded claim; 0-rows loser path returns `(false,nil)`; race test passes |
| T9 | workflow-orchestrator #6 | ✅ APPROVE | True guarded transitions; advisory-lock activity-sequence |
| T10 | workflow-orchestrator #7 | ✅ APPROVE | Auto-ready in same tx as `done`; ALL-deps; no re-ready past `ready` |
| T13 | workflow-orchestrator #8 | ✅ APPROVE | merged:true (not closed); guarded same-tx done + auto-ready; API errors safe |
| T6 | workflow-orchestrator #2 | 🟡 CHANGES | `actor_type` parsed but never persisted; `MaterializeFeature` DRY duplication → **T20** |
| **T11** | **workflow-orchestrator #5** | 🔴 **CHANGES** | **Dispatch does not match the real broker/dispatcher ABI → T19** |
| **T12** | **workflow-orchestrator #9** | 🔴 **CHANGES** | **Reap cannot resolve completions (empty slugs); no `owner='go'` scope → T19** |
| T14 | workflow-orchestrator #10 | 🟡 CHANGES | Shipped non-existent `golang:1.25-alpine`; builder/go.mod mismatch; no poll backoff → **T21** |
| T18 | workflow-orchestrator #11 | 🟡 CHANGES | Asserts the invariants — but against a **mock** broker, so it missed the T11/T12 defects → **T22** |

---

## 🔴 Root cause — the Go broker client was built to a guessed protocol

There is a cross-repo seam between the new Go orchestrator (`workflow-orchestrator`) and the real broker / dispatcher / ABI (`agent-workflow/runtime/{broker,dispatcher,abi}`). T11 (dispatch) and T12 (reap) were written to a **guessed** wire protocol; their unit tests **mocked the guess**; and the e2e gate (T18) used a **test-local mock broker** rather than the real broker binary. So nothing in the entire feature exercised the real contract, and the result compiles, tests green, and merges — while the load-bearing path is non-functional.

This is **in v1 scope, not deferred**: the v1 "human-merge slice" still requires claim → dispatch → executor opens the impl PR → reap → `in_review`. A broken dispatch/reap loop means v1's core path does not run end-to-end.

### Confirmed defects (verified against the real code)

1. **No `job` envelope on the dispatch stream entry.**
   `internal/orchestrator/dispatch.go:131-141` (`enqueueJob`) `XADD`s flat individual fields (`task_id`, `feature_id`, `workspace_id`, `handle`, `management_repo`, `base_branch`, `branch`). The dispatcher reads a **single field named `job`** and `JSON.parse`s it into a `DispatchJob` (`agent-workflow/runtime/dispatcher/src/consumer.ts:347-349`). With no `job` field, `message.job` is `undefined` → `dispatch_parse_error` is emitted and the entry is discarded → **no executor ever spawns.**

2. **No `nonce` sent on `/register`.**
   `dispatch.go:88-122` (`registerHandle`) posts `{handle, owner, metadata}` with **no nonce**. The ABI requires a single-use nonce (`agent-workflow/runtime/abi/src/types.ts:54`) and the broker rejects any callback whose nonce does not match the registered one. The required `DispatchJob.nonce` is also absent from the enqueue. → **the executor's completion callback fails validation and never lands in `broker:pending:go`.**

3. **PascalCase metadata tags.**
   `dispatch.go:49-52` declares `handleMetadata` with JSON tags `"FeatureID"`, `"TaskID"`, `"TenantID"`, `"StartedAt"`. The broker's `HandleMetadata` uses snake_case: `"feature_id"`, `"task_id"`, `"tenant_id"`, `"started_at"` (`agent-workflow/runtime/broker/internal/store/store.go:18-23`). The broker stores **empty** slugs, which breaks reap's slug-based row resolution.

4. **Reap slow-path lookup is not owner-scoped.**
   `internal/orchestrator/reap.go` `dbLookupTaskBySlug` resolves a completion by `workspace_id + feature_name + task_name` but **without `owner='go'`**. Combined with defect 3 (empty slugs after restart, when the in-memory `HandleStore` fast path is gone), this can fail to resolve, or in principle resolve onto a legacy (`owner IS NULL`) row sharing the same slug. The §4.4 contract requires resolution scoped to `owner='go'`.

**All four share one fix:** align the Go broker client to the real ABI. They are kept as a single task (**T19**) because the snake_case `HandleMetadata` struct is shared by both the register (dispatch) and decode (reap) paths — fixing one without the other leaves the protocol half-broken.

---

## 🟡 Secondary findings

### T6 (#2) — `actor_type` dropped + DRY duplication → **T20**
- `GoTaskSpec.ActorType` is parsed from the fixture but **never persisted** — `InsertTask` writes no `execution`/`actor_type` (`internal/orchestrator/create.go`). This violates the task-structure rule requiring `execution.actor_type`.
- `MaterializeFeature` (`create.go:189-270`) duplicates the bodies of `CreateFeature`/`CreateTask`/`InitialAutoReady` inline (because those helpers take `*pgxpool.Pool` and cannot join the tx). The two copies have **already drifted** on `actor_type`. Refactor the helpers to accept a `queries.DBTX` so the materializer composes them inside the tx.

### T14 (#10) — runtime hardening → **T21**
- PR shipped `FROM golang:1.25-alpine`, which does not exist — the "`docker build` succeeds" acceptance criterion failed. Fixed only later in `766ee75`, which now pins `golang:1.24-alpine` while `go.mod` declares `go 1.25.7` (forces a toolchain re-download; fails in an offline/network-restricted build).
- Poll loop uses a fixed `time.Ticker` with no jitter/backoff (rubric: thundering-herd / GitHub rate-limit risk).
- `serveHealthz` does `log.Fatal` on `ListenAndServe` error — a healthz port-bind failure kills the whole orchestrator.

### T18 (#11) — e2e mocks the broker → **T22**
- The test is a real testcontainers integration test and asserts all six invariants — but the two most load-bearing (A2: TS never drains a go completion; A3: go drains only its own) run against a test-local `mockBroker` that re-implements partition-by-owner, and the "TS" side is a directly-seeded DB row, not a real broker drain. This is **exactly why** the T11/T12 protocol defects slipped through.
- The suite applies a checked-in `db/schema/schema.sql` snapshot rather than the real goose migrations, so it can pass against a schema prod never runs.

---

## 🟢 Non-blocking notes
- T5: `db/schema/schema.sql` snapshot omits the two `owner` indexes T1 adds (codegen-harmless fidelity nit).
- T1: `goose up/down` was never run against a live Postgres (no Docker in CI) — SQL is statically correct; recommend one manual run before go-live.
- T9: `SetBlocked` allows `blocked` from any status (`from="*"`) — broader than v1's FSM (`in_progress → blocked`).
- T2: the upsert `COALESCE(owner, EXCLUDED.owner)` guards the `owner` value but not sibling columns; safe today because go features never enter the YAML snapshot.
- T17b: the claude owner-gate landed via PR #257, not the recorded #258 — correct in the merged tree, audit-trail mismatch only.

---

## Remediation tasks

| Task | Title | Fixes | Repo | Depends on |
|---|---|---|---|---|
| **T19** | Align Go broker client to the real broker/dispatcher ABI | 🔴 T11, T12 | `workflow-orchestrator` | — |
| **T20** | Persist `actor_type`; de-dup `MaterializeFeature` via shared `DBTX` | 🟡 T6 | `workflow-orchestrator` | — |
| **T21** | Orchestrator runtime hardening (builder image, poll backoff, non-fatal healthz) | 🟡 T14 | `workflow-orchestrator` | — |
| **T22** | Replace T18 e2e mock broker with the real broker; run real migrations in the suite | 🟡 T18 | `workflow-orchestrator` | T19 |

Each task's precise scope, files, and acceptance criteria are in `tasks.md` under the matching `## T<n>` section; the findings they address are detailed above.
