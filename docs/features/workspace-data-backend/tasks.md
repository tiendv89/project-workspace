# Tasks - Workspace Data Backend

Feature status reference: `in_tdd`; stage status: `technical_design/approved`, `tasks/awaiting_approval`, `handoff/draft` paused until T7 is reviewed. Machine state lives in `tasks/T<n>.yaml`; this file is narrative only.

## Index

| ID | Wave | Repo | Title | Depends on |
|---|---:|---|---|---|
| T1 | 1 | workspace-github-adapter | Go backend foundation and canonical workspace DTOs | [] |
| T2 | 2 | workspace-github-adapter | GitHub workspace adapter and parser | [T1] |
| T3 | 2 | workspace-github-adapter | PostgreSQL schema and sqlc database adapter | [T1] |
| T4 | 3 | workflow-backend | Workspace source service and HTTP API routes | [T2, T3] |
| T5 | 4 | workflow-backend | Backend integration tests and release validation | [T3, T4, T6] |
| T6 | 4 | workflow | Docker Compose — local infra and service entries for workspace-data-backend | [T1, T4] |
| T7 | 5 | workspace-github-adapter | GitHub webhook handler and task sync queue | [T2, T3, T6] |

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
- [ ] Add `Dockerfile` for `adapter-service` binary (multi-stage build: build → runtime).
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
- Return commit SHA, fetch timestamp, source paths, and parser warnings for persistence.
- Build GitHub web URLs for each document file (`workspace_feature_documents.url`) — content is not stored.

### Required skills

- backend-engineer
- go-best-practices

### Subtasks

- [ ] Pick the GitHub fetch strategy and document why it fits import and targeted sync.
- [ ] Build repository URL/ref normalization and validation.
- [ ] Implement GitHub client calls with context cancellation and retry-aware error handling.
- [ ] Implement feature discovery from `docs/features/*/status.yaml`.
- [ ] Implement YAML parsing for workspace, feature status, and task YAML files.
- [ ] Build GitHub web URL for each document file (product spec, technical design, tasks.md, status.yaml) — no content stored.
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

- Add `goose` SQL migrations for `workspaces`, `workspace_repos`, `workspace_features`, `workspace_feature_documents`, `workspace_tasks`, `workspace_activity_events`, `workspace_github_sources`, and `workspace_sync_runs`.
- Add `sqlc` query definitions for workspace list/detail reads, feature/task reads, activity reads, core table upserts, targeted updates, and sync-run audit writes.
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
- [ ] Add constraints and indexes for workspace lookup, feature status/stage, task status/repo, activity timeline, and sync-run audit queries.
- [ ] Add `sqlc` config and SQL query files following repo layout.
- [ ] Generate typed Go query code through `sqlc`.
- [ ] Implement `DbWorkspaceAdapter` methods using `pgx` and generated queries.
- [ ] Implement transactional full reconciliation upserts (all core tables in one transaction) and targeted sync upserts (per-feature).
- [ ] Implement `workspace_activity_events` upsert — normalize feature `history[]` and task `log[]` into rows during sync.
- [ ] Implement targeted update methods for feature docs and task rows.
- [ ] Implement staleness derivation from latest `workspace_sync_runs` row (no active snapshot pointer).
- [ ] Add tests for migration apply, list/detail reads, core table upsert, activity normalization, targeted update, and stale fallback.
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
- On import or sync success, upsert all affected core tables and return normalized DTOs.
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
- [ ] Add `Dockerfile` for `api-service` binary (multi-stage build: build → runtime).
- [ ] Verify Go tests pass for route and service packages.

---

## T5 - Backend integration tests and release validation

### Description

Validate the completed backend feature end to end across GitHub parsing, PostgreSQL persistence, service orchestration, and HTTP routes.

This task depends on T3 and T4 because it needs migrated PostgreSQL tables and reachable API routes.

Deliverables:

- Integration test for first import: GitHub fixture or mocked GitHub -> PostgreSQL write -> workspace read API.
- Integration test for successful sync updating core tables and writing a success sync-run row.
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

---

## T6 - Docker Compose — local infra and service entries for workspace-data-backend

### Description

Add all workspace-data-backend Docker Compose entries to `runtime/orchestrator/templates/docker-compose.yml` in two profiles: infra (PostgreSQL, Redis, asynqmon) and services (adapter-service, api-service).

Deliverables:

**`workspace-infra` profile** — pulled images, no build required:
- `postgres`: PostgreSQL 16, port `5432`, database `workspace_data`, named volume, health check.
- `redis`: Redis 7, port `6379`, named volume.
- `asynqmon`: asynq monitoring UI, port `8080`, points at Redis.

**`workspace-backend` profile** — builds from local repo paths:
- `adapter-service`: builds from `WORKSPACE_GITHUB_ADAPTER_LOCAL_PATH`, depends on `postgres` + `redis`, env vars `DATABASE_URL`, `REDIS_URL`, `GITHUB_TOKEN`. Joins `agents-net`.
- `api-service`: builds from `WORKFLOW_BACKEND_LOCAL_PATH`, depends on `postgres`, env vars `DATABASE_URL`, `ADAPTER_SERVICE_URL`. Exposes HTTP port. Joins `agents-net`.

Document all required env vars in the file header and `.env.template`.

Usage after this task:
```
docker compose --profile workspace-infra up -d                           # infra only
docker compose --profile workspace-infra --profile workspace-backend up -d  # full stack
```

### Required skills

- backend-engineer

### Subtasks

- [ ] Add `postgres`, `redis`, `asynqmon` services under `workspace-infra` profile with named volumes.
- [ ] Add `adapter-service` build + env + depends_on under `workspace-backend` profile.
- [ ] Add `api-service` build + env + depends_on + port under `workspace-backend` profile.
- [ ] Add named volumes for postgres and redis data.
- [ ] Add `WORKSPACE_GITHUB_ADAPTER_LOCAL_PATH`, `WORKFLOW_BACKEND_LOCAL_PATH`, `POSTGRES_PASSWORD`, `DATABASE_URL`, `REDIS_URL`, `ADAPTER_SERVICE_URL` to `.env.template`.
- [ ] Document startup commands in the file header comment.
- [ ] Verify `docker compose --profile workspace-infra up -d` starts infra only and not the app services.
- [ ] Verify `docker compose up` (no profile) starts neither infra nor app services.

---

## T7 - GitHub webhook handler and task sync queue

### Description

Implement the missing `adapter-service` webhook runtime so GitHub push events can keep the read mirror current without manual sync.

This task owns the webhook HTTP handler, GitHub signature verification, branch routing, task-branch queue enqueueing, and the asynq worker that drains queued task sync events.

Deliverables:

- Add a webhook endpoint in `adapter-service` for GitHub push events.
- Verify GitHub webhook signatures using `GITHUB_WEBHOOK_SECRET`; reject invalid signatures before parsing.
- Parse push payload `ref` and changed paths from `commits[].added`, `commits[].modified`, and `commits[].removed`.
- Route base-branch pushes to targeted feature sync for each touched `docs/features/<feature-id>/` path.
- Route `feature/<feature-id>` pushes to targeted feature sync for that feature.
- Route `feature/<feature-id>-T<n>` pushes to an asynq `task:sync` job with `{WorkspaceID, FeatureID, TaskID}` payload and `asynq.Unique(24*time.Hour)` dedupe.
- Return quickly from the webhook handler after validation and enqueue/dispatch; task branch work must not block the webhook response.
- Implement the asynq worker that derives the task branch from `workspace.yaml` branch pattern, fetches current task branch HEAD, parses `tasks/T<n>.yaml`, and upserts `workspace_tasks` plus task activity events in one transaction.
- Clear pending task-sync jobs for the workspace before full reconciliation starts.
- Expose worker/client configuration through `REDIS_URL`; document `GITHUB_WEBHOOK_SECRET` and webhook setup alongside existing adapter-service env vars.
- Add tests for valid/invalid signatures, ignored branches, base branch changed-path routing, feature branch targeted sync, task branch enqueue dedupe, worker success, retryable worker failure, and full-reconciliation queue clearing.

### Required skills

- backend-engineer
- go-best-practices

### Subtasks

- [ ] Add webhook HTTP route/handler to `adapter-service`.
- [ ] Implement GitHub HMAC signature verification with `GITHUB_WEBHOOK_SECRET`.
- [ ] Parse push event refs and changed file paths.
- [ ] Implement branch classification for base branch, feature branch, task branch, and ignored branch.
- [ ] Dispatch base branch and feature branch events to targeted feature sync.
- [ ] Add asynq client setup and enqueue task branch events with `task:sync`, `task-sync` queue, `Unique(24h)`, retries, and backoff.
- [ ] Add asynq worker/server setup for task sync queue drain.
- [ ] Implement task worker fetch of current task branch HEAD and upsert of task rows/activity rows in a transaction.
- [ ] Clear pending task-sync jobs before full reconciliation.
- [ ] Document webhook URL, `GITHUB_WEBHOOK_SECRET`, and `REDIS_URL` requirements.
- [ ] Add unit tests for signature verification, branch routing, changed-path extraction, enqueue behavior, and ignored branches.
- [ ] Add worker tests for success, retryable failure, and dead/retry visibility where practical.
- [ ] Verify `go test ./...` passes for the adapter-service packages.
