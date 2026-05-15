# Tasks - Workspace Data Backend

Feature status reference: `ready_for_implementation`; stage status: `technical_design/approved`, `tasks/approved`. Machine state lives in `tasks/T<n>.yaml`; this file is narrative only.

## Index

| ID | Wave | Repo | Title | Depends on |
|---|---:|---|---|---|
| T1 | 1 | workspace-github-adapter | Go backend foundation and canonical workspace DTOs | [] |
| T2 | 2 | workspace-github-adapter | GitHub workspace adapter and parser | [T1] |
| T3 | 2 | workspace-github-adapter | PostgreSQL schema and sqlc database adapter | [T1] |
| T4 | 3 | workflow-backend | Workspace source service and HTTP API routes | [T2, T3] |
| T5 | 4 | workflow-backend | Backend integration tests and release validation | [T3, T4] |

---

## T1 - Go backend foundation and canonical workspace DTOs

### Description

Establish the Go implementation boundary for this backend feature and define the canonical data contracts shared by the GitHub adapter, database adapter, service layer, and HTTP handlers.

This task owns the package layout, DTOs, adapter interfaces, source-state semantics, and source-error contract. It also owns the minimal Go module and service bootstrap needed for later tasks to compile against, since `workspace-github-adapter` is a new repo.

Deliverables:

- Confirm or create the Go module and service package layout for `workspace-github-adapter`.
- Define canonical workspace DTOs for workspace summary/detail, feature summary/detail, task summary/detail, pull request refs, activity events, source state, and source errors.
- Define Go interfaces for `GitHubWorkspaceAdapter` and `DbWorkspaceAdapter`.
- Define source-state semantics for fresh, stale, partial, unavailable, and failed states.
- Define normalized backend error shape with machine-readable code, user-facing message, source kind, and retryability hint.
- Add focused unit tests for DTO mapping and source-error helpers where useful.

### Required skills

- backend-engineer
- go-best-practices

### Subtasks

- [ ] Inspect current `workspace-github-adapter` repo state (entrypoint, package layout, build command, test command) — bootstrap if empty.
- [ ] Add Go module and service bootstrap for `workspace-github-adapter` (new repo — both binaries start here).
- [ ] Define workspace, feature, task, PR, activity, source-state, and source-error DTOs.
- [ ] Define Go adapter interfaces for GitHub ingestion and PostgreSQL persistence.
- [ ] Define source error codes for GitHub, database, parser, validation, and adapter failures.
- [ ] Add unit tests for DTO/source-state helpers where practical.
- [ ] Verify `go test ./...` or the repo-equivalent test command passes for the new contract layer.

---

## T2 - GitHub workspace adapter and parser

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

- [ ] Pick the GitHub fetch strategy and document why it fits import and targeted sync.
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

## T3 - PostgreSQL schema and sqlc database adapter

### Description

Add the PostgreSQL persistence layer for saved workspaces and normalized workspace snapshots using SQL migrations, `sqlc` query definitions, and `pgx` runtime access.

This task depends on T1 because table rows and queries must map into the canonical DTOs and adapter contract defined there.

Deliverables:

- Add `goose` SQL migrations for `workspaces`, `workspace_snapshots`, `workspace_features`, `workspace_feature_documents`, `workspace_tasks`, `workspace_activity_events`, and `workspace_sync_runs`.
- Add the `last_targeted_sync_at` field needed for webhook-targeted updates.
- Add `sqlc` query definitions for workspace list/detail reads, feature/task reads, activity reads, snapshot writes, targeted updates, and sync-run audit writes.
- Configure `pgx` database connection handling through `DATABASE_URL`.
- Preserve lowercase `snake_case` physical names for tables, columns, indexes, and constraints.
- Keep credentials and expanded local paths out of persisted UI-facing rows.
- Add database adapter tests that run against PostgreSQL.

### Required skills

- backend-engineer
- go-best-practices
- postgres-best-practices

### Subtasks

- [ ] Inspect current `workspace-github-adapter` database conventions, if any.
- [ ] Add `goose` migration files for workspace, snapshot, feature, document, task, activity, and sync-run tables.
- [ ] Add constraints and indexes for workspace lookup, feature status/stage, task status/repo, activity timeline, snapshot version, and sync-run audit queries.
- [ ] Add `sqlc` config and SQL query files following repo layout.
- [ ] Generate typed Go query code through `sqlc`.
- [ ] Implement `DbWorkspaceAdapter` methods using `pgx` and generated queries.
- [ ] Implement transactional full-snapshot writes and active snapshot promotion.
- [ ] Implement targeted update methods for feature docs and task YAML rows.
- [ ] Implement stale-cache read behavior without replacing `active_snapshot_id` on failed sync.
- [ ] Add tests for migration apply, list/detail reads, snapshot write, targeted update, and stale fallback.
- [ ] Verify migrations apply and generated queries compile.

---

## T4 - Workspace source service and HTTP API routes

### Description

Expose the Go HTTP API consumed by `digital-factory-ui` and coordinate GitHub ingestion with PostgreSQL reads through a source service.

This task depends on T2 and T3 because routes must be able to import/sync through GitHub and serve persisted snapshots from the database.

Deliverables:

- Add source service orchestration for list, import, detail, sync, feature detail, feature tasks, task detail, and activity.
- Add HTTP handlers under the backend's route conventions, using `gin` if no stronger repo-local convention exists.
- Serve all UI reads from PostgreSQL, not GitHub.
- On import or sync success, persist the new or updated snapshot and return normalized DTOs.
- On sync failure with cached data, return cached data marked stale.
- On sync failure without cached data, return a structured source error.
- Respect the chosen GitHub token reuse policy in import/sync request handling.
- Add route/service tests for success, validation errors, GitHub errors, database errors, and stale-cache fallback.

### Required skills

- backend-engineer
- go-best-practices

### Subtasks

- [ ] Implement source service methods for list, import, detail, sync, feature detail, task detail, and activity.
- [ ] Add saved workspace list route.
- [ ] Add GitHub workspace import route.
- [ ] Add workspace detail route.
- [ ] Add workspace sync route.
- [ ] Add feature detail and feature tasks routes.
- [ ] Add task detail route.
- [ ] Add activity route.
- [ ] Map adapter errors to stable HTTP status codes and error payloads.
- [ ] Return stale cached payloads with source-state metadata when sync fails and cache exists.
- [ ] Add handler/service tests for success and failure paths.
- [ ] Verify Go tests pass for route and service packages.

---

## T5 - Backend integration tests and release validation

### Description

Validate the completed backend feature end to end across GitHub parsing, PostgreSQL persistence, service orchestration, and HTTP routes.

This task depends on T3 and T4 because it needs migrated PostgreSQL tables and reachable API routes.

Deliverables:

- Integration test for first import: GitHub fixture or mocked GitHub -> PostgreSQL write -> workspace read API.
- Integration test for successful sync updating the active snapshot.
- Integration test for sync failure with existing cache returning stale data.
- Integration test for sync failure without cache returning structured source error.
- Integration tests for workspace list/detail, feature detail, feature tasks, task detail, and activity routes.
- Migration validation on a fresh PostgreSQL database.
- Release notes or backend-local docs covering required env vars, migration command, sync polling config, and GitHub token behavior.

### Required skills

- backend-engineer
- go-best-practices
- postgres-best-practices

### Subtasks

- [ ] Build integration fixtures for a representative workflow management repo.
- [ ] Add full import integration test.
- [ ] Add sync success integration test.
- [ ] Add sync failure with stale cache integration test.
- [ ] Add sync failure without cache integration test.
- [ ] Add API integration tests for list/detail/feature/task/activity routes.
- [ ] Validate `goose` migrations on a fresh PostgreSQL database.
- [ ] Validate `sqlc` generated queries compile in CI/local test flow.
- [ ] Document required env vars, migration command, polling config, and token policy.
- [ ] Confirm backward compatibility: existing routes keep working and frontend can keep using direct GitHub reads until `workspace-tabs-data-flow` switches over.
