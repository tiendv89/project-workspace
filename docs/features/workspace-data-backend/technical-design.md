# Technical Design

## Feature

- Feature ID: `workspace-data-backend`
- Title: `Workspace Data Backend — GitHub Sync and Read API`

## 1. Current State

`workflow-backend` is the backend implementation target, but it has no workspace data layer today. There is no database schema for storing workspace snapshots, no GitHub parsing logic, and no workspace read API. The dashboard calls `api.github.com` directly from the browser and keeps the active workspace in `localStorage`.

```text
Today:

  digital-factory-ui (browser)
    → api.github.com   (direct GitHub API calls)
    → localStorage     (single ephemeral workspace)
```

There is no server-side persistence. Workspaces do not survive browser session resets and are unavailable across devices.

Key constraints:
- `workflow-backend` is the backend service — all implementation work lands there.
- `digital-factory-ui` is the UI consumer — it currently calls GitHub directly but will be updated in `workspace-tabs-data-flow` to call `workflow-backend` instead.
- GitHub still owns all task state writes. This feature introduces read-only mirroring only.
- This feature standardizes the workspace data backend on Go, PostgreSQL, `pgx`, `sqlc`, and `goose`. Database naming uses lowercase `snake_case`.

## 2. Problem Framing

Two things must be built:

1. **Source ingestion**: fetch a GitHub management repository on import or resync, parse its workspace YAML and feature documents, and persist a normalised snapshot in PostgreSQL.
2. **Read API**: serve workspace list, workspace detail, feature search/list, task search/list, feature detail, task detail, source documents, and activity from the database through stable REST routes that the UI (`workspace-tabs-data-flow`) consumes.

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

Chosen for the persistence model.

### Option C — Single backend service

One Go service exposes UI routes, performs GitHub import/sync, handles webhooks, drains the task queue, and writes PostgreSQL rows.

Pros:
- Smallest deployment topology.
- No inter-service RPC contract.
- Easier local bootstrap for the first implementation pass.

Cons:
- Public UI API, GitHub credentials, webhook handling, and queue workers all share one runtime boundary.
- Harder to restrict the internet-facing process to read-oriented operations.
- Scaling read traffic and sync/queue work independently is not possible.

Not chosen.

### Option D — Split API service and adapter service

Two Go binaries share one PostgreSQL database. `api-service` is internet-facing and serves UI routes. `adapter-service` is internal and owns GitHub fetches, webhook routing, sync orchestration, and Redis/asynq task-branch queueing.

Pros:
- Keeps GitHub write-side sync and queue work out of the public API process.
- Lets UI read traffic and sync/worker load scale independently.
- Matches the DBML split between adapter-agnostic core tables and GitHub-adapter bookkeeping.
- Gives a clean future replacement point for the GitHub adapter.

Cons:
- Requires an internal RPC contract and service-to-service configuration.
- Requires deployment of two binaries plus Redis for task-branch queueing.

Chosen for the service topology.

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
│  SyncWorker ──→ drains Redis/asynq queue                │
│    └─ fetches HEAD of task branch → upserts core tables │
│                                                         │
│  SyncService ──→ full reconciliation                    │
│    └─ triggered by: import RPC, manual RPC, webhook     │
│                                                         │
│  Writes to: workspace_features, workspace_feature_docs, │
│             workspace_tasks, workspace_activity_events, │
│             workspace_repos                             │
│  Owns:      workspace_github_sources,                   │
│             workspace_snapshots, workspace_sync_runs    │
│  Uses:      Redis/asynq task-sync queue                 │
└─────────────────────────────────────────────────────────┘
                          │ shared PostgreSQL
┌─────────────────────────────────────────────────────────┐
│  api-service  (read side — internet-facing)             │
│                                                         │
│  GET  /api/workspaces                                   │
│  GET  /api/workspaces/:id                               │
│  GET  /api/workspaces/:id/features                      │
│  GET  /api/workspaces/:id/tasks                         │
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
| `webhook` | `main` (base branch) | Full reconciliation | Entire workspace — a merge landed |
| `webhook` | `feature/<feature-id>` | Targeted sync | Feature artifacts only |
| `webhook` | `feature/<feature-id>-T<n>` | Queue | Single task (deduped, drained async) |
| Any other branch | — | Ignored | — |

#### Branch routing for webhook events

The GitHub push event payload contains `ref` (e.g. `refs/heads/feature/workspace-data-backend-T1`). The backend extracts the branch name and matches it against these patterns in order:

```
base branch (e.g. "main")
  → Apply the queue supersession policy for this workspace
  → Full reconciliation of the entire workspace

"feature/<feature-id>"  (no task suffix)
  → Targeted sync: read docs/features/<feature-id>/status.yaml
                        docs/features/<feature-id>/product-spec.md
                        docs/features/<feature-id>/technical-design.md
                        docs/features/<feature-id>/tasks.md
    Upsert/delete workspace_features + workspace_feature_documents rows.

"feature/<feature-id>-T<n>"
  → Enqueue:
      asynq task type: "task:sync"
      payload: { WorkspaceID, FeatureID, TaskID }
      queue: "task-sync"
      dedup: asynq.Unique(24h)
    Return 200 immediately. Worker handles the fetch.

Any other branch
  → Ignore.
```

The feature-id and task-id are extracted from the branch name using the workspace `git.branch_pattern` from `workspace.yaml` (`feature/{feature_id}-{work_id}`).

#### Full reconciliation — step by step

1. Write `workspace_sync_runs` row: `status: running`, `mode: full_reconciliation`, `started_at: now()`.
2. Apply the queue supersession policy before the full read begins. The implementation must either clear only this workspace's pending task-sync jobs or make older queued task jobs skip themselves after a newer full reconciliation. It must not delete unrelated workspace jobs from a shared queue.
3. Fetch the full repository tree at `HEAD` of the base branch from GitHub. Record `commit_sha`.
4. Discover all `docs/features/*/status.yaml` paths.
5. For each feature: read `status.yaml`, `product-spec.md`, `technical-design.md`, `tasks.md`, and all `tasks/T*.yaml` files. Parse into DTOs.
6. `BEGIN TRANSACTION`
   - Upsert `workspace_repos` on `(workspace_id, repo_id)`.
   - Upsert `workspace_features` on `(workspace_id, feature_id)`.
   - Upsert `workspace_feature_documents` on `(workspace_id, feature_id, document_type)`.
   - Upsert `workspace_tasks` on `(workspace_id, feature_id, task_id)`.
   - Upsert `workspace_activity_events` on `(workspace_id, feature_id, task_id, sequence)`.
   - Delete rows no longer present in the fetched set (removed features, deleted tasks, etc.).
7. `COMMIT`.
8. Write `workspace_snapshots` row: `commit_sha`, `status: success`, `created_at: now()`.
9. Update `workspace_sync_runs`: `status: success`, `snapshot_id`, `finished_at: now()`. The `commit_sha` is stored on `workspace_snapshots`, not on `workspace_sync_runs`.

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

**Supersede queue on full reconciliation**:

The full read supersedes pending task-level partial updates for the same workspace. T4 chooses the concrete implementation:

- Workspace-scoped queue clearing, if queue names can safely be scoped by workspace.
- Stale-job skipping, if one shared `task-sync` queue is used.

Do not call a global queue clear that can delete another workspace's pending jobs.

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

Two Go binaries in `workflow-backend`, sharing one PostgreSQL database and one `sqlc`-generated query package.

| | `adapter-service` | `api-service` |
|---|---|---|
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
- Inter-service: `adapter-service` exposes an internal RPC (HTTP or gRPC — implementation choice in T1) for `import` and `sync` triggers from `api-service`.

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
    SearchFeatures(ctx context.Context, workspaceID string, filter WorkspaceSearchFilter) ([]FeatureSummary, error)
    SearchTasks(ctx context.Context, workspaceID string, filter WorkspaceSearchFilter) ([]TaskSummary, error)
    GetFeature(ctx context.Context, workspaceID, featureID string) (*FeatureDetail, error)
    GetTask(ctx context.Context, workspaceID, taskID string) (*TaskDetail, error)
    ListFeatureTasks(ctx context.Context, workspaceID, featureID string) ([]TaskSummary, error)
    ListActivity(ctx context.Context, workspaceID string, scope ActivityScope) ([]ActivityEvent, error)
    SaveFullReconciliation(ctx context.Context, workspaceID string, snapshot *WorkspaceSnapshot, runID string) (*SnapshotRecord, error)
    SaveTargetedFeatureSync(ctx context.Context, workspaceID string, feature *FeatureSnapshot, changedPaths []string) error
    SaveTaskSync(ctx context.Context, workspaceID string, task *TaskSnapshot) error
    GetLatestSyncRun(ctx context.Context, workspaceID string) (*SyncRun, error)
}
```

The boundary requirement is that GitHub parsing does not appear in `DbWorkspaceAdapter` and database calls do not appear in `GitHubWorkspaceAdapter`.

### Canonical Backend DTOs

UI-facing contract. Names are indicative — implementation may differ as long as the information is present.

- `WorkspaceSummary`: id, name, repo URL, source state, updated time.
- `WorkspaceDetail`: summary, feature summaries, task summaries, source state.
- `FeatureSummary`: feature id, title, status, current stage, updated time, task counts.
- `FeatureDetail`: summary, product spec markdown, technical design markdown, tasks, logs, source state.
- `TaskSummary`: task id, feature id, title, status, repo, branch, next action, blocked state.
- `TaskDetail`: summary, dependencies, execution context, PR refs, blocked context, activity log.
- `WorkspaceSearchFilter`: optional query text, status list, date-time range, pagination, and sort. Feature search applies it to feature name/title/status/updated time; task search applies it to task name/title/status/updated time.
- `PullRequestRef`: label, url, status, repo.
- `ActivityEvent`: action, scope, actor, timestamp, note.
- `SourceState`: source kind, stale flag, partial flag, last synced time, error code, user-facing error message.

No raw YAML, no raw markdown, and no database row shapes are exposed to the UI.

### GitHub Adapter

Responsibilities:

- Validate repository URL and access token.
- Fetch repository content (GitHub Contents API or archive download — implementation choice).
- Discover `docs/features/*/status.yaml` files.
- Read feature-level `product-spec.md`, `technical-design.md`, `tasks.md`, and `tasks/T*.yaml` for each feature found.
- Parse YAML into structured objects; preserve raw markdown strings for document views.
- Map missing optional files to empty states, not hard failures.
- Treat inaccessible repos, invalid YAML, missing required files, rate limits, and network failures as structured `SourceError` objects.
- Return freshness metadata (commit SHA, fetch timestamp) for the snapshot record.

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

**GitHub adapter** — GitHub connection config and sync bookkeeping. These PostgreSQL tables are removable as a unit when the GitHub adapter is replaced. Task-branch queueing is adapter-owned too, but it lives in Redis/asynq rather than PostgreSQL.

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

Indexes: unique `(workspace_id, repo_id)`; index `workspace_id`.

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
| `history` | jsonb | no | Full parsed `history` array. |
| `source_path` | text | yes | e.g. `docs/features/executor-self-briefing/status.yaml`. |
| `source_hash` | text | no | Hash for change detection. |
| `created_at` | timestamptz | yes | |
| `updated_at` | timestamptz | yes | |

Indexes: unique `(workspace_id, feature_id)`; index `(workspace_id, feature_status)`; index `(workspace_id, current_stage)`.

##### `workspace_feature_documents`

One row per feature document. Always reflects current known state.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | |
| `feature_id` | text | yes | |
| `document_type` | text | yes | `product_spec`, `technical_design`, `tasks_md`, or `status_yaml`. |
| `source_path` | text | yes | |
| `content` | text | no | Raw file content. |
| `content_hash` | text | no | |
| `created_at` | timestamptz | yes | |
| `updated_at` | timestamptz | yes | |

Indexes: unique `(workspace_id, feature_id, document_type)`; index `(workspace_id, feature_id)`.

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
| `log` | jsonb | no | |
| `source_path` | text | yes | |
| `source_hash` | text | no | |
| `created_at` | timestamptz | yes | |
| `updated_at` | timestamptz | yes | |

Indexes: unique `(workspace_id, feature_id, task_id)`; index `(workspace_id, feature_id)`; index `(workspace_id, status)`; index `(workspace_id, repo)`.

##### `workspace_activity_events`

Derived timeline rows from feature `history[]` and task `log[]`. Lets the UI fetch timelines without scanning JSON arrays.

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

##### `workspace_snapshots`

One row per completed full reconciliation. Adapter bookkeeping only — tracks `commit_sha` so the staleness check has a reference point. No core table references this.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | |
| `commit_sha` | text | no | Git commit SHA at time of full reconciliation. |
| `status` | text | yes | `success` or `failed`. |
| `created_at` | timestamptz | yes | |

Indexes: `(workspace_id, created_at DESC)`.

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
| `snapshot_id` | uuid FK | no | `workspace_snapshots` row written by this full reconciliation run. Null for targeted runs. |
| `changed_paths` | jsonb | no | File paths synced (targeted runs). |
| `started_at` | timestamptz | yes | |
| `finished_at` | timestamptz | no | |
| `error_code` | text | no | |
| `error_message` | text | no | |
| `metadata` | jsonb | no | Counts, warnings, skipped files. |

Indexes: `(workspace_id, started_at)`; `(workspace_id, trigger)`; `(workspace_id, status)`.

#### Task sync queue

There is no `workspace_sync_queue` PostgreSQL table. Task-level webhook events are backed by Redis/asynq:

- Queue name: `task-sync`.
- Task type: `task:sync`.
- Payload: `{ WorkspaceID, FeatureID, TaskID }`.
- Deduplication: `asynq.Unique(24h)` gives one pending item per payload key.
- Full reconciliation supersession: workspace-scoped queue clearing or stale-job skipping; never global deletion of unrelated workspace jobs.
- Monitoring: `asynqmon`.
- Runtime config: `REDIS_URL`.

#### Write rules

- Full reconciliation upserts all core tables in one transaction. Rollback leaves core tables with last good state.
- Targeted sync upserts only the affected feature's rows in one transaction.
- Task queue drain upserts a single task's rows in one transaction.
- Full reconciliation supersedes pending Redis/asynq task-sync jobs for the same workspace before its transaction begins.
- `workspaces` is written only on import (create) and explicit workspace config update — never by sync operations.
- Credentials and local paths are never written to any table.

### Workspace Source Service

Orchestration logic:

- `listWorkspaces` → reads `workspaces` + `workspace_repos` from `DbWorkspaceAdapter`.
- `importWorkspace(input)` → calls `GitHubWorkspaceAdapter`, upserts core tables via `DbWorkspaceAdapter`, returns `WorkspaceDetail`.
- `getWorkspace(id)` → reads core tables from `DbWorkspaceAdapter`; derives `SourceState` from latest `workspace_sync_runs` row.
- `searchFeatures(workspaceID, filter)` → reads `workspace_features` by feature name/title, status, and date-time range; derives `SourceState` from latest `workspace_sync_runs` row.
- `searchTasks(workspaceID, filter)` → reads `workspace_tasks` by task id/title, status, and date-time range; derives `SourceState` from latest `workspace_sync_runs` row.
- `syncWorkspace(id)` → full reconciliation via `GitHubWorkspaceAdapter`; upserts on success. On failure, core tables are unchanged — `SourceState.stale = true` is derived from the failed `workspace_sync_runs` row.
- If core tables are empty and sync fails on first import → returns structured `SourceError` (no cached data to fall back to).

### Backend API Routes

Representative shape (exact paths follow `workflow-backend` conventions):

```
GET  /api/workspaces
POST /api/workspaces/import
GET  /api/workspaces/:workspaceId
POST /api/workspaces/:workspaceId/sync
GET  /api/workspaces/:workspaceId/features?query=&status=&updated_from=&updated_to=&limit=&cursor=
GET  /api/workspaces/:workspaceId/tasks?query=&status=&updated_from=&updated_to=&limit=&cursor=
GET  /api/workspaces/:workspaceId/features/:featureId
GET  /api/workspaces/:workspaceId/features/:featureId/tasks
GET  /api/workspaces/:workspaceId/tasks/:taskId
GET  /api/workspaces/:workspaceId/activity
```

`GET /api/workspaces/:workspaceId/features` is the feature search/list route. Query behavior:

- `query`: optional text search over feature id/name/title and next action.
- `status`: optional repeated or comma-separated feature status filter.
- `updated_from`, `updated_to`: optional RFC3339 date-time range over feature `updated_at`.
- `limit` and `cursor`: optional pagination controls.

The route returns feature summaries with task counts and the same `SourceState` metadata used by workspace detail. It does not return raw markdown or raw YAML; those remain on the feature detail/source-document routes.

`GET /api/workspaces/:workspaceId/tasks` is the workspace-level task search/list route. Query behavior:

- `query`: optional text search over task id/name/title and feature id.
- `status`: optional repeated or comma-separated task status filter.
- `updated_from`, `updated_to`: optional RFC3339 date-time range over task `updated_at`.
- `limit` and `cursor`: optional pagination controls.

The route returns task summaries across all features in the workspace. Feature-scoped task listing remains available at `GET /api/workspaces/:workspaceId/features/:featureId/tasks`.

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

- T1 (service layout, adapter contract, DTOs, and internal RPC contract) must be finalised before T2 and T3 can produce conformant output.
- T2 (GitHub adapter) and T3 (schema + database adapter) are both inputs to T4 (adapter-service sync orchestration). T4 cannot be completed until both T2 and T3 are done.
- T4 (adapter-service sync orchestration, webhooks, and Redis/asynq worker) requires T2 parser output and T3 transactional persistence.
- T5 (api-service read routes) requires T3 because UI reads must come from PostgreSQL core tables.
- T6 (api-service import/sync RPC proxy and fallback behavior) requires T4's internal adapter RPC and T5's route/error conventions.
- T7 (integration tests) requires T4/T6 routes, the adapter worker path, and a real PostgreSQL instance.

### External dependencies

- `workflow-backend` repo must have a working Go module and service entrypoint. If the existing project is not yet Go-based, T1 must establish the Go module, package layout, and service bootstrap before adapter work continues.
- PostgreSQL must be accessible from the `workflow-backend` runtime. `DATABASE_URL` must be set in environment config before T3 migrations can run.
- GitHub API access (token or unauthenticated for public repos) is needed for T2 integration testing.
- Redis must be reachable through `REDIS_URL` before the adapter-service task queue can run.
- GitHub webhook delivery requires a configured webhook secret and an externally reachable adapter webhook endpoint, or a relay equivalent in non-public environments.

### Blocking decisions

- **GitHub fetch strategy**: Contents API (file-by-file) vs repository archive download (zip/tarball). The archive approach is faster for initial import; Contents API is easier to make incremental. This must be decided in T2.
- **Credential storage**: PAT provided on import — is it stored server-side for reuse in sync, or re-provided by the UI on each sync? Storing it requires an encryption strategy. Must be resolved before T2 is complete.
- **Internal RPC transport**: HTTP+JSON vs gRPC between `api-service` and `adapter-service`. This must be decided in T1 so T4 and T6 implement the same contract.
- **Task queue isolation policy**: v001 can use one Redis/asynq queue only if full reconciliation clears do not delete unrelated workspace tasks. If multiple workspaces can sync concurrently, T4 must implement workspace-scoped queues or stale-job skipping before shipping.

### Configuration dependencies

- `DATABASE_URL` — PostgreSQL connection string for runtime `pgx` queries and `goose` migrations.
- `REDIS_URL` — Redis connection string for `adapter-service` task-branch sync queueing.
- Optional direct migration URL — only needed if the deployment database uses a pooler that is incompatible with migrations. The exact env var name should follow `workflow-backend` conventions.
- GitHub API token handling (to be determined in T2).
- Internal adapter RPC base URL or service discovery config for `api-service`.
- GitHub webhook secret for adapter-service webhook validation.

### Release dependencies

- PostgreSQL database must be provisioned and `DATABASE_URL` set before T3 migrations can be run.
- `workspace-tabs-data-flow` frontend tasks are blocked on T6 routes being deployed and reachable.

## 6. Parallelization / Blocking Analysis

```
D1: Choose GitHub fetch strategy (Contents API vs archive download)
  └── Unblock before T2 hardens network behavior and before T4 runs import/sync orchestration
D2: Decide GitHub token reuse policy (store encrypted server-side vs require per sync)
  └── Unblock before T6 finalizes import/sync request semantics and fallback behavior
D3: Choose internal RPC transport between api-service and adapter-service
  └── Unblock before T1 freezes service contracts used by T4 and T6
D4: Confirm Redis/asynq task queue isolation policy
  └── Unblock before T4 ships full-reconciliation queue clearing

T1: Go backend foundation + canonical contracts [workflow-backend]
  └── Can begin now — no blockers

T2: GitHub workspace adapter + parser           [workflow-backend]
T3: PostgreSQL schema (goose/sqlc) + DB adapter [workflow-backend]
  └── T2 and T3 run in parallel
  └── BLOCKED on T1 (canonical snapshot DTOs, source errors, and RPC contracts must be frozen)
  └── T2 also resolves D1 before adapter behavior is final
  │
  T4: Adapter-service sync, webhooks, and queue worker [workflow-backend]
    └── BLOCKED on T2 (GitHub adapter must produce conformant snapshots)
    └── BLOCKED on T3 (DB adapter must write current mirror rows, sync runs, and snapshot bookkeeping)
    └── BLOCKED on D3 (adapter RPC server must match the frozen transport contract)
    └── BLOCKED on D4 (queue clear/skip behavior must not corrupt other workspace syncs)
  │
  T5: API-service workspace read routes + source state [workflow-backend]
    └── BLOCKED on T3 (read routes must query migrated PostgreSQL core tables)
    └── T4 and T5 run in parallel once their own blockers are clear
    │
    T6: API import/sync RPC proxy + stale fallback [workflow-backend]
      └── BLOCKED on T4 (adapter-service import/sync RPC must exist)
      └── BLOCKED on T5 (API route and error-response conventions must be in place)
      └── BLOCKED on D2 (token reuse policy changes request and error semantics)
      │
      T7: Backend integration tests + release validation [workflow-backend]
        └── BLOCKED on T4 (adapter-service worker/webhook paths must exist)
        └── BLOCKED on T6 (UI-facing import/sync and fallback routes must exist)
```

All tasks target `workflow-backend`. T2/T3 can run in parallel after T1. T4 and T5 can overlap once T3 is ready and T2 is complete for T4.

`workspace-tabs-data-flow` frontend integration can begin against T1/T5/T6 draft contracts from this feature; full integration is blocked on T6 being deployed and reachable.

## 7. Repository Impact

| Repo | Changes |
|---|---|
| `workflow-backend` | New Go packages and binaries for `api-service` and `adapter-service`: workspace contracts, GitHub adapter, database adapter, adapter RPC, webhook handlers, Redis/asynq worker, HTTP handlers, `goose` SQL migrations, `sqlc` query definitions, integration tests. |
| `management-repo` | Planning artifacts only (`docs/features/workspace-data-backend/`). No runtime changes. |

Unaffected repos: `digital-factory-ui` (consumer, updated in `workspace-tabs-data-flow`), `workflow`, `rag-service`, `git-nexus`.

## 8. Validation and Release Impact

### Testing expectations

- **Unit tests**: GitHub adapter parsing (valid YAML, missing files, invalid YAML, rate-limit response), database adapter CRUD, adapter RPC handler behavior, API route mapping, source-state fallback logic (sync failure + stale cache path, sync failure + no cache path).
- **Integration tests**: full import flow (real or mocked GitHub → adapter-service → PostgreSQL write → read back via api-service), webhook branch routing, task queue drain, sync success flow, sync failure with stale fallback, workspace list and detail routes, feature and task detail routes.
- **Schema tests**: `goose` migrations apply cleanly on a fresh database; existing data survives a re-migration if run incrementally; `sqlc` generated queries compile against the schema.

### Migration / config impact

- `goose` migrations must be run before the service starts for the first time.
- `DATABASE_URL`, `REDIS_URL`, adapter RPC service config, and any deployment-specific direct migration URL must be present in the environment when migrations and services run.
- No existing data migration required — this is a greenfield schema.

### Rollout concerns

- The backend routes from T5/T6 are the prerequisite for `workspace-tabs-data-flow` frontend work. Coordinate deployment timing with that feature.
- GitHub credential handling strategy must be confirmed before T2 ships to avoid a second breaking schema change.

### Backward compatibility

- No existing routes are affected. This feature adds new routes; it does not modify existing ones.
- `digital-factory-ui` still calls GitHub directly until `workspace-tabs-data-flow` switches it to these routes. Both paths can coexist during the transition.
