# Tasks - Workspace Data Backend

Feature status reference: `ready_for_implementation`; stage status: `technical_design/approved`, `tasks/approved`. Machine state lives in `tasks/T<n>.yaml`; this file is narrative only.

## Index

| ID | Wave | Title | Depends on |
|---|---:|---|---|
| T1 | 1 | Go backend foundation and canonical workspace contracts | [] |
| T2 | 2 | GitHub workspace adapter and parser | [T1] |
| T3 | 2 | PostgreSQL schema and sqlc database adapter | [T1] |
| T4 | 3 | Adapter-service sync orchestration, webhooks, and task queue | [T2, T3] |
| T5 | 3 | API-service workspace read/search routes and source state | [T3] |
| T6 | 4 | API import/sync RPC proxy and stale fallback | [T4, T5] |
| T7 | 5 | Backend integration tests and release validation | [T4, T6] |

---

## T1 — Go backend foundation and canonical workspace contracts

### Description

Establish the Go implementation boundary for this backend feature and define the canonical contracts shared by the GitHub adapter, database adapter, adapter-service RPC, api-service handlers, and tests.

This task owns the package layout, DTOs, adapter interfaces, source-state semantics, source-error contract, and internal RPC contract. If `workflow-backend` is not yet Go-based, this task also owns the minimal Go module and service bootstrap needed for later tasks to compile against.

Deliverables:

- Confirm or create the Go module and service package layout for `workflow-backend`.
- Define the two-binary boundary: `api-service` for internet-facing reads/import/sync triggers and `adapter-service` for GitHub sync, webhooks, and queue workers.
- Define canonical workspace DTOs for workspace summary/detail, feature summary/detail, task summary/detail, pull request refs, activity events, source state, and source errors.
- Define Go interfaces for `GitHubWorkspaceAdapter`, `DbWorkspaceAdapter`, and the internal adapter RPC client/server.
- Choose HTTP+JSON or gRPC for the internal adapter RPC contract and freeze request/response shapes.
- Define source-state semantics for fresh, stale, partial, unavailable, and failed states.
- Define normalized backend error shape with machine-readable code, user-facing message, source kind, and retryability hint.
- Add focused unit tests for DTO mapping, source-error helpers, and RPC contract helpers where useful.

### Required skills

- backend-engineer
- go-best-practices

### Subtasks

- [ ] Inspect current `workflow-backend` entrypoint, package layout, build command, and test command.
- [ ] Add or align Go module/service bootstrap if the backend is not yet Go-based.
- [ ] Define package layout for shared contracts, `api-service`, `adapter-service`, adapters, database queries, and tests.
- [ ] Define workspace, feature, task, PR, activity, source-state, and source-error DTOs.
- [ ] Define Go adapter interfaces for GitHub ingestion and PostgreSQL persistence.
- [ ] Choose and document the internal RPC transport between api-service and adapter-service.
- [ ] Define import/sync RPC request and response contracts.
- [ ] Define source error codes for GitHub, database, parser, validation, adapter, queue, and RPC failures.
- [ ] Add unit tests for DTO/source-state helpers where practical.
- [ ] Verify `go test ./...` or the repo-equivalent test command passes for the new contract layer.

---

## T2 — GitHub workspace adapter and parser

### Description

Implement the Go GitHub adapter that reads a workflow management repository and maps workspace files into the canonical snapshot DTOs from T1.

This task depends on T1 because GitHub parsing must output stable workspace snapshots and source errors rather than source-specific records.

Deliverables:

- Validate repository URL, owner, repo, branch/ref, and optional token input.
- Decide and implement the GitHub fetch strategy for import/sync: Contents API, archive download, or a hybrid approach.
- Discover `docs/features/*/status.yaml`.
- Read `workspace.yaml`, feature `status.yaml`, `product-spec.md`, `technical-design.md`, `tasks.md`, and `tasks/T*.yaml` where available.
- Parse YAML with `gopkg.in/yaml.v3`; preserve markdown strings for document views.
- Map missing optional files to empty states and missing required files to structured source errors.
- Map inaccessible repos, invalid YAML, rate limits, and network failures to canonical source errors.
- Return commit SHA, fetch timestamp, source paths, content hashes, and parser warnings for persistence.

### Required skills

- backend-engineer
- go-best-practices

### Subtasks

- [ ] Pick the GitHub fetch strategy and document why it fits full reconciliation and targeted sync.
- [ ] Build repository URL/ref normalization and validation.
- [ ] Implement GitHub client calls with context cancellation and retry-aware error handling.
- [ ] Implement feature discovery from `docs/features/*/status.yaml`.
- [ ] Implement YAML parsing for workspace, feature status, and task YAML files.
- [ ] Preserve markdown content for product spec, technical design, and tasks narrative views.
- [ ] Map parsed files into canonical snapshot DTOs from T1.
- [ ] Map GitHub/parser failures into canonical source errors.
- [ ] Add fixture-backed tests for success, missing optional files, invalid YAML, inaccessible repo, and rate-limit/network failures.
- [ ] Verify Go tests pass for the adapter package.

---

## T3 — PostgreSQL schema and sqlc database adapter

### Description

Add the PostgreSQL persistence layer for saved workspaces and the current normalized workspace mirror using SQL migrations, `sqlc` query definitions, and `pgx` runtime access.

This task depends on T1 because table rows and queries must map into the canonical DTOs and adapter contract defined there.

Deliverables:

- Add `goose` SQL migrations for `workspaces`, `workspace_repos`, `workspace_features`, `workspace_feature_documents`, `workspace_tasks`, `workspace_activity_events`, `workspace_github_sources`, `workspace_snapshots`, and `workspace_sync_runs`.
- Do not create a PostgreSQL queue table; task-branch sync queueing is handled by Redis/asynq outside the database schema.
- Add `sqlc` query definitions for workspace list/detail reads, feature/task reads, activity reads, current mirror writes, targeted updates, GitHub source reads/writes, snapshot bookkeeping, and sync-run audit writes.
- Configure `pgx` database connection handling through `DATABASE_URL`.
- Preserve lowercase `snake_case` physical names for tables, columns, indexes, and constraints.
- Keep credentials and expanded local paths out of persisted UI-facing rows.
- Add database adapter tests that run against PostgreSQL.

### Required skills

- backend-engineer
- go-best-practices
- postgres-best-practices

### Subtasks

- [ ] Inspect current `workflow-backend` database conventions, if any.
- [ ] Add `goose` migration files for workspace, repo, feature, document, task, activity, GitHub source, snapshot, and sync-run tables.
- [ ] Add constraints and indexes for workspace lookup, repo lookup, feature status/stage, task status/repo, activity timeline, GitHub source lookup, snapshot lookup, and sync-run audit queries.
- [ ] Add `sqlc` config and SQL query files following repo layout.
- [ ] Generate typed Go query code through `sqlc`.
- [ ] Implement `DbWorkspaceAdapter` methods using `pgx` and generated queries.
- [ ] Implement transactional full-reconciliation writes that update current core tables and record snapshot bookkeeping without a read-path snapshot pointer.
- [ ] Implement targeted update methods for feature docs and task YAML rows.
- [ ] Implement task-level update methods for queued task-branch sync rows.
- [ ] Implement stale-cache read behavior from the latest `workspace_sync_runs` row; failed syncs must not overwrite current core tables.
- [ ] Add tests for migration apply, list/detail reads, mirror writes, targeted update, task update, sync-run staleness, and stale fallback.
- [ ] Verify migrations apply and generated queries compile.

---

## T4 — Adapter-service sync orchestration, webhooks, and task queue

### Description

Implement the internal `adapter-service` write side: import/sync orchestration, GitHub webhook routing, Redis/asynq task-branch queueing, and the internal RPC server consumed by `api-service`.

This task depends on T2 and T3 because it must fetch normalized GitHub snapshots and persist them through the database adapter in transactions.

Deliverables:

- Add the `adapter-service` binary or service entrypoint.
- Implement internal RPC handlers for import and manual sync using the T1 contract.
- Implement full reconciliation orchestration: create sync run, fetch repository, upsert core tables, write snapshot bookkeeping, mark sync run success/failure.
- Implement targeted feature sync for feature-branch webhook events.
- Implement GitHub webhook validation, branch routing, and ignored-branch behavior.
- Implement Redis/asynq task enqueueing for task-branch webhook events with one pending job per `(workspace_id, feature_id, task_id)` payload.
- Implement the task-sync worker that fetches current task-branch HEAD and upserts task rows and activity events.
- Resolve the full-reconciliation queue clear policy so pending task jobs cannot corrupt another workspace's sync state.
- Map adapter, GitHub, queue, and database failures to canonical source errors.
- Add service tests for import, manual sync, webhook routing, task enqueue, worker drain, stale-job handling, and failure audit rows.

### Required skills

- backend-engineer
- go-best-practices

### Subtasks

- [ ] Create or align `adapter-service` entrypoint and runtime config.
- [ ] Add internal RPC server handlers for import and manual sync.
- [ ] Implement full reconciliation transaction orchestration and sync-run bookkeeping.
- [ ] Implement targeted feature sync orchestration.
- [ ] Implement GitHub webhook signature validation and branch classification.
- [ ] Implement Redis/asynq client/server config through `REDIS_URL`.
- [ ] Implement task-branch enqueueing with deduplication.
- [ ] Implement task-sync worker drain behavior.
- [ ] Resolve and implement queue clear or stale-job skip behavior for full reconciliation.
- [ ] Add tests for RPC handlers, webhook routing, queue enqueue/drain, and sync failure behavior.
- [ ] Verify adapter-service tests pass.

---

## T5 — API-service workspace read/search routes and source state

### Description

Expose the read-only UI-facing API routes that serve saved workspace data from PostgreSQL core tables, support separate feature and task search/filter queries, and attach source-state metadata derived from sync runs.

This task depends on T3 because all UI reads must come from the migrated PostgreSQL schema and generated query layer.

Deliverables:

- Add or align the `api-service` binary or service entrypoint.
- Add saved workspace list route.
- Add workspace detail route.
- Add feature search/list route with `query`, `status`, `updated_from`, `updated_to`, and pagination.
- Add workspace-level task search/list route with `query`, `status`, `updated_from`, `updated_to`, and pagination.
- Add feature detail route.
- Add feature tasks route.
- Add task detail route.
- Add activity route.
- Derive `SourceState` from the latest `workspace_sync_runs` row, not from `workspaces`.
- Ensure API responses expose DTOs only, not raw database rows, credentials, or expanded local paths.
- Map database and validation errors to stable HTTP status codes and error payloads.
- Add route/service tests for successful reads, feature search/filter combinations, task search/filter combinations, not found, validation errors, stale source state, and database errors.

### Required skills

- backend-engineer
- go-best-practices

### Subtasks

- [ ] Create or align `api-service` entrypoint and route registration.
- [ ] Implement workspace list route.
- [ ] Implement workspace detail route.
- [ ] Implement feature search/list route with `query`, `status`, `updated_from`, `updated_to`, `limit`, and `cursor` query parameters.
- [ ] Implement workspace-level task search/list route with `query`, `status`, `updated_from`, `updated_to`, `limit`, and `cursor` query parameters.
- [ ] Implement feature detail and feature tasks routes.
- [ ] Implement task detail route.
- [ ] Implement activity route.
- [ ] Add source-state derivation from latest sync run.
- [ ] Map database and validation failures to canonical API errors.
- [ ] Add handler/service tests for success, feature search/filter, task search/filter, and failure paths.
- [ ] Verify API read-route tests pass.

---

## T6 — API import/sync RPC proxy and stale fallback

### Description

Connect the UI-facing import and sync routes to `adapter-service` through the internal RPC contract, and return stable success, stale-cache, and structured-error payloads.

This task depends on T4 and T5 because it needs a working adapter RPC server and established api-service route/error conventions.

Deliverables:

- Add GitHub workspace import route.
- Add workspace sync route.
- Implement the adapter RPC client in `api-service`.
- Validate import/sync request payloads, repo URLs, workspace IDs, and token inputs.
- Respect the chosen GitHub token reuse policy in request handling.
- On import or sync success, read the updated workspace detail from PostgreSQL and return normalized DTOs.
- On sync failure with cached data, return cached data marked stale.
- On sync failure without cached data, return a structured source error.
- Ensure `api-service` does not call GitHub directly.
- Add route/service tests for import success, sync success, adapter RPC failure, GitHub failure with cache, GitHub failure without cache, and token policy errors.

### Required skills

- backend-engineer
- go-best-practices

### Subtasks

- [ ] Implement adapter RPC client configuration in `api-service`.
- [ ] Add GitHub workspace import route.
- [ ] Add workspace sync route.
- [ ] Validate import/sync request payloads and token policy.
- [ ] Fetch updated workspace detail from PostgreSQL after successful adapter RPC calls.
- [ ] Return stale cached payloads with source-state metadata when sync fails and cache exists.
- [ ] Return structured source errors when sync fails and no cache exists.
- [ ] Add tests for success, adapter failure, stale fallback, no-cache failure, and token-policy failures.
- [ ] Verify import/sync route tests pass.

---

## T7 — Backend integration tests and release validation

### Description

Validate the completed backend feature end to end across GitHub parsing, PostgreSQL persistence, adapter-service sync/queue work, api-service HTTP routes, and release configuration.

This task depends on T4 and T6 because it needs both the adapter-service write side and UI-facing api-service routes.

Deliverables:

- Integration test for first import: GitHub fixture or mocked GitHub -> adapter-service -> PostgreSQL write -> api-service read API.
- Integration test for successful manual sync updating current mirror rows and snapshot bookkeeping.
- Integration test for feature-branch webhook targeted sync.
- Integration test for task-branch webhook enqueue and worker drain.
- Integration test for sync failure with existing cache returning stale data.
- Integration test for sync failure without cache returning structured source error.
- Integration tests for workspace list/detail, feature search/filter, task search/filter, feature detail, feature tasks, task detail, and activity routes.
- Migration validation on a fresh PostgreSQL database.
- Release notes or backend-local docs covering required env vars, migration command, Redis/asynq config, adapter RPC config, webhook config, and GitHub token behavior.

### Required skills

- backend-engineer
- go-best-practices
- postgres-best-practices

### Subtasks

- [ ] Build integration fixtures for a representative workflow management repo.
- [ ] Add full import integration test.
- [ ] Add manual sync success integration test.
- [ ] Add feature-branch webhook targeted sync integration test.
- [ ] Add task-branch enqueue and worker-drain integration test.
- [ ] Add sync failure with stale cache integration test.
- [ ] Add sync failure without cache integration test.
- [ ] Add API integration tests for list/detail/feature search/filter/task search/filter/feature/task/activity routes.
- [ ] Validate `goose` migrations on a fresh PostgreSQL database.
- [ ] Validate `sqlc` generated queries compile in CI/local test flow.
- [ ] Document required env vars, migration command, Redis/asynq config, adapter RPC config, webhook config, and token policy.
- [ ] Confirm backward compatibility: existing routes keep working and frontend can keep using direct GitHub reads until `workspace-tabs-data-flow` switches over.
