# Technical Design

## Feature

- Feature ID: `dashboard`
- Title: `Workflow Dashboard Web`

## Figma

| Figma reference | Covers |
|---|---|
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=62-3198&t=dBztH5XSYbZ9jPyR-0 | Workspace connect / import screen |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=71-85&t=xHuTHtgkwgQhVAcT-0 | Workspace detail Kanban board |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=71-2&t=xHuTHtgkwgQhVAcT-0 | Left-side task tracking panel |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=62-3276&t=dBztH5XSYbZ9jPyR-0 | Task detail sheet |

Implementation tasks that touch these UI surfaces must include matching `### Figma` subsections. If `FIGMA_ACCESS_TOKEN` is set in the local tooling environment, agents must read design context through the Figma API/MCP before writing UI code. `FIGMA_ACCESS_TOKEN` is a local implementation-tooling secret only — never commit it, never expose it in frontend runtime config.

---

## 1. Current State

The `digital-factory-ui` repo is a React + Vite application with TanStack Router. The `main` branch is expected to be empty or minimal. The `dev` branch contains an existing prototype with working UI foundations:

- Demo login/auth flow using `localStorage.isLoggedIn`.
- Workspace list and import screen — parses a repository URL and stores it in `localStorage.workspaces`.
- Kanban board (`KanbanBoard.tsx`) that shows hardcoded sample features and tasks.
- Task detail sheet (`TaskDetailSheet.tsx`) wired to sample task data.
- Route fallbacks: 404 and error boundary.
- Shared UI primitives under `src/components/ui`.

**Agent instruction:** Before starting implementation, check out the `dev` branch to inspect existing code. Low-level primitives (`src/components/ui` — Button, Input, Badge, etc.), the TanStack Router setup, `tailwind.config`, and `src/styles.css` design tokens may be worth carrying forward. High-level components (`KanbanBoard.tsx`, `TaskDetailSheet.tsx`, route files) are replaced by Figma-aligned new components and should not be reused as-is.

Limitations that block real usefulness:

- Board data is hardcoded sample data — no real YAML is loaded.
- Workspace import stores a URL string but never fetches anything from GitHub.
- The login/workspace-list flow is a demo and does not match the product spec's no-login, connect-first journey.
- The existing high-level components (`KanbanBoard.tsx`, `TaskDetailSheet.tsx`, workspace list/import) do not match the Figma design and will be replaced entirely. The low-level primitives under `src/components/ui` (Button, Input, Badge, etc.) and TanStack Router routing infrastructure may be retained where they fit the new design.

The `workflow-backend` repo exists but is **not required by this design**. All data access is browser-side.

---

## 2. Problem Framing

### What must change

- Replace the demo login + workspace-list flow with a single **connect screen** where the user provides a GitHub `owner/repo` and optional PAT.
- Persist the workspace identity and PAT in `localStorage` keyed by workspace ID so the board opens immediately on return visits.
- Add a **GitHub Contents API client** that fetches feature and task YAML from the connected repository.
- Add a **YAML parser** that decodes base64 GitHub API responses into typed feature/task objects.
- Wire the board to real parsed data — no more hardcoded sample features.
- Add a **left-side task tracking panel** for `IN PROGRESS`, `READY`, and `IN REVIEW` tasks with elapsed-time labels.
- Add a **Sync button** that re-fetches the GitHub Contents API and refreshes the board.
- Show clear error states: access denied, no workflow YAML found, parse failures.

### What must remain stable

- No task/status mutations from the UI — the connected repo is read-only.
- No user account system — repository credential is the only gate.
- No drag-and-drop Kanban mutations.
- No real-time sync — sync-on-load plus manual sync is sufficient.
- Figma frames are the visual source of truth for all screens.

### Fixed assumptions

- GitHub is the only repository provider for v1.
- The app calls `https://api.github.com` directly from the browser — no backend proxy.
- PAT is stored in `localStorage` — this is an accepted tradeoff for an internal alpha.
- The workflow YAML structure follows `docs/features/<featureId>/status.yaml` and `docs/features/<featureId>/tasks/T<n>.yaml`.
- Task YAML `title` field is present (tech-lead generates it; see task generation rules).
- Only one workspace is supported per browser profile in v1.

---

## 3. Options Considered

### Option A — Minimal service layer, adapt existing components

Add new service files (`github.ts`, `workspace-store.ts`, `yaml-parser.ts`) and a data loading hook, then adapt existing high-level components to consume real data.

**Pros**
- Smallest diff if existing components can be reused.

**Cons**
- The Figma design is a complete UI replacement — existing `KanbanBoard.tsx`, `TaskDetailSheet.tsx`, and route components do not match the new design and cannot be adapted in place.
- Forces agents to work around legacy component shape while building a new UI, increasing complexity.
- The main advantage of Option A (reuse existing UI) does not apply here.

**Implementation impact:** Medium-high despite the "minimal" label — old components must be replaced anyway, so the diff size is similar to Option B but with worse structure.

**Dependency impact:** Adds `yaml` npm package.

### Option B — Feature-folder compound components with Provider/Context

Build new UI from Figma using feature modules (`workspaces`, `board`, `tasks`, `errors`), each owning a Provider/Context, compound component API, and service layer. Reuse low-level primitives and routing infrastructure from `dev` branch.

**Pros**
- Since the UI is rebuilt from scratch anyway, choosing a clean structure costs nothing extra.
- Feature modules give clear file ownership — important when multiple tasks run in parallel (T4/T5/T6 can each own distinct directories without write conflicts).
- Provider/Context boundaries isolate board state, connect state, and task detail state cleanly.
- Creates the right seams for future improvements (multi-workspace, backend sync).

**Cons**
- Requires naming discipline and strict feature boundaries during implementation.

**Implementation impact:** Moderate. New feature folders, providers, and compound components. Low-level primitives and router setup carried from `dev` branch.

**Dependency impact:** Adds `yaml` npm package for YAML parsing.

---

## 4. Chosen Design

**Chosen approach: Option B — feature-folder compound components with Provider/Context.**

The Figma design replaces the existing UI entirely, so there is no existing board to preserve. Since the UI is being rebuilt from scratch regardless, choosing a clean feature-folder structure costs nothing extra and gives better parallel-execution properties: T4 (board), T5 (left panel), and T6 (task detail) can each own separate feature directories with no git write contention between them. Low-level primitives and routing setup are carried from the `dev` branch.

### Proposed folder structure

```
src/
  app/
    providers/
      AppProviders.tsx      ← root provider composition
  components/
    ui/                     ← carried from dev branch (Button, Input, Badge, etc.)
  features/
    workspaces/
      components/
        ConnectForm/
          index.tsx
          ConnectForm.tsx
          ConnectForm.context.tsx
      services/
        workspace-store.ts  ← localStorage read/write
      index.ts
    board/
      components/
        KanbanBoard/
          index.tsx
          KanbanBoard.tsx
          KanbanBoard.context.tsx
        FeatureRow/
          index.tsx
        TaskCard/
          index.tsx
        TaskTrackingPanel/
          index.tsx
          TaskTrackingPanel.tsx
      hooks/
        useBoardData.ts     ← GitHub API calls + YAML parsing + board state
      index.ts
    tasks/
      components/
        TaskDetailSheet/
          index.tsx
          TaskDetailSheet.tsx
      index.ts
    errors/
      components/
        ErrorScreen/
          index.tsx
      index.ts
  services/
    github.ts               ← GitHub Contents API client
    yaml-parser.ts          ← YAML decode + typed board objects
  routes/
    __root.tsx
    index.tsx               ← redirect: /connect or /board
    connect.tsx             ← ConnectForm page shell
    board.tsx               ← KanbanBoard + TaskTrackingPanel shell
  styles.css                ← carried from dev branch
```

### localStorage schema

```ts
// Key: "dashboard:workspace"
type StoredWorkspace = {
  id: string           // UUID generated at connect time
  owner: string        // parsed from user input
  repo: string         // parsed from user input
  name: string         // derived display name (= repo)
  isPrivate: boolean   // true when PAT was provided
  pat?: string         // stored for private repos (alpha tradeoff)
  connectedAt: string  // ISO timestamp
}
```

### GitHub Contents API client (`src/services/github.ts`)

Wraps `https://api.github.com`. Sends `Authorization: Bearer {pat}` when PAT is present.

Key methods:

```ts
async listDirectory(path: string): Promise<GitHubEntry[]>
// GET /repos/{owner}/{repo}/contents/{path}
// Returns array of { name, path, type: "file" | "dir", sha }

async getFileContent(path: string): Promise<string>
// GET /repos/{owner}/{repo}/contents/{path}
// Returns decoded UTF-8 content (atob base64 from response.content)
```

Rate limits: 60 req/hr unauthenticated, 5000/hr with PAT. For a typical workspace with ~20 features and ~100 tasks, one load makes roughly 2 + 20 + 100 = 122 requests — well within the authenticated limit, but unauthenticated load of large repos may hit the ceiling. A single `GET /repos/{owner}/{repo}/git/trees/{sha}?recursive=1` call can retrieve the full file tree in one request as a later optimisation.

Error mapping:

| HTTP status | Displayed error |
|---|---|
| 401 / 403 | "Access denied. Check your PAT or repository visibility." |
| 404 on `docs/features` | "No workflow data found in this repository." |
| Other 4xx / 5xx | "GitHub API error. Try again." |

### YAML parser (`src/services/yaml-parser.ts`)

Uses the `yaml` npm package. Parses `status.yaml` and task YAML into typed objects.

```ts
type ParsedFeature = {
  id: string
  title: string
  featureStatus: string
  tasks: ParsedTask[]
}

type ParsedTask = {
  id: string
  title: string
  status: string
  dependsOn: string[]
  execution?: { actor_type: string }
  branch?: string
  pr?: { url?: string; status?: string; workspace_pr?: { url?: string; status?: string } }
  blockedReason?: string
  log?: Array<{ action: string; by: string; at: string; note?: string }>
}
```

Malformed YAML files are skipped with a console warning; they do not crash the board.

### Workspace storage service (`src/services/workspace-store.ts`)

Thin wrapper over `localStorage`:

```ts
getWorkspace(): StoredWorkspace | null
saveWorkspace(w: StoredWorkspace): void
clearWorkspace(): void
```

### Board data hook (`src/hooks/useBoardData.ts`)

```ts
function useBoardData(workspace: StoredWorkspace): {
  features: ParsedFeature[]
  loading: boolean
  error: string | null
  reload: () => void
}
```

On call: lists `docs/features/`, fetches all `status.yaml` and `tasks/T*.yaml` files in parallel batches, parses YAML, and returns typed feature/task state.

### Routing changes

| Route | Before | After |
|---|---|---|
| `/` | Checks `localStorage.isLoggedIn`, redirects | Checks `StoredWorkspace` in `localStorage`, redirects to `/board` or `/connect` |
| `/login` | Demo login form | Replaced by `/connect` |
| `/connect` | (new) | Repository connect form: `owner/repo` input + optional PAT, validates with a test API call, saves to `localStorage`, navigates to `/board` |
| `/workspaces` | Workspace list + import | Removed (one workspace per profile in v1) |
| `/board` | Kanban board (sample data) | Kanban board + left panel (real data via `useBoardData`) |

### Left-side task tracking panel

Renders three rows: `IN PROGRESS`, `READY`, `IN REVIEW`.

Each row filters all tasks (across all features) by `task.status`. Each task item shows:
- Task title
- Parent feature name
- Elapsed time since the task last entered its current status

Elapsed time computation: scan `task.log` for the most recent entry whose `action` matches the current status (e.g., `in_progress`, `ready`, `in_review`, `moved_to_review`). Compute `Date.now() - new Date(logEntry.at).getTime()`. Format as `Xh Ym` or `Xd Yh`. If no matching log entry exists, show `—`.

### Sync button

Mounted in the board header. Calls `reload()` from `useBoardData`. Shows a loading spinner during re-fetch. Re-uses the PAT from `localStorage`.

### Connect screen

Parses user input as:
1. `owner/repo` short form.
2. `https://github.com/owner/repo` full HTTPS URL.
3. `git@github.com:owner/repo.git` SSH form.

Validates by calling `GET /repos/{owner}/{repo}` (unauthenticated first; if 404 and PAT provided, retries with PAT). On 401/403, shows "Access denied." On success, saves to `localStorage` and navigates to `/board`.

### Compatibility

- Existing `localStorage.workspaces` and `localStorage.isLoggedIn` keys are ignored and left untouched.
- The board route is renamed from `/workspaces/:workspaceId` to `/board` to match the single-workspace v1 model.

---

## 5. Dependency Analysis

| Dependency | Type | Status | Notes |
|---|---|---|---|
| React + Vite | Frontend stack | Resolved | Existing in `digital-factory-ui`. |
| TanStack Router | Routing | Resolved | Existing; routes `/connect` and `/board` need adding. |
| `yaml` npm package | YAML parsing | Needs install | Add to `package.json`. Alternatively `js-yaml` — both are small and actively maintained. |
| GitHub Contents API | Data source | Resolved | Public API; no registration required. |
| GitHub PAT | Runtime credential | User-provided | Only required for private repos. Stored in `localStorage`. |
| Figma frames | UI source of truth | Resolved | Links provided in product spec; `FIGMA_ACCESS_TOKEN` is optional local tooling secret. |
| `docs/features` YAML layout | Data contract | Resolved | Parser targets `status.yaml` + `tasks/T<n>.yaml`. |

No unresolved blocking dependencies.

---

## 6. Parallelization / Blocking Analysis

```
T1: Connect screen + localStorage service + routing — digital-factory-ui
  └── Can begin now — no blockers

T2: GitHub Contents API client + YAML parser — digital-factory-ui
  └── Can begin now — no blockers
  └── T1 and T2 run in parallel

  T3: Board data loading hook + sync button — digital-factory-ui
    └── BLOCKED on T1 (connect screen must exist so routing to /board is wired)
    └── BLOCKED on T2 (GitHub client and YAML parser must be in place for real data)
    │
    T4: Kanban board wired to real data — digital-factory-ui
    T5: Left task tracking panel — digital-factory-ui
    T6: Task detail sheet with real data — digital-factory-ui
      └── T4, T5, T6 run in parallel
      └── BLOCKED on T3 (parsed feature/task data and elapsed-time helpers must be available)
      └── T4 and T5 must not mutate the same component files to avoid git conflicts
      │
      T7: Error states, empty states, end-to-end QA — digital-factory-ui
        └── BLOCKED on T4 (board must render real data)
        └── BLOCKED on T5 (left panel must be implemented)
        └── BLOCKED on T6 (task detail must use real data)
```

Parallelization summary:

- T1 and T2 start immediately and run in parallel (independent files).
- T3 follows T1 and T2.
- T4, T5, T6 run in parallel after T3; each owns distinct files so there is no write contention.
- T7 is the final QA and validation pass and waits for T4, T5, T6.

---

## 7. Repository Impact

| Repo ID | Impact |
|---|---|
| `digital-factory-ui` | All implementation work: GitHub API client, YAML parser, localStorage service, connect screen, board data hook, routing changes, left panel, real-data board wiring, error states, sync button. |
| `management-repo` | Holds this feature plan and final handoff evidence only. No runtime code. |

No changes planned for `workflow-backend`, `workflow`, or `rag-service`.

---

## 8. Validation and Release Impact

**Testing expectations:**

- Typecheck and production build must pass.
- Unit tests for:
  - `github.ts` — input parsing, auth header presence, error mapping (mock `fetch`).
  - `yaml-parser.ts` — valid YAML, malformed YAML skip, missing optional fields, missing log entries.
  - `workspace-store.ts` — save, load, and clear round-trip.
  - `useBoardData` — loading state, success state, error state (mock GitHub client).
  - Elapsed-time computation — known timestamps to expected formatted strings.
- Browser QA for: connect screen (public repo, private repo, invalid PAT, invalid URL), board load, left panel, sync button, task detail sheet, 404, error boundary.

**Migration / config impact:**

- Add `yaml` (or `js-yaml`) to `package.json`.
- No backend configuration required.
- Existing `localStorage.workspaces` and `localStorage.isLoggedIn` keys are ignored — no migration needed.

**Rollout concerns:**

- Rate limiting: unauthenticated repos with many features/tasks may approach the 60 req/hr ceiling. Mitigate by prompting users to add a PAT. A future optimisation can replace per-file fetches with a single Git Tree API call.
- PAT in `localStorage`: documented as an alpha tradeoff. If the product grows to external users, replace with a secure backend token store in a later feature.

**Backward compatibility:**

- Existing demo/sample data is removed. There is no production user base to migrate.
- Route `/workspaces` and `/login` are removed or redirected; no external links to preserve.

**Handoff implications:**

- No backend deployment required — pure frontend release.
- Browser QA and Figma fidelity check are required before handoff approval.
- Known v1 limitation: only one workspace per browser profile; PAT stored in `localStorage`.
