# Technical Design

## Feature
- Feature ID: `dashboard`
- Title: `Workflow Dashboard Web`

## Figma

The product spec includes Figma links. These links are design contracts for downstream UI implementation tasks.

| Figma reference | Covers |
|---|---|
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=14-2&t=l6DiKoWXEtl6DNSM-0 | Login page |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=34-490&t=l6DiKoWXEtl6DNSM-0 | Workspace list and repository import |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=34-537&t=l6DiKoWXEtl6DNSM-0 | Workspace detail Kanban board |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=35-752&t=l6DiKoWXEtl6DNSM-0 | Status filter dropdown |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=36-935&t=l6DiKoWXEtl6DNSM-0 | Workspace switcher dropdown |
| https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=36-1108&t=l6DiKoWXEtl6DNSM-0 | Task detail sheet |

Implementation tasks that touch these UI surfaces must include matching `### Figma` subsections in `tasks.md`. If `FIGMA_PERSONAL_ACCESS_TOKEN` is unavailable during implementation, those tasks must block rather than guess visual details.

## Current State

The dashboard application described by the product spec is a React + Vite frontend using TanStack Router. It currently has local demo authentication, local workspace storage, a workspace list/import screen, a workspace detail Kanban board, a task detail sheet, route-level fallback states, and reusable UI primitives under `src/components/ui`.

Current implementation shape:

- Routes currently own substantial UI and workflow state directly.
- Board behavior is concentrated in `src/components/KanbanBoard.tsx`.
- Task sheet behavior lives in `src/components/TaskDetailSheet.tsx`.
- Workspace persistence lives in `src/lib/workspaces.ts`.
- Auth persistence lives in `src/lib/auth.ts`.
- Chat components exist but are not mounted.

Current data boundaries:

- Auth state is local-only through `localStorage.isLoggedIn`.
- Workspace state is local-only through `localStorage.workspaces`.
- Repository import parses and stores repository metadata only; it does not clone, sync, or call a backend.
- Board feature and task data is sample data in the frontend.
- Toast calls may not render visibly until the root app mounts a toaster.

Current workspace/repo constraints:

- `workspace.yaml` declares `dashboard` as the frontend implementation repo id.
- The implementation repository is `git@github.com:Kadamato/dashboard.git`.
- `.env` points `DASHBOARD_UI_LOCAL_PATH` to `/home/kadamato/Documents/dashboard`.
- `/home/kadamato/Documents/dashboard` exists locally and is currently an empty git checkout with no React/Vite app files.
- Future task YAML must use `repo: dashboard`.

## Problem Framing

The product needs a stable React + Vite architecture before implementation continues. The current UI works as a prototype, but route files and large components hold too much state and behavior. Adding private repository import, an `Add workspace` modal, shared validation, workspace switching, and future real data loading will become brittle if state stays scattered across routes and monolithic components.

The implementation must change:

- Use React + Vite as the explicit frontend stack.
- Keep TanStack Router for routing.
- Move routes toward thin composition shells.
- Introduce feature folders with compound components.
- Hide feature logic inside Provider/Context instead of pushing state into every UI part.
- Expose declarative compound APIs using direct root attachment such as `WorkspaceImport.Root = Root` and `WorkspaceImport.TokenField = TokenField`; do not introduce a generic compound helper factory.
- Add private repository import UI and validation.
- Share import behavior between the `/workspaces` import card and the board `Add workspace` modal.
- Add the board `Add workspace` modal with enabled `Import repository` and disabled `Create workspace`.
- Preserve existing login, workspace list, board, filter, switcher, task sheet, 404, and error boundary behavior.

The implementation must not change:

- No real backend API is added in this scope.
- No repository clone or Git provider sync is added in this scope.
- No real authentication is added in this scope.
- No Kanban drag/drop or task mutation is added in this scope.
- No create/edit/delete feature or task workflow is added in this scope.
- No raw GitHub personal access token is persisted in browser storage.

Fixed assumptions:

- This is a frontend-only local behavior update unless a later approved feature introduces backend-backed sync.
- Workspace imports continue to create local workspace records.
- Private repository mode records safe metadata only, such as `privateRepository: true` and `tokenConfigured: true`.
- Figma frames are the visual source of truth for UI implementation.

## Options Considered

### Option A: Route-level state with shared utility functions

Keep route and component ownership close to the current app. Extract import validation and parsing into shared utility functions, then update the existing routes and board component directly.

Pros:

- Smallest immediate diff.
- Fast to implement for the private repository switch.
- Does not require a larger folder refactor.

Cons:

- Keeps `KanbanBoard.tsx` and route files too large.
- Duplicates interaction state across workspace list and modal flows.
- Makes future real data loading harder because UI parts stay coupled to storage details.
- Does not satisfy the requested compound/provider/context architecture.

Implementation impact:

- Low immediate effort, but more future churn.

Dependency impact:

- No additional dependencies.

### Option B: Feature-based compound components with Provider/Context

Refactor the React + Vite app into feature folders. Each substantial workflow surface owns a Provider/Context for behavior and exposes compound UI parts for composition. Routes become thin shells that assemble feature page components.

Pros:

- Matches the requested architecture.
- Keeps component UI small and declarative.
- Hides logic inside feature providers and hooks.
- Makes shared flows like repository import reusable between page card and modal.
- Creates clear seams for later backend-backed workspace data.
- Limits rerender scope by splitting auth, workspace, import, board, and task-detail state.

Cons:

- Larger refactor than a utility-only patch.
- Requires careful migration so existing UX does not regress.
- Requires naming discipline and strict feature boundaries.

Implementation impact:

- Moderate. Requires moving files, adding providers/hooks, and rewriting route composition.

Dependency impact:

- No new runtime state library is required.
- Depends on React Context, existing TanStack Router, existing UI primitives, and Figma access for visual fidelity.

### Option C: Global state library first

Introduce a global state library for auth, workspaces, board filters, selected task, modal state, and import state.

Pros:

- Centralized state can simplify cross-page reads.
- May help if the app later needs complex server cache integration.

Cons:

- Unnecessary for the current local-only scope.
- Adds a dependency before real backend data exists.
- Can make feature logic less encapsulated if used as an app-wide store.
- Does not naturally produce the requested compound component API.

Implementation impact:

- Medium to high, plus future migration risk.

Dependency impact:

- Adds package/dependency review and state architecture decisions outside current scope.

## Chosen Design

Choose Option B: feature-based compound components with Provider/Context.

The dashboard will remain a React + Vite application with TanStack Router. The implementation should reorganize UI into feature modules and keep route files thin. Each feature module owns:

- Domain types.
- Local storage or sample-data adapters.
- Provider/Context state.
- Hooks for feature behavior.
- Compound UI components.
- A public `index.ts` or `index.tsx` API.

Compound component rule:

- Use explicit, manual root attachment.
- Do not use a generic `createCompoundComponent()` helper.
- Keep UI parts small.
- Hide state transitions and localStorage writes inside providers/hooks.

Example shape:

```tsx
function WorkspaceImportRoot(props: WorkspaceImportRootProps) {
  return (
    <WorkspaceImportProvider {...props}>
      <WorkspaceImportLayout>{props.children}</WorkspaceImportLayout>
    </WorkspaceImportProvider>
  )
}

function UrlField() {
  const { url, setUrl, importing, clearError } = useWorkspaceImport()
  return <input value={url} disabled={importing} onChange={...} />
}

export const WorkspaceImport = WorkspaceImportRoot as typeof WorkspaceImportRoot & {
  UrlField: typeof UrlField
  PrivateRepositorySwitch: typeof PrivateRepositorySwitch
  TokenField: typeof TokenField
  SubmitButton: typeof SubmitButton
  ErrorMessage: typeof ErrorMessage
}

WorkspaceImport.UrlField = UrlField
WorkspaceImport.PrivateRepositorySwitch = PrivateRepositorySwitch
WorkspaceImport.TokenField = TokenField
WorkspaceImport.SubmitButton = SubmitButton
WorkspaceImport.ErrorMessage = ErrorMessage
```

The route/page can then compose:

```tsx
<WorkspaceImport.Root onImported={handleImported}>
  <WorkspaceImport.UrlField />
  <WorkspaceImport.PrivateRepositorySwitch />
  <WorkspaceImport.TokenField />
  <WorkspaceImport.ErrorMessage />
  <WorkspaceImport.SubmitButton />
</WorkspaceImport.Root>
```

### Proposed Folder Structure

```text
src/
  app/
    providers/
      AppProviders.tsx
    routing/
      RouterProvider.tsx
  components/
    ui/
      ...
  features/
    auth/
      components/
        LoginForm/
          index.tsx
          LoginForm.tsx
          LoginForm.context.tsx
      hooks/
        useAuth.ts
      model/
        auth.types.ts
      services/
        auth.storage.ts
      index.ts
    workspaces/
      components/
        WorkspaceList/
          index.tsx
          WorkspaceList.tsx
          WorkspaceList.context.tsx
        WorkspaceCard/
          index.tsx
        WorkspaceSwitcher/
          index.tsx
          WorkspaceSwitcher.tsx
          WorkspaceSwitcher.context.tsx
        WorkspaceImport/
          index.tsx
          WorkspaceImport.tsx
          WorkspaceImport.context.tsx
        AddWorkspaceModal/
          index.tsx
          AddWorkspaceModal.tsx
          AddWorkspaceModal.context.tsx
      hooks/
        useWorkspaces.ts
        useWorkspaceImport.ts
      model/
        workspace.types.ts
        workspace-import.types.ts
      services/
        workspace.storage.ts
        workspace-import.service.ts
      index.ts
    board/
      components/
        KanbanBoard/
          index.tsx
          KanbanBoard.tsx
          KanbanBoard.context.tsx
        BoardHeader/
          index.tsx
        StatusFilter/
          index.tsx
          StatusFilter.context.tsx
        FeatureRow/
          index.tsx
        SegmentBar/
          index.tsx
      hooks/
        useBoardFilters.ts
        useFeatureRows.ts
      model/
        board.types.ts
        sample-features.ts
      index.ts
    tasks/
      components/
        TaskCard/
          index.tsx
        TaskDetailSheet/
          index.tsx
          TaskDetailSheet.tsx
          TaskDetailSheet.context.tsx
      model/
        task.types.ts
      index.ts
    errors/
      components/
        NotFoundScreen/
          index.tsx
        ErrorBoundaryScreen/
          index.tsx
      index.ts
  lib/
    storage/
      safe-local-storage.ts
    utils.ts
  routes/
    __root.tsx
    index.tsx
    login.tsx
    workspaces/
      index.tsx
      $workspaceId.tsx
  styles.css
```

### Provider / Context Design

`AppProviders`

- Owns app-wide provider composition only.
- Should not own feature-specific business logic.
- May mount toaster support if the existing app needs visible `toast.success()` behavior.

`AuthProvider`

- Owns demo auth state.
- Wraps `localStorage.isLoggedIn` reads/writes.
- Exposes `isLoggedIn`, `login()`, and `logout()`.

`WorkspacesProvider`

- Owns workspace list state and seed behavior.
- Wraps `localStorage.workspaces`.
- Exposes `workspaces`, `getWorkspace(id)`, `addWorkspace(input)`, `removeWorkspace(id)`.
- Preserves existing seeded defaults.

`WorkspaceImportProvider`

- Owns import form state: `url`, `privateRepository`, `token`, `error`, `importing`.
- Exposes `submit()`, `reset()`, and field setters.
- Uses `workspace-import.service.ts` for validation and workspace creation payloads.
- Clears token after successful import, modal close, or private switch off.
- Never writes raw token to `localStorage`.

`BoardProvider`

- Owns workspace-specific board UI state: search query, selected status filters, expanded feature ids, selected task, open dropdown/modal state.
- Reads workspace identity from `WorkspacesProvider`.
- Reads sample board data from `features/board/model/sample-features.ts` until real data loading is designed.

`TaskDetailProvider`

- Owns selected task sheet state if task detail behavior becomes too large for `BoardProvider`.
- Can remain colocated with `BoardProvider` if state remains small.

### Import Safety Design

Workspace import creates local records only. The import service should return a safe payload:

```ts
type CreateWorkspaceInput = {
  repositoryUrl: string
  privateRepository: boolean
  tokenConfigured: boolean
}
```

The raw token may exist only inside transient React state before submit. It must not be:

- Stored in `localStorage`.
- Included in workspace cards.
- Added to route params.
- Logged to console.
- Written into task metadata.

When `privateRepository` is false:

- Hide the token field.
- Clear token and token error.
- Save no private metadata or save `privateRepository: false` consistently with existing workspace type decisions.

When `privateRepository` is true:

- Require non-empty token.
- Accept both classic `ghp_...` and fine-grained `github_pat_...` token shapes by validating only non-empty value in this scope.
- Persist only `privateRepository: true` and `tokenConfigured: true`.

### Route Composition Design

Routes should become thin:

- `/` handles redirect only.
- `/login` renders `LoginPage` or `LoginForm` from `features/auth`.
- `/workspaces` renders `WorkspacesPage` composed from `WorkspaceList`, `WorkspaceImport`, and sign-out action.
- `/workspaces/:workspaceId` renders `WorkspaceBoardPage` composed from `KanbanBoard`, `WorkspaceSwitcher`, `StatusFilter`, `FeatureRow`, and `TaskDetailSheet`.

Route files should not own import validation, workspace parsing, filter counting, or task sheet formatting logic. Those belong in feature services/providers/hooks.

Affected repositories:

- Implementation repo: `dashboard`.
- Management repo: `management-repo` stores this design and future task state only.

Compatibility considerations:

- Existing workspace records without `privateRepository` or `tokenConfigured` must continue to load.
- Imported public workspaces should not gain private metadata unless a default value is intentionally added.
- Existing duplicate detection by exact repository URL must continue to work.
- Existing workspace cards must not reveal tokens or imply token storage.
- Existing redirects, local auth, sample Kanban data, dropdowns, sheet behavior, and fallback screens must remain compatible.
- Existing public component behavior should be preserved while internals move behind providers.

Operational and release implications:

- This is a frontend-only release once the implementation repo is resolved.
- No data migration is required for existing localStorage records.
- Users who enable private repository mode should understand that this is local demo metadata until backend sync exists.

## Dependency Analysis

Internal dependencies:

- `src/lib/workspaces.ts` logic should move or be wrapped by `features/workspaces/services/workspace.storage.ts`.
- `src/lib/auth.ts` logic should move or be wrapped by `features/auth/services/auth.storage.ts`.
- `src/routes/workspaces/index.tsx` should become a thin route that composes `WorkspacesPage`.
- `src/components/KanbanBoard.tsx` should be split into `features/board` compound components and providers.
- `src/components/TaskDetailSheet.tsx` should move under `features/tasks/components/TaskDetailSheet`.
- Shared visual tokens in `src/styles.css` remain the source for colors and surfaces.
- `src/components/ui` remains the shared primitive layer and should not own feature state.

External dependencies:

- D1: Dashboard repo scaffold. The repo id is now resolved as `dashboard`; the local repo is empty and needs the React/Vite app scaffold before feature modules can be implemented.
- D2: Figma access. Product spec includes Figma links. If implementation tasks include `### Figma` and `FIGMA_PERSONAL_ACCESS_TOKEN` is missing, implementation must block rather than guess visual values.
- D3: GitHub personal access token behavior. In this scope, tokens are user input for validation only and are not persisted.

Blocking decisions:

- Implementation tasks can use `repo: dashboard`.
- Feature UI tasks that depend on app files must wait until the React/Vite scaffold exists in the dashboard repo.
- Figma-backed UI tasks cannot start without either Figma MCP access or an explicit human decision to defer strict Figma reading.

Vendor/tooling choices:

- React + Vite is the app stack.
- TanStack Router remains the routing layer.
- React Context is the state-sharing mechanism for local feature state.
- Existing UI primitives and lucide icons remain preferred.
- Do not introduce Redux, Zustand, Jotai, or another global state library for this scope.
- Do not introduce a GitHub SDK, backend client, or secret storage library in this scope.

Configuration dependencies:

- `DASHBOARD_UI_LOCAL_PATH` points to `/home/kadamato/Documents/dashboard`.
- The local dashboard repo remote currently uses GitHub HTTPS while `workspace.yaml` declares the SSH URL; align remotes before implementation push if the workflow requires SSH.
- `FIGMA_PERSONAL_ACCESS_TOKEN` is not present in project `.env` during planning inspection.

Release dependencies:

- No backend deployment is required.
- Frontend validation and browser QA are required before PR creation.

## Parallelization / Blocking Analysis

External decisions and dependencies:

```
D1: Dashboard repo app scaffold
  Repo id is resolved as dashboard. Unblock feature work by creating the React/Vite scaffold in /home/kadamato/Documents/dashboard.

D2: Provide Figma access for UI implementation
  Unblock by setting FIGMA_PERSONAL_ACCESS_TOKEN if tasks will enforce Figma MCP reads.
```

Proposed implementation task graph for the next planning phase:

```
T1: React/Vite feature architecture and provider scaffold
  └── Can begin now after tasks approval — repo id dashboard is declared and local path exists
  │
  T2: Workspace domain services and import provider
    └── BLOCKED on T1 (feature folders and provider conventions must exist)
    │
    T3: Workspace list page compound components
      └── BLOCKED on T2 (workspace storage and import provider must be in place)
      └── BLOCKED on D2 (Figma frame for workspace page must be read before UI implementation)
      │
    T4: Board shell, workspace switcher, and Add workspace modal
      └── BLOCKED on T2 (modal import must reuse the shared import provider)
      └── BLOCKED on D2 (Figma frames for workspace detail and switcher must be read before UI implementation)
      └── T3 and T4 can run in parallel after T2
      │
      T5: Kanban feature row, filter, segment bar, and task sheet compounds
        └── BLOCKED on T1 (board provider and compound structure must exist)
        └── BLOCKED on D2 (Figma frames for board, filter, and task detail must be read before UI implementation)
        └── T5 can run in parallel with T3/T4 after T1 if it avoids workspace import files
        │
        T6: Route integration, fallback screens, and toast wiring
          └── BLOCKED on T3 (workspace list route composition must be ready)
          └── BLOCKED on T4 (workspace detail shell and modal must be ready)
          └── BLOCKED on T5 (board/task compounds must be ready)
          │
          T7: End-to-end QA and release handoff
            └── BLOCKED on T6 (routes and providers must be integrated before full QA)
```

Notes:

- T3 and T4 run in parallel after T2 because they touch different entry points but share import behavior.
- T5 can run in parallel with T3/T4 after T1 if it limits edits to board/task component files and does not mutate workspace import provider files.
- T6 waits for the UI branches to converge because route composition and provider nesting must be validated together.
- T7 waits for all implementation tasks because it validates full user flows.

## Repository Impact

`management-repo`:

- Stores `docs/features/dashboard/product-spec.md`, `technical-design.md`, future `tasks.md`, and future task YAML state.
- No implementation code changes belong here.

`dashboard`:

- Declared frontend repo id in `workspace.yaml`.
- GitHub URL: `git@github.com:Kadamato/dashboard.git`.
- Local path env: `DASHBOARD_UI_LOCAL_PATH`.
- Current local path: `/home/kadamato/Documents/dashboard`.
- Future task YAML must use `repo: dashboard`.
- The repo currently needs React/Vite app scaffolding and the feature-based compound/provider structure.

No changes are planned for:

- `workflow`
- `rag-service`

## Validation And Release Impact

Testing expectations:

- Typecheck and build the React + Vite app.
- Unit or component tests for repository URL validation and private token validation if the app has an established test setup.
- Provider-level tests for auth, workspace storage, import form state, and board filters where test tooling exists.
- Browser QA for `/login`, `/workspaces`, `/workspaces/:workspaceId`, status filter dropdown, workspace switcher dropdown, `Add workspace` modal, private repository token field, and task detail sheet.
- Manual localStorage inspection to confirm raw tokens are not persisted.
- Regression checks for duplicate repository URL handling.
- Regression checks for workspace deletion, sign out, route redirects, 404, and error boundary behavior.

Migration and config impact:

- Existing localStorage workspace records must remain valid.
- No backend migration is required.
- No token migration is required because raw tokens are not stored.
- File moves should preserve exported route/component behavior through feature `index.ts` APIs.
- The dashboard repo must be scaffolded before page-level UI tasks can run.

Rollout concerns:

- Private repository UI may imply real private repo access. Copy and behavior must remain clear that current import is local-only.
- Token input must be cleared after successful import, private switch off, or modal close.
- Token values must never appear in workspace cards, task sheets, console logs, URL params, or persisted JSON.
- Refactoring `KanbanBoard.tsx` into compounds is broad enough to require visual regression checks across all existing board states.

Backward compatibility constraints:

- Public repository import flow must remain unchanged when the private switch is off.
- Existing workspace cards and fallback behavior must remain stable.
- Existing sample Kanban feature/task data remains the current board data source.
- Existing route paths must not change.

Deployment and handoff implications:

- This feature can ship as a frontend-only change after implementation repo resolution and browser QA.
- Backend-backed private repository sync should be handled by a separate future feature with secure token storage and provider validation.
