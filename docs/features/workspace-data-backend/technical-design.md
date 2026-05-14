# Technical Design

## Feature

- Feature ID: `workspace-data-backend`
- Title: `Workspace Data Backend — GitHub Sync and Read API`

## 1. Current State

`workflow-backend` is a NestJS TypeScript service that exists today but has no workspace data layer. There is no database schema for storing workspace snapshots, no GitHub parsing logic, and no workspace read API. The dashboard calls `api.github.com` directly from the browser and keeps the active workspace in `localStorage`.

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
- `workflow-backend` uses PostgreSQL via Prisma. Database naming uses lowercase `snake_case`.

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

```text
WRITE PATH (import / sync):
  GitHub repository
    → GitHubWorkspaceAdapter   (fetch + parse → WorkspaceSnapshot)
      → WorkspaceService       (orchestrate + stale-fallback logic)
        → DbWorkspaceAdapter   (persist snapshot to PostgreSQL)

READ PATH (all UI reads):
  API routes
    → WorkspaceService
      → DbWorkspaceAdapter     (read from PostgreSQL)
        → SourceState attached (stale flag, last synced time, error)
          → UI (workspace-tabs-data-flow)
```

On import: `GitHubWorkspaceAdapter` fetches and parses the repo → `WorkspaceService` calls `DbWorkspaceAdapter.saveSnapshot` → API route returns the result.

On read: `WorkspaceService` calls `DbWorkspaceAdapter` → attaches `SourceState` → returns to API route.

On sync: same write path as import; on success snapshot is updated; on failure `WorkspaceService` returns the existing active snapshot with `SourceState.stale = true`.

The database schema is defined in `database/schema.dbml` (repo root) and versioned under `database/v<NNN>/`. See `docs/overview.md` § Database Schema for the versioning rules.

### Backend Technology Stack

- Language: Go.
- HTTP framework: `gin` (`github.com/gin-gonic/gin`).
- Database driver: `pgx/v5` (`github.com/jackc/pgx/v5`) — direct PostgreSQL driver, no ORM.
- Query layer: `sqlc` (`github.com/sqlc-dev/sqlc`) — generates type-safe Go from SQL queries; SQL is the source of truth for queries, not a Go ORM.
- Migrations: `golang-migrate` (`github.com/golang-migrate/migrate/v4`) — SQL migration files, up/down.
- Database naming: all physical table, column, index, and constraint names use lowercase `snake_case`. Go structs use PascalCase; `sqlc` handles the mapping.
- YAML parsing: `gopkg.in/yaml.v3`.
- Tests: standard `testing` package; `testcontainers-go` for PostgreSQL integration tests.
- Connection config: `DATABASE_URL` for runtime (`pgx` DSN); migrations use the same DSN or a direct URL when the host uses a connection pooler.

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
- `FeatureDetail`: summary, product spec markdown, technical design markdown, tasks, logs, source state.
- `TaskSummary`: task id, feature id, title, status, repo, branch, next action, blocked state.
- `TaskDetail`: summary, dependencies, execution context, PR refs, blocked context, activity log.
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
- Read cached workspace, feature, and task detail by ID.
- Write or replace a workspace snapshot after a successful import or sync (inside a transaction where the database supports it).
- Update `workspaces.active_snapshot_id` only after the new snapshot is fully written.
- Return stale cached data when a sync fails and an active snapshot exists.
- Never expose stored credentials or `local_path` values to UI DTOs.

### Database Schema

All physical names use lowercase `snake_case`. Prisma model names use PascalCase.

#### `workspaces`

One row per saved workspace.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | Stable workspace id used in API routes. |
| `slug` | text unique | yes | Human-readable key derived from repo or workspace name. |
| `name` | text | yes | Display name from `workspace.yaml`. |
| `repo_url` | text | yes | GitHub repository URL. |
| `repo_owner` | text | yes | Parsed GitHub owner/org. |
| `repo_name` | text | yes | Parsed GitHub repo name. |
| `default_branch` | text | no | Branch used for sync. |
| `workspace_config` | jsonb | no | Parsed `workspace.yaml` content. |
| `active_snapshot_id` | uuid FK | no | Points to the current visible snapshot. |
| `source_state` | jsonb | yes | Stale flag, partial flag, last synced time, error summary. |
| `created_at` | timestamptz | yes | |
| `updated_at` | timestamptz | yes | |

Indexes: unique `slug`; unique `(repo_owner, repo_name)`; index `updated_at`; index `active_snapshot_id`.

#### `workspace_snapshots`

One row per import or sync result. Immutable after creation.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | Parent workspace. |
| `source_kind` | text | yes | `github` or `database`. |
| `source_ref` | text | yes | Branch or ref used. |
| `commit_sha` | text | no | Git commit SHA when known. |
| `status` | text | yes | `fresh`, `partial`, `stale`, or `failed`. |
| `started_at` | timestamptz | yes | |
| `completed_at` | timestamptz | no | |
| `error_code` | text | no | Machine-readable failure code. |
| `error_message` | text | no | User-readable error summary. |
| `metadata` | jsonb | no | Counts, parser warnings, skipped files. |
| `created_at` | timestamptz | yes | |

Indexes: `(workspace_id, created_at)`; `(workspace_id, status)`; `(workspace_id, commit_sha)`.

#### `workspace_features`

One row per feature per snapshot.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | |
| `snapshot_id` | uuid FK | yes | |
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

Indexes: unique `(snapshot_id, feature_id)`; `(workspace_id, feature_id)`; `(workspace_id, feature_status)`; `(workspace_id, current_stage)`.

#### `workspace_feature_documents`

One row per feature document per snapshot.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | |
| `snapshot_id` | uuid FK | yes | |
| `feature_id` | text | yes | |
| `document_type` | text | yes | `product_spec`, `technical_design`, `tasks_md`, or `status_yaml`. |
| `source_path` | text | yes | |
| `content` | text | no | Raw file content. |
| `content_hash` | text | no | |
| `created_at` | timestamptz | yes | |

Indexes: unique `(snapshot_id, feature_id, document_type)`; `(workspace_id, feature_id)`.

#### `workspace_tasks`

One row per task YAML per snapshot.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | |
| `snapshot_id` | uuid FK | yes | |
| `feature_id` | text | yes | |
| `task_id` | text | yes | e.g. `T1`. |
| `title` | text | yes | |
| `repo` | text | no | Implementation repo id. |
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

Indexes: unique `(snapshot_id, feature_id, task_id)`; `(workspace_id, feature_id)`; `(workspace_id, status)`; `(workspace_id, repo)`.

#### `workspace_activity_events`

Derived timeline rows from feature `history[]` and task `log[]`. Lets the UI fetch timelines without scanning JSON arrays.

| Column | Type | Req | Notes |
|---|---|---|---|
| `id` | uuid PK | yes | |
| `workspace_id` | uuid FK | yes | |
| `snapshot_id` | uuid FK | yes | |
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

#### Snapshot write rules

- Import and sync write all related snapshot rows inside one transaction.
- `workspaces.active_snapshot_id` is updated only after the snapshot is complete.
- A failed sync writes a `workspace_sync_runs` diagnostic row but must not replace `active_snapshot_id`.
- If sync fails and `active_snapshot_id` is set, the service returns that snapshot with `SourceState.stale = true`.
- Credentials and expanded local paths are never written to UI-facing tables.

### Workspace Source Service

Orchestration logic:

- `listWorkspaces` → reads from `DbWorkspaceAdapter`.
- `importWorkspace(input)` → calls `GitHubWorkspaceAdapter`, writes snapshot via `DbWorkspaceAdapter`, returns `WorkspaceDetail`.
- `getWorkspace(id)` → reads active snapshot from `DbWorkspaceAdapter`.
- `syncWorkspace(id)` → calls `GitHubWorkspaceAdapter`, updates snapshot on success; on failure returns cached snapshot with `stale: true`.
- If no cached snapshot exists on failure → returns structured `SourceError`.

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

- T1 (adapter contract + DTOs) must be finalised before T2 and T3 can produce conformant output.
- T2 (GitHub adapter) and T3 (schema + database adapter) are both inputs to T4 (source service + API routes). T4 cannot be completed until both T2 and T3 are done.
- T5 (integration tests) requires T4 routes and a real PostgreSQL instance.

### External dependencies

- `workflow-backend` repo must have a working NestJS + Prisma setup. If the existing project does not yet have Prisma wired up, T3 must add it as part of the schema task.
- PostgreSQL must be accessible from the `workflow-backend` runtime. `DATABASE_URL` must be set in environment config before T3 migrations can run.
- GitHub API access (token or unauthenticated for public repos) is needed for T2 integration testing.

### Blocking decisions

- **GitHub fetch strategy**: Contents API (file-by-file) vs repository archive download (zip/tarball). The archive approach is faster for initial import; Contents API is easier to make incremental. This must be decided in T2.
- **Credential storage**: PAT provided on import — is it stored server-side for reuse in sync, or re-provided by the UI on each sync? Storing it requires an encryption strategy. Must be resolved before T2 is complete.

### Configuration dependencies

- `DATABASE_URL` — PostgreSQL connection string for Prisma runtime queries.
- `DIRECT_DATABASE_URL` — direct connection for Prisma migrations (needed when host uses a connection pooler).
- GitHub API token handling (to be determined in T2).

### Release dependencies

- PostgreSQL database must be provisioned and `DATABASE_URL` set before T3 migrations can be run.
- `workspace-tabs-data-flow` frontend tasks are blocked on T4 routes being deployed and reachable.

## 6. Parallelization / Blocking Analysis

```
T1: Source adapter contract + canonical DTOs  [workflow-backend]
  └── Can begin now — no blockers

T2: GitHub workspace adapter + parser          [workflow-backend]
T3: PostgreSQL schema (Prisma) + DB adapter   [workflow-backend]
  └── T2 and T3 run in parallel
  └── Both BLOCKED on T1 (DTO shapes must be frozen before adapters produce output)

  T4: Workspace source service + API routes   [workflow-backend]
    └── BLOCKED on T2 (GitHub adapter must produce conformant DTOs)
    └── BLOCKED on T3 (DB adapter must be able to read/write snapshots)

    T5: Backend integration tests             [workflow-backend]
      └── BLOCKED on T4 (routes must exist and be reachable)
      └── BLOCKED on T3 (requires live PostgreSQL with migrated schema)
```

All tasks target `workflow-backend`. No cross-repo parallelization within this feature.

`workspace-tabs-data-flow` T1 (frontend API client) can begin against T1/T4 draft contract from this feature; full integration is blocked on T4 being deployed.

## 7. Repository Impact

| Repo | Changes |
|---|---|
| `workflow-backend` | New NestJS modules: workspace adapter contract, GitHub adapter, database adapter, source service, API controllers, Prisma schema migrations, integration tests. |
| `management-repo` | Planning artifacts only (`docs/features/workspace-data-backend/`). No runtime changes. |

Unaffected repos: `digital-factory-ui` (consumer, updated in `workspace-tabs-data-flow`), `workflow`, `rag-service`, `git-nexus`.

## 8. Validation and Release Impact

### Testing expectations

- **Unit tests**: GitHub adapter parsing (valid YAML, missing files, invalid YAML, rate-limit response), database adapter CRUD, source service fallback logic (sync failure + stale cache path, sync failure + no cache path).
- **Integration tests**: full import flow (real or mocked GitHub → PostgreSQL write → read back via API), sync success flow, sync failure with stale fallback, workspace list and detail routes, feature and task detail routes.
- **Schema tests**: Prisma migrations apply cleanly on a fresh database; existing data survives a re-migration if run incrementally.

### Migration / config impact

- Prisma migrations must be run before the service starts for the first time.
- `DATABASE_URL` and (where needed) `DIRECT_DATABASE_URL` must be present in the environment.
- No existing data migration required — this is a greenfield schema.

### Rollout concerns

- The backend routes from this feature are the prerequisite for `workspace-tabs-data-flow` frontend work. Coordinate deployment timing with that feature.
- GitHub credential handling strategy must be confirmed before T2 ships to avoid a second breaking schema change.

### Backward compatibility

- No existing routes are affected. This feature adds new routes; it does not modify existing ones.
- `digital-factory-ui` still calls GitHub directly until `workspace-tabs-data-flow` switches it to these routes. Both paths can coexist during the transition.
