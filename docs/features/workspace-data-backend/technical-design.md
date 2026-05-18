# Technical Design

## Feature

- Feature ID: `workspace-data-backend`
- Title: `Workspace Data Backend — GitHub Sync and Read API`

## 1. Current State

There is no dedicated workspace data service today. `workflow-backend` exists but has no workspace data layer — no database schema for storing workspace snapshots, no GitHub parsing logic, and no workspace read API. The dashboard calls `api.github.com` directly from the browser and keeps the active workspace in `localStorage`.

```text
Today:

  digital-factory-ui (browser)
    → api.github.com   (direct GitHub API calls)
    → localStorage     (single ephemeral workspace)
```

There is no server-side persistence. Workspaces do not survive browser session resets and are unavailable across devices.

Key constraints:
- `workspace-github-adapter` is the new dedicated adapter service — the write-side implementation lands here. It owns GitHub ingestion, webhook handling, sync orchestration, the task queue drain, the database schema, and write-side DB access.
- `workflow-backend` is the read-side API service — the HTTP routes and read service for the UI land here. It reads from the shared PostgreSQL database and issues RPC calls to `workspace-github-adapter` for import and sync triggers.
- `digital-factory-ui` is the UI consumer — it currently calls GitHub directly but will be updated in `workspace-tabs-data-flow` to call `workflow-backend` instead.
- GitHub still owns all task state writes. This feature introduces read-only mirroring only.
- This feature standardizes the workspace data backend on Go, PostgreSQL, `pgx`, `sqlc`, and `goose`. Database naming uses lowercase `snake_case`.

## 2. Problem Framing

Two things must be built:

1. **Source ingestion**: fetch a GitHub management repository on import or resync, parse its workspace YAML and feature documents, and persist a normalised snapshot in PostgreSQL.
2. **Read API**: serve workspace list, workspace detail, feature detail, task detail, source documents, and activity from the database through stable REST routes that the UI (`workspace-tabs-data-flow`) consumes.

The UI always reads from the backend API. It does not need to know whether the underlying data came from a fresh GitHub fetch or a cached snapshot — that distinction belongs to the backend's stale-state markers, not to the API contract shape.

What must remain stable:
- Existing task YAML ownership, agent claim protocol, and workflow lifecycle are unchanged.
- No write path to task state. The database layer stores read-only mirrors.
- GitHub is used for import and resync only — all UI reads come from the database.

## 3. Options Considered

### Option A — Proxy-on-demand (no persistence)

Backend forwards every UI request to GitHub and returns normalised DTOs. Nothing is stored.

Pros:
- Always fresh data.
- No schema or migration work.

Cons:
- No cross-session persistence. Workspace is gone when the session ends.
- GitHub failure == blank board. No stale fallback.
- Rate limit exposure: every UI read hits the GitHub API.
- Slower than a local database read.

Not chosen.

### Option B — Import-and-cache (PostgreSQL snapshot)

Backend ingests the GitHub repository once on import, stores a normalised snapshot in PostgreSQL, and serves all reads from the database. A sync operation re-fetches from GitHub and updates the snapshot. If sync fails, the last successful snapshot is returned with a stale marker.

Pros:
- Cross-session and cross-device persistence.
- GitHub failure is non-fatal after first import.
- UI reads are fast local database queries.
- Rate-limit exposure is bounded to import/sync operations.
- Snapshot versioning enables stale fallback and diff-based refresh.

Cons:
- Data can be stale between syncs.
- Requires schema design and migration.
- Requires GitHub parsing logic in the backend.

Chosen.

## 4. Chosen Design

### Architecture

Two backend services share one PostgreSQL database. They have separate responsibilities and can be deployed independently.

```text
┌─────────────────────────────────────────────────────────┐
│  adapter-service  (write side — not internet-facing)    │
│                                                         │
│  GitHub webhook ──→ WebhookHandler                      │
│                       ├─ base branch  → full reconcile  │
│                       ├─ feature branch → targeted sync │
│                       └─ task branch  → enqueue         │
│                                                         │
│  SyncWorker (per workspace) ──→ drains queue            │
│    └─ fetches HEAD of task branch → upserts core tables │
│                                                         │
│  SyncService ──→ full reconciliation                    │
│    └─ triggered by: import RPC, manual RPC, webhook     │
│                                                         │
│  Writes to: workspace_features, workspace_feature_docs, │
│             workspace_tasks, workspace_activity_events, │
│             workspace_repos                             │
│  Owns:      workspace_github_sources, workspace_sync_runs, │
│             workspace_sync_queue                           │
└─────────────────────────────────────────────────────────┘
                          │ shared PostgreSQL
┌─────────────────────────────────────────────────────────┐
│  api-service  (read side — internet-facing)             │
│                                                         │
│  GET  /api/workspaces                                   │
│  GET  /api/workspaces/:id                               │
│  GET  /api/workspaces/:id/features/:featureId           │
│  GET  /api/workspaces/:id/features/:featureId/tasks     │
│  GET  /api/workspaces/:id/tasks/:taskId                 │
│  GET  /api/workspaces/:id/activity                      │
│  POST /api/workspaces/import   ──→ RPC → adapter        │
│  POST /api/workspaces/:id/sync ──→ RPC → adapter        │
│                                                         │
│  Reads from: core tables only (workspaces, repos,       │
│              features, tasks, documents, activity)      │
│  Derives staleness from: workspace_sync_runs            │
└─────────────────────────────────────────────────────────┘
                          ↑ consumed by
                  digital-factory-ui
```

`import` and `sync` are triggered via the `api-service` — it validates the request and issues an RPC call to `adapter-service`. The adapter does the actual GitHub fetch and upserts. The `api-service` does not call GitHub directly.

On read: `api-service` queries core tables → derives `SourceState` from latest `workspace_sync_runs` row → returns to the UI.

On sync failure: core tables are untouched (transaction rolled back); `SourceState.stale = true` is derived from the failed `workspace_sync_runs` row — no fallback snapshot pointer needed.

The database schema is defined in `database/schema.dbml` (repo root) and versioned under `database/v<NNN>/`. See `docs/overview.md` § Database Schema for the versioning rules.

### Sync Strategy

There are two sync modes and one async queue mechanism. The trigger determines which runs.

**Full reconciliation** — reads everything from the base branch from scratch. Upserts all core tables in one transaction. Cancels any pending task queue items before running — the full read supersedes all queued partial updates.

**Targeted sync** — reads only the changed feature's artifacts. Upserts only the affected rows for that feature. Used for webhook events on feature branches.

**Task sync queue** — webhook events on task branches are enqueued rather than processed on-the-fly. A background worker drains the queue per workspace, always fetching the current HEAD of the task branch at drain time. One pending item per task is enforced — out-of-order webhook delivery is safe because the worker fetches the latest state regardless of arrival order.

#### Trigger → mode mapping

| Trigger | Branch | Mode | Scope |
|---|---|---|---|
| `import` | — | Full reconciliation | Entire workspace (first time) |
| `manual` | — | Full reconciliation | Entire workspace |
| `webhook` | `main` (base branch) | Targeted sync | Changed features only (paths from push event) |
| `webhook` | `feature/<feature-id>` | Targeted sync | Feature artifacts only |
| `webhook` | `feature/<feature-id>-T<n>` | Queue | Single task (deduped, drained async) |
| Any other branch | — | Ignored | — |

#### Branch routing for webhook events

The GitHub push event payload contains `ref` (e.g. `refs/heads/feature/workspace-data-backend-T1`). The backend extracts the branch name and matches it against these patterns in order:

```
base branch (e.g. "main")
  → Extract changed file paths from push event commits[].added/modified/removed.
  → For each unique docs/features/<feature-id>/ path found, run a targeted sync
    for that feature (same as feature branch targeted sync below).
  → Features not touched by this push are not re-read.
  → Note: feature deletions (folder removed from main) are not detected here;
    use a manual full reconciliation to clean up orphan rows.

"feature/<feature-id>"  (no task suffix)
  → Targeted sync: read docs/features/<feature-id>/status.yaml
                        docs/features/<feature-id>/product-spec.md
                        docs/features/<feature-id>/technical-design.md
                        docs/features/<feature-id>/tasks.md
    Upsert/delete workspace_features + workspace_feature_documents rows.

"feature/<feature-id>-T<n>"
  → Enqueue via asynq:
      asynq.NewTask("task:sync", TaskSyncPayload{WorkspaceID, FeatureID, TaskID},
          asynq.Queue("task-sync"),
          asynq.Unique(24*time.Hour),  // dedup: one pending item per task
          asynq.MaxRetry(3),
      )
    Return 200 immediately. Worker handles the fetch.

Any other branch
  → Ignore.
```

The feature-id and task-id are extracted from the branch name using the workspace `git.branch_pattern` from `workspace.yaml` (`feature/{feature_id}-{work_id}`).

#### Full reconciliation — step by step

1. Write `workspace_sync_runs` row: `status: running`, `mode: full_reconciliation`, `started_at: now()`.
2. Delete all pending task-sync jobs for this workspace from the asynq queue (`inspector.DeleteAllPendingTasks("task-sync")`).
3. Fetch the full repository tree at `HEAD` of the base branch from GitHub. Record `commit_sha`.
4. Discover all `docs/features/*/status.yaml` paths.
5. For each feature: read `status.yaml`, `product-spec.md`, `technical-design.md`, `tasks.md`, and all `tasks/T*.yaml` files. Parse into DTOs.
6. `BEGIN TRANSACTION`
   - Upsert `workspace_features` on `(workspace_id, feature_id)`.
   - Upsert `workspace_feature_documents` on `(workspace_id, feature_id, document_type)`.
   - Upsert `workspace_tasks` on `(workspace_id, feature_id, task_id)`.
   - Upsert `workspace_activity_events` on `(workspace_id, feature_id, task_id, sequence)`.
   - Delete rows no longer present in the fetched set (removed features, deleted tasks, etc.).
7. `COMMIT`.
8. Update `workspace_sync_runs`: `status: success`, `commit_sha`, `finished_at: now()`.

On failure:
- `ROLLBACK` — core tables are untouched; last good state is preserved.
- Update `workspace_sync_runs`: `status: failed`, `error_code`, `error_message`, `finished_at: now()`.

#### Targeted sync — step by step (feature level)

1. Write `workspace_sync_runs` row: `status: running`, `mode: targeted`, `feature_id`, `started_at: now()`.
2. Fetch feature artifacts from GitHub: `status.yaml`, `product-spec.md`, `technical-design.md`, `tasks.md`.
3. `BEGIN TRANSACTION`
   - Upsert `workspace_features` for this `feature_id`.
   - Upsert/delete `workspace_feature_documents` for this `feature_id`.
   - Upsert/delete `workspace_tasks` for this `feature_id`.
   - Upsert/delete `workspace_activity_events` for this `feature_id`.
4. `COMMIT`.
5. Update `workspace_sync_runs`: `status: success`, `finished_at: now()`.

On failure: `ROLLBACK`. Only this feature's rows are unchanged.

#### Task sync queue — enqueue and drain

The task queue is backed by `asynq` (`github.com/hibiken/asynq`) using Redis. No database table is needed.

**Task payload** — the branch is derived from workspace `branch_pattern` + `feature_id` + `task_id` at execution time; it is not stored in the payload:
```go
type TaskSyncPayload struct {
    WorkspaceID string
    FeatureID   string
    TaskID      string
}
```

**Enqueue** (webhook handler, synchronous — returns immediately):
```go
task := asynq.NewTask("task:sync", payload,
    asynq.Queue("task-sync"),
    asynq.Unique(24*time.Hour),           // dedup key = task type + payload
    asynq.MaxRetry(3),
    asynq.Backoff(asynq.DefaultBackoff),
)
client.Enqueue(task)
```

`asynq.Unique` ensures only one pending item exists per `(WorkspaceID, FeatureID, TaskID)` for 24 hours. A second webhook for the same task within that window is a no-op — the existing pending item is kept. The worker always fetches current HEAD at execution time, so no branch update is needed on dedup.

**Worker** (`adapter-service` asynq server):
1. Derive branch from `workspace.branch_pattern` + `feature_id` + `task_id`.
2. Fetch current `HEAD` of branch from GitHub. Parse task YAML into DTO.
3. `BEGIN TRANSACTION`
   - Upsert `workspace_tasks` on `(workspace_id, feature_id, task_id)`.
   - Upsert/delete `workspace_activity_events` for this task.
4. `COMMIT`.

On failure: asynq retries automatically with backoff up to `MaxRetry`. After max retries the task moves to the dead queue and is visible in `asynqmon`.

**Clear queue on full reconciliation**:
```go
inspector := asynq.NewInspector(redisOpt)
inspector.DeleteAllPendingTasks("task-sync")
```

All pending task-sync jobs are deleted before the full reconciliation transaction begins. The full read supersedes them.

#### Staleness signal

Derived at read time by `WorkspaceService` — the `workspaces` table carries no sync state:

```sql
SELECT status, finished_at
FROM workspace_sync_runs
WHERE workspace_id = $1
ORDER BY finished_at DESC NULLS LAST
LIMIT 1
```

- Last run `failed` → `stale: true` in response DTO.
- Last run `success` but `finished_at` older than a configurable threshold → `stale: true`.
- Otherwise → `stale: false`.

### Backend Technology Stack

Two Go binaries across two repos, sharing one PostgreSQL database. `adapter-service` lives in `workspace-github-adapter`; `api-service` lives in `workflow-backend`.

| | `adapter-service` | `api-service` |
|---|---|---|
| Repo | `workspace-github-adapter` | `workflow-backend` |
| Role | Write side — GitHub sync, webhook ingestion, queue drain | Read side — UI-facing REST API |
| Internet-facing | No — internal only | Yes |
| GitHub calls | Yes | No |
| DB access | Read + write (core + adapter tables) | Read only (core tables) |

Common stack:
- Language: Go.
- HTTP framework: `gin` (`github.com/gin-gonic/gin`).
- Database driver: `pgx/v5` (`github.com/jackc/pgx/v5`) — direct PostgreSQL driver, no ORM.
- Query layer: `sqlc` (`github.com/sqlc-dev/sqlc`) — generates type-safe Go from SQL queries; SQL is the source of truth for queries, not a Go ORM.
- Migrations: `goose` (`github.com/pressly/goose/v3`) — SQL migration files, up/down. Run once at deploy time, not per service.
- Database naming: all physical table, column, index, and constraint names use lowercase `snake_case`. Go structs use PascalCase; `sqlc` handles the mapping.
- Task queue: `asynq` (`github.com/hibiken/asynq`) — Redis-backed distributed task queue used by `adapter-service` for task-branch webhook events. Provides built-in deduplication, retries, and monitoring via `asynqmon`. No custom queue table needed.
- YAML parsing: `gopkg.in/yaml.v3`.
- Tests: standard `testing` package; `testcontainers-go` for PostgreSQL integration tests.
- Connection config: `DATABASE_URL` for runtime (`pgx` DSN); `REDIS_URL` for asynq; migrations use the same DSN or a direct URL when the host uses a connection pooler.
- Inter-service: `adapter-service` exposes an internal RPC (HTTP or gRPC — implementation choice in T2) for `import` and `sync` triggers from `api-service`.

### Adapter Boundaries

Two adapters with separate, non-overlapping responsibilities:

**`GitHubWorkspaceAdapter`** — ingest only (no reads):

```go
type GitHubWorkspaceAdapter interface {
    ImportWorkspace(ctx context.Context, input ImportInput) (*WorkspaceSnapshot, error)
    SyncWorkspace(ctx context.Context, workspaceID, repoURL, ref string) (*WorkspaceSnapshot, error)
}
```

This adapter fetches the GitHub repository, parses YAML and markdown, and returns a `WorkspaceSnapshot` value object. It does not read from or write to the database. The service layer owns the persistence call.

**`DbWorkspaceAdapter`** — read/write to PostgreSQL (no GitHub calls):

```go
type DbWorkspaceAdapter interface {
    ListWorkspaces(ctx context.Context) ([]WorkspaceSummary, error)
    GetWorkspace(ctx context.Context, workspaceID string) (*WorkspaceDetail, error)
    GetFeature(ctx context.Context, workspaceID, featureID string) (*FeatureDetail, error)
    GetTask(ctx context.Context, workspaceID, taskID string) (*TaskDetail, error)
    ListFeatureTasks(ctx context.Context, workspaceID, featureID string) ([]TaskSummary, error)
    ListActivity(ctx context.Context, workspaceID string, scope ActivityScope) ([]ActivityEvent, error)
    SaveSnapshot(ctx context.Context, workspaceID string, snapshot *WorkspaceSnapshot) error
    GetActiveSnapshot(ctx context.Context, workspaceID string) (*WorkspaceSnapshot, error)
}
```

The boundary requirement is that GitHub parsing does not appear in `DbWorkspaceAdapter` and database calls do not appear in `GitHubWorkspaceAdapter`.

### Canonical Backend DTOs

UI-facing contract. Names are indicative — implementation may differ as long as the information is present.

- `WorkspaceSummary`: id, name, repo URL, source state, updated time.
- `WorkspaceDetail`: summary, feature summaries, task summaries, source state.
- `FeatureSummary`: feature id, title, status, current stage, updated time, task counts.
- `FeatureDetail`: summary, document links (url per document_type), tasks, logs, source state.
- `TaskSummary`: task id, feature id, title, status, repo, branch, next action, blocked state.
- `TaskDetail`: summary, dependencies, execution context, PR refs, blocked context, activity log.
- `PullRequestRef`: label, url, status, repo.
- `ActivityEvent`: action, scope, actor, timestamp, note.
- `SourceState`: stale flag, last synced time, error code, user-facing error message.

Documents (product spec, technical design, tasks.md) are returned as GitHub URLs — the UI fetches content on demand. No inline markdown or raw YAML is returned by the API.

### GitHub Adapter

#### Fetch strategy options

Three options were considered for reading repository content from GitHub.

**Option A — Archive download (zip/tarball)**

Single `GET /repos/{owner}/{repo}/zipball/{ref}` request downloads the entire repo.

Pros: one HTTP call for full import; very fast.
Cons: downloads all repo content including source code and build files; requires zip extraction logic; cannot be used for targeted sync (fetching a single feature's files) — still needs Contents API for that path. Results in maintaining two different fetch strategies.

Not chosen.

**Option B — Contents API (file-by-file)**

`GET /repos/{owner}/{repo}/contents/{path}` fetched per file.

Pros: uniform — works for both full reconciliation and targeted sync; no extraction logic; fine-grained per-file error handling.
Cons: one HTTP round trip per file; slow for full reconciliation on large workspaces with many features.

Not chosen as the primary strategy for full reconciliation.

**Option C — Git Trees API for discovery + Contents API for fetches (chosen)**

`GET /repos/{owner}/{repo}/git/trees/{sha}?recursive=1` returns the full file tree in one call. Then `GET /repos/{owner}/{repo}/contents/{path}` fetches only the files that are needed (`status.yaml`, `product-spec.md`, `technical-design.md`, `tasks.md`, `tasks/T*.yaml`).

Pros: single call to discover all `docs/features/*/` paths; fetches only relevant files; same approach works uniformly for full reconciliation and targeted sync; no zip extraction; per-file error handling preserved.
Cons: two-phase approach (tree + per-file fetches); slightly more code than a single archive download.

Chosen. This eliminates the need for a dual strategy and keeps the code surface minimal.

#### Responsibilities

- Validate repository URL. Use `GITHUB_TOKEN` from environment for all API calls.
- Fetch full file tree via Git Trees API to discover `docs/features/*/status.yaml` paths.
- Read `workspace.yaml`, feature `status.yaml`, `product-spec.md`, `technical-design.md`, `tasks.md`, and `tasks/T*.yaml` via Contents API.
- Build GitHub web URLs for each document file to populate `workspace_feature_documents.url`.
- Parse YAML into structured objects.
- Map missing optional files to empty states, not hard failures.
- Treat inaccessible repos, invalid YAML, missing required files, rate limits, and network failures as structured `SourceError` objects.
- Return freshness metadata (commit SHA, fetch timestamp) for the sync-run record.

### Database Adapter

Responsibilities:

- List saved workspaces from PostgreSQL.
- Read current workspace, feature, and task detail by ID (core tables always reflect latest known state — no snapshot join needed).
- Upsert core tables after a successful import or sync, inside a transaction.
- On sync failure, core tables are untouched — the adapter returns whatever is currently in the tables; `WorkspaceService` attaches staleness from `workspace_sync_runs`.
- Derive `SourceState` from the latest `workspace_sync_runs` row, not from a field on `workspaces`.
- Never expose stored credentials or `local_path` values to UI DTOs.

### Database Schema

All physical names use lowercase `snake_case`. Generated Go structs use PascalCase; `sqlc` maps them from SQL query definitions and table columns.

The schema is split into two layers:

**Core** — workspace identity and current state. Adapter-agnostic. Survives adapter replacement intact.

**GitHub adapter** — GitHub connection config, sync bookkeeping, and the task sync queue. Removable as a unit when the GitHub adapter is replaced.

#### Core tables

##### `workspaces`

One row per saved workspace. Contains only identity and config — no adapter fields, no sync state.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | Stable workspace id used in API routes. |
| `slug` | text unique | yes | Human-readable key derived from workspace name. |
| `name` | text | yes | Display name from `workspace.yaml`. |
| `management_repo_id` | text | yes | `repos[].id` entry that is the management repo. |
| `branch_pattern` | text | no | `git.branch_pattern` from `workspace.yaml` — used for webhook branch routing. |
| `created_at` | timestamptz | yes | |
| `updated_at` | timestamptz | yes | |

Indexes: unique `slug`; index `updated_at`.

##### `workspace_repos`

One row per repo declared in `workspace.yaml` `repos[]`. Stable registry that tasks reference by `repo_id`.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | |
| `repo_id` | text | yes | Logical repo identifier, e.g. `workflow-backend`. Matches `repos[].id` in `workspace.yaml` and `repo:` in task YAMLs. |
| `base_branch` | text | no | Default integration branch for this repo. |
| `created_at` | timestamptz | yes | |
| `updated_at` | timestamptz | yes | |

Indexes: unique `(workspace_id, repo_id)`.

##### `workspace_features`

One row per feature. Always reflects current known state — no snapshot versioning.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | |
| `feature_id` | text | yes | Folder name, e.g. `executor-self-briefing`. |
| `title` | text | yes | |
| `feature_status` | text | no | From `status.yaml`. |
| `current_stage` | text | no | From `status.yaml`. |
| `next_action` | text | no | |
| `stages` | jsonb | no | Full parsed `stages` object. |
| `source_path` | text | yes | e.g. `docs/features/executor-self-briefing/status.yaml`. |
| `source_hash` | text | no | Hash for change detection. |
| `created_at` | timestamptz | yes | |
| `updated_at` | timestamptz | yes | |

Indexes: unique `(workspace_id, feature_id)`; index `(workspace_id, feature_status)`; index `(workspace_id, current_stage)`.

##### `workspace_feature_documents`

One row per feature document. Stores a link to the file on GitHub rather than the content itself.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | |
| `feature_id` | text | yes | |
| `document_type` | text | yes | `product_spec`, `technical_design`, `tasks_md`, or `status_yaml`. |
| `source_path` | text | yes | Relative path in repo, e.g. `docs/features/x/product-spec.md`. |
| `url` | text | no | GitHub web URL to the document file. |
| `created_at` | timestamptz | yes | |
| `updated_at` | timestamptz | yes | |

Indexes: unique `(workspace_id, feature_id, document_type)`.

##### `workspace_tasks`

One row per task YAML. Always reflects current known state.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | |
| `feature_id` | text | yes | |
| `task_id` | text | yes | e.g. `T1`. |
| `title` | text | yes | |
| `repo` | text | no | Implementation repo id. Matches `workspace_repos.repo_id`. |
| `status` | text | no | |
| `depends_on` | jsonb | yes | Array of task ids. `[]` when none. |
| `blocked_reason` | text | no | |
| `branch` | text | no | |
| `execution` | jsonb | no | |
| `pr` | jsonb | no | |
| `workspace_pr` | jsonb | no | |
| `source_path` | text | yes | |
| `source_hash` | text | no | |
| `created_at` | timestamptz | yes | |
| `updated_at` | timestamptz | yes | |

Indexes: unique `(workspace_id, feature_id, task_id)`; index `(workspace_id, feature_id)`; index `(workspace_id, status)`; index `(workspace_id, repo)`.

##### `workspace_activity_events`

Normalized activity rows sourced from feature `history[]` and task `log[]` during sync. One row per event — queryable by scope, feature, task, and time without scanning JSON arrays.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | |
| `scope_type` | text | yes | `workspace`, `feature`, or `task`. |
| `feature_id` | text | no | |
| `task_id` | text | no | |
| `action` | text | no | |
| `actor` | text | no | |
| `occurred_at` | text | no | Raw parseable timestamp. |
| `note` | text | no | |
| `sequence` | integer | yes | Position in source array. |
| `raw_event` | jsonb | yes | Full original event. |
| `created_at` | timestamptz | yes | |

Indexes: `(workspace_id, scope_type, occurred_at)`; `(workspace_id, feature_id, occurred_at)`; `(workspace_id, feature_id, task_id, occurred_at)`.

#### GitHub adapter tables

All tables below are owned by the GitHub adapter. Dropping them removes GitHub sync entirely — core tables are unaffected.

##### `workspace_github_sources`

GitHub connection config for a workspace. 1:1 with `workspaces`.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | |
| `repo_url` | text | yes | GitHub repository URL. |
| `repo_owner` | text | yes | Parsed GitHub owner/org. |
| `repo_name` | text | yes | Parsed GitHub repo name. |
| `default_branch` | text | no | Branch used for sync. Defaults to `main` when absent. |
| `created_at` | timestamptz | yes | |
| `updated_at` | timestamptz | yes | |

Indexes: unique `workspace_id`; unique `(repo_owner, repo_name)`.

##### `workspace_sync_runs`

One row per sync attempt — full or targeted. Primary source for staleness derivation and audit.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | |
| `trigger` | text | yes | `import`, `manual`, `webhook_base`, `webhook_feature`, `webhook_task_queue`. |
| `branch` | text | no | Branch that triggered the sync. Null for `import` and `manual`. |
| `feature_id` | text | no | For `webhook_feature` and `webhook_task_queue` triggers. |
| `task_id` | text | no | For `webhook_task_queue` trigger. |
| `mode` | text | yes | `full_reconciliation` or `targeted`. |
| `status` | text | yes | `running`, `success`, `partial`, `failed`, `skipped`. |
| `commit_sha` | text | no | Git commit SHA at time of full reconciliation. Null for targeted runs. |
| `changed_paths` | jsonb | no | File paths synced (targeted runs). |
| `started_at` | timestamptz | yes | |
| `finished_at` | timestamptz | no | |
| `error_code` | text | no | |
| `error_message` | text | no | |
| `metadata` | jsonb | no | Counts, warnings, skipped files. |

Indexes: `(workspace_id, started_at)`; `(workspace_id, trigger)`; `(workspace_id, status)`.

##### Task sync queue (asynq + Redis — not a DB table)

Task-level webhook events are not stored in PostgreSQL. The queue is backed by `asynq` using Redis. Payload: `{ WorkspaceID, FeatureID, TaskID }`. Dedup via `asynq.Unique(24h)` — one pending item per task at a time. Monitor via `asynqmon`. Requires `REDIS_URL` in environment.

#### Write rules

- Full reconciliation upserts all core tables in one transaction. Rollback leaves core tables with last good state.
- Targeted sync upserts only the affected feature's rows in one transaction.
- Task queue drain upserts a single task's rows in one transaction.
- Full reconciliation deletes all pending task-sync jobs from the asynq queue before its transaction begins.
- `workspaces` is written only on import (create) and explicit workspace config update — never by sync operations.
- Credentials and local paths are never written to any table.

### Workspace Source Service

Orchestration logic:

- `listWorkspaces` → reads `workspaces` + `workspace_repos` from `DbWorkspaceAdapter`.
- `importWorkspace(input)` → calls `GitHubWorkspaceAdapter`, upserts core tables via `DbWorkspaceAdapter`, returns `WorkspaceDetail`.
- `getWorkspace(id)` → reads core tables from `DbWorkspaceAdapter`; derives `SourceState` from latest `workspace_sync_runs` row.
- `syncWorkspace(id)` → full reconciliation via `GitHubWorkspaceAdapter`; upserts on success. On failure, core tables are unchanged — `SourceState.stale = true` is derived from the failed `workspace_sync_runs` row.
- If core tables are empty and sync fails on first import → returns structured `SourceError` (no cached data to fall back to).

### Backend API Routes

Representative shape (exact paths follow `workflow-backend` conventions):

```
GET  /api/workspaces
POST /api/workspaces/import
GET  /api/workspaces/:workspaceId
POST /api/workspaces/:workspaceId/sync
GET  /api/workspaces/:workspaceId/features/:featureId
GET  /api/workspaces/:workspaceId/features/:featureId/tasks
GET  /api/workspaces/:workspaceId/tasks/:taskId
GET  /api/workspaces/:workspaceId/activity
```

Error response shape:

```json
{
  "code": "GITHUB_RATE_LIMIT",
  "message": "GitHub API rate limit reached. Try again in 45 minutes.",
  "source": "github",
  "retryable": true,
  "cached_data": { ... }
}
```

Every error response must include `code` (machine-readable), `message` (user-readable), `source` (`github`, `database`, or `adapter`), and `retryable`. When stale cached data is available, include it in `cached_data` so the UI can degrade gracefully.

## 5. Dependency Analysis

### Internal dependencies

- T1 is the only wave 1 task — no blockers.
- T2 and T3 are blocked on T1; they run in parallel with each other once T1 is done.
- T4 is blocked on both T2 and T3.
- T3 owns activity normalization: it must upsert `workspace_activity_events` rows from feature `history[]` and task `log[]` during sync — not T2 or T4.
- T6 is blocked on T1 (adapter-service Dockerfile) and T4 (api-service Dockerfile). It covers both infra (PostgreSQL, Redis, asynqmon) and service compose entries in one task.
- T5 is blocked on T2, T3, T4, and T6. T5 and T6 run in parallel in wave 4.
- T7 is blocked on T2, T3, and T6. It implements the adapter-side webhook runtime that the original task breakdown missed: GitHub signature verification, branch routing, asynq enqueue/drain, task sync worker, and queue clearing before full reconciliation.

### External dependencies

- `workspace-github-adapter` repo must have a working Go module and service entrypoint. T1 establishes the Go module, package layout, and service bootstrap for both binaries.
- PostgreSQL must be accessible from both `workspace-github-adapter` (adapter-service) and `workflow-backend` (api-service). `DATABASE_URL` must be set in both services' environment config; migrations are run from `workspace-github-adapter` before either service starts.
- GitHub API access (token or unauthenticated for public repos) is needed for T2 integration testing.

### Blocking decisions

- **GitHub fetch strategy**: Resolved — Git Trees API for discovery + Contents API for individual file fetches. See GitHub Adapter § Fetch strategy options.
- **GitHub token**: Resolved — `GITHUB_TOKEN` environment variable on `adapter-service`. No per-workspace credential storage, no UI re-prompt.

### Configuration dependencies

- `DATABASE_URL` — PostgreSQL connection string for runtime `pgx` queries and `goose` migrations.
- `REDIS_URL` — Redis connection string for asynq task queue enqueueing, worker drain, and queue inspection.
- Optional direct migration URL — only needed if the deployment database uses a pooler that is incompatible with migrations. The exact env var name should follow `workspace-github-adapter` repo conventions (migrations live there).
- `GITHUB_TOKEN` — GitHub API token for `adapter-service`. Required on `adapter-service` only; `api-service` makes no GitHub calls.
- `GITHUB_WEBHOOK_SECRET` — shared secret used by `adapter-service` to verify GitHub webhook signatures before accepting push payloads.

### Release dependencies

- PostgreSQL database must be provisioned and `DATABASE_URL` set before T3 migrations can be run.
- `workspace-tabs-data-flow` frontend tasks are blocked on T4 routes being deployed and reachable.

## 6. Parallelization / Blocking Analysis

```
D2: GitHub token policy — resolved: GITHUB_TOKEN env var on adapter-service

── Wave 1 ───────────────────────────────────────────────────────────────────────
T1: Source adapter contract + canonical DTOs    [workspace-github-adapter]
  └── Can begin now — no blockers

── Wave 2 — parallel, both blocked on T1 ────────────────────────────────────────
T2: GitHub workspace adapter + parser           [workspace-github-adapter]
  └── BLOCKED on T1 (DTOs and source error contract must be frozen)
  └── Fetch strategy resolved: Git Trees API + Contents API

T3: PostgreSQL schema (goose/sqlc) + DB adapter [workspace-github-adapter]
  └── BLOCKED on T1 (table rows must map to frozen canonical DTOs)

── Wave 3 ───────────────────────────────────────────────────────────────────────
T4: Workspace source service + API routes       [workflow-backend]
  └── BLOCKED on T2 (GitHub adapter must produce conformant DTOs)
  └── BLOCKED on T3 (DB adapter must be able to upsert core tables and write sync-run audit rows)

── Wave 4 — parallel ────────────────────────────────────────────────────────────
T5: Backend integration tests                   [workflow-backend]
  └── BLOCKED on T2 (GitHub fixture data needed for import/sync tests)
  └── BLOCKED on T3 (requires live PostgreSQL with migrated schema)
  └── BLOCKED on T4 (routes must exist)
  └── BLOCKED on T6 (infra + compose entries must exist)

T6: Docker Compose — local infra + service entries [workflow]
  └── BLOCKED on T1 (adapter-service Dockerfile must exist)
  └── BLOCKED on T4 (api-service Dockerfile must exist)

── Wave 5 — correction / follow-up ─────────────────────────────────────────────
T7: GitHub webhook handler + task sync queue [workspace-github-adapter]
  └── BLOCKED on T2 (GitHub fetch/parser must support targeted reads)
  └── BLOCKED on T3 (DB adapter must support feature/task upserts and sync-run audit)
  └── BLOCKED on T6 (Redis/asynq infra and adapter-service compose config must exist)
```

T1 is the only wave 1 task. T2 and T3 run in parallel in wave 2. T4 is wave 3. T5 and T6 run in parallel in wave 4 — T6 depends on T1 and T4; T5 depends on T2, T3, T4, and T6. T7 is a corrective follow-up task for the webhook runtime and can begin after the amended task breakdown is reviewed and approved; its implementation dependencies are T2, T3, and T6.

`workspace-tabs-data-flow` frontend work can begin against the T1/T4 draft API contract; full integration requires T4 deployed and reachable.

## 7. Repository Impact

| Repo | Changes |
|---|---|
| `workspace-github-adapter` | New Go service repo. `adapter-service` binary: GitHub webhook handler, sync worker, full reconciliation, targeted sync, asynq queue drain. `goose` SQL migrations for all core and adapter tables. `sqlc` query definitions for write operations. Adapter interfaces and canonical DTOs (T1). |
| `workflow-backend` | `api-service` binary: HTTP routes for workspace list/detail, feature, task, activity, import, and sync. Read-side `sqlc` query definitions. Source service orchestration — reads from DB, triggers RPC calls to `adapter-service` for import/sync. Integration tests. |
| `management-repo` | Planning artifacts only (`docs/features/workspace-data-backend/`). No runtime changes. |

Unaffected repos: `digital-factory-ui` (consumer, updated in `workspace-tabs-data-flow`), `workflow`, `rag-service`, `git-nexus`.

## 8. Validation and Release Impact

### Testing expectations

- **Unit tests**: GitHub adapter parsing (valid YAML, missing files, invalid YAML, rate-limit response), database adapter CRUD, source service fallback logic (sync failure + stale cache path, sync failure + no cache path).
- **Integration tests**: full import flow (real or mocked GitHub → PostgreSQL write → read back via API), sync success flow, sync failure with stale fallback, workspace list and detail routes, feature and task detail routes.
- **Schema tests**: `goose` migrations apply cleanly on a fresh database; existing data survives a re-migration if run incrementally; `sqlc` generated queries compile against the schema.

### Migration / config impact

- `goose` migrations must be run before the service starts for the first time.
- `DATABASE_URL` and any deployment-specific direct migration URL must be present in the environment when migrations run.
- No existing data migration required — this is a greenfield schema.

### Rollout concerns

- The backend routes from this feature are the prerequisite for `workspace-tabs-data-flow` frontend work. Coordinate deployment timing with that feature.
- `GITHUB_TOKEN` must be set in `adapter-service` environment before T2 integration tests can run against real GitHub.

### Backward compatibility

- No existing routes are affected. This feature adds new routes; it does not modify existing ones.
- `digital-factory-ui` still calls GitHub directly until `workspace-tabs-data-flow` switches it to these routes. Both paths can coexist during the transition.
