# Technical Design — `workflow-db`

## Feature
- Feature ID: `workflow-db`
- Title: Workflow State Database — Agent Write Path and Relational Storage
- Status: **draft** — Phase 1 design, pending human approval before task breakdown.
- Product spec: `docs/features/workflow-db/product-spec.md` (approved 2026-06-05)

> **Provenance.** RAG and GitNexus MCPs were unavailable in this session; this design is grounded by direct reads of the implementation repos checked out as workspace siblings (`agent-workflow`, `workflow-backend`, `workspace-github-adapter`) with `file:line` citations throughout. No Figma section: the product spec contains no Figma links and this feature ships no new frontend UI.

---

## 1. Current state

### What exists today
- **Workflow state is git/YAML.** Every claim, status change, and log entry is a commit+push to the management repo, arbitrated by push-rejection. The TS orchestrator discovers work by scanning `docs/features/*/tasks/*.yaml` from a git checkout (`agent-workflow/runtime/orchestrator/src/eligibility/match.ts`), claims via YAML mutate + commit + push with SHA-based contention (`.../src/task/claim.ts:150-372`), and resolves completions back to a task file by `metadata.feature_id`/`metadata.task_id` (`.../src/loop/reap-loop.ts:131-175`).
- **A Postgres mirror already exists.** Feature `workspace-data-backend` built:
  - **Schema + migrations + write adapter** in repo `workspace-github-adapter` — goose migrations under `database/migrations/` (`00001`–`00011`), sqlc queries under `database/queries/`, and a YAML→DB sync adapter (`internal/adapter/db/adapter.go`) that fetches YAML from GitHub, parses it, and **upserts** rows in a transaction, then **deletes rows not present in the source** (`upsertSnapshot` `adapter.go:562-617`; `DeleteWorkspaceFeaturesNotIn`).
  - **Read API** in repo `workflow-backend` — a gin service over a **read-only** pgx pool (`internal/database/db.go`), routes for workspaces/features/tasks/activity (`internal/handler/workspace.go:40-52`), DTOs the frontend consumes (`internal/domain/dto.go`).
  - Both services point at the **same Postgres** (`DATABASE_URL`).
- **The relevant tables already model our domain** (in `workspace-github-adapter/database/migrations`):
  - `workspace_features` — `feature_id UUID`, `feature_name`, `title`, `feature_status`, `current_stage`, `next_action`, `stages JSONB`, `source_path NOT NULL`, `source_hash`. Unique `(workspace_id, feature_name)`.
  - `workspace_tasks` — `task_id UUID`, `task_name`, `feature_id` FK, `title`, `status`, `blocked_reason`, `branch`, `repo`, `depends_on JSONB`, `execution JSONB`, `pr JSONB`, `workspace_pr JSONB`, `source_path NOT NULL`, `source_hash`. Unique `(workspace_id, feature_id, task_name)`.
  - `workspace_activity_events` — normalized log/history with `sequence` dedup.
  - `workspace_sync_runs` — sync audit trail.
- **The broker already carries identity.** `HandleMetadata{ Kind, Subkind, TaskID, FeatureID, TenantID, StartedAt }` (`agent-workflow/runtime/broker/internal/store/store.go:17-24`) rides on every completion. The dispatch stream (`platform:dispatch`) and completion broker (`broker:pending` sorted set, `broker:reg:{handle}`) are one Redis from `standalone-executor-hardening`. The executor is standalone/owner-agnostic and writes only `result.json`.

### Current constraints / limitations
- The Postgres mirror is **read-only and derived**: the only writer is the adapter, and its reconciliation **deletes any row not found in the YAML source**. A live writer that creates DB-only rows would have them deleted on the next sync unless reconciliation is scoped.
- `workspace_features.source_path` / `workspace_tasks.source_path` are `NOT NULL` — they assume a YAML origin.
- There is **no `owner` column** and **no claim/locking mechanism** in the schema; `status` is a free-text mirror, not an enforced FSM.
- `broker.ListCompleted(max, lockMs)` has **no filter** (`broker/internal/server/server.go:117-147`) — any orchestrator drains any completion.
- No org/tenant scoping in the schema (isolation is `workspace_id` only); `HandleMetadata.TenantID` exists but is unused by the schema.

### Relevant system boundaries (repos, from `workspace.yaml`)
- `workflow` → `agent-workflow` (TS orchestrator, Go broker, dispatcher, executors, ABI).
- `workspace-github-adapter` → schema/migrations + YAML→DB sync adapter.
- `workflow-backend` → read API consumed by the frontend.

---

## 2. Problem framing

### Primary goal
Introduce the **Go/Postgres orchestrator** that writes workflow state **directly to the database**, and run it alongside the TS/git orchestrator so it can **gradually take over and ultimately replace** the TS path. This feature is the *first step* of that replacement — not a permanent two-orchestrator end-state. Every decision below serves that goal first.

### What must change
1. Give the Go orchestrator a way to write live task state to the shared DB and claim tasks atomically — replacing git commits for the features it owns.
2. Add an **`owner`** discriminator so the DB can hold both legacy (YAML-synced) and live (DB-native) features without the two writers colliding.
3. Stop the YAML→DB sync adapter from **clobbering** live DB-native rows.
4. **Partition the broker** so the TS orchestrator never drains a Go feature's completion, and vice versa.

### Priorities (not hard constraints — everything here is changeable)
Nothing is off-limits: the FE, read API, executor, dispatcher, broker, schema, and the TS orchestrator may **all** be modified if the Go orchestrator needs it. We optimize for **low disruption to the running legacy path during the transition**, which yields the following *preferences* (reasons to reuse rather than rewrite) — not walls:
- **Keep the TS path working for legacy features** while it is still in service. The TS orchestrator may take small additive changes (e.g. declaring `owner='ts'` to the broker); we avoid changes that alter how it drives legacy features — but only because it is still running them, not because it is frozen.
- **Reuse the existing read API and FE if they suffice.** Go-owned rows can surface through `workflow-backend`'s existing endpoints with little or no change — preferred to keep scope down, but the FE/read API may change if the Go path needs it.
- **Reuse the executor and dispatcher** — they are owner-agnostic (ABI-neutral, from `standalone-executor-hardening`), so we reuse them as-is; they may change if required.
- **Single-owner-per-feature invariant** (this one *is* firm): every feature is driven by exactly one orchestrator at a time, so there is never a competing write to the same feature. (This is what the spec's "no dual-write" means — the term is shorthand for this invariant, not a separate rule.)

> **Spec reconciliation.** The approved `product-spec.md` framed "TS unchanged," "FE needs no change," and "executor unchanged" as near-hard constraints. Per human direction during design review these are **preferences, not constraints** — the overriding goal is the Go orchestrator replacing TS via direct DB writes, and anything may change to serve it. The spec wording is reconciled and a `scope_changed` entry recorded in `status.yaml` history; the `product_spec` stage remains approved.

### Assumptions already fixed
- Database is **PostgreSQL** (spec open question #1 — decided).
- Net-new-in-Go; **no import/migration** of existing git features (spec "Coexistence model").
- One shared Postgres + one shared schema (this design confirms spec open question #8 — see §4).

---

## 3. Options considered

### A. Where the live writer sits relative to the existing schema
- **A1 — Reuse the existing shared schema; partition write authority by `owner` (chosen).** Adapter owns `owner IS NULL` rows; Go orchestrator owns `owner = 'go'` rows.
  - *Pros*: one DB, one schema, FE unchanged by construction; smallest surface.
  - *Cons*: cross-repo schema coupling (migrations live in `workspace-github-adapter`); the adapter must learn to scope its reconciliation.
- **A2 — Separate `workflow-db` database/schema, synced into the read DB.** 
  - *Pros*: clean ownership.
  - *Cons*: reintroduces a sync step between the two databases and forces the read API to merge two sources. **Rejected** — it adds the very sync layer this feature exists to remove, for no benefit over a shared schema.

### B. Write path of the Go orchestrator (spec open question #2/#3)
- **B1 — In-process pgx driver (chosen).** Orchestrator writes Postgres directly.
  - *Pros*: atomic single-statement claims, local transactions, no extra service; matches the credential-isolation pattern (DB creds live with the orchestrator, never the executor).
  - *Cons*: orchestrator needs DB access code.
- **B2 — HTTP write API.** 
  - *Cons*: extra hop/service for the only v1 writer; non-runtime write clients are the **deferred MCP feature**. **Rejected for v1** (revisit when MCP lands).

### C. Atomic claim mechanism (spec open question #4)
- **C1 — Conditional `UPDATE … WHERE status = <expected>` (chosen).** The claim is one statement guarded by the current status; `0 rows` ⇒ claim lost.
  - *Pros*: atomic (row lock), encodes the FSM transition guard directly, no extra column, mirrors the existing first-push-wins semantics; reusable for every guarded transition (`ready→in_progress`, `change_requested→in_progress`, `in_review→reviewing`, …).
  - *Cons*: each transition is its own guarded statement (acceptable — the FSM is small).
- **C2 — Optimistic locking via a `version` column + CAS.** Equivalent safety, extra column and read-modify-write; less direct than guarding on `status`. *Secondary.*
- **C3 — `SELECT … FOR UPDATE` then `UPDATE`.** Explicit row lock; more round-trips than C1 for no gain here. *Rejected.*
- **Optional defense-in-depth**: a `BEFORE UPDATE` trigger validating `old.status → new.status` against the allowed-transition table, making the DB a *central* FSM enforcement point (matches the product thesis "rules stay as code"). Recommended but **stageable** — not required for the atomic claim itself.

### D. Broker partitioning (spec open question #7)
- **D1 — Owner-namespaced completion queues, declared symmetrically (chosen).** Registration records `owner`; on callback the broker enqueues into `broker:pending:<owner>`; `list-completed` reads the caller's queue. Both orchestrators declare their owner — the Go orchestrator `'go'`, the TS orchestrator `'ts'` (a small additive change, now permitted). To stay safe-by-default, an absent owner still maps to the legacy `broker:pending` queue, so a not-yet-updated TS build degrades gracefully rather than draining go completions.
  - *Pros*: hard isolation (different keyspace per owner — no lock-and-skip semantics on a shared sorted set); symmetric and explicit; the shared registry (`broker:reg:{handle}`) stays shared for nonce validation, which is fine.
  - *Cons*: small additive change in the broker and in the TS orchestrator's broker calls.
- **D2 — `owner` filter param on a single shared `ListCompleted`.** Broker keeps one pending set and returns only items matching the caller's owner.
  - *Cons*: filtering interacts awkwardly with peek-and-lock (must avoid locking items it then skips). *Secondary — viable but messier than per-owner queues.*
- **Dispatch stream stays shared.** The executor is owner-agnostic, so the Go orchestrator enqueues `DispatchJob`s onto the **same** `platform:dispatch` stream and reuses the existing dispatcher unchanged; only the **completion** path is partitioned. No dispatcher change.

### E. Scope of the Go orchestrator in v1
- **E1 — Minimal lifecycle loop (chosen).** Create go feature/tasks in DB, eligibility over `owner='go'`, DB-atomic claim, dispatch+reap over the partitioned broker, write `ready→in_progress→in_review→done` and `→blocked`. Reuses the existing dispatcher + executors.
- **E2 — Full TS-orchestrator parity now** (reviewer cycle automation, drift daemon, handoff trigger). *Deferred* — large, and not required by the v1 success criteria. Called out in §8.

---

## 4. Chosen design

**One shared Postgres, one shared schema, write authority partitioned by `owner`.** This is the answer to spec open question #8.

### 4.1 Schema change (repo: `workspace-github-adapter`)
Additive goose migration:
- Add `owner TEXT NULL` to `workspace_features` (semantics: `NULL` = legacy git/YAML, driven by the TS orchestrator + adapter sync; `'go'` = DB-native, driven by the Go orchestrator). Tasks inherit owner via their `feature_id`; optionally denormalize `owner` onto `workspace_tasks` for query convenience.
- Relax `source_path`/`source_hash` to `NULL`-able (DB-native rows have no YAML origin).
- Index `workspace_features (workspace_id, owner)` and (if denormalized) `workspace_tasks (workspace_id, owner, status)` to make the Go orchestrator's eligibility scan cheap.
- **Migrations remain owned by `workspace-github-adapter`** (the schema's current home). The Go orchestrator and read API are schema *consumers*. This coupling is documented, not eliminated, in v1.

### 4.2 Sync adapter scoping (repo: `workspace-github-adapter`)
The YAML→DB sync must treat the DB as authoritative for `owner = 'go'` rows:
- All upserts write `owner = NULL` (or leave existing `owner` untouched) and must **never** target a `'go'` row.
- The reconciliation deletes (`DeleteWorkspaceFeaturesNotIn` / task equivalents, `adapter.go:562-617`) must be **scoped to `owner IS NULL`** so DB-native features/tasks are never deleted for being absent from YAML.
- Net effect: the adapter's behavior for legacy features is identical to today; it is simply blind to `'go'` rows.

### 4.3 Go orchestrator write path + atomic claim (repo: `workflow`)
- New Go service under `agent-workflow/runtime/` (e.g. `runtime/orchestrator-go/`), with its own pgx access layer to the shared schema (sqlc against the same migrations, or a small vendored query package).
- **Create**: a go-owned feature is `INSERT`ed into `workspace_features` with `owner='go'` (and its tasks into `workspace_tasks`), `source_path = NULL`.
- **Atomic claim** (`ready → in_progress`):
  ```sql
  UPDATE workspace_tasks
     SET status = 'in_progress',
         execution = $exec,         -- last_updated_by / last_updated_at
         updated_at = now()
   WHERE workspace_id = $ws AND feature_id = $feat AND task_id = $task
     AND status = 'ready'
  RETURNING id;
  ```
  Zero rows ⇒ another writer won or the precondition changed ⇒ stop (mirrors first-push-wins). The same guarded-UPDATE shape implements every lifecycle transition (`change_requested→in_progress`, `in_review→reviewing`, `reviewing→review_passed`, …), so the DB enforces the FSM at write time.
- **Status transitions + log**: each transition is a guarded `UPDATE`; each log entry is an `INSERT` into `workspace_activity_events` (sequence-based, matching the adapter's normalization) — no YAML, no git.
- **Dependency unblock / auto-ready**: on marking a task `done`, the orchestrator advances dependents whose `depends_on` are all `done` to `ready` in the same transaction.

### 4.4 Dispatch + reap over the partitioned broker (repos: `workflow`)
- **Broker (Go)** gains owner-awareness (design D1): `Register` records the owner; callback enqueues into the owner's pending queue; `ListCompleted` reads the caller's queue (absent owner ⇒ legacy queue, for graceful degradation). `Store` interface (`broker/internal/store/store.go:57-88`) and the `/register`, `/callback`, `/list-completed` handlers (`server.go`) change additively. The TS orchestrator takes a small additive change to declare `owner='ts'` on its broker calls (`HttpBrokerAdapter`) so its completions land in — and are drained from — the `ts` queue.
- **Go orchestrator** registers each handle with `owner='go'` + `HandleMetadata{ feature_id, task_id, … }`, enqueues a `DispatchJob` (`abi/src/types.ts:50-96`) onto the shared `platform:dispatch` stream, and drains its own completion queue, resolving each completion back to a DB row by `metadata.feature_id`/`metadata.task_id` (the DB analogue of `reap-loop.ts:131-175`) — then writes the resulting status transition to Postgres.
- **Executor + dispatcher reused as-is** (owner-agnostic — no change needed for v1); `LOG_SINK=none` already keeps the standalone path's logs off the management repo.

### 4.5 Read API (repo: `workflow-backend`)
- **No functional change needed for v1** (reused as-is): the read queries select rows by `workspace_id` regardless of `owner`, so go-owned features/tasks surface through the existing endpoints the moment the orchestrator writes them. This is what lets the FE need little or no change — a preference, not a constraint; the read API/FE may evolve if the Go path requires it.
- Optional, additive: expose `owner` in the feature/task DTO so the UI can badge DB-native features. Not required for v1.

### Why this design
- Serves the primary goal (a Go orchestrator writing directly to the DB) with the **least disruption to the running legacy path**: reuse the same schema + read API + executor/dispatcher, and touch the TS path only additively (`owner='ts'`). This is a deliberate scope choice, not a forced one — any of these may change later as Go takes over more of the workload.
- The `owner` discriminator + scoped reconciliation is the precise mechanism that lets one schema host two writers while preserving the single-owner-per-feature invariant.

### Compatibility / operational implications
- Purely additive migration (nullable column, relaxed constraints) — safe for the running read API and adapter.
- DB credentials live only with the Go orchestrator (and the adapter), never the executor — consistent with the dispatch-service credential-isolation pattern.
- Rollback: drop the Go orchestrator and the `owner` filter; legacy path is unaffected.

---

## 5. Dependency analysis (mandatory)

**Internal**
- Schema migration (`owner`, nullable `source_path`) is the root dependency for: adapter scoping, Go orchestrator write path, and the optional read-API DTO field.
- Broker owner-partitioning is independent of the schema and can proceed in parallel.
- The Go orchestrator dispatch+reap loop depends on **both** the write path/claim (schema) **and** the partitioned broker.

**External / cross-repo**
- Migrations are owned by `workspace-github-adapter` but consumed by `workflow` (Go orchestrator) and `workflow-backend` (read API). The migration must be applied to the shared DB before the Go orchestrator runs. **This is a cross-repo release-ordering dependency**, not a code dependency.

**Vendor/tooling**
- Postgres (decided), pgx/v5 (existing), goose (existing migration tool), sqlc (existing). Redis (existing broker). No new vendor choices.

**Blocking decisions still open for review (do not silently resolve)**
- **Go orchestrator location** — recommended `workflow` (`agent-workflow/runtime/`) for ABI/broker cohesion; alternatives are `workflow-backend` (DB-code reuse, but conflates the read service) or `workspace-github-adapter` (owns schema/writes, but conflates the sync adapter). **Decision needed at design approval.**
- **Status-transition validation trigger** — include as DB-central enforcement now, or stage it. Recommended: stage after the atomic claim is proven.
- **Multi-tenancy** — schema has no org/tenant column; `HandleMetadata.TenantID` is unused. v1 stays `workspace_id`-scoped; org scoping is a forward extension (flagged, not designed here).

**Unresolved → stated explicitly**: the exact `owner` denormalization onto `workspace_tasks` (vs join-to-feature) is left to implementation; both are viable and do not change the contract.

---

## 6. Parallelization / blocking analysis (mandatory)

> Anticipated breakdown for planning only — task YAMLs are **not** created in Phase 1. Finalized in Phase 2 (tasks stage). Each task touches exactly one repo.

```
External decision: Go-orchestrator repo location (recommend `workflow`) ── resolve at design approval; gates T4/T5/T7

T1: Schema migration — add nullable `owner`, relax source_path, indexes        [workspace-github-adapter]
  └── Can begin now — no blockers
  │
T3: Broker owner-partitioning — namespaced completion queues, owner-aware       [workflow]
    register/callback/list-completed; TS orchestrator declares owner='ts'
    (small additive change); absent-owner ⇒ legacy queue for safe default
  └── Can begin now — no blockers (independent of schema)
  │
  ├── T2: Scope YAML→DB sync to `owner IS NULL` (never upsert/delete 'go' rows)  [workspace-github-adapter]
  │     └── BLOCKED on T1 (owner column must exist to scope reconciliation)
  │
  └── T4: Go orchestrator write path — pgx layer, create go feature/tasks,       [workflow]
          atomic guarded-UPDATE claim, status + activity writes, auto-ready
        └── BLOCKED on T1 (schema: owner column + nullable source_path)
        │
        T5: Go orchestrator dispatch + reap loop — register(owner='go'),          [workflow]
            enqueue DispatchJob on shared stream, drain go completion queue,
            resolve completion → DB transition
          └── BLOCKED on T4 (write path + claim must exist)
          └── BLOCKED on T3 (partitioned broker must exist)
        │
        T6: Read API — verify go-owned rows surface unchanged; optionally         [workflow-backend]
            expose `owner` in DTO
          └── BLOCKED on T1 (owner column) for the optional DTO field
          └── BLOCKED on T4 (needs go-owned rows written to verify against)

T7: End-to-end coexistence integration test — drive a go feature to `done` in    [workflow]
    parallel with a legacy feature; assert TS never drains a go completion;
    assert both surface via the read API; assert sync never deletes go rows
  └── BLOCKED on T2 (sync scoping), T5 (full go loop), T6 (read-API verification)

Parallelism:
- T1 and T3 run in parallel immediately.
- T2 and T4 run in parallel once T1 lands (different concerns, same repo for T2; T4 in `workflow`).
- T5 and T6 run in parallel once their blockers clear (T5 after T3+T4; T6 after T1+T4).
- T7 is the final integration gate.
```

---

## 7. Repository impact

| Repo (`workspace.yaml` id) | Change | Tasks |
|---|---|---|
| `workspace-github-adapter` | `owner` migration + relaxed `source_path`; scope sync upserts/deletes to `owner IS NULL` | T1, T2 |
| `workflow` (`agent-workflow`) | Broker owner-partitioning **+ TS orchestrator declares `owner='ts'`** (small additive change); new Go orchestrator (write path, atomic claim, dispatch+reap loop); coexistence integration test | T3, T4, T5, T7 |
| `workflow-backend` | Verify go-owned rows surface via existing read API; optional `owner` DTO field | T6 |
| `management-repo` | Feature docs / status only (this design, task files) | n/a (docs) |

No task writes to more than one repo (one-repo rule satisfied). The **dispatcher and executors are not modified**; the TS orchestrator takes only the small additive `owner='ts'` broker-call change (T3) and is otherwise unchanged for legacy features.

---

## 8. Validation and release impact

**Testing expectations**
- T1: migration up/down tested against a scratch DB; existing adapter + read-API suites stay green.
- T2: adapter tests proving a sync cycle **does not** create, update, or delete `owner='go'` rows while still reconciling legacy rows normally.
- T3: broker tests — a `go`-owner callback lands only in the `go` queue and a `ts`-owner callback only in the `ts` queue; each `list-completed` returns only its owner's completions; absent-owner degrades to the legacy queue; registry/nonce validation still shared. Plus a TS-orchestrator test that it declares `owner='ts'` and still drives legacy features unchanged.
- T4: claim concurrency test — N racing claimers, exactly one wins `ready→in_progress` (the `0-rows` loser path); FSM guard rejects illegal transitions.
- T5: completion routed back to the correct DB row and status written; blocked path writes `blocked_reason`.
- T7: the load-bearing coexistence test — go feature and legacy feature driven concurrently; **assert the TS orchestrator never drains a go completion** and the sync never deletes go rows.

**Migration / config impact**
- One additive migration applied to the shared Postgres before the Go orchestrator starts. `DATABASE_URL` for the Go orchestrator points at the same DB as the adapter/read-API.
- Broker gains an optional `owner` on register/list-completed; default preserves current behavior.

**Rollout concerns**
- Order: apply migration (T1) → deploy adapter scoping (T2) and broker (T3) → start Go orchestrator (T4/T5). Starting the Go orchestrator before T2 is deployed risks the sync deleting go rows — sequence enforced in release notes.
- Backward compatibility: legacy git/YAML path and the read API are unchanged throughout.

**Deferred scope (explicitly out of v1)**
- Full TS-orchestrator parity in Go: automated reviewer cycle (`reviewing`/`review_passed`/`review_incomplete`), drift daemon, handoff trigger.
- HTTP write API + MCP server for external clients (separate downstream feature).
- Org/tenant multi-tenancy scoping.
- Migrating existing git features into the DB (spec: net-new-in-Go only).

---

## Spec open questions — resolution map
- **#1 Database** → PostgreSQL (decided in spec).
- **#2 API surface** → in-process pgx; no HTTP write API in v1 (§3-B, §4.3).
- **#3 Agent write path** → Go orchestrator writes directly to Postgres; executor never touches the DB (§4.3).
- **#4 Claim mechanism** → conditional guarded `UPDATE` on `status` (§3-C, §4.3); optional FSM trigger deferred.
- **#7 Broker partitioning** → owner-namespaced completion queues declared symmetrically; shared dispatch stream; TS takes a small additive `owner='ts'` change (§3-D, §4.4).
- **#8 Shared DB & schema ownership** → one shared Postgres + one schema; write authority partitioned by `owner`; migrations owned by `workspace-github-adapter` (§4).

---

**Technical design draft complete. Awaiting human approval before task breakdown.**
