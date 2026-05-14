# Tasks - Workspace Tabs and End-to-End Workspace Data Flow

Feature status reference: `in_design`; stage status: `product_spec/awaiting_approval`. Machine state lives in `tasks/T<n>.yaml`; this file is narrative only.

## Index

| ID | Wave | Repo | Title | Depends on |
|---|---:|---|---|---|
| T1 | 1 | workflow-backend | NestJS source adapter contract and canonical workspace DTOs | [] |
| T2 | 2 | workflow-backend | NestJS GitHub workspace adapter and import/sync parser | [T1] |
| T3 | 2 | workflow-backend | Prisma/Supabase workspace adapter and cache persistence | [T1] |
| T4 | 3 | workflow-backend | NestJS workspace APIs and source error contract | [T2, T3] |
| T5 | 4 | digital-factory-ui | Frontend API client and workspace shell integration | [T4] |
| T6 | 5 | digital-factory-ui | Task and feature tabs from backend detail payloads | [T5] |
| T7 | 6 | digital-factory-ui | Refresh, stale data, and source-state UX | [T4, T5, T6] |
| T8 | 7 | digital-factory-ui | End-to-end integration tests and browser QA | [T4, T5, T6, T7] |

---

## T1 - NestJS source adapter contract and canonical workspace DTOs

### Description

Define the NestJS backend source boundary that normalizes GitHub and database workspace data before it reaches API routes or UI components.

This task owns the shared DTOs and adapter interfaces used by later GitHub, database, backend API, and frontend integration work.

Deliverables:

- Define canonical workspace DTOs for workspace summaries, workspace detail, feature summaries, feature detail, task summaries, task detail, pull request refs, activity events, and source state.
- Define a `WorkspaceSourceAdapter` style interface or equivalent backend boundary for GitHub and database sources.
- Define NestJS module/service/controller boundaries for source adapters, source orchestration, and workspace API presentation.
- Define source-state semantics for fresh, stale, partial, unavailable, and error states.
- Define normalized backend error shape with machine-readable code, user-facing message, source kind, and retryability hint.
- Add mapper/helper tests for DTO validation where practical.
- Document the expected adapter flow in backend-local comments or docs if the backend repo convention supports it.

### Required skills

- backend-engineer
- typescript-best-practices

### Subtasks

- [ ] Inspect current `workflow-backend` data models, route conventions, and migration path to NestJS.
- [ ] Define NestJS module layout for workspace source adapters, source service, Prisma access, and API controllers.
- [ ] Define workspace, feature, task, PR, activity, and source-state DTOs.
- [ ] Define adapter contract for GitHub and database-backed sources.
- [ ] Define source error contract and retryability fields.
- [ ] Add unit tests for DTO mappers/helpers where applicable.
- [ ] Typecheck passes.

---

## T2 - NestJS GitHub workspace adapter and import/sync parser

### Description

Implement the NestJS GitHub adapter that reads workflow repository data and maps it into the canonical DTOs.

This task depends on T1 because GitHub parsing should output the shared workspace model rather than source-specific records.

Deliverables:

- Validate repository URL and access input.
- Fetch repository content through the backend's chosen GitHub strategy inside an injectable NestJS service.
- Discover `docs/features/*/status.yaml`.
- Read feature-level `product-spec.md`, `technical-design.md`, `tasks.md`, and `tasks/T*.yaml` where available.
- Parse YAML and preserve source markdown for document views.
- Map feature status, stage state, task state, PR refs, dependencies, blocked state, and activity into canonical DTOs.
- Treat optional missing files as empty states.
- Treat inaccessible repos, invalid YAML, missing required status files, rate limits, and network failures as structured source errors.
- Add unit tests with representative workflow repo fixtures.

### Required skills

- backend-engineer
- typescript-best-practices

### Subtasks

- [ ] Identify existing GitHub fetch utilities or add a narrow NestJS GitHub client/service.
- [ ] Build repository URL normalization and validation.
- [ ] Implement feature discovery from `docs/features/*/status.yaml`.
- [ ] Implement YAML parsing for feature status and task YAML files.
- [ ] Preserve markdown content for product spec and technical design views.
- [ ] Map GitHub files into canonical workspace DTOs.
- [ ] Map GitHub/source failures into normalized source errors.
- [ ] Add fixture-backed tests for success, missing optional files, invalid YAML, inaccessible repo, and rate limit/network failures.
- [ ] Typecheck passes.

---

## T3 - Prisma/Supabase workspace adapter and cache persistence

### Description

Implement the Prisma-backed database adapter that stores and reads saved workspaces plus normalized workspace snapshots in Supabase Postgres.

This task depends on T1 because database records should map into the same canonical DTOs as GitHub adapter output.

Deliverables:

- Add Prisma schema and migration for `workspaces`, `workspace_repositories`, `workspace_snapshots`, `workspace_features`, `workspace_feature_documents`, `workspace_tasks`, `workspace_activity_events`, and `workspace_sync_runs`.
- Configure Prisma for Supabase Postgres with `DATABASE_URL` and direct migration connection support.
- List saved workspaces from backend persistence.
- Read cached workspace detail, feature detail, task detail, task lists, and activity data.
- Write or update normalized workspace snapshots after successful GitHub import or sync.
- Store last successful sync metadata and source freshness.
- Return stale cached data when a fresh GitHub sync fails and cache exists.
- Keep secrets and database-only implementation fields out of UI payloads.
- Add persistence tests or repository tests following current backend conventions.

### Required skills

- backend-engineer
- database-engineer
- typescript-best-practices

### Subtasks

- [ ] Inspect current backend persistence conventions and add Prisma if it is not already present.
- [ ] Add Prisma schema/migration for workspace, repository, snapshot, feature, document, task, activity, and sync-run tables.
- [ ] Configure Supabase Postgres connection handling for runtime queries and direct migrations.
- [ ] Use lowercase `snake_case` physical table, column, index, and constraint names through Prisma `@map`/`@@map` where needed.
- [ ] Enforce unique constraints for workspace slug, workspace repository ids, snapshot feature ids, feature documents, and snapshot task ids.
- [ ] Add indexes for workspace lookup, feature status/stage, task status/repo/branch, activity timelines, and sync runs.
- [ ] Implement database adapter read methods.
- [ ] Implement snapshot write/update methods for import and sync.
- [ ] Store raw feature documents separately from normalized feature/task rows.
- [ ] Derive `workspace_activity_events` from feature history and task logs.
- [ ] Persist last successful sync metadata.
- [ ] Ensure UI DTOs do not expose secrets or raw database records.
- [ ] Add tests for list, detail read, snapshot write, stale cache fallback, and missing workspace.
- [ ] Typecheck passes.

---

## T4 - NestJS workspace APIs and source error contract

### Description

Expose the NestJS API surface consumed by the dashboard UI and coordinate GitHub/database adapters through a source service.

This task depends on T2 and T3 because the routes must import/sync from GitHub and read cached database-backed workspaces.

Deliverables:

- `GET /api/workspaces` or equivalent saved workspace list route.
- `POST /api/workspaces/import` or equivalent GitHub import route.
- `GET /api/workspaces/:workspaceId` or equivalent workspace detail route.
- `POST /api/workspaces/:workspaceId/sync` or equivalent refresh route.
- Feature detail route for source documents, task list, logs, and source state.
- Task detail route for task metadata, dependencies, PR refs, blocked context, and activity.
- NestJS controllers for workspace list, import, detail, sync, feature detail, feature tasks, task detail, and activity routes.
- Source service that reads Prisma/Supabase data by default, imports/syncs via GitHub, and updates database snapshots on success.
- Sync failure behavior that returns stale cached data when available.
- Route tests for success, validation errors, GitHub errors, database errors, and stale-cache fallback.

### Required skills

- backend-engineer
- api-design
- typescript-best-practices

### Subtasks

- [ ] Add NestJS source service that coordinates GitHub and Prisma/Supabase database adapters.
- [ ] Add saved workspace list route.
- [ ] Add GitHub import route.
- [ ] Add workspace detail route.
- [ ] Add workspace sync/refresh route.
- [ ] Add feature detail and feature tasks routes.
- [ ] Add task detail route.
- [ ] Map adapter errors to stable API error payloads.
- [ ] Return stale cached data with visible source state when sync fails and cache exists.
- [ ] Add NestJS controller/service tests for success and failure paths.
- [ ] Typecheck passes.

---

## T5 - Frontend API client and workspace shell integration

### Description

Update the dashboard frontend to load saved workspaces, workspace detail, import, and sync through backend APIs.

This task depends on T4 because the UI should consume normalized backend payloads instead of parsing GitHub or raw YAML directly.

Deliverables:

- Frontend workspace API client for list, import, detail, sync, feature detail, and task detail calls.
- Workspace shell state that distinguishes board, task tab, and feature tab surfaces.
- Per-workspace open work item tabs, active tab, originating feature context, and close behavior.
- Workspace tab click returns to the default board.
- Switching workspace clears or hides tabs from the previous workspace.
- Sidebar remains visible only in the default board surface.
- Workspace dropdown loads saved workspaces from backend data.
- Import modal submits to backend import route and handles normalized errors.
- Unit/component tests for API states, workspace switch, import validation, and shell isolation.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Identify current frontend data-loading and workspace shell patterns.
- [ ] Add or update typed frontend API client for backend workspace routes.
- [ ] Replace local fixture/GitHub parsing reads with backend workspace payloads in the shell.
- [ ] Define typed work item tab model for Task and Feature tabs.
- [ ] Add session state for open tabs, active tab, active workspace, and originating feature context.
- [ ] Add route/page shells for Task tab and Feature tab surfaces.
- [ ] Wire workspace tab click to board navigation.
- [ ] Build dropdown/import modal against backend list/import routes.
- [ ] Ensure switching workspace removes previous workspace tabs from the active UI.
- [ ] Add tests for API state handling, import errors, tab open/focus/close, and workspace isolation.
- [ ] Typecheck passes.

---

## T6 - Task and feature tabs from backend detail payloads

### Description

Build route-backed Task and Feature tab work sessions that render backend detail payloads.

This task depends on T5 because tab shells and frontend API client must already exist.

Deliverables:

- Task tab route/page shell without sidebar.
- Task header with Back button, task title, copy task id icon, temporary check feedback, task id badge, status badge, optional priority badge, and updated time.
- Task information section with Repository, Branch, Next Action, Executed By, Depends On, Blocked Reason, and Blocked Context.
- Pull Requests section with Workspace PR and Repository PR cards.
- Activity Timeline with action, timestamp, actor, and note.
- Feature tab route/page shell without sidebar.
- Feature header with Back button, feature title, copy feature id icon, temporary check feedback, feature status pill, current stage pill, modified time, and active-view summary.
- Feature view tabs: `Product Spec`, `Technical Design`, `Tasks`, `Logs`.
- Product Spec and Technical Design views render backend markdown as readable UI.
- Tasks view renders backend task summaries and opens Task tabs while preserving originating Feature context.
- Logs view renders backend activity timeline and empty state `No feature logs are available.`
- No agent, chat, split panel, composer, model, or conversation controls.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Build Task tab route/page shell without sidebar.
- [ ] Render task header, copy feedback, badges, updated time, and metadata sections from backend task detail.
- [ ] Render task PR cards and activity timeline from backend payloads.
- [ ] Implement Task tab Back behavior to originating Feature tab when present.
- [ ] Build Feature tab route/page shell without sidebar.
- [ ] Render feature header, copy feedback, status/stage pills, modified time, and active-view summary.
- [ ] Build current stage hover popover with ordered stage rows and current badge.
- [ ] Render Product Spec and Technical Design markdown views from backend strings.
- [ ] Render Tasks view with task metadata list and task drilldown behavior.
- [ ] Render Logs view with source badge, activity timeline, and empty state.
- [ ] Add tests for task/feature detail rendering, metadata fallbacks, PR link states, markdown rendering, task drilldown, logs, copy feedback, and back behavior.
- [ ] Typecheck passes.

---

## T7 - Refresh, stale data, and source-state UX

### Description

Make source freshness visible and recoverable in the frontend.

This task depends on T4, T5, and T6 because backend source-state payloads and the UI surfaces must exist first.

Deliverables:

- Workspace refresh/sync action wired to backend sync route.
- Loading state for workspace list, import, workspace detail, sync, feature detail, and task detail.
- Empty states for no saved workspaces, no feature tasks, no feature logs, and missing optional task data.
- Source-state notice for stale cached data.
- Source-state notice for partially loaded data.
- User-readable error state for GitHub errors, database errors, adapter validation errors, and network failures.
- Retry behavior where backend routes support it.
- No workspace data is blanked when stale cache is available.
- Tests for source-state rendering and retry behavior.

### Required skills

- frontend-engineer
- frontend-testing
- typescript-best-practices

### Subtasks

- [ ] Add workspace refresh/sync UI entry point following existing product patterns.
- [ ] Wire refresh/sync to backend API client.
- [ ] Render loading states for each backend-backed surface.
- [ ] Render empty states for saved workspaces, feature tasks, feature logs, and missing task sections.
- [ ] Render stale cache and partial data notices from backend `SourceState`.
- [ ] Render source-specific errors without exposing implementation details or secrets.
- [ ] Keep cached data visible when backend marks it stale.
- [ ] Add tests for loading, empty, stale, partial, error, retry, and cached-data fallback states.
- [ ] Typecheck passes.

---

## T8 - End-to-end integration tests and browser QA

### Description

Run final integration tests and browser QA across the backend adapter/API flow and frontend workspace tabs.

This task depends on T4 through T7. It owns regression fixes directly caused by this feature.

Deliverables:

- Backend unit/integration tests pass.
- Frontend unit/component tests pass.
- TypeScript typecheck passes in affected repos.
- Production build passes in affected repos where applicable.
- End-to-end path is verified: GitHub source or fixture -> adapter -> backend API -> UI.
- Database cache path is verified: saved workspace -> database adapter -> backend API -> UI.
- Browser QA verifies workspace dropdown search, switch, outside click, active check, and import modal.
- Browser QA verifies sync/refresh, stale cache, and source-error states.
- Browser QA verifies task single click, double click, right click, sidebar task behavior, and no duplicate default tab.
- Browser QA verifies Feature Mode feature single click, double click, right click, and Task Mode feature double-click gating.
- Browser QA verifies Task tab header, metadata, PR cards, timeline, copy feedback, close behavior, and Back behavior.
- Browser QA verifies Feature tab header, stage popover, view tabs, markdown views, Tasks view, Logs view, copy feedback, task drilldown, and Back behavior.
- Browser QA confirms no agent, chat, model, composer, or conversation controls are present.
- Screenshots or notes are captured for key Figma/reference surfaces where practical.

### Required skills

- backend-engineer
- frontend-engineer
- browser-qa-frontend

### Subtasks

- [ ] Run backend tests.
- [ ] Run frontend tests.
- [ ] Run TypeScript typecheck in affected repos.
- [ ] Run production builds where applicable.
- [ ] Verify GitHub source import/sync to backend API response.
- [ ] Verify database saved workspace/cache path to backend API response.
- [ ] Start local backend and frontend.
- [ ] Verify workspace dropdown and import modal flows in browser.
- [ ] Verify sync/refresh, stale cache, and source-error states.
- [ ] Verify task click, double-click, and right-click flows from board and sidebar.
- [ ] Verify feature click, double-click, and right-click flows in Task Mode and Feature Mode.
- [ ] Verify Task tab page content, copy feedback, PR cards, timeline, Back, close, and no-sidebar layout.
- [ ] Verify Feature tab page content, stage popover, view tabs, markdown rendering, task drilldown, Back, close, and no-sidebar layout.
- [ ] Verify no agent, chat, panel, composer, model selector, skill mention, or conversation controls remain.
- [ ] Fix feature-owned regressions found during QA.
