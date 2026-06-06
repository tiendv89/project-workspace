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
- **A Postgres mirror already exists** (verified against latest `main`). Feature `workspace-data-backend` built:
  - **Schema + migrations** in repo **`workflow-backend`** — goose migrations under `migrations/` (`00001`–`00014`) with a `cmd/migration` runner and `pkg/db`. **This is the schema's single home.**
  - **YAML→DB sync adapter** in repo **`workspace-github-adapter`** — `internal/adapter/db/adapter.go` (+ `internal/handler/sync.go`, `internal/github/adapter.go`): fetches YAML from GitHub, parses it, **upserts** rows in a transaction, then **deletes rows not present in the source** (`DeleteWorkspaceFeaturesNotIn` etc.). It consumes the schema via sqlc queries under `database/queries/`.
  - **Read API** in repo **`workflow-backend`** — a gin service over a read pgx pool (`internal/database/db.go`), routes for workspaces/features/tasks/activity (`internal/handler/workspace.go:42-52`), DTOs the frontend consumes (`internal/domain/dto.go`).
  - All services point at the **same Postgres** (`DATABASE_URL`).
- **The relevant tables already model our domain** (migrations in `workflow-backend/migrations`):
  - `workspaces` — now includes `organization_id UUID NOT NULL` (migrations `00013`/`00014`) — **org-level multi-tenancy already exists** at the workspace level.
  - `workspace_features` — `feature_id`, `feature_name`, `title`, `feature_status`, `current_stage`, `next_action`, `stages JSONB`, `source_path NOT NULL`, `source_hash`. Unique `(workspace_id, feature_name)`.
  - `workspace_tasks` — `task_id`, `task_name`, `feature_id`, `title`, `status`, `blocked_reason`, `branch`, `repo`, `depends_on JSONB`, `execution JSONB`, `pr JSONB`, `workspace_pr JSONB`, `source_path NOT NULL`, `source_hash`. Unique `(workspace_id, feature_id, task_id)`.
  - `workspace_activity_events` — normalized log/history with `sequence` dedup.
  - `workspace_sync_runs` — sync audit trail.
- **The broker already carries identity.** `HandleMetadata{ Kind, Subkind, TaskID, FeatureID, TenantID, StartedAt }` (`agent-workflow/runtime/broker/internal/store/store.go:17-24`) rides on every completion. The dispatch stream (`platform:dispatch`) and completion broker (`broker:pending` sorted set, `broker:reg:{handle}`) are one Redis from `standalone-executor-hardening`. The executor is standalone/owner-agnostic and writes only `result.json`.

### Current constraints / limitations
- The Postgres mirror is **read-only and derived**: the only writer is the adapter, and its reconciliation **deletes any row not found in the YAML source**. A live writer that creates DB-only rows would have them deleted on the next sync unless reconciliation is scoped.
- `workspace_features.source_path` / `workspace_tasks.source_path` are `NOT NULL` — they assume a YAML origin.
- There is **no `owner` column** and **no claim/locking mechanism** in the schema; `status` is a free-text mirror, not an enforced FSM.
- `broker.ListCompleted(max, lockMs)` has **no filter** (`broker/internal/server/server.go:117-147`) — any orchestrator drains any completion.
- **Org scoping exists at the workspace level** (`workspaces.organization_id NOT NULL`); rows are scoped by `workspace_id`, and each workspace belongs to an organization. Any new writer must set `organization_id`/`workspace_id` correctly. (`HandleMetadata.TenantID` exists on the broker but is not yet wired to `organization_id`.)

### Relevant system boundaries (repos, from `workspace.yaml`)
- `workflow` → `agent-workflow` (TS orchestrator, Go broker, dispatcher, executors, ABI).
- `workflow-backend` → **schema/migrations home** + read API consumed by the frontend.
- `workspace-github-adapter` → YAML→DB sync adapter (consumes the schema via sqlc queries).

---

## 2. Problem framing

### Primary goal
Introduce the **Go/Postgres orchestrator** that writes workflow state **directly to the database**, and run it alongside the TS/git orchestrator so it can **gradually take over and ultimately replace** the TS path. This feature is the *first step* of that replacement — not a permanent two-orchestrator end-state. Every decision below serves that goal first.

### What must change
1. Give the Go orchestrator a way to write live task state to the shared DB and claim tasks atomically — replacing git commits for the features it owns.
2. Add an **`owner`** discriminator so the DB can hold both legacy (YAML-synced) and live (DB-native) features without the two writers colliding.
3. Stop the YAML→DB sync adapter from **clobbering** live DB-native rows.
4. **Partition the broker** so the TS orchestrator never drains a Go feature's completion, and vice versa.
5. **Make the TS orchestrator's feature-level loops owner-aware** so they ignore go-owned features — whose git `status.yaml` is frozen at authoring while live state lives in the DB (surfaced during design — see §4.6).
6. **Make the authoring skills produce go-shaped features** (`init-feature` asks go/ts; `tech-lead` emits no git task YAMLs for go) and materialize them into the DB — designed in §4.7, implemented in Phase 2.

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
  - *Cons*: the schema is consumed across repos (migrations owned by `workflow-backend`; consumed by the adapter and the Go orchestrator), so the `owner` migration is a cross-repo release-ordering dependency; the adapter must learn to scope its reconciliation.
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
v1 is a **human-merge slice**: it proves the DB write path end-to-end *without* automating review yet. A go feature is driven `ready → in_progress → in_review`; the executor opens the impl PR exactly as today; a **human reviews and merges that PR**; the orchestrator's PR-merge poll observes the merge and writes `in_review → done`, then auto-readies dependents. No reviewer agent is dispatched in v1.

- **E1 — Human-merge lifecycle loop (chosen).** DB-atomic claim, eligibility over `owner='go'`, dispatch + reap over the partitioned broker (→ `in_review`), a **PR-merge poll** (the DB analogue of `pr/handle-merged.ts`) that writes `in_review → done` when the impl PR merges, `→ blocked`, and dependency auto-ready. Reuses the existing dispatcher + executors. No reviewer cycle, no drift daemon, no handoff trigger.
- **E2 — Autonomous parity (deferred to a dedicated follow-up feature).** The reviewer cycle (`in_review → reviewing → review_passed`/`change_requested`/`review_incomplete`, and the `change_requested → in_progress` fix loop), the drift daemon, and the handoff trigger. Tracked as the new feature **`go-orchestrator-parity`** — see §8.

The covered vs deferred surface:

```
v1 (E1, human-merge):
  todo → ready → in_progress → in_review ──[human merges PR]──► done → (auto-ready deps)
                                   │
deferred (E2 → go-orchestrator-parity):
                                   └─► reviewing → review_passed ─► done
                                              ├─► change_requested → in_progress
                                              └─► review_incomplete → reviewing / blocked
        + drift daemon (base-branch rebase) + handoff trigger (feature-level done)
```

**Why the reviewer cycle is deferred (not just postponed arbitrarily).**
1. **It's a clean seam.** The reviewer cycle is a self-contained sub-machine entered only at `in_review` and exited only at `done`/`blocked`. Cutting there leaves v1 with a complete, legal lifecycle — not a stub.
2. **`in_review → done` is already a sanctioned FSM edge.** The workflow rules define `in_review → done` for "the impl PR merges directly without a reviewer cycle." v1 uses an *existing* legal route to a terminal state, not a degenerate shortcut.
3. **It doesn't de-risk what v1 must prove.** v1's load-bearing risks are all on the DB write path — atomic claim under contention, owner-partitioned coexistence (TS never drains a go completion), and scoped sync (sync never deletes go rows). None of these involve review. The human-merge slice is the *smallest* path that still reaches `done`, so it exercises claim → dispatch → reap → merge-detection → done → auto-ready without the reviewer surface.
4. **It's the same primitive, so nothing is wasted.** Every deferred transition is the identical guarded-`UPDATE` shape v1 already builds (§4.3). The follow-up feature adds reviewer *dispatch* + *verdict routing* on top of primitives v1 proves — it does not redo them.
5. **The deferred pieces cohere as one feature.** Reviewer automation, the drift daemon, and the handoff trigger are exactly the autonomous loops the TS orchestrator runs beyond basic task lifecycle. Bundling them into v1 would multiply the test matrix (reviewer happy-path, REQUEST_CHANGES fix loop, incomplete retries/escalation, drift rebase, feature-done) without reducing v1's write-path risk. They form a coherent, independently-testable successor slice.

---

## 4. Chosen design

**One shared Postgres, one shared schema, write authority partitioned by `owner`.** This is the answer to spec open question #8.

### 4.1 Schema change (repo: `workflow-backend` — the schema/migrations home)
Additive goose migration added to `workflow-backend/migrations/` (next sequence, e.g. `00015_*_owner`):
- Add `owner TEXT NULL` to `workspace_features` (semantics: `NULL` = legacy git/YAML, driven by the TS orchestrator + adapter sync; `'go'` = DB-native, driven by the Go orchestrator). Tasks inherit owner via their `feature_id`; optionally denormalize `owner` onto `workspace_tasks` for query convenience.
- Relax `source_path`/`source_hash` to `NULL`-able (DB-native rows have no YAML origin).
- Index `workspace_features (workspace_id, owner)` and (if denormalized) `workspace_tasks (workspace_id, owner, status)` to make the Go orchestrator's eligibility scan cheap.
- **Migrations are owned by `workflow-backend`** (a single, clear schema home — this resolves the earlier "where does the schema live" coupling). The sync adapter (`workspace-github-adapter`) and the Go orchestrator (`workflow-orchestrator`) are schema *consumers*; the read API lives in `workflow-backend` too.

### 4.2 Sync adapter scoping (repo: `workspace-github-adapter`)
The YAML→DB sync (`internal/adapter/db/adapter.go`) must treat the DB as authoritative for `owner = 'go'` rows:
- All upserts write `owner = NULL` (or leave existing `owner` untouched) and must **never** target a `'go'` row.
- The reconciliation deletes (`DeleteWorkspaceFeaturesNotIn` / task equivalents) must be **scoped to `owner IS NULL`** so DB-native features/tasks are never deleted for being absent from YAML. Its sqlc queries (`database/queries/*.sql`) are regenerated to be owner-aware.
- Net effect: the adapter's behavior for legacy features is identical to today; it is simply blind to `'go'` rows. (Depends on the schema migration in `workflow-backend`.)

### 4.3 Go orchestrator write path + atomic claim (repo: `workflow-orchestrator` — new)
- New Go service in its **own dedicated repo** (`workflow-orchestrator`, now created + registered), with its own pgx access layer to the shared schema (sqlc against the migrations owned by `workflow-backend`, or a small shared query package). It speaks the broker/dispatch protocol over Redis/HTTP and re-declares the ABI types in Go (the ABI is TypeScript).
- **Create**: a go-owned feature is `INSERT`ed into `workspace_features` with `owner='go'`, `source_path = NULL`, and the correct `workspace_id` + `organization_id` (org scoping is mandatory — `workspaces.organization_id` is `NOT NULL`); its tasks go into `workspace_tasks`.
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
  Zero rows ⇒ another writer won or the precondition changed ⇒ stop (mirrors first-push-wins). The same guarded-UPDATE shape implements every lifecycle transition (`change_requested→in_progress`, `in_review→reviewing`, `reviewing→review_passed`, …), so the DB enforces the FSM at write time. **v1 exercises only the human-merge subset** — `ready→in_progress`, `in_progress→in_review`, `in_review→done`, `→blocked`, plus auto-ready; the reviewer-cycle transitions reuse this identical primitive but are built in the `go-orchestrator-parity` follow-up (§3-E, §8).
- **Status transitions + log**: each transition is a guarded `UPDATE`; each log entry is an `INSERT` into `workspace_activity_events` (sequence-based, matching the adapter's normalization) — no YAML, no git.
- **Dependency unblock / auto-ready**: on marking a task `done`, the orchestrator advances dependents whose `depends_on` are all `done` to `ready` in the same transaction.

### 4.4 Dispatch + reap over the partitioned broker (repos: `workflow`)
- **Broker (Go)** gains owner-awareness (design D1): `Register` records the owner; callback enqueues into the owner's pending queue; `ListCompleted` reads the caller's queue (absent owner ⇒ legacy queue, for graceful degradation). `Store` interface (`broker/internal/store/store.go:57-88`) and the `/register`, `/callback`, `/list-completed` handlers (`server.go`) change additively. The TS orchestrator takes a small additive change to declare `owner='ts'` on its broker calls (`HttpBrokerAdapter`) so its completions land in — and are drained from — the `ts` queue.
- **Go orchestrator** registers each handle with `owner='go'` + `HandleMetadata{ feature_id, task_id, … }`, enqueues a `DispatchJob` (`abi/src/types.ts:50-96`) onto the shared `platform:dispatch` stream, and drains its own completion queue, resolving each completion back to a DB row by `metadata.feature_id`/`metadata.task_id` (the DB analogue of `reap-loop.ts:131-175`) — then writes the resulting status transition to Postgres. **Executor completion lands the task in `in_review`** (the executor has opened the impl PR); it does not by itself reach `done`.
- **PR-merge poll (`in_review → done`)** — a periodic GitHub poll over go-owned tasks in `in_review` (the DB analogue of `pr/handle-merged.ts` + `pr/check-in-review.ts`): when the impl PR reports `merged: true`, the orchestrator writes the guarded `in_review → done` transition and runs dependency auto-ready in the same transaction. **This is how a v1 (human-merge) feature reaches a terminal state** — there is no reviewer dispatch in v1. Without this poll the reap loop would dead-end at `in_review`, so it is firmly **in v1 scope, not deferred**.
- **Executor + dispatcher reused as-is** (owner-agnostic — no change needed for v1); `LOG_SINK=none` already keeps the standalone path's logs off the management repo.

### 4.5 Read API (repo: `workflow-backend`)
- **No functional change needed for v1** (reused as-is): the read queries select rows by `workspace_id` regardless of `owner`, so go-owned features/tasks surface through the existing endpoints the moment the orchestrator writes them. This is what lets the FE need little or no change — a preference, not a constraint; the read API/FE may evolve if the Go path requires it.
- Optional, additive: expose `owner` in the feature/task DTO so the UI can badge DB-native features. Not required for v1.

### 4.6 TS orchestrator owner-awareness (repo: `workflow`)
Verified by reading the orchestrator source. **Task-level** work discovery is gated on the presence of `tasks/*.yaml`, so a go feature — which ships **no** task YAMLs in git (see §4.7) — is invisible to it. But several **feature-level** loops scan `docs/features/*` and act on `status.yaml`'s `feature_status` *regardless of task YAMLs*. Because a go feature's git `status.yaml` is frozen at its authoring state (the live `feature_status` lives in the DB), these loops would wrongly act on it. The fix is an `owner: go` marker in `status.yaml` plus an `owner !== "go"` guard at the top of each affected loop.

**Safe by construction (task-YAML-gated — no change needed):** `eligibility/match.ts` (`loadFeatureTasks` returns `[]` with no task YAMLs, :193/:210), `pr/check-in-review.ts` (:234), `pr/handle-merged.ts` (:271/:749), `feature/check-tasks-done.ts` (`tasks.length===0 ⇒ continue`, :198 — no 0-of-0 false positive), `feature/handoff-trigger.ts` (:118/:437), `loop/state-invariant-checker.ts` (:224), `loop/dispatch-reconciler.ts` (:178), `task/unblock-deps.ts` (:57).

**Require an `owner` guard (status.yaml-gated — would wrongly act):**

| Loop | Gate (cited) | Wrong action on a go feature |
|---|---|---|
| `feature/lifecycle-manager.ts` | `feature_status ∈ {ready_for_implementation, in_implementation, in_handoff}` (:419) | creates a feature branch + **writes its `status.yaml`** |
| `feature/review-cycle.ts` (drift daemon) | `feature_status === "in_handoff"` + `feature_branch_base_sha` (:476–495) | drift detection / rebase / escalation on a branch it doesn't own |
| `feature/notification-watcher.ts` | `feature_status ∈ WATCHED_STATUSES` (:225) | posts Slack `feature_start` / status-change notifications |

This is the **owner-awareness task (T4)**; each loop above is a declared subtask. `handle-done.ts` / `check-tasks-done.ts` are already defensively safe (`handoff_pr_url` / 0-task guards) but should also take the guard for explicitness.

> **State-write ownership (verified, load-bearing).** The **orchestrator** performs *all* management-repo state writes via its own code (`claim.ts`, `mutate-yaml.ts`, `append-log.ts`, `handle-merged.ts`, `unblock-deps.ts`). The **executor** writes `result.json` + POSTs the broker callback (`reap-loop.ts:131`); in the runtime it skips management-repo writes via the `AGENT_RUNTIME` guard — **with one exception**: claude `start-implementation`'s `started`-log step (Hard Rule #3) is **not** guarded and commits a log entry to the git task YAML, which §4.7 owner-gates for go. Consequence: the Go orchestrator reimplements the write path against the DB (tasks T5–T14), the executor is otherwise owner-agnostic (it reads its briefing from the git narrative, which exists for go features), and "owner-aware skills" is **mostly** the authoring skills in §4.7 plus that single `started`-log owner-gate.

### 4.7 Owner-aware workflow skills — design only, not implemented in this design (repos: management-repo / `workflow` skills)
A go feature must be *created* in the go shape: `status.yaml` carrying `owner: go`, narrative in `tasks.md`, and **no `tasks/*.yaml` in git** (state lives in the DB). The authoring skills must therefore become owner-aware. Executor-run skills already skip management-repo writes **in the runtime** via the `AGENT_RUNTIME` guard, so most need no owner change — the one exception is claude `start-implementation`'s `started`-log step (not guarded), called out below. **Default rule baked into every skill: an absent `owner` field ⇒ `ts`** (preserves every existing feature). The concrete edits land on a dedicated `workflow`-repo branch (owner-aware skills), implemented ahead of Phase 2 as a prerequisite. Skill trees: `claude/workflow_skills/` (authoring + interactive) and `hermes/workflow_skills/` (leaner executor runtime) — both must stay consistent.

| Skill | Tree(s) | Change for a go feature (absent `owner` ⇒ `ts` everywhere) |
|---|---|---|
| `init-feature` | **claude only** | **Change** — explicitly **ask `go` vs `ts` (never assume)**. For `go`: write `owner: go` into `status.yaml`, create `tasks.md`, and create **no** `tasks/*.yaml`. |
| `tech-lead` | **claude only** | **Change** — for a `go` feature emit `tasks.md` narrative only (no git `tasks/*.yaml`) + the materialization input (`workspace_tasks`, `owner='go'`). |
| `start-implementation` | **claude + hermes** | **claude: change** — its `started`-log git write (Hard Rule #3) is **not** `AGENT_RUNTIME`-guarded, so gate it on `owner !== 'go'`; a go task (no git YAML) skips it and the orchestrator/DB records the started entry. **hermes: no functional change** — already writes **zero** management-repo state (stops before push; wrapper owns the rest), so already go-safe; add an explicit owner note for parity. |
| `pr-create` | claude (hermes copy has **no `SKILL.md`** — anomaly to resolve) | **No change** — already `AGENT_RUNTIME`-guarded to skip all management-repo writes in the runtime. |
| `respond-to-review`, `review-pr` | claude / hermes | Reviewer path — **out of v1** (owned by `go-orchestrator-parity`). |
| `list-features`, `resume-feature` | claude | Read go state from the DB / read-API — **forward work**, not required for the v1 human-merge slice. |

**Open item — feature materialization (Gap A):** *how* an approved go feature's task definitions reach the DB. Two viable mechanisms for Phase 2 to choose: (a) `tech-lead`/`init-feature` emit a definition that a small **materializer** (CLI or orchestrator `create` command — task T6) inserts; (b) the orchestrator create path (T6) is driven by a seed/fixture for v1 testing while the human-authoring trigger lands with the skills. The v1 e2e test (T18) may seed the DB directly; the skill-driven authoring path is required for real human use. The **agent/human-facing write & update API + MCP** for this (credential-clean materialization, task-definition updates, and manual-intervention transitions like `blocked→ready`/`cancelled`) is tracked as the deferred feature **`workflow-db-mcp`** — note that the Go orchestrator's *execution-state* writes are in-process (B1) and need no API; only these non-runtime writes do.

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
- **TS orchestrator owner-awareness (T4)** depends only on the `owner: go` `status.yaml` marker convention — not on the DB schema — so it can land independently and early (testable with a hand-authored `owner: go` status.yaml). See §4.6.
- **Authoring skills (T16/T17)** depend on the marker convention (T4a) and the materialization contract (T6). The Go orchestrator can be built and tested end-to-end via a seed/fixture (T6) **without** the skills; the skills are what make the human-authoring journey real. See §4.7.

**External / cross-repo**
- Migrations are owned by `workflow-backend` (the schema's single home) and consumed by the sync adapter (`workspace-github-adapter`) and the Go orchestrator (`workflow-orchestrator`); the read API lives in `workflow-backend` too. The `owner` migration (in `workflow-backend`) must be applied to the shared DB before the sync-scoping change (`workspace-github-adapter`) and the Go orchestrator run. **This is a cross-repo release-ordering dependency**, not a code dependency.

**Vendor/tooling**
- Postgres (decided), pgx/v5 (existing), goose (existing migration tool), sqlc (existing). Redis (existing broker). No new vendor choices.

**Blocking decisions still open for review (do not silently resolve)**
- **Go orchestrator location — RESOLVED: a new dedicated repo `workflow-orchestrator`** (created on GitHub + registered in `workspace.yaml`). Rationale: it is the successor that will *replace* the TS orchestrator, so it should not live inside `agent-workflow` (which holds the TS orchestrator being retired). The ABI is TypeScript (no Go type reuse from co-location) and the broker/dispatch are reached over Redis/HTTP (language-agnostic), so co-location buys nothing; a clean repo gives independent module/CI/release and a clean retirement path. (Alternatives `workflow`/`workflow-backend`/`workspace-github-adapter` rejected — each conflates the successor with a system it must outlive or with the read/sync services.)
- **Status-transition validation trigger** — include as DB-central enforcement now, or stage it. Recommended: stage after the atomic claim is proven.
- **Org scoping (`organization_id`)** — already exists (`workspaces.organization_id NOT NULL`). The Go orchestrator must populate it on every write. Wiring `HandleMetadata.TenantID` → `organization_id` end-to-end, and any per-org isolation beyond workspace scoping, is forward work (flagged, not designed here).
- **Feature materialization mechanism (Gap A)** — *how* an approved go feature's task definitions are inserted into the DB (a materializer CLI, an orchestrator `create` command, or a test seed for v1). Not resolved here; Phase 2 decides (§4.7). The v1 e2e test may seed directly, so this does not block the Go orchestrator tasks.

**Unresolved → stated explicitly**: the exact `owner` denormalization onto `workspace_tasks` (vs join-to-feature) is left to implementation; both are viable and do not change the contract.

---

## 6. Parallelization / blocking analysis (mandatory)

> Anticipated breakdown for planning only — task YAMLs are **not** created in Phase 1. Finalized in Phase 2 (tasks stage). Each task touches exactly one repo, and is intentionally broken **as small as possible so each critical path is covered separately**.
>
> **Instruction to Phase 2 (tasks stage).** Every task below must receive a precise change description in `tasks.md`: the exact files/functions/queries to change, the guarded-`UPDATE`/`INSERT` statement or query where relevant, and explicit acceptance criteria. Do not restate the title — describe *what changes and how it is verified*.

**Workstream S — shared schema & infrastructure**
- **T1** — Schema migration: nullable `owner`, relax `source_path`/`source_hash`, indexes `(workspace_id, owner[, status])`  `[workflow-backend]` — *no blockers*
- **T2** — Sync adapter: scope upserts/deletes to `owner IS NULL` (never create/update/delete `'go'` rows); regen owner-aware sqlc queries  `[workspace-github-adapter]` — *blocked on T1 (cross-repo)*
- **T3** — Broker owner-partitioning: namespaced completion queues + TS orchestrator declares `owner='ts'`; absent-owner ⇒ legacy queue  `[workflow]` — *no blockers*

**Workstream A — TS orchestrator owner-awareness** (the guard task; see §4.6)
- **T4** — Add an `owner` guard to the status.yaml-gated feature loops  `[workflow]` — *can begin now: reads a `status.yaml` field; testable with a hand-authored `owner: go` status.yaml.* Subtasks (each declares the exact path changed):
  - **4a** — read `owner` from `status.yaml`; define + document the `owner: go` marker convention
  - **4b** — `feature/lifecycle-manager.ts:419` — skip `owner==='go'` before the `BRANCH_ELIGIBLE` check (no branch created, no `status.yaml` write)
  - **4c** — `feature/review-cycle.ts:476` — skip `owner==='go'` (no drift detection / rebase / escalation)
  - **4d** — `feature/notification-watcher.ts:225` — skip `owner==='go'` (no Slack notifications)
  - **4e** — defensive `owner` guards in `feature/check-tasks-done.ts` / `feature/handle-done.ts` for explicitness

**Workstream G — Go orchestrator** (each critical path a separate task)  `[workflow-orchestrator (new repo)]`
- **T5** — DB access layer: pgx/sqlc setup, config, connection to the shared schema — *blocked on T1*
- **T6** — Feature/task creation (+ materializer/seed): `INSERT` go feature + tasks (`owner='go'`, `source_path NULL`, valid `workspace_id`+`organization_id`); expose a seed/CLI for tests — *blocked on T5*
- **T7** — Eligibility scan: query `owner='go'` tasks that are `ready` with all `depends_on` `done` — *blocked on T5*
- **T8** — Atomic claim: guarded `UPDATE … WHERE status='ready'`; `0-rows` loser path — *blocked on T5*
- **T9** — Status transitions + activity log: guarded `UPDATE` for `in_progress→in_review` and `→blocked`; `INSERT` into `workspace_activity_events` — *blocked on T5*
- **T10** — Dependency auto-ready: on `done`, advance dependents whose `depends_on` are all `done`, in the same transaction — *blocked on T9*
- **T11** — Dispatch: register handle `owner='go'` + `HandleMetadata`, enqueue `DispatchJob` on the shared stream — *blocked on T5, T3*
- **T12** — Reap: drain the go completion queue, resolve completion → DB row, write `in_review` — *blocked on T11, T9*
- **T13** — PR-merge poll: poll GitHub for go `in_review` tasks; write `in_review→done` + auto-ready — *blocked on T9, T6*
- **T14** — Orchestration loop: compose T7–T13 into one poll cycle (eligibility → claim → dispatch → reap → merge-poll) — *blocked on T7–T13*

**Workstream R — read side**
- **T15** — Read API: verify go-owned rows surface unchanged via existing endpoints; optional `owner` in DTO  `[workflow-backend]` — *blocked on T1 (DTO), T6 (rows to verify)*

**Workstream K — owner-aware skills** (design in §4.7; being implemented ahead of Phase 2 on a dedicated branch — repo `workflow` = `agent-workflow`, which hosts both `claude/workflow_skills/` and `hermes/workflow_skills/`)
- **T16** — `init-feature` (claude): explicitly ask `go` vs `ts`; for `go` set `owner: go` and create **no** `tasks/*.yaml`  `[workflow]` — *blocked on T4a (marker convention)*
- **T17** — `tech-lead` (claude): for a `go` feature emit `tasks.md` only (no git task YAMLs) + the materialization input  `[workflow]` — *blocked on T4a, T6 (materializer contract)*
- **T17b** — `start-implementation` (claude): owner-gate Hard Rule #3's `started`-log git write — skip it for `owner='go'`; absent/`ts` unchanged. hermes `start-implementation` verified go-safe (writes no management-repo state) — parity note only.  `[workflow]` — *no blockers (reads `status.yaml` owner)*

**Integration gate**
- **T18** — E2E coexistence test: drive a seeded go feature to `done` via a **human-merged** impl PR, in parallel with a legacy feature; assert TS never drains a go completion, both surface via the read API, and sync never deletes go rows  `[workflow-orchestrator]` — *blocked on T2, T4, T14, T15*

**Parallelism**
- T1, T3, T4 start immediately (T4 needs only the marker convention 4a).
- Once T1 lands: T2 and T5 begin. Once T5 lands: T6 / T7 / T8 / T9 run in parallel.
- T16 / T17 (skills) run in parallel with the G-workstream once 4a (marker) and the T6 materializer contract are fixed.
- T18 is the final gate.

---

## 7. Repository impact

| Repo (`workspace.yaml` id) | Change | Tasks |
|---|---|---|
| `workflow-backend` (schema home) | `owner` migration + relaxed `source_path` (in `migrations/`); verify go-owned rows surface via existing read API; optional `owner` DTO field | T1, T15 |
| `workspace-github-adapter` | Scope YAML→DB sync upserts/deletes to `owner IS NULL`; regen owner-aware sqlc queries | T2 |
| `workflow` (`agent-workflow`) | Broker owner-partitioning **+ TS declares `owner='ts'`** (T3); **TS feature-loop `owner` guards** — `lifecycle-manager`, `review-cycle`, `notification-watcher` (T4) | T3, T4 |
| `workflow-orchestrator` (new repo — created + registered) | New Go orchestrator, broken per critical path: DB layer, creation/materializer, eligibility, atomic claim, transitions+log, auto-ready, dispatch, reap, PR-merge poll, loop wiring; coexistence integration test | T5–T14, T18 |
| `workflow` skills (canonical source; repo id confirmed in Phase 2) | Owner-aware authoring skills — `init-feature` (ask go/ts), `tech-lead` (no git task YAMLs for go) — **design only here, implemented in Phase 2 (§4.7)** | T16, T17 |
| `management-repo` | Feature docs / status only (this design). The `workflow-orchestrator` repo is **already registered** in `workspace.yaml`. | n/a (docs/config) |

One-repo rule satisfied (each task touches a single repo). The **dispatcher and executors are not modified** (owner-agnostic). The TS orchestrator takes only **additive** changes: `owner='ts'` on broker calls (T3) and `owner !== "go"` skip-guards on three feature-level loops (T4) — it is otherwise unchanged for legacy features.

---

## 8. Validation and release impact

**Testing expectations**
- T1 (`workflow-backend`): migration up/down tested against a scratch DB; existing read-API + adapter suites stay green.
- T2: adapter tests proving a sync cycle **does not** create, update, or delete `owner='go'` rows while still reconciling legacy rows normally.
- T3: broker tests — a `go`-owner callback lands only in the `go` queue and a `ts`-owner callback only in the `ts` queue; each `list-completed` returns only its owner's completions; absent-owner degrades to the legacy queue; registry/nonce validation still shared. Plus a TS-orchestrator test that it declares `owner='ts'` and still drives legacy features unchanged.
- T4 (owner guard): a feature whose `status.yaml` carries `owner: go` is **skipped** by `lifecycle-manager`, `review-cycle`, and `notification-watcher` (no branch created, no drift action, no Slack post) — one assertion per loop; a feature with no `owner` (legacy) is still acted upon unchanged.
- T6: a created go feature/tasks carry a valid `organization_id`/`workspace_id` and `source_path = NULL`.
- T8 (claim): concurrency test — N racing claimers, exactly one wins `ready→in_progress` (the `0-rows` loser path); the guarded `UPDATE` rejects an illegal precondition.
- T9/T12 (transitions + reap): completion routed back to the correct DB row and the right status written; the blocked path writes `blocked_reason`.
- T13 (merge poll): a merged impl PR drives `in_review→done` and triggers auto-ready of dependents.
- T16/T17 (skills): `init-feature` refuses to assume — it asks `go`/`ts`, and for `go` writes `owner: go` and creates **no** `tasks/*.yaml`; `tech-lead` emits `tasks.md` only for a go feature (no git task YAMLs).
- T18: the load-bearing coexistence test — go feature and legacy feature driven concurrently (the go feature reaches `done` via a **human-merged** impl PR — no reviewer cycle in v1); **assert the TS orchestrator never drains a go completion** and the sync never deletes go rows.

**Migration / config impact**
- One additive migration applied to the shared Postgres before the Go orchestrator starts. `DATABASE_URL` for the Go orchestrator points at the same DB as the adapter/read-API.
- Broker gains an optional `owner` on register/list-completed; default preserves current behavior.

**Rollout concerns**
- Order: apply migration (T1) → deploy adapter scoping (T2), broker (T3), and TS owner-guards (T4) → start Go orchestrator (T5–T14). Starting the Go orchestrator before T2 is deployed risks the sync deleting go rows, and before T4 risks the TS orchestrator branch-managing/notifying a go feature — both sequenced in release notes.
- Backward compatibility: legacy git/YAML path and the read API are unchanged throughout.

**Deferred scope (explicitly out of v1)**
- **Autonomous parity in Go — tracked as the dedicated follow-up feature `go-orchestrator-parity`.** The reviewer cycle (`in_review→reviewing`, `reviewing→review_passed`/`change_requested`/`review_incomplete`, `change_requested→in_progress`, and retry/escalation), the drift daemon (base-branch rebase), and the handoff trigger (feature-level `done` + feature-branch PRs). v1 ships the human-merge slice instead (§3-E); this feature layers autonomous review on top of v1's proven write-path primitives.
- HTTP write API + MCP server for agent/external clients — tracked as the dedicated follow-up feature **`workflow-db-mcp`**.
- Per-org isolation beyond the existing `workspaces.organization_id` scoping (the Go orchestrator must populate `organization_id`, but tenant-isolation hardening and `HandleMetadata.TenantID` wiring are forward work).
- Migrating existing git features into the DB (spec: net-new-in-Go only).

---

## Spec open questions — resolution map
- **#1 Database** → PostgreSQL (decided in spec).
- **#2 API surface** → in-process pgx; no HTTP write API in v1 (§3-B, §4.3). The agent/human-facing write & update API + MCP is deferred to **`workflow-db-mcp`**.
- **#3 Agent write path** → Go orchestrator writes directly to Postgres; executor never touches the DB (§4.3).
- **#4 Claim mechanism** → conditional guarded `UPDATE` on `status` (§3-C, §4.3); optional FSM trigger deferred.
- **#5 Auth** → moot for v1: with no write API (B1) the Go orchestrator holds DB credentials directly (credential-isolation pattern); there is no API to authenticate. API auth (service / per-org tokens) is designed in **`workflow-db-mcp`**.
- **#6 Deployment** → the Go orchestrator points at the **same shared Postgres** as the adapter/read-API via `DATABASE_URL` (§8); local Docker Compose for dev, hosted Postgres for prod — consistent with the existing services.
- **#7 Broker partitioning** → owner-namespaced completion queues declared symmetrically; shared dispatch stream; TS takes a small additive `owner='ts'` change (§3-D, §4.4).
- **#8 Shared DB & schema ownership** → one shared Postgres + one schema; write authority partitioned by `owner`; migrations owned by **`workflow-backend`** (a single, clear schema home — coupling resolved) (§4).

---

**Technical design draft complete. Awaiting human approval before task breakdown.**
