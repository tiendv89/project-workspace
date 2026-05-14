# Technical Design

## Feature

- Feature ID: `workspace-tabs-data-flow`
- Title: `Workspace Tabs and End-to-End Workspace Data Flow`

## 1. Current State

There is no backend layer today. The dashboard calls the GitHub API directly from the browser, parses workspace YAML files in the browser, and stores the active workspace configuration in `localStorage`. There is no server-side database, no cache, and no multi-workspace support.

```text
Current system (what exists now):

  UI (browser)
    → api.github.com (direct: Contents API, Pulls API)
      → yaml-parser.ts (browser-side YAML parse)
        → localStorage (single workspace, ephemeral)
          → board components
```

Key files that implement this today:

- `src/services/github.ts` — direct `fetch` calls to `https://api.github.com`
- `src/services/yaml-parser.ts` — browser-side YAML and markdown parsing
- `src/services/workspace-store.ts` — `localStorage` get/set/clear
- `src/features/board/data/load-board-data.ts` — board loader built on the GitHub client above

This feature replaces that direct-GitHub path. After this feature:

- The UI never calls GitHub directly.
- GitHub is used only for import and sync operations, handled entirely by the backend.
- All UI reads come from a backend-managed Supabase Postgres database.
- When a sync fails, the backend returns the last cached snapshot with a stale marker.
- Workspace configuration is stored server-side, not in `localStorage`.

The dashboard still needs workspace, task tab, and feature tab surfaces, but all source data must arrive through backend contracts. UI components should not own GitHub parsing, raw YAML parsing, database shape assumptions, agent state, model selection, or conversation behavior.

Fixed constraints:

- Workspace board remains the default workspace surface.
- Workspace dropdown opens only from the workspace tab control.
- Sidebar is visible only on the workspace board, not inside Task tab or Feature tab pages.
- Task tab and Feature tab may be route-backed pages.
- Work item data comes from normalized backend payloads.
- GitHub and database source differences are hidden behind adapters.
- Agent, chat, model, composer, and conversation controls are not part of this feature.

## 2. Problem Framing

The system must support three connected workflows:

1. Source ingestion: import or refresh workflow data from GitHub and store reusable workspace snapshots in the database.
2. Source normalization: expose a common workspace model regardless of whether the read came from GitHub or database cache.
3. UI consumption: render workspace board, task tabs, and feature tabs from backend payloads with stable loading, empty, stale, and error states.

What must remain stable:

- Existing workflow lifecycle, approval gates, task status, and task YAML ownership remain unchanged.
- The management repo only stores feature planning artifacts.
- `workflow-backend` owns source adapters, backend routes, cache reads/writes, and error mapping.
- `digital-factory-ui` owns workspace/tab UI, frontend API client, interaction behavior, and browser QA.
- Task execution still starts only after task-stage approval and task activation.

## 3. Options Considered

### Option A - Frontend reads GitHub directly

This approach keeps the dashboard responsible for fetching and parsing GitHub files.

Pros:

- Smallest backend change.
- Can reuse existing frontend parsing experiments if present.

Cons:

- Conflicts with the requested end-to-end architecture.
- Keeps GitHub, database, and YAML shape details inside UI code.
- Makes database fallback and source freshness harder to reason about.
- Keeps access-token and rate-limit handling close to the browser.

Not chosen.

### Option B - Backend source adapters with a stable UI API

This approach places GitHub and database reads behind backend adapters. The UI consumes only normalized backend DTOs.

Pros:

- Matches the requested `GitHub/DB -> adapter -> BE -> UI` flow.
- Gives source parsing and source freshness one backend boundary.
- Lets the UI stay focused on presentation and interaction.
- Supports cached workspace reopen without re-importing every time.
- Keeps future source additions behind the same adapter contract.

Cons:

- Requires backend and frontend work in the same feature.
- Requires explicit DTO mapping and source-status semantics.
- May need database schema or persistence updates depending on the current backend storage model.

Chosen.

## 4. Chosen Design

Choose Option B: backend source adapters plus a stable UI-facing API.

### Architecture

```text
GitHub repository
  -> GitHubWorkspaceAdapter
    -> WorkspaceSourceService
      -> Workspace API routes
        -> Frontend API client
          -> Workspace shell, board, task tabs, feature tabs

Database cache
  -> DbWorkspaceAdapter
    -> WorkspaceSourceService
      -> Workspace API routes
        -> Frontend API client
          -> Workspace shell, board, task tabs, feature tabs
```

Adapters are NestJS backend modules inside `workflow-backend`. They must expose clear service interfaces so GitHub parsing and database reads do not leak into controllers or frontend components.

### Backend Technology Stack

Backend implementation is standardized on:

- Runtime: Node.js-compatible TypeScript service.
- Framework: NestJS.
- API layer: NestJS controllers and DTO validation.
- Service layer: NestJS injectable services for GitHub source adapter, database adapter, and workspace source orchestration.
- Database host: Supabase Postgres.
- ORM and migration tool: Prisma Client plus Prisma Migrate.
- Database naming: lowercase `snake_case` table, column, index, and constraint names.
- Source parsing: `yaml` npm package or an equivalent YAML parser approved in implementation.
- Tests: NestJS-compatible unit/integration tests, plus Prisma migration/schema validation.

Supabase is the Postgres host, not a frontend data source. The frontend talks only to the backend API. Backend code talks to Supabase Postgres through Prisma.

Prisma model names may use PascalCase in TypeScript, but database objects must use `@@map` and `@map` where needed so the physical Supabase schema stays lowercase `snake_case`.

Connection configuration:

- `DATABASE_URL` is used by the deployed NestJS backend for runtime Prisma queries.
- `DIRECT_DATABASE_URL` is used for Prisma migrations when Supabase provides separate pooled and direct connection strings.
- Migration operations must use the direct Supabase Postgres connection, not a transaction pooler URL.
- Runtime may use Supabase's pooled connection URL when compatible with the Prisma configuration chosen during implementation.

### Source Adapter Contract

The backend should define a typed adapter boundary similar to:

```ts
type WorkspaceSourceKind = "github" | "database";

interface WorkspaceSourceAdapter {
  kind: WorkspaceSourceKind;
  listWorkspaces(): Promise<WorkspaceSummary[]>;
  getWorkspace(workspaceId: string): Promise<WorkspaceDetail>;
  getFeature(workspaceId: string, featureId: string): Promise<FeatureDetail>;
  getTask(workspaceId: string, taskId: string): Promise<TaskDetail>;
  listFeatureTasks(workspaceId: string, featureId: string): Promise<TaskSummary[]>;
  listActivity(workspaceId: string, scope: ActivityScope): Promise<ActivityEvent[]>;
}
```

GitHub import and sync can be modeled as service operations rather than generic adapter methods if the existing backend structure fits better:

```ts
importWorkspaceFromGitHub(input): Promise<WorkspaceDetail>
syncWorkspaceFromGitHub(workspaceId): Promise<WorkspaceDetail>
```

The exact function names can follow the backend codebase, but the boundary must keep source parsing outside UI and route presentation code.

### Canonical Backend DTOs

The UI-facing contract should include:

- `WorkspaceSummary`: id, name, repo URL, source state, updated time.
- `WorkspaceDetail`: summary, board columns/groups, feature summaries, task summaries, source state.
- `FeatureSummary`: feature id, title, status, current stage, updated time, task counts.
- `FeatureDetail`: summary, product spec markdown, technical design markdown, tasks, logs, source state.
- `TaskSummary`: task id, feature id, title, status, priority, repo, branch, next action, blocked state.
- `TaskDetail`: summary, dependencies, execution context, PR refs, blocked context, activity.
- `PullRequestRef`: label, url, status, repo.
- `ActivityEvent`: action, stage/scope, actor, timestamp, note.
- `SourceState`: source kind, freshness, last synced time, stale flag, partial flag, user-facing error when relevant.

DTO names do not have to be exact, but this information must be represented without frontend raw-YAML parsing.

### GitHub Adapter

GitHub adapter responsibilities:

- Validate repository URL and access input.
- Fetch or download repository content using the backend's preferred GitHub strategy.
- Discover `docs/features/*/status.yaml`.
- Read feature-level `product-spec.md`, `technical-design.md`, `tasks.md`, and `tasks/T*.yaml` where available.
- Parse YAML and markdown into backend DTOs.
- Preserve raw markdown strings for document views.
- Map missing optional files to empty states instead of hard failures.
- Treat missing required feature status, invalid YAML, inaccessible repositories, rate limits, and network failures as structured source errors.
- Return source metadata so the backend can mark freshness and partial data.

### Database Adapter

Database adapter responsibilities:

- List saved workspaces.
- Read cached workspace detail.
- Read cached feature and task detail.
- Write or update workspace snapshots after successful GitHub import or sync.
- Preserve last successful sync metadata.
- Return stale cached data when a fresh GitHub sync fails and cache exists.
- Never expose stored secrets or implementation-specific database records to the UI.

If the current backend does not yet have the required persistence table/collection, the backend task must add the schema below. Database object names use lowercase `snake_case`.

### Database Schema Design

The database must store normalized workspace state as queryable records, not only one opaque snapshot blob. Raw source documents are preserved separately so the UI can render the same feature and task information that exists in the imported workspace repository.

#### `workspaces`

One row per saved workspace.

| Column | Type | Required | Notes |
|---|---|---:|---|
| `id` | UUID/string PK | yes | Stable backend workspace id used by UI routes. |
| `slug` | text unique | yes | Human-readable workspace key, usually derived from imported repo or workspace folder name. |
| `name` | text | yes | Display name from `workspace.yaml` or import metadata. |
| `repo_url` | text | yes | Canonical GitHub repository URL used for import/sync. |
| `repo_owner` | text | yes | Parsed GitHub owner/org. |
| `repo_name` | text | yes | Parsed GitHub repo name. |
| `default_branch` | text | no | Branch used for sync when not explicitly overridden. |
| `workspace_config` | JSON | no | Parsed `workspace.yaml`, including `workspace_id`, approval, git branch pattern, environments, roles, model policy, automation, orchestrator, management repo, and repos. |
| `active_snapshot_id` | UUID/string FK | no | Points to the currently visible snapshot after a successful import or sync. |
| `source_state` | JSON | yes | Current source status shown by UI: source kind, stale flag, partial flag, last synced time, and last error summary. |
| `created_at` | timestamp | yes | Backend creation time. |
| `updated_at` | timestamp | yes | Backend update time. |

Indexes and constraints:

- Unique `slug`.
- Unique `repo_owner + repo_name` if the product allows only one saved workspace per GitHub repo.
- Index `updated_at`.
- Index `active_snapshot_id`.

#### `workspace_repositories`

One row per repository declared in `workspace.yaml -> repos[]`. This keeps current workspace repo information queryable without forcing the UI to parse `workspace_config`.

| Column | Type | Required | Notes |
|---|---|---:|---|
| `id` | UUID/string PK | yes | Repository row id. |
| `workspace_id` | FK `workspaces.id` | yes | Parent workspace. |
| `repo_id` | text | yes | Repo id from `workspace.yaml`, for example `management-repo` or `digital-factory-ui`. |
| `github` | text | no | GitHub SSH/HTTPS URL from config. |
| `local_path_ref` | text | no | Env reference or local path string from config, never expanded to secret values in UI DTOs. |
| `base_branch` | text | no | Repo base branch from config. |
| `owner_role` | text | no | Owner role from config. |
| `raw_config` | JSON | yes | Original repo object from `workspace.yaml`. |
| `created_at` | timestamp | yes | Backend creation time. |
| `updated_at` | timestamp | yes | Backend update time. |

Indexes and constraints:

- Unique `workspace_id + repo_id`.
- Index `workspace_id + owner_role`.

#### `workspace_snapshots`

One row per import/sync result. A snapshot is immutable after creation; a successful import or sync updates `workspaces.active_snapshot_id` to the new snapshot. Keeping snapshots versioned lets the backend serve stale data after a failed sync.

| Column | Type | Required | Notes |
|---|---|---:|---|
| `id` | UUID/string PK | yes | Snapshot id. |
| `workspace_id` | FK `workspaces.id` | yes | Parent workspace. |
| `source_kind` | enum/text | yes | `github` or `database`. |
| `source_ref` | text | yes | Branch/ref/tag used for this snapshot. |
| `commit_sha` | text | no | Git commit SHA when known. |
| `tree_sha` | text | no | Git tree/archive id when known. |
| `status` | enum/text | yes | `fresh`, `partial`, `stale`, or `failed`. |
| `started_at` | timestamp | yes | Sync/import start time. |
| `completed_at` | timestamp | no | Sync/import completion time. |
| `error_code` | text | no | Machine-readable failure code. |
| `error_message` | text | no | User-readable error summary. |
| `metadata` | JSON | no | Counts, parser warnings, rate-limit metadata, skipped files, and source diagnostics. |
| `created_at` | timestamp | yes | Backend creation time. |

Indexes and constraints:

- Index `workspace_id + created_at`.
- Index `workspace_id + status`.
- Index `workspace_id + commit_sha`.

#### `workspace_features`

One row per feature in a snapshot. It mirrors the current `status.yaml` feature payload while keeping status, stage, and next action queryable.

| Column | Type | Required | Notes |
|---|---|---:|---|
| `id` | UUID/string PK | yes | Feature row id. |
| `workspace_id` | FK `workspaces.id` | yes | Parent workspace. |
| `snapshot_id` | FK `workspace_snapshots.id` | yes | Snapshot this feature belongs to. |
| `feature_id` | text | yes | Feature id from `status.yaml` or folder name. |
| `title` | text | yes | Feature title from `status.yaml`. |
| `feature_status` | text | no | Value from `feature_status`. |
| `current_stage` | text | no | Value from `current_stage`. |
| `next_action` | text | no | Value from `next_action`. |
| `stages` | JSON | no | Full parsed `stages` object. |
| `history` | JSON | no | Full parsed `history` array. |
| `revalidation` | JSON | no | Parsed `revalidation` object when present. |
| `source_path` | text | yes | Example `docs/features/<feature_id>/status.yaml`. |
| `source_hash` | text | no | Hash of source status content for change detection. |
| `created_at` | timestamp | yes | Backend creation time. |
| `updated_at` | timestamp | yes | Backend update time. |

Indexes and constraints:

- Unique `snapshot_id + feature_id`.
- Index `workspace_id + feature_id`.
- Index `workspace_id + feature_status`.
- Index `workspace_id + current_stage`.

#### `workspace_feature_documents`

One row per feature document. This preserves the current raw document surfaces exactly as the UI needs them.

| Column | Type | Required | Notes |
|---|---|---:|---|
| `id` | UUID/string PK | yes | Document row id. |
| `workspace_id` | FK `workspaces.id` | yes | Parent workspace. |
| `snapshot_id` | FK `workspace_snapshots.id` | yes | Snapshot this document belongs to. |
| `feature_id` | text | yes | Feature id. |
| `document_type` | enum/text | yes | `status_yaml`, `product_spec`, `technical_design`, or `tasks_md`. |
| `source_path` | text | yes | Source file path in repo. |
| `content` | text | no | Raw YAML or markdown file content. |
| `content_hash` | text | no | Hash for change detection. |
| `created_at` | timestamp | yes | Backend creation time. |

Indexes and constraints:

- Unique `snapshot_id + feature_id + document_type`.
- Index `workspace_id + feature_id`.

#### `workspace_tasks`

One row per task YAML file in a snapshot. It stores the current task API fields fully, including execution, PR, log, workspace PR, and blocked context.

| Column | Type | Required | Notes |
|---|---|---:|---|
| `id` | UUID/string PK | yes | Task row id. |
| `workspace_id` | FK `workspaces.id` | yes | Parent workspace. |
| `snapshot_id` | FK `workspace_snapshots.id` | yes | Snapshot this task belongs to. |
| `feature_id` | text | yes | Parent feature id. |
| `task_id` | text | yes | Task id from task YAML, for example `T1`. |
| `title` | text | yes | Task title. |
| `repo` | text | no | Implementation repo id. |
| `status` | text | no | Task lifecycle state. |
| `depends_on` | JSON | yes | Array of task ids. Empty array when absent. |
| `blocked_reason` | text | no | Value from `blocked_reason`. |
| `blocked_context` | JSON | no | Full parsed `blocked_context`. |
| `branch` | text | no | Task branch. |
| `execution` | JSON | no | Full parsed `execution` object. |
| `pr` | JSON | no | Full parsed implementation PR object. |
| `workspace_pr` | JSON | no | Full parsed workspace PR object. |
| `log` | JSON | no | Full parsed task log array. |
| `source_path` | text | yes | Example `docs/features/<feature_id>/tasks/T1.yaml`. |
| `source_hash` | text | no | Hash of source task YAML. |
| `created_at` | timestamp | yes | Backend creation time. |
| `updated_at` | timestamp | yes | Backend update time. |

Indexes and constraints:

- Unique `snapshot_id + feature_id + task_id`.
- Index `workspace_id + feature_id`.
- Index `workspace_id + status`.
- Index `workspace_id + repo`.
- Index `workspace_id + branch`.

#### `workspace_activity_events`

Derived timeline rows from feature `history[]` and task `log[]`. This table lets the UI fetch timelines without scanning all JSON arrays.

| Column | Type | Required | Notes |
|---|---|---:|---|
| `id` | UUID/string PK | yes | Activity event id. |
| `workspace_id` | FK `workspaces.id` | yes | Parent workspace. |
| `snapshot_id` | FK `workspace_snapshots.id` | yes | Snapshot this event belongs to. |
| `scope_type` | enum/text | yes | `workspace`, `feature`, or `task`. |
| `feature_id` | text | no | Feature id for feature/task events. |
| `task_id` | text | no | Task id for task events. |
| `action` | text | no | Event action. |
| `stage` | text | no | Feature stage when present. |
| `actor` | text | no | `by` value from source event. |
| `occurred_at` | timestamp/text | no | Source event timestamp; keep raw parseable value if timestamp parsing fails. |
| `note` | text | no | Source note/comment. |
| `source_path` | text | yes | Source file that produced the event. |
| `sequence` | integer | yes | Stable order within the source array. |
| `raw_event` | JSON | yes | Full original event object. |
| `created_at` | timestamp | yes | Backend creation time. |

Indexes and constraints:

- Index `workspace_id + scope_type + occurred_at`.
- Index `workspace_id + feature_id + occurred_at`.
- Index `workspace_id + feature_id + task_id + occurred_at`.

#### `workspace_sync_runs`

One row per import or refresh attempt, including failed runs that do not create a fresh active snapshot.

| Column | Type | Required | Notes |
|---|---|---:|---|
| `id` | UUID/string PK | yes | Sync run id. |
| `workspace_id` | FK `workspaces.id` | yes | Parent workspace. |
| `trigger` | enum/text | yes | `import`, `manual_refresh`, `webhook`, or `scheduled`. |
| `source_kind` | enum/text | yes | Usually `github`. |
| `source_ref` | text | no | Branch/ref used. |
| `status` | enum/text | yes | `running`, `success`, `partial`, or `failed`. |
| `snapshot_id` | FK `workspace_snapshots.id` | no | Snapshot created by this run when available. |
| `started_at` | timestamp | yes | Run start time. |
| `finished_at` | timestamp | no | Run finish time. |
| `error_code` | text | no | Machine-readable failure code. |
| `error_message` | text | no | User-readable error summary. |
| `metadata` | JSON | no | Counts, warnings, rate-limit details, and skipped paths. |

Indexes and constraints:

- Index `workspace_id + started_at`.
- Index `workspace_id + status`.

#### Snapshot write rules

- Import/sync writes a new `workspace_snapshots` row and all related feature, document, task, and activity rows inside one transaction when the selected DB supports transactions.
- `workspaces.active_snapshot_id` changes only after the new snapshot is complete enough to serve.
- Failed sync creates a `workspace_sync_runs` row and may create a failed `workspace_snapshots` row for diagnostics, but it must not replace `active_snapshot_id`.
- If sync fails and `active_snapshot_id` exists, backend returns that active snapshot with `SourceState.stale = true`.
- Raw credentials and expanded local paths are never stored in UI-facing tables or DTOs.

### Workspace Source Service

The source service coordinates adapters:

- Workspace list reads from the database adapter.
- Import reads from GitHub adapter, then writes normalized snapshot to database adapter.
- Workspace detail reads from database adapter by default.
- Refresh/sync reads from GitHub adapter and updates database adapter on success.
- If refresh/sync fails, return cached database data with `SourceState.stale = true` when available.
- If no cached data exists, return a structured error.

### Backend API

Representative route shape:

- `GET /api/workspaces`
- `POST /api/workspaces/import`
- `GET /api/workspaces/:workspaceId`
- `POST /api/workspaces/:workspaceId/sync`
- `GET /api/workspaces/:workspaceId/features/:featureId`
- `GET /api/workspaces/:workspaceId/features/:featureId/tasks`
- `GET /api/workspaces/:workspaceId/tasks/:taskId`
- `GET /api/workspaces/:workspaceId/activity`

Exact paths can follow existing backend conventions. The important contract is that the frontend gets normalized JSON and never consumes GitHub archive contents, raw database rows, or raw YAML as its primary data source.

Error response requirements:

- Stable machine-readable code.
- Human-readable message.
- Source kind when relevant: `github`, `database`, or `adapter`.
- Retryability hint when practical.
- Existing cached data should be returned separately from the error when safe to show.

### Frontend API Client

The frontend should add or update a dedicated workspace API client:

- Fetch saved workspaces.
- Import workspace.
- Fetch workspace detail.
- Sync workspace.
- Fetch feature detail.
- Fetch task detail.
- Normalize backend errors into UI states without hiding source context.

Components should depend on frontend view models derived from backend DTOs, not source-specific parsing helpers.

### Workspace Shell

The workspace shell owns:

- Current workspace identity.
- Saved workspace list from backend.
- Active top-level surface: board, task tab, or feature tab.
- Open work item tabs for the active workspace only.
- Active task/feature session metadata.
- Cleanup behavior when workspace changes or is deleted.
- Source state banners or inline notices when data is stale or partially loaded.

The default board view keeps the sidebar visible. Task and Feature tab pages render without the sidebar.

### Workspace Dropdown and Import Modal

The workspace tab itself navigates back to the board. The right-side dropdown icon opens the switcher.

Dropdown behavior:

- Title: `Switch workspace`.
- Search input auto-focuses.
- Workspace list filters immediately.
- Active workspace shows a check icon.
- Empty state: `No workspace matches this search.`
- Footer action opens `Import workspace`.

Import modal behavior:

- Modal title: `Import workspace`.
- Description: `Import a repository to create a new workspace.`
- Form fields: repository URL and GitHub Personal Access Token when private access is needed.
- Repository URL is required.
- Token is password type and never displayed after entry.
- Submit calls the backend import route.
- Duplicate workspace, invalid URL, missing/invalid token, private repo access, adapter validation, and network errors render inline without closing the modal.

### Work Item Interaction Model

Task entry points:

- Single click opens quick task detail modal/sheet.
- Double click opens or focuses a Task tab.
- Right click opens a custom context menu with `New tab`.

Feature entry points:

- In Task Mode, single click opens quick feature detail. Feature double click does not open a Feature tab.
- In Feature Mode, single click opens quick feature detail, double click opens/focuses a Feature tab, and right click offers `New tab`.

Use native `dblclick` for double-click handling. Do not delay single-click behavior to infer double-clicks. If both single and double click occur, double click wins the persistent session behavior and the UI must avoid leaving a confusing modal focus state.

### Task Tab Page

Task tab content is a full work session, not a modal. It includes:

- Back button.
- Task title.
- Copy task id icon with temporary check feedback.
- Task id badge.
- Status badge, priority badge if available, and updated time if available.
- Repository, Branch, Next Action, Executed By, Depends On, Blocked Reason, and Blocked Context.
- Pull Requests section with Workspace PR and Repository PR cards.
- Activity Timeline with action, timestamp, actor, and note.
- Optional Done-state footer actions `Approve Workspace` and `Approve Repo` if those actions are available in the existing product surface.

Task tab data comes from backend task detail payloads. Missing values show `None`, except missing execution owner shows `Unassigned`.

### Feature Tab Page

Feature tab content is also a full work session. It includes:

- Back button.
- Feature title.
- Copy feature id icon with temporary check feedback.
- Feature status pill.
- Current stage pill.
- Modified time.
- Short active-view summary.
- View tabs: `Product Spec`, `Technical Design`, `Tasks`, `Logs`.

Product Spec and Technical Design render backend-provided markdown as readable UI similar to GitHub markdown preview. Tasks view renders backend task summaries. Logs view renders backend activity events and uses empty state `No feature logs are available.`

## 5. Dependency Analysis

Internal dependencies:

- Backend DTO and adapter contracts must exist before frontend API client work can be final.
- GitHub adapter and database adapter must exist before backend import/sync can be fully validated.
- Backend workspace detail route must exist before the frontend board can remove fixture/source parsing assumptions.
- Task and Feature tab pages depend on backend task/feature detail APIs.
- Source stale/error state must be represented in backend responses before UI can show correct fallback states.

External dependencies:

- `workflow-backend` implements adapters, source service, API routes, cache reads/writes, and backend tests.
- `digital-factory-ui` implements workspace shell, API client, tab/session state, views, interactions, and browser QA.
- GitHub API/network availability may affect import/sync tests.
- Database availability and schema/storage shape may affect saved workspace tests.

Blocking decisions:

- Confirm whether GitHub PAT is transient-only for import/sync or whether an existing secure backend credential pattern should be reused.
- Product must approve whether Done-state footer actions `Approve Workspace` and `Approve Repo` are active buttons or read-only placeholders if the current UI does not already support those actions.

Vendor/tooling choices:

- Use existing React/TypeScript stack in `digital-factory-ui`.
- Implement backend work in `workflow-backend` using NestJS, TypeScript, Prisma, and Supabase Postgres.
- Use Prisma Migrate for the database schema in the Database Schema Design section.
- Keep physical database objects lowercase `snake_case`; use Prisma `@map` and `@@map` where TypeScript model names differ.
- Use an existing YAML parser already present in backend if available; otherwise add one in the NestJS task that owns GitHub parsing.
- Use existing Markdown rendering approach in the frontend if one exists; otherwise add a small Markdown renderer in the implementation task that owns Feature tab source views.

Configuration dependencies:

- Backend needs the GitHub access mechanism required by import/sync.
- Backend needs Supabase Postgres configuration for saved workspace cache: `DATABASE_URL` for runtime and `DIRECT_DATABASE_URL` for Prisma migrations when Supabase provides both pooled and direct URLs.
- Frontend should only need backend base URL/config already used by the app.

Release dependencies:

- Backend routes and persistence must be deployed or runnable before frontend end-to-end QA.
- Database migration or storage initialization may be required if saved workspace cache does not exist.

## 6. Parallelization / Blocking Analysis

External decisions:

- D1: Token handling policy may affect T2/T4 but should not block local adapter contract work.

T1: Source adapter contract and canonical DTOs
  -> Can begin now.

T2: GitHub workspace adapter and import/sync parser
  -> Blocked on T1 DTO shape.

T3: Database workspace adapter and cache persistence
  -> Blocked on T1 DTO shape.

T4: Backend workspace API routes and source error contract
  -> Blocked on T2 and T3 for full behavior.

T5: Frontend backend API client and workspace shell
  -> Can start against T1/T4 draft contract, final integration blocked on T4.

T6: Task and Feature tabs from backend detail payloads
  -> Blocked on T5 shell and T4 detail endpoints.

T7: Refresh, stale data, and source-state UX
  -> Blocked on T4 source-state responses and T5/T6 UI surfaces.

T8: Integration tests and browser QA
  -> Blocked on T4 through T7.

## 7. Repository Impact

Affected repos:

- `workflow-backend`: NestJS backend modules, source adapter contracts, GitHub adapter, Prisma/Supabase database adapter/cache, workspace API routes, sync/import behavior, backend tests, and Prisma migrations.
- `digital-factory-ui`: frontend API client, workspace shell, dropdown/import modal, board data loading, task and feature tabs, source-state UI, and browser QA.
- `management-repo`: planning artifacts under `docs/features/workspace-tabs-data-flow/`.

Unaffected repos:

- `workflow`: no shared workflow-skill changes.
- `rag-service`: no implementation impact.
- `git-nexus`: no implementation impact.

## 8. Validation and Release Impact

Testing expectations:

- Backend unit tests for GitHub parser/adapter mapping, database adapter mapping, source service fallback behavior, and route error mapping.
- Backend integration tests for workspace import, saved workspace list/detail, sync success, and sync failure with stale cache fallback.
- Frontend unit/component tests for API client states, workspace dropdown/import modal, tab creation/focus/close, context menu behavior, stage popover, view switching, source-state banners, and markdown rendering.
- Browser QA for desktop flows: workspace list, import, sync, workspace switch, task/feature single/double/right click, Task tab, Feature tab, stale/error states, and workspace switch cleanup.
- Responsive sanity check for tab header overflow and source-state notices.

Migration/config impact:

- Database migration or storage initialization may be needed for saved workspace summaries and normalized workspace snapshots.
- Backend GitHub access config may be needed for private repository import/sync.
- Frontend should not store GitHub source data as the durable source of truth.

Rollout concerns:

- Preserve existing board behavior when no work item tabs are open.
- Ensure workspace switching clears old workspace tabs from the active UI.
- Ensure stale cached data is visibly marked.
- Ensure source errors do not blank an otherwise usable cached workspace.
- Ensure no agent, chat, model, composer, or conversation controls are present in this feature.

Backward compatibility:

- Existing imported workspace data should be migrated or adapted into the new backend DTO shape when possible.
- Existing task/feature data shape should be adapted through backend mappers instead of hardcoding frontend mock fields.

Handoff implications:

- After implementation tasks finish, handoff should include backend route test evidence, database/cache verification, browser QA evidence, and screenshots for the reference surfaces.
