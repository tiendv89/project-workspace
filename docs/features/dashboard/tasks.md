# Tasks — Workflow Dashboard Web

Feature status reference: `ready_for_implementation`; stage status: `tasks/approved`. Machine state lives in `tasks/T<n>.yaml`; this file is narrative only.

## Index

| ID | Wave | Title | Depends on |
|---|---:|---|---|
| T1 | 1 | App scaffold — routing, connect screen, localStorage service | [] |
| T2 | 1 | GitHub Contents API client and YAML parser | [] |
| T3 | 2 | Board data loading hook, BoardProvider, and sync | [T1, T2] |
| T4 | 3 | Kanban board compound components | [T3] |
| T5 | 3 | Left task tracking panel | [T3] |
| T6 | 3 | Task detail sheet | [T3] |
| T7 | 4 | Error states, empty states, and end-to-end QA | [T4, T5, T6] |

---

## T1 — App scaffold — routing, connect screen, localStorage service

### Description

Set up the new application structure in `digital-factory-ui`. This task establishes the routing skeleton, the connect screen (Journey 1 / 1b), and the localStorage workspace service that all later tasks depend on.

Before starting, check out the `dev` branch of `digital-factory-ui` to identify reusable pieces: `src/components/ui` primitives (Button, Input, Badge, etc.), TanStack Router bootstrap, `tailwind.config`, and `src/styles.css` design tokens. Carry those forward; do not carry over `KanbanBoard.tsx`, `TaskDetailSheet.tsx`, or existing route page files.

Specific deliverables:

- `src/services/workspace-store.ts` — `localStorage` wrapper for `StoredWorkspace`:
  ```ts
  type StoredWorkspace = {
    id: string; owner: string; repo: string; name: string
    isPrivate: boolean; pat?: string; connectedAt: string
  }
  getWorkspace(): StoredWorkspace | null
  saveWorkspace(w: StoredWorkspace): void
  clearWorkspace(): void
  ```
- `src/routes/index.tsx` — checks `localStorage` for saved workspace; redirects to `/board` if found, otherwise `/connect`.
- `src/routes/connect.tsx` — thin shell rendering `ConnectForm`.
- `src/routes/board.tsx` — thin shell (board content added in T3–T6).
- `src/features/workspaces/components/ConnectForm/` — connect form compound component:
  - Parses `owner/repo`, `https://github.com/owner/repo`, and `git@github.com:owner/repo.git` formats.
  - PAT field shown when user marks repository as private.
  - On submit: validates input, calls `GET /repos/{owner}/{repo}` as a lightweight access probe, saves to `localStorage`, navigates to `/board`.
  - Inline error for access denied and invalid URL format.
- `src/app/providers/AppProviders.tsx` — root provider composition shell (minimal for now; later tasks add providers).

### Figma

- Connect / import screen: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=62-3198&t=dBztH5XSYbZ9jPyR-0

### Required skills

- frontend-engineer
- figma-mcp
- typescript-best-practices

### Subtasks

- [ ] Check out `dev` branch; copy reusable primitives, router setup, tailwind config, and styles to new scaffold
- [ ] Define `StoredWorkspace` type and implement `workspace-store.ts`
- [ ] Add `/`, `/connect`, `/board` routes with TanStack Router
- [ ] Build `ConnectForm` compound component matching Figma connect screen
- [ ] Implement input parsing for `owner/repo`, HTTPS URL, and SSH URL formats
- [ ] PAT field toggle; GitHub API probe on submit
- [ ] Wire localStorage save and navigate to `/board` on success
- [ ] Inline error for access denied and invalid URL
- [ ] `AppProviders.tsx` shell in place
- [ ] Typecheck passes; dev server loads `/connect`

---

## T2 — GitHub Contents API client and YAML parser

### Description

Implement the two core services that all data-loading work depends on: the GitHub Contents API client and the YAML parser. These are pure service modules with no UI and can be built in parallel with T1.

Deliverables:

- `src/services/github.ts` — GitHub Contents API client:
  - Constructor: `{ owner, repo, pat? }`.
  - `listDirectory(path: string): Promise<GitHubEntry[]>` — `GET /repos/{owner}/{repo}/contents/{path}`, returns `{ name, path, type }[]`.
  - `getFileContent(path: string): Promise<string>` — decodes base64 `response.content` via `atob`.
  - Sends `Authorization: Bearer {pat}` when PAT is present.
  - Error mapping: 401/403 → `GitHubAccessError`, 404 → `GitHubNotFoundError`, other → `GitHubApiError`.

- `src/services/yaml-parser.ts` — YAML parser:
  - Add `yaml` npm package.
  - `parseFeatureStatus(raw: string): FeatureStatusYaml`
  - `parseTaskYaml(id: string, raw: string): ParsedTask | null` — returns `null` and logs a warning for malformed YAML.
  - Exports `ParsedFeature`, `ParsedTask`, `LogEntry` types.

```ts
type ParsedFeature = {
  id: string; title: string; featureStatus: string; tasks: ParsedTask[]
}
type ParsedTask = {
  id: string; title: string; status: string; dependsOn: string[]
  execution?: { actor_type: string }; branch?: string
  pr?: { url?: string; status?: string; workspace_pr?: { url?: string; status?: string } }
  blockedReason?: string; log?: LogEntry[]
}
type LogEntry = { action: string; by: string; at: string; note?: string }
```

Unit tests expected for both services.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Add `yaml` package to `package.json`
- [ ] Implement `github.ts` — `listDirectory` and `getFileContent`
- [ ] Auth header logic (Bearer token when PAT present, unauthenticated otherwise)
- [ ] Map 401/403/404/other HTTP errors to typed error classes
- [ ] Implement `yaml-parser.ts` — `parseFeatureStatus` and `parseTaskYaml`
- [ ] Export `ParsedFeature`, `ParsedTask`, `LogEntry` types
- [ ] Malformed YAML: console.warn and return null
- [ ] Unit tests: github.ts error mapping; yaml-parser valid + malformed + missing-fields cases
- [ ] Typecheck passes

---

## T3 — Board data loading hook, BoardProvider, and sync

### Description

Wire the GitHub client and YAML parser (T2) into a React hook and provider that loads real board data and exposes it to all board UI components. Also adds the sync button to the board shell.

Depends on T1 (routing and workspace storage) and T2 (GitHub client and YAML parser).

Deliverables:

- `src/features/board/hooks/useBoardData.ts`:
  ```ts
  function useBoardData(workspace: StoredWorkspace): {
    features: ParsedFeature[]; loading: boolean
    error: BoardLoadError | null; reload: () => void
  }
  ```
  Fetches `docs/features/` listing, then for each feature directory fetches `status.yaml` + lists `tasks/` + fetches each `T*.yaml`, parses all YAML, returns typed state.

- `src/features/board/components/KanbanBoard/KanbanBoard.context.tsx` — `BoardProvider` / `useBoardContext`. Exposes: `features`, `loading`, `error`, `reload`, `searchQuery`, `setSearchQuery`, `activeFilters`, `setActiveFilters`, `expandedFeatureIds`, `toggleFeature`, `selectedTask`, `setSelectedTask`.

- `src/routes/board.tsx` — wraps board content in `BoardProvider`; reads workspace from `localStorage`; shows error state when `!workspace` (redirects to `/connect`).

- Sync button in board header shell (`src/features/board/components/BoardHeader/`) — calls `reload()`, shows spinner while `loading`.

- `BoardLoadError` discriminated union: `access_denied | not_found | parse_error | network_error`.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Implement `useBoardData` with parallel GitHub API fetches for all features and tasks
- [ ] Handle `docs/features/` listing → per-feature parallel fetches
- [ ] Map GitHub errors to `BoardLoadError` discriminants
- [ ] Implement `BoardProvider` / `useBoardContext` with full board state shape
- [ ] Mount `BoardProvider` in `board.tsx` shell; redirect to `/connect` if no workspace
- [ ] Add `BoardLoadError` discriminated union type
- [ ] Implement `BoardHeader` shell with sync button; spinner on `loading`
- [ ] Unit tests for `useBoardData` (mock GitHub client — loading / success / each error type)
- [ ] Typecheck passes

---

## T4 — Kanban board compound components

### Description

Build the Kanban board UI from the Figma workspace detail board frame. This task owns `src/features/board/components/KanbanBoard/`, `FeatureRow/`, and `TaskCard/`. It consumes `useBoardContext` from T3 — no direct data fetching here. Runs in parallel with T5 and T6 after T3.

Read the Figma workspace detail board frame via Figma MCP before writing any component code. Extract layout, column headers, feature row anatomy, segment bar, and task card anatomy directly from Figma.

Deliverables:

- `KanbanBoard.tsx` — root compound; renders 7 fixed status columns (`TODO`, `READY`, `IN PROGRESS`, `BLOCKED`, `IN REVIEW`, `DONE`, `CANCELLED`); maps features to `FeatureRow` components; applies search and filter from `useBoardContext`.
- `FeatureRow/` — collapsed row (lifecycle pill, progress text, task segment bar) + expanded 7-column task grid with `TaskCard` cells.
- `TaskCard/` — task title with `T{n}` prefix, next-action label for the current status, execution actor badge (agent=purple, human=blue); click sets `selectedTask` in `BoardContext`.
- Compound assembled in `KanbanBoard/index.tsx`.

### Figma

- Workspace detail Kanban board: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=71-85&t=xHuTHtgkwgQhVAcT-0

### Required skills

- frontend-engineer
- figma-mcp
- typescript-best-practices

### Subtasks

- [ ] Read Figma workspace detail board frame via Figma MCP before writing code
- [ ] Implement `KanbanBoard.tsx` — 7 status columns, map features to rows
- [ ] Apply search filter and status filter from `useBoardContext`
- [ ] Implement `FeatureRow` — collapsed (pill, progress, segment bar) and expanded (task grid)
- [ ] Segment bar: one coloured segment per task matching status colour
- [ ] Implement `TaskCard` — title prefix, next-action label, actor badge, click handler
- [ ] Assemble compound exports in `index.tsx`
- [ ] Verify column headers, feature row layout, card shape, and colours match Figma
- [ ] Typecheck passes; board renders real data from a test workspace

---

## T5 — Left task tracking panel

### Description

Build the left-side task tracking panel from the Figma task tracking panel frame. The panel shows three rows: `IN PROGRESS`, `READY`, `IN REVIEW`. Each row lists matching tasks with an elapsed-time label.

This task owns `src/features/board/components/TaskTrackingPanel/`. Runs in parallel with T4 and T6 — distinct directories, no write contention.

Read the Figma task tracking panel frame before writing any component code.

Elapsed-time logic:
- Scan `task.log` for the most recent entry whose `action` matches the current status (`in_progress`, `ready`, `in_review`, or `moved_to_review`).
- `Date.now() - new Date(logEntry.at).getTime()` → format as `Xh Ym` (< 24h) or `Xd Yh`.
- No matching log entry → display `—`.

Place the elapsed-time utility in `src/lib/time.ts` so T6 can reuse it.

Deliverables:

- `TaskTrackingPanel/` compound; reads tasks from `useBoardContext` filtered by status.
- Three rows; per-item: task title, parent feature name, elapsed-time label.
- Click on item sets `selectedTask` in `BoardContext`.
- `src/lib/time.ts` — elapsed-time computation and formatting.

### Figma

- Left-side task tracking panel: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=71-2&t=xHuTHtgkwgQhVAcT-0

### Required skills

- frontend-engineer
- figma-mcp
- typescript-best-practices

### Subtasks

- [ ] Read Figma task tracking panel frame via Figma MCP before writing code
- [ ] Implement elapsed-time utility in `src/lib/time.ts` with unit tests
- [ ] Implement `TaskTrackingPanel` compound — three status rows
- [ ] Filter tasks by status from `useBoardContext`
- [ ] Per-item: task title, feature name, elapsed-time label
- [ ] Click sets `selectedTask` in BoardContext
- [ ] Verify layout, row labels, spacing, and item shape match Figma
- [ ] Typecheck passes

---

## T6 — Task detail sheet

### Description

Build the task detail sheet from the Figma task detail frame. Opens when a task card (T4) or left panel item (T5) is clicked, reading `selectedTask` from `BoardContext`.

This task owns `src/features/tasks/components/TaskDetailSheet/`. Runs in parallel with T4 and T5.

Read the Figma task detail frame before writing any component code.

Deliverables:

- `TaskDetailSheet/` compound; slides in from the right; closes on overlay click or X button; clears `selectedTask`.
- Header: task ID badge, status badge, task title.
- Metadata section: repository, branch, next action, execution actor, `depends_on` badges, blocked reason.
- PR section: workspace PR card and repository PR card; URLs open in new tab; no-URL cards are visually disabled.
- Timeline: renders `task.log` as a vertical activity timeline with status-coloured dots, formatted timestamps (`MMM d, HH:mm`), actor, and note. Empty state: `No activity logs available.`
- Reuses elapsed-time utility from T5 (`src/lib/time.ts`) for any time display.

### Figma

- Task detail sheet: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Dashboard-Workflow-UI?node-id=62-3276&t=dBztH5XSYbZ9jPyR-0

### Required skills

- frontend-engineer
- figma-mcp
- typescript-best-practices

### Subtasks

- [ ] Read Figma task detail frame via Figma MCP before writing code
- [ ] Implement `TaskDetailSheet` compound — slide-in, overlay close, X button
- [ ] Header: task ID badge, status badge, title
- [ ] Metadata grid: repo, branch, next action, actor, depends_on, blocked reason
- [ ] PR cards: workspace PR and repo PR, link and disabled states
- [ ] Timeline: log entries with coloured dots, formatted timestamps, actor, note
- [ ] Empty timeline state
- [ ] Reuse `src/lib/time.ts` for time formatting
- [ ] Verify all panel states match Figma
- [ ] Typecheck passes

---

## T7 — Error states, empty states, and end-to-end QA

### Description

Add all missing error and empty states, then run end-to-end browser QA across every user journey in the product spec. This is the final integration task; all board, panel, and sheet tasks must be complete before QA begins.

Error states to implement:

- **Access denied** (`access_denied`): message + "Reconnect" button → navigates to `/connect`.
- **No workflow data** (`not_found`): `docs/features/` missing in the connected repository.
- **Parse error** (`parse_error`): YAML exists but is unparseable. Shows a Sync retry button.
- **Network error** (`network_error`): generic retry button.
- **Empty board**: `docs/features/` exists but has no feature directories.
- **Connect screen — access denied**: inline error on form submit.

QA checklist (all must pass in a real browser with a real test workspace):

- Journey 1: connect public repo → board loads with real data.
- Journey 1 (private, valid PAT): board loads and PAT is stored in `localStorage`.
- Journey 1 (private, invalid PAT): access denied error shown on connect screen.
- Journey 1b: reload browser → board reopens from `localStorage` without re-entering credentials.
- Journey 2: expand features, click task cards, verify task detail sheet content.
- Journey 3: click Sync → board refreshes with latest data.
- Journey 4: left panel shows IN PROGRESS / READY / IN REVIEW tasks with correct elapsed times.
- Error state: connect repo with no `docs/features/` → `not_found` state shown.
- Inspect `localStorage` → workspace identity and PAT present for private workspace.

### Required skills

- frontend-engineer
- browser-qa-frontend

### Subtasks

- [ ] Implement `AccessDeniedState` component (reconnect button)
- [ ] Implement `NoWorkflowDataState` component
- [ ] Implement `ParseErrorState` component (sync retry)
- [ ] Implement `NetworkErrorState` component (retry)
- [ ] Implement `EmptyBoardState` component
- [ ] Mount all error states in `/board` route shell via `BoardLoadError` discriminant
- [ ] Inline access denied error in `ConnectForm`
- [ ] Run browser QA — all journeys listed above
- [ ] Verify `localStorage` PAT and workspace identity for private workspace
- [ ] Typecheck and production build pass
- [ ] Fix any regressions before opening PR
