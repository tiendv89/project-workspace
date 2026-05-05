# Tasks — Workflow Dashboard Web

Feature status reference: `in_tdd`; stage status: `tasks/draft`. Machine state lives in `tasks/T<n>.yaml`; this file is narrative only.

## Index

| ID | Wave | Title | Depends on |
|---|---:|---|---|
| T1 | 1 | Backend workspace metadata persistence and sync history | [] |
| T2 | 2 | Backend GitHub import and sync service | [T1] |
| T3 | 3 | Backend workflow YAML parser and board APIs | [T2] |
| T4 | 1 | Frontend React/Vite provider and API client foundation | [] |
| T5 | 4 | Frontend connect workspace flow | [T2, T4] |
| T6 | 4 | Frontend board and task tracking panel | [T3, T4] |
| T7 | 4 | Backend tests, security checks, and sync hardening | [T1, T2, T3] |
| T8 | 5 | End-to-end QA and release handoff | [T5, T6, T7] |

## T1 — Backend workspace metadata persistence and sync history

### Description

Add the backend persistence foundation for the dashboard. This task creates the NestJS dashboard workspace module in `workflow-backend` and defines Supabase Postgres persistence through Prisma 7 for workspace metadata, repo cache references, and sync history. PAT values are intentionally excluded from durable storage.

### Required skills

- backend-engineer
- nestjs-best-practices
- postgres-best-practices
- typescript-best-practices

### Subtasks

- [ ] Add or update the NestJS dashboard/workspaces module boundary.
- [ ] Define Prisma 7 models/migrations for `dashboard_workspaces` and `dashboard_sync_runs` without PAT columns.
- [ ] Add required config validation for `DATABASE_URL`.
- [ ] Persist repository metadata, default branch, repo cache path/ref, sync status, and sync-run outcomes.
- [ ] Implement `GET /api/workspaces` to return the existing imported workspace without requiring PAT.
- [ ] Implement `GET /api/workspaces/:workspaceId` to return one workspace detail record without requiring PAT.
- [ ] Ensure workspace API DTOs never expose PAT values.
- [ ] Add unit tests for persistence, config validation, and DTO redaction behavior.

## T2 — Backend GitHub import and sync service

### Description

Implement server-side repository access in `workflow-backend`. This task accepts repository input and a transient PAT from the connect flow, attempts GitHub access through the import service, clones the repository into a backend-managed cache, and supports manual re-pull/re-parse sync requests. The first import creates reusable cached workspace state; later app opens must not require re-import. The connected management repository remains read-only, and PAT values are never persisted.

### Required skills

- backend-engineer
- nestjs-best-practices
- typescript-best-practices

### Subtasks

- [ ] Accept repository input that follows the expected GitHub repository pattern and pass it to the import service.
- [ ] Implement `POST /api/workspaces` import flow using the request PAT only.
- [ ] Add repo cache path config and writable-path validation.
- [ ] Clone private/public GitHub repos server-side using the PAT.
- [ ] Reuse the existing repo cache for board reads after the first import.
- [ ] Implement `POST /api/workspaces/:id/sync` to accept a transient PAT when private repo sync requires it.
- [ ] Record sync run status without storing PAT values.
- [ ] Return structured errors for access denied, missing workflow files, and clone/sync failures.
- [ ] Ensure PAT values are redacted from logs and errors.

## T3 — Backend workflow YAML parser and board APIs

### Description

Build the backend parser and read APIs that turn imported workflow YAML into dashboard-ready data. This task reads only the approved workflow paths, parses features and tasks, derives task elapsed-time metadata from status transition logs, and serves the board/detail DTOs consumed by the frontend.

### Required skills

- backend-engineer
- nestjs-best-practices
- typescript-best-practices

### Subtasks

- [ ] Read `docs/features/*/status.yaml` from the imported repo cache.
- [ ] Read `docs/features/*/tasks/T*.yaml` from the imported repo cache.
- [ ] Parse YAML into typed feature/task DTOs.
- [ ] Derive task status groups for `TODO`, `READY`, `IN PROGRESS`, `BLOCKED`, `IN REVIEW`, `DONE`, and `CANCELLED`.
- [ ] Derive left-panel rows for `IN PROGRESS`, `READY`, and `IN REVIEW`.
- [ ] Compute elapsed-time labels from the matching status transition log timestamp.
- [ ] Add fallback timestamp confidence when a matching transition timestamp is absent.
- [ ] Implement `GET /api/workspaces/:id/features`.
- [ ] Include task detail metadata, dependencies, blocked reason, PR links, and activity log data.
- [ ] Add parser tests for valid YAML, malformed YAML, missing logs, and empty workspaces.

## T4 — Frontend React/Vite provider and API client foundation

### Description

Create the frontend architecture foundation in `digital-factory-ui`. This task establishes the React/Vite feature structure, Context/Provider boundaries, API client modules, and direct compound-component conventions that the connect flow, board, tracking panel, and task detail UI will compose.

### Required skills
- frontend-engineer
- typescript-best-practices
- figma-mcp

### Figma

- Workspaces page Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=62-3198&t=dBztH5XSYbZ9jPyR-0
- Workspace detail page Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=71-85&t=xHuTHtgkwgQhVAcT-0
- Task tracking panel Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=71-2&t=xHuTHtgkwgQhVAcT-0
- Task detail Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=62-3276&t=dBztH5XSYbZ9jPyR-0

### Subtasks

- [ ] Confirm the `digital-factory-ui` repo is resolved from `DIGITAL_FACTORY_UI_LOCAL_PATH`.
- [ ] Confirm local agent tooling has `FIGMA_ACCESS_TOKEN` available for Figma API/MCP reads; do not add it to frontend runtime env.
- [ ] Establish feature folders for `workspaces`, `board`, `tasks`, `sync`, and `errors`.
- [ ] Create `WorkspaceProvider`, `BoardProvider`, and `TaskDetailProvider`.
- [ ] Create a typed API client for current workspace lookup, workspace detail, workspace import, feature list, and sync endpoints.
- [ ] Define direct root-attached compound component conventions.
- [ ] Add loading, error, empty, and stale-data state primitives.
- [ ] Verify typecheck/build for the frontend foundation.

## T5 — Frontend connect workspace flow

### Description

Implement the Figma-backed connect/import screen in `digital-factory-ui`. The flow first checks for an existing imported workspace and skips import when one exists. If no workspace exists, it accepts GitHub repository input and PAT, sends the PAT only to the backend import API, handles errors, and navigates to the board after the backend creates/imports the workspace. The frontend may keep PAT only in memory for the current tab/session to support immediate sync, but must never persist it.

### Required skills

- frontend-engineer
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma

- Workspaces page Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=62-3198&t=dBztH5XSYbZ9jPyR-0

### Subtasks

- [ ] Read the Workspaces page Figma frame through Figma API/MCP using local `FIGMA_ACCESS_TOKEN`; fallback to `docs/features/dashboard/design/workspaces-connect-import.png` if unavailable.
- [ ] Implement `WorkspaceConnect` compound components.
- [ ] Load `GET /api/workspaces/current` before showing the connect form.
- [ ] Use `GET /api/workspaces/:workspaceId` when routing directly to a known workspace board.
- [ ] Navigate directly to the workspace board when an imported workspace already exists.
- [ ] Add repository input and GitHub PAT fields.
- [ ] Submit to `POST /api/workspaces` through the API client.
- [ ] Keep PAT only in transient component/provider state.
- [ ] Clear PAT on failure reset, unmount, disconnect, or explicit credential reset.
- [ ] Render access denied, missing workflow YAML, clone/sync failure, and generic import errors.
- [ ] Navigate to the workspace board after successful import.
- [ ] Browser-check the connect flow against the Figma frame.
- [ ] Verify PAT is not present in localStorage/sessionStorage.

## T6 — Frontend board and task tracking panel

### Description

Implement the workspace detail board in `digital-factory-ui` using backend-provided workflow data. This task owns the Figma-backed Kanban board, expandable feature rows, task cards, left-side task tracking panel for `IN PROGRESS`, `READY`, and `IN REVIEW`, search/filter state, and task-detail opening behavior.

### Required skills

- frontend-engineer
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma

- Workspace detail page Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=71-85&t=xHuTHtgkwgQhVAcT-0
- Task tracking panel Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=71-2&t=xHuTHtgkwgQhVAcT-0
- Task detail Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=62-3276&t=dBztH5XSYbZ9jPyR-0

### Subtasks

- [ ] Read the Workspace detail, Task tracking panel, and Task detail Figma frames through Figma API/MCP using local `FIGMA_ACCESS_TOKEN`; fallback to checked-in design screenshots if unavailable.
- [ ] Implement `KanbanBoard` compound components.
- [ ] Render feature rows across all workflow task statuses.
- [ ] Implement search and task status filtering.
- [ ] Implement `TaskTrackingPanel` compound components.
- [ ] Group tracking-panel tasks by `IN PROGRESS`, `READY`, and `IN REVIEW`.
- [ ] Show elapsed-time labels from backend DTOs.
- [ ] Open the shared task detail sheet from both task cards and tracking-panel task items.
- [ ] Preserve empty, loading, error, and sync-refresh states.
- [ ] Browser-check the board and tracking panel against Figma.

## T7 — Backend tests, security checks, and sync hardening

### Description

Harden the backend implementation in `workflow-backend` before cross-repo QA. This task adds focused tests around transient credential safety, sync behavior, parser behavior, and DTO redaction so the frontend can rely on stable contracts and safe token handling.

### Required skills

- backend-engineer
- nestjs-best-practices
- postgres-best-practices
- typescript-best-practices

### Subtasks

- [ ] Add tests for PAT-required import behavior.
- [ ] Add tests for existing workspace lookup and cache-based board access without PAT.
- [ ] Add tests for workspace detail lookup by id without PAT.
- [ ] Add tests that API responses never expose PAT values.
- [ ] Add tests that Prisma models, sync history, errors, and logs never persist PAT values.
- [ ] Add tests for clone/sync success and failure paths.
- [ ] Add parser fixture tests for feature/task YAML.
- [ ] Add tests for elapsed-time derivation for `in_progress`, `ready`, and `in_review`.
- [ ] Validate Prisma migration against Supabase/Postgres test environment.
- [ ] Document required backend environment variables.

## T8 — End-to-end QA and release handoff

### Description

Validate the completed frontend/backend dashboard flow and prepare handoff evidence in the management repo. This task does not approve the feature; it captures test results, environment requirements, known limitations, and any deviations from the product spec or Figma frames for human review.

### Required skills

- browser-qa-frontend
- frontend-engineer
- backend-engineer

### Subtasks

- [ ] Run backend tests and record results.
- [ ] Run frontend typecheck/build and record results.
- [ ] Start backend and frontend locally with documented environment variables.
- [ ] Import a test management repository using a GitHub PAT.
- [ ] Reopen the app and verify the existing board loads without re-importing or re-entering PAT.
- [ ] Verify PAT is not persisted in browser storage, backend database rows, or returned by APIs.
- [ ] Verify board renders real feature/task YAML data.
- [ ] Verify manual sync refreshes board state.
- [ ] Verify left-side task tracking panel rows and elapsed-time labels.
- [ ] Verify task detail sheet opens from Kanban cards and tracking-panel items.
- [ ] Capture Figma deviations or product-spec deviations.
- [ ] Write handoff evidence under `docs/features/dashboard/handoffs/`.
