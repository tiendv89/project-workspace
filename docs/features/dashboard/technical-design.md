# Technical Design

## Feature

- Feature ID: `dashboard`
- Title: `Workflow Dashboard Web`

## Figma

| Figma reference | Covers |
|---|---|
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=62-3198&t=dBztH5XSYbZ9jPyR-0 | Workspaces connect/import screen |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=71-85&t=xHuTHtgkwgQhVAcT-0 | Workspace detail Kanban board |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=71-2&t=xHuTHtgkwgQhVAcT-0 | Left-side task tracking panel for `IN PROGRESS`, `READY`, and `IN REVIEW` |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=62-3276&t=dBztH5XSYbZ9jPyR-0 | Task detail sheet |

---

## 1. Current State

This management workspace defines the `dashboard` feature and maps implementation work to existing repos in `workspace.yaml`.

Relevant repo boundaries:

| Repo ID | Purpose |
|---|---|
| `digital-factory-ui` | React/Vite frontend application for the dashboard UI. |
| `workflow-backend` | NestJS backend that will own repository import, transient credential handling, YAML parsing, and dashboard APIs. |
| `management-repo` | This planning workspace; no product runtime code belongs here. |

Current constraints and limitations:

- `AGENTS.md` is not present in this checkout; shared workflow rules are available through `CLAUDE.md`.
- Product spec now requires GitHub PAT access only for v1.
- The PAT is used transiently by the backend for import/sync and must never be persisted or returned to the browser.
- The dashboard must read workflow YAML from connected management repositories and treat it as read-only.
- The prior technical design was frontend-only and is superseded.
- Task YAML has been regenerated from this design and remains draft until approval.

---

## 2. Problem Framing

### What must change

- Move repository access and PAT handling out of the browser into `workflow-backend`.
- Add NestJS APIs for workspace import, feature/task listing, and manual sync.
- Persist workspace connection metadata and sync state only; keep PAT handling transient.
- Parse `docs/features/<featureId>/status.yaml` and `docs/features/<featureId>/tasks/T<n>.yaml` into board-ready DTOs.
- Implement the frontend in `digital-factory-ui` using React/Vite, feature-oriented modules, compound components, Context, and Provider boundaries.
- Add the left-side task tracking panel using the Figma frame for `IN PROGRESS`, `READY`, and `IN REVIEW`.
- Derive task elapsed-time labels from task status transition timestamps.

### What must remain stable

- No user account system in v1.
- No task/status mutation from the dashboard UI.
- No drag-and-drop Kanban mutations.
- Load cached workspace data on app open plus manual `Sync` is sufficient; realtime websocket/SSE is out of scope.
- The source repository YAML remains read-only.
- Figma frames are the UI source of truth.

### Fixed assumptions

- GitHub is the only repository provider for v1.
- GitHub PAT is the only repository access method for v1.
- Supabase Postgres is the backing store for workspace connection metadata.
- Prisma 7 is used if persistence schema/migrations are needed; this design requires workspace metadata persistence, so Prisma 7 should be used.
- PAT values are request/session credentials only. The backend must not store them in the database.
- The workflow YAML structure follows:
  - `docs/features/<featureId>/status.yaml`
  - `docs/features/<featureId>/tasks/T<n>.yaml`

---

## 3. Options Considered

### Option A — Frontend calls GitHub directly

The React app stores the PAT locally and calls GitHub REST APIs directly.

**Pros**
- Minimal backend work.
- Faster first prototype.
- No backend import service or DB schema.

**Cons**
- Conflicts with the approved product spec because the token would live in the browser.
- Harder to protect private repo access.
- Larger workspaces create many browser-side GitHub requests.
- No durable place for workspace metadata, sync status, or import errors.

**Implementation impact:** Low frontend-only implementation, but high security mismatch.

**Dependency impact:** Depends only on GitHub REST and frontend packages, but does not satisfy the backend import boundary.

### Option B — NestJS backend imports and serves workflow data

The frontend first asks `workflow-backend` for an existing imported workspace. If one exists, the board loads from the persisted workspace record and backend repo cache without a new import. If none exists, the frontend sends repository input + PAT to `workflow-backend`. The backend uses the PAT transiently to clone or pull the repo, stores workspace metadata and sync history in Supabase Postgres through Prisma 7, parses workflow YAML, and returns board DTOs.

**Pros**
- Matches the product spec: PAT stays out of browser persistence and backend durable storage.
- Keeps repository access logic in one backend boundary.
- Enables import-once reuse, manual sync, import error handling, and later cache/snapshot improvements.
- Provides stable typed APIs for React providers.

**Cons**
- Requires backend schema and repository cache handling.
- Requires cross-repo integration between frontend and backend.
- Requires deployment configuration for DB URL and repo cache path.

**Implementation impact:** Medium. Work spans `workflow-backend` and `digital-factory-ui`.

**Dependency impact:** Requires NestJS modules, Supabase Postgres, Prisma 7, YAML parsing, GitHub repo access, and repo cache configuration.

### Option C — GitHub Bot Account

The system provides a bot account and the user adds it as a read-only collaborator.

**Pros**
- Avoids user-provided PAT input.
- Can improve onboarding for organization-managed installs later.

**Cons**
- Explicitly out of scope for v1.
- Requires account provisioning, organization policies, and bot credential operations.
- Delays the current dashboard path.

**Implementation impact:** High for v1 and not aligned with current product decision.

**Dependency impact:** Requires operational GitHub account management not currently defined.

---

## 4. Chosen Design

**Chosen approach: Option B — NestJS backend with transient PAT handling, Supabase Postgres, Prisma 7, and React/Vite frontend.**

This is chosen because the approved product spec requires repository access to stay behind the backend boundary while keeping v1 simple. The PAT is used only for import/sync operations, is not persisted by the frontend or backend, and is never returned in API responses. The v1 flow stays minimal: import once with repository input + PAT, persist workspace metadata/cache, reopen the board many times from cached data, and support manual sync with a transient credential when needed. The frontend remains focused on interaction, routing, provider state, and Figma-accurate composition.

### Backend design

`workflow-backend` owns:

- `WorkspacesModule`
  - `GET /api/workspaces`
  - `POST /api/workspaces`
  - `GET /api/workspaces/:workspaceId`
  - returns the existing imported workspace metadata when available
  - returns one workspace detail record by id for direct board routes and refreshes
  - accepts repository input that follows the expected GitHub repository pattern and requires PAT presence
  - does not block the flow with a separate repository-format gate before import; GitHub access, clone/sync, and missing workflow files are surfaced as structured import errors
  - stores workspace metadata without any PAT field
  - starts initial import/sync
- `WorkspaceSyncService`
  - clones the GitHub repository into a backend-managed cache path using the request PAT
  - re-pulls on manual sync using a PAT supplied for that sync request or currently held in frontend provider memory
  - never writes to the connected management repository
- `WorkflowYamlParser`
  - reads only `docs/features/*/status.yaml` and `docs/features/*/tasks/T*.yaml`
  - skips malformed YAML with structured warnings
  - projects feature/task records for the board
- `DashboardQueryController`
  - `GET /api/workspaces/:id/features`
  - parses from the cached repo and returns feature rows, task cards, task detail metadata, dependency state, PR metadata, and task log timestamps
- `SyncController`
  - `POST /api/workspaces/:id/sync`
  - re-pulls and re-parses the repository

Persistence:

- Supabase Postgres stores workspace connection metadata and sync history.
- Prisma 7 owns schema and migrations.
- No PAT column is stored in the database.
- PAT values must not be written to logs, sync history, DTOs, or error payloads.

Recommended tables:

| Table | Purpose |
|---|---|
| `dashboard_workspaces` | Workspace id, repository input, owner, repo, default branch, repo cache path/ref, sync status, last synced timestamp. |
| `dashboard_sync_runs` | Import/sync attempt history, error messages, started/completed timestamps. |

The parsed feature/task board may be computed on demand from the repo cache in v1. The first import creates the workspace record and repo cache; later app opens reuse that record/cache and do not require PAT unless the user asks to sync a private repo. Persisting parsed board snapshots is optional and should only be added if sync latency becomes a real problem.

### Frontend design

`digital-factory-ui` owns:

- React + Vite application structure.
- Feature-based folders for `workspaces`, `board`, `tasks`, `sync`, and `errors`.
- Context/Provider state boundaries:
  - `WorkspaceProvider` for selected workspace and import state.
  - `BoardProvider` for fetched board state, search/filter state, expanded features, selected task, and sync state.
  - `TaskDetailProvider` for task detail sheet state.
- Compound components:
  - `WorkspaceConnect.Root`, `.Form`, `.Error`, `.Submit`
  - `KanbanBoard.Root`, `.Column`, `.FeatureRow`, `.TaskCard`
  - `TaskTrackingPanel.Root`, `.Row`, `.TaskItem`
  - `TaskDetailSheet.Root`, `.Header`, `.Metadata`, `.Timeline`
- API client:
  - `getCurrentWorkspace()`
  - `getWorkspace(workspaceId)`
  - `createWorkspace({ repository, pat })`
  - `getWorkspaceFeatures(workspaceId)`
  - `syncWorkspace(workspaceId, { pat? })`

Task timing:

- `IN PROGRESS`: elapsed time since the task entered `in_progress`.
- `READY`: elapsed time since the task entered `ready`.
- `IN REVIEW`: elapsed time since the task entered `in_review`; UI copy should communicate that work is complete and waiting for review.
- Backend should derive timestamps from task log entries where possible.
- If a matching transition timestamp is absent, fallback to the newest reliable task log timestamp and include a `timestampConfidence: "fallback"` marker for the frontend.

Compatibility considerations:

- Existing browser-only localStorage demo state should be ignored.
- Returning users should load the existing workspace through `GET /api/workspaces`; direct workspace routes should load detail through `GET /api/workspaces/:workspaceId`. The connect/import screen appears only when no workspace exists or the cached workspace needs reconnect.
- API contracts should be additive and versionable.
- The dashboard remains read-only against the connected management repo.

Operational implications:

- Backend deploys require Supabase database URL, Prisma migrations, and repo cache path.
- Frontend deploys require backend API base URL.
- PAT values must never appear in API responses, frontend storage, backend durable storage, logs, or PR descriptions.

---

## 5. Dependency Analysis

| Dependency | Type | Status | Notes |
|---|---|---|---|
| React + Vite | Frontend stack | Resolved | Required by user. |
| Compound components | Frontend architecture | Resolved | Use direct root-attached compound exports. |
| Context + Provider | Frontend state | Resolved | Providers own workflow board state and interaction state. |
| NestJS | Backend stack | Resolved | Required by user for API/backend boundary. |
| Supabase Postgres | Database | Resolved | Stores workspace connection and sync metadata. |
| Prisma 7 | ORM/migrations | Resolved for this design | Needed because workspace metadata and sync history persistence are required. |
| GitHub PAT | Runtime credential | User-provided | Must have read access to target management repo; used transiently for import/sync and not persisted. |
| Git repo cache path | Configuration | Blocking before import/sync runtime | Backend needs writable storage for clone/pull cache reused across app opens. |
| Figma frames and local fallback screenshots | UI source of truth | Resolved | Agents should read design through Figma API/MCP with local `FIGMA_ACCESS_TOKEN` when available. If Figma API/MCP access fails, use checked-in screenshots under `docs/features/dashboard/design/`. `FIGMA_ACCESS_TOKEN` is a local implementation-tooling secret only and must never be committed, logged, or shipped to the frontend runtime. |
| `docs/features` YAML contract | Data contract | Resolved | Parser assumes standard workflow layout. |

Unresolved dependency:

- Exact Supabase project/database URL is environment-specific and must be provided before backend runtime validation.

---

## 6. Parallelization / Blocking Analysis

External dependencies:

```
D1: Supabase DATABASE_URL and migration target are available
D2: Backend repo cache path is writable
D3: FIGMA_ACCESS_TOKEN is available in the local agent/tooling environment for Figma API/MCP design reads
```

Per-task dependency diagram:

```
T1: Backend workspace metadata persistence + sync history — workflow-backend
  └── Can begin now — no blockers
  └── Requires D1 before runtime verification
  │
T2: Backend GitHub clone/pull import service — workflow-backend
  └── BLOCKED on T1 (workspace metadata and sync-run persistence must exist)
  └── Requires D2 before runtime verification
  │
  T3: Backend workflow YAML parser + board APIs — workflow-backend
    └── BLOCKED on T2 (parser needs a stable imported repository/cache boundary)
    │
T4: Frontend React/Vite provider and API client foundation — digital-factory-ui
  └── Can begin now — no blockers
  └── T1 and T4 run in parallel
  │
  T5: Frontend connect workspace flow — digital-factory-ui
    └── BLOCKED on T4 (provider/API client structure must exist)
    └── BLOCKED on T2 (current-workspace lookup and import endpoint must support import-once reuse)
    └── Uses D3 to read Figma via API/MCP; fallback to checked-in screenshots if unavailable
    │
  T6: Frontend board + task tracking panel — digital-factory-ui
    └── BLOCKED on T4 (board provider and API client structure must exist)
    └── BLOCKED on T3 (feature/task DTOs and elapsed-time fields must be stable)
    └── Uses D3 to read Figma via API/MCP; fallback to checked-in screenshots if unavailable
    │
  T7: Backend tests, security checks, and sync hardening — workflow-backend
    └── BLOCKED on T1 (Prisma model and workspace persistence must exist)
    └── BLOCKED on T2 (clone/pull service must exist)
    └── BLOCKED on T3 (parser/API behavior must exist)
    │
    T8: End-to-end QA and release handoff — management-repo
      └── BLOCKED on T5 (connect flow must be implemented)
      └── BLOCKED on T6 (board/task tracking UI must be implemented)
      └── BLOCKED on T7 (backend validation must pass)
```

Parallelization summary:

- T1 and T4 can start immediately and run in parallel after task approval.
- T2 follows T1.
- T3 follows T2.
- T5 and T6 can run in parallel after their blockers are satisfied.
- T7 can run while frontend implementation proceeds once backend tasks are ready.
- T8 is the final cross-surface validation and handoff task.

---

## 7. Repository Impact

| Repo ID | Impact |
|---|---|
| `workflow-backend` | Add NestJS dashboard/workspace modules, Supabase/Prisma schema for workspace metadata and sync history, transient PAT import/sync handling, GitHub clone/sync services, YAML parser, and dashboard APIs. |
| `digital-factory-ui` | Add React/Vite dashboard UI, providers/context, compound components, Figma-aligned screens, API client, connect flow, board, task tracking panel, and task detail integration. |
| `management-repo` | Holds this feature plan and final handoff evidence only. |

No runtime code changes are planned for `workflow` or `rag-service`.

---

## 8. Validation and Release Impact

Backend validation:

- Unit tests for PAT-required import behavior and repository input forwarding to the import service.
- Unit tests for `GET /api/workspaces` returning an existing workspace without PAT.
- Unit tests for `GET /api/workspaces/:workspaceId` returning workspace detail without PAT.
- Unit tests that assert PAT is not persisted in Prisma models, DTOs, sync history, or error payloads.
- Prisma migration validation against Supabase Postgres.
- Parser tests for valid feature/task YAML, malformed YAML, missing optional fields, missing logs, and status transition timestamp fallback.
- Integration test for import + sync using a fixture management repo.
- Integration test for import once, reopen/load board from cache, then sync with transient PAT.

Frontend validation:

- Typecheck and production build.
- Provider/API client tests for loading, error, empty, and sync states.
- Provider/API client tests for existing workspace bootstrap before showing the connect flow.
- Browser QA for workspaces connect screen, workspace detail board, task tracking panel, and task detail sheet.
- Figma validation for all referenced frames using local `FIGMA_ACCESS_TOKEN` when available, with checked-in screenshot fallback if API/MCP access fails.

Security validation:

- Confirm PAT is not stored in browser localStorage/sessionStorage.
- Confirm PAT is not stored in backend database rows.
- Confirm PAT is not returned by any API response.
- Confirm backend logs redact PAT values.

Migration/config impact:

- Add Supabase database configuration.
- Add Prisma 7 schema/migrations for dashboard workspace metadata.
- Add backend repo cache path env var.
- Add frontend backend API base URL env var.

Rollout concerns:

- First rollout should target develop only; staging/production remain disabled in `workspace.yaml`.
- Existing frontend demo/localStorage state can be ignored.
- If import/sync latency is high for large repos, add persisted parsed snapshots in a later iteration.

Handoff implications:

- Handoff must document transient PAT behavior, required environment variables, test evidence, and known v1 limitations.
- Human review is still required before marking any implementation task done.
