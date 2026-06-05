# Product Specification

## Feature
- Feature ID: `workflow-db`
- Title: Workflow State Database — Agent Write Path and Relational Storage

## Problem

Today every agent action — claiming a task, updating status, logging progress, marking done — is a git commit and push to the management repo. This works at low concurrency but creates compounding problems as the platform scales:

The git-based claim protocol uses push-rejection as its concurrency primitive. Two agents racing for the same task both write to a branch and the slower push loses. This works, but it is slow (full git round-trip per claim), has a retry cost, and becomes a bottleneck under high agent parallelism.

Workflow state — features, tasks, stages, log entries, dependencies — lives as YAML files that must be opened and parsed one by one to answer questions like "what tasks are ready right now?" or "which features are blocked and why?" There is no queryable record, no referential integrity, and no event history that can be sliced or aggregated.

This is the foundation we need to fix before the platform can grow. `workflow-db` stands up a database as the system of record for the live task state of the features it owns, with the runtime writing that state to it instead of git. It runs **alongside** the existing git/YAML path rather than replacing it in one step (see "Coexistence model — parallel orchestrators"): new features are created in the database world, while existing features finish their lifecycle in git. For a database-owned feature the management repo retains only narrative artifacts (product specs, technical designs, tasks.md) and is no longer the source of truth for its live task state.

## Goals

- Make task-state writes (claim, status transition, log entries, blocked state) database operations rather than git commits, for features the Go orchestrator owns.
- Replace the git push-rejection claim protocol with a database-backed atomic claim that is fast and correct under high agent concurrency. (The concurrency mechanism is a technical-design decision — see open question #4.)
- Store features, tasks, stages, log entries, and dependencies in a relational schema with foreign keys and constraints.
- Store state so cross-feature questions (all ready tasks, all blocked tasks with reason, the task dependency graph, agent activity by time range) are answerable from the database in a single query — not by parsing YAML files one at a time. (The read API that exposes these to the frontend is `workspace-data-backend`'s, not this feature's — see "Relationship to other features".)
- Keep git for code artifacts and narrative documents — only live task state moves to the database.
- **Run the Go/Postgres orchestrator in parallel with the unchanged TS/git orchestrator, partitioned by a nullable `owner` field.** Non-null `owner` = Go (state in the DB); null/absent = legacy TS (state in git). New features are created in whichever world owns them; existing git features stay in git. The two share only the completion broker / dispatch queue, which must be partitioned by `owner` so neither orchestrator drains the other's work. (See "Coexistence model — parallel orchestrators".)

## Non-goals

- Not replacing git for implementation repos or narrative files (`tasks.md`, `product-spec.md`, `technical-design.md`).
- Not building a full Jira replacement — no issue assignment, sprint planning, or time tracking in v1.
- Not real-time push notifications in v1 — polling is acceptable for the dashboard.
- **Not the frontend read layer, and not a new read API.** The frontend reads features through `workspace-data-backend`'s existing read API (see "Relationship to other features"). Because the Go orchestrator writes `go`-owned features into the database that API already serves, the frontend should need little or no change — `workflow-db` does not build a read API or modify the FE.
- **Not the MCP server for external LLM clients.** Exposing workflow reads/writes to IDE plugins and copilots via MCP is deferred to its own downstream feature (see "Relationship to other features"). It is not required for `workflow-db`.

## Relationship to other features

### Prerequisite — `standalone-executor-hardening` (DONE, 2026-05-30)

`workflow-db` introduces a second orchestrator — Go, backed by Postgres — that must run **in parallel** with the existing TypeScript/git orchestrator. That coexistence depends on the executor being decoupled from the orchestrator, which is exactly what `standalone-executor-hardening` delivered. With that feature complete (T1–T7 all merged, feature `done`), the following are now settled inputs to this design — they do not need to be re-litigated here:

- **The executor is standalone and orchestrator-agnostic.** Any orchestrator — including the new Go/Postgres one — can drive the existing, proven TypeScript executor over the ABI (`runtime/abi/docs/abi-spec.md`) and broker protocol. The Go orchestrator does **not** reimplement the executor; the rewrite surface is the orchestrator only.
- **Topology is per-orchestrator-instance** (`RUNTIME_PROFILE` + the bootstrap profile map, set per service in compose) — not a global mode. Two orchestrators with different profiles run side by side on the same infrastructure. This is the concrete mechanism by which the TS/git and Go/Postgres orchestrators run in parallel (see "Coexistence model — parallel orchestrators").
- **The orchestrator owns the entire claim and all workflow-state writes; the executor writes none.** The claim (status → `in_progress` plus the state write) happens in the orchestrator, and the executor is spawned only if the claim is won, receiving an already-claimed branch. This directly resolves open question #3 below.
- **A dispatch service is the sole holder of spawn credentials; the orchestrator runs unprivileged.** This establishes the credential-isolation pattern this feature's DB write path should follow: privileged material (here, DB credentials) lives with the mediating service, never in executor/agent context.
- **The standalone path already took executor logs off the management repo** (`LOG_SINK=none` → stdout). That is the first slice of workflow state to leave git; `workflow-db` continues that direction for the rest of live task state.

### Related — `workspace-data-backend` (the read side)

`workspace-data-backend` is the **read API the frontend uses to list and display all features**, plus an **adapter that syncs YAML → database** so legacy (git/YAML) features are queryable through that API. It is the read/migration side; `workflow-db` is the write side. The two are complementary:

- `workspace-data-backend` owns the **read API and the FE-facing data shape**, and (via its YAML→DB adapter) keeps legacy features visible.
- `workflow-db` makes the **Go orchestrator write `go`-owned features' live state directly into the same database** — so they surface through the existing read API with **no YAML and no adapter step**.

Done right, the **frontend needs little or no change**: it already reads the database through `workspace-data-backend`; `workflow-db` simply adds a second, live writer (the Go orchestrator) alongside the existing YAML→DB sync. The coordination point — whether the two features share one database and one schema — is open question #8.

### Downstream — workflow MCP server (separate feature)

Exposing workflow reads and writes to external LLM clients (IDE plugins, copilots) through an MCP server is a **separate downstream feature**, out of scope here. When it is built it belongs on `workflow-db` (the live system of record, which owns the write path) rather than on the read-only FE API — but that is a later step.

## Coexistence model — parallel orchestrators

`workflow-db` does **not** cut the workspace over in one shot and does **not** migrate existing features. The TS/git and Go/Postgres orchestrators run **in parallel**, and for *feature state* the split is clean:

- **The TS orchestrator reads git/YAML; the Go orchestrator reads the Postgres DB.** TS is unchanged — it keeps doing exactly what it does today.
- **The Go orchestrator never creates a feature in git.** A Go feature is created directly in the DB and lives there only — it never appears as YAML. A legacy feature lives in git only. For *state*, the two read **disjoint stores**, so neither can see, claim, or write the other's features — no cross-system locking or skip-logic on the state path.
- The **`owner`** field is **nullable**: non-null = Go (set automatically on creation), null/absent = legacy/TS. Existing git features need **no backfill**, and the Go orchestrator drives only non-null-`owner` rows. There is no import and no cutover — existing features finish their lifecycle in git; net-new work is created in whichever world owns it.

**The one surface the two orchestrators share is the broker — and it must be partitioned by `owner`.** The completion broker and dispatch queue (one Redis, from `standalone-executor-hardening`) are shared infrastructure, and today completions are *drained opportunistically by any orchestrator*. That is unsafe across the two worlds: a TS orchestrator that drained a Go executor's completion could not resolve the task (it is not in git), and vice versa. So the broker must scope each orchestrator to its own features — e.g. an `owner` filter on the drain (null/yaml vs go) or separate queues per world — designed so the **TS orchestrator still needs no change** (Go takes the new queue / passes the new filter; the legacy drain keeps its current behaviour by default). This is the only place the two touch. See open question #7.

## Key open questions (to resolve in technical design)

1. **Database** — DECIDED: **PostgreSQL**. (SQLite was considered for zero-infra simplicity but rejected; Postgres is the operational standard and matches the `Go/Postgres` orchestrator named throughout this spec and `standalone-executor-hardening`.)
2. **API surface** — the FE read API is `workspace-data-backend`'s (see "Relationship to other features"), so `workflow-db` likely needs no read API of its own. Does it expose an HTTP *write* API in v1, or is the Go orchestrator's in-process DB access the only writer? (Ties to #3; external-client write access is the deferred MCP feature.)
3. **Agent write path** — RESOLVED by `standalone-executor-hardening` (see "Relationship to other features"). The executor never writes workflow state; the **orchestrator** owns the entire claim and all status/log writes. In the DB world this means the **Go orchestrator** writes to Postgres, and executors (agent containers) never hold DB credentials or touch the database — exactly as they hold no spawn credentials today. Still open for technical design (with #2): whether the orchestrator writes to Postgres directly (in-process driver) or through an HTTP write API. (External, non-runtime write clients are the deferred MCP feature — not v1.)
4. **Claim protocol** — optimistic locking vs `SELECT FOR UPDATE`. What is the right mechanism for the new atomic claim?
5. **Auth** — the write API is consumed by the **orchestrator** (the executor never touches the DB — see #3); a service token authenticating the orchestrator is the minimum. Is that sufficient for v1, or is per-tenant scoping needed from the start?
6. **Deployment** — local Docker Compose for development, hosted Postgres for production?
7. **Broker partitioning by `owner`** — the completion broker / dispatch queue is the one surface both orchestrators share (one Redis, from `standalone-executor-hardening`), and today any orchestrator drains any completion. It must be partitioned so the TS orchestrator never drains or dispatches a non-null-`owner` (Go) feature's executor work, and vice versa. Open for technical design: an `owner` filter parameter on the broker drain (treating null/yaml as legacy) vs two separate queues per world — chosen so the **TS orchestrator itself needs no change** (the broker, not the legacy orchestrator, carries the new behaviour).
8. **Shared database & schema ownership** — does `workflow-db` write to the *same* database `workspace-data-backend` reads (so the frontend needs no change), and if so, who owns the schema the two must agree on? The "FE needs no change" outcome depends on a single shared schema; a separate `workflow-db` database would reintroduce a sync step and defeat the purpose.

## Success criteria

- A feature with a **non-null `owner`** (set automatically when the Go orchestrator creates it) is picked up by the Go orchestrator; null-`owner` features are ignored by it and left to the TS/git orchestrator.
- For a `go`-owned feature, task-state writes (claim, status transition, log) are database operations, not git commits.
- The TS/git orchestrator runs **unchanged** — no code modification — and keeps driving its null-`owner` features from git/YAML while the Go orchestrator runs in parallel on the same workspace.
- The shared completion broker / dispatch queue is partitioned by `owner`: the TS orchestrator never drains or dispatches a non-null-`owner` (Go) feature's executor work, and the Go orchestrator never drains a legacy one's — achieved without changing the TS orchestrator itself.
- No dual-write or contention occurs between the two orchestrators: each mutates state only for the features it owns.
- A `go`-owned feature's live state lives **only** in the database — it has no git/YAML representation, and the database is its sole source of truth.
- Cross-feature questions over `go`-owned features (all ready tasks, all blocked tasks) are answerable from the database in a single query, against live state with no static build step.
- A `go`-owned feature created by the Go orchestrator surfaces through `workspace-data-backend`'s existing read API with no change to the frontend.
