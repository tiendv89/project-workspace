# Tasks — Feature Status Dashboard v2

**Feature status:** [`status.yaml`](status.yaml) — technical design approved, task planning stage.
**Machine state:** [`tasks/T<n>.yaml`](tasks/) — source of truth for status, dependencies, branch, PR, and log.

## Index

| ID  | Wave | Title                      | Depends on |
|-----|------|----------------------------|------------|
| T1  | 1    | v1 archive + v2 scaffold   | —          |
| T2  | 2    | Server data layer          | T1         |
| T3  | 2    | App shell                  | T1         |
| T10 | 2    | docker-compose service     | T1         |
| T4  | 3    | Workspace Picker screen    | T2, T3     |
| T5  | 3    | Dashboard screen           | T2, T3     |
| T6  | 3    | Features list screen       | T2, T3     |
| T7  | 3    | Feature detail screen      | T2, T3     |
| T8  | 3    | New Feature modal          | T2, T3     |
| T9  | 3    | Task Board screen          | T2, T3     |

---

## T1 — v1 archive + v2 scaffold

### Description

Archives the existing v1 codebase to a `v1-archive` branch, resets `main` to a clean state, and initialises a fresh Next.js 16 App Router project with all required dependencies, Dockerfile, and environment template. Root task — nothing else can begin until this scaffold exists.

Sequence:
1. Create and push `v1-archive` branch from current `digital-factory-ui` main.
2. Reset main to empty (wipe commit removing all v1 files).
3. Initialise Next.js 16 App Router at the repo root with pnpm.
4. Add HeroUI v3, js-yaml, @types/js-yaml, simple-git.
5. Configure Tailwind CSS v4 + HeroUI provider in root layout.
6. Add Inter + Cousine fonts via `next/font`.
7. Write `Dockerfile` (node:20-alpine, pnpm install + build + start).
8. Write `.env.local.example` template with all required vars.
9. Commit with message `feat: v2 scaffold — Next.js 16 App Router`.

### Required skills
- `frontend-engineer`
- `nextjs-best-practices`
- `typescript-best-practices`

### Subtasks
- [ ] Create and push `v1-archive` branch from current main
- [ ] Wipe main — single commit removing all v1 files
- [ ] Initialise Next.js 16 App Router with pnpm
- [ ] Install HeroUI v3 + configure provider in root layout
- [ ] Install js-yaml (@types/js-yaml) and simple-git
- [ ] Configure Tailwind CSS v4
- [ ] Add Inter + Cousine fonts via next/font
- [ ] Write Dockerfile (node:20-alpine, pnpm build + start)
- [ ] Write .env.local.example (WORKSPACE_SCAN_ROOT, GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, SSH_KEY_PATH)
- [ ] Verify `pnpm dev` starts and root page renders without errors

---

## T2 — Server data layer

### Description

Implements all server-side data access and write-back logic: workspace discovery, YAML readers for features and tasks, shared TypeScript types, and Server Actions for approve/reject/reset stage and new-feature scaffolding. Must complete before any screen can render live data.

### Required skills
- `frontend-engineer`
- `nextjs-best-practices`
- `typescript-best-practices`

### Subtasks
- [ ] `types/workspace.ts` — WorkspaceConfig, WorkspaceSummary
- [ ] `types/feature.ts` — FeatureStatus, StageReview, FeatureSummary
- [ ] `types/task.ts` — TaskYaml, TaskStatus, LogEntry
- [ ] `lib/workspace.ts` — scan WORKSPACE_SCAN_ROOT one level deep for workspace.yaml files
- [ ] `lib/features.ts` — read status.yaml per feature, list + filter features by status/stage
- [ ] `lib/tasks.ts` — read tasks/T<n>.yaml files for a given feature
- [ ] `lib/git.ts` — simple-git wrapper: git add + commit + push, targeting the feature branch
- [ ] `actions/approve.ts` — Server Action: read status.yaml, mutate review fields, write back, git commit
- [ ] `actions/init-feature.ts` — Server Action: scaffold docs/features/<id>/ directory, git commit
- [ ] Smoke test: round-trip a workspace.yaml + status.yaml parse to verify no runtime errors

---

## T3 — App shell

### Description

Implements the root layout shell: sidebar navigation, top header bar, WorkspaceContext provider, and WorkspaceSwitcher. Every page renders inside this shell. Must exist before any screen task can produce a consistent page layout.

### Required skills
- `frontend-engineer`
- `nextjs-best-practices`
- `heroui-react`
- `typescript-best-practices`
- `figma-mcp`
- `figma:figma-implement-design`

### Figma
- Dashboard frame (sidebar + header layout): https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-2

### Subtasks
- [ ] Read Figma frame 2-2 via Figma MCP before writing any UI
- [ ] `context/WorkspaceContext.tsx` — active workspace stored in localStorage, exposed via React context
- [ ] `components/layout/Sidebar.tsx` — nav links (Dashboard, Features, Tasks), workspace label, active-route highlight
- [ ] `components/layout/Header.tsx` — breadcrumb/page title + workspace switcher trigger
- [ ] `components/layout/WorkspaceSwitcher.tsx` — dropdown listing discovered workspaces; sets active workspace
- [ ] `app/layout.tsx` — root layout: WorkspaceContext provider + sidebar + header + content slot
- [ ] Verify sidebar highlights the correct nav item per route

---

## T4 — Workspace Picker screen

### Description

Implements the Workspace Picker — the full-page grid that renders on first visit when no `active_workspace_id` is stored. Each card shows workspace name and summary counts. Selecting a card stores the workspace ID in localStorage and transitions to the Dashboard.

### Required skills
- `frontend-engineer`
- `nextjs-best-practices`
- `heroui-react`
- `typescript-best-practices`
- `figma-mcp`
- `figma:figma-implement-design`

### Figma
- Dashboard frame (first-load / workspace picker state): https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-2

### Subtasks
- [ ] Read Figma frame 2-2 via Figma MCP before writing any UI
- [ ] `components/workspace/WorkspaceCard.tsx` — card: workspace name, feature count, in-progress count
- [ ] `components/workspace/WorkspacePicker.tsx` — full-page grid of WorkspaceCard
- [ ] `app/page.tsx` — conditionally renders WorkspacePicker (no stored workspace) or Dashboard (workspace selected)
- [ ] On card click: write `active_workspace_id` to localStorage, navigate to dashboard

---

## T5 — Dashboard screen

### Description

Implements the main Dashboard: workspace-level stat cards (total features, in_progress, blocked, done) and a recent activity feed drawn from feature and task history entries. Rendered after a workspace is selected.

### Required skills
- `frontend-engineer`
- `nextjs-best-practices`
- `heroui-react`
- `typescript-best-practices`
- `figma-mcp`
- `figma:figma-implement-design`

### Figma
- Dashboard: https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-2

### Subtasks
- [ ] Read Figma frame 2-2 via Figma MCP before writing any UI
- [ ] `components/dashboard/StatCard.tsx` — label, count, icon, color variant
- [ ] `components/dashboard/RecentActivity.tsx` — chronological list of recent log/history entries
- [ ] Dashboard section of `app/page.tsx` — four stat cards + recent activity feed
- [ ] Data: server-read from lib/features.ts + lib/tasks.ts (no client-side fetching)

---

## T6 — Features list screen

### Description

Implements the `/features` page: a filterable table of all features in the active workspace with status badges, stage progress bars, and filter pills by lifecycle stage and review status.

### Required skills
- `frontend-engineer`
- `nextjs-best-practices`
- `heroui-react`
- `typescript-best-practices`
- `figma-mcp`
- `figma:figma-implement-design`

### Figma
- Features: https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-574

### Subtasks
- [ ] Read Figma frame 2-574 via Figma MCP before writing any UI
- [ ] `components/features/FilterPills.tsx` — filter pills for feature_status and current_stage
- [ ] `components/features/FeaturesTable.tsx` — table rows: feature name, status badge, stage, progress bar, last updated
- [ ] Status badge — color-coded per feature_status value
- [ ] Lifecycle progress bar — position derived from current_stage in the ordered lifecycle
- [ ] `app/features/page.tsx` — filter pills + features table, server-rendered feature list

---

## T7 — Feature detail screen

### Description

Implements the `/features/[featureId]` page: a stage stepper showing current lifecycle position, a review card per stage (with approve/reject/reset buttons wired to Server Actions), and a task table. This is the only screen with write-back interactions.

### Required skills
- `frontend-engineer`
- `nextjs-best-practices`
- `heroui-react`
- `typescript-best-practices`
- `figma-mcp`
- `figma:figma-implement-design`

### Figma
- Feature Detail: https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-2141

### Subtasks
- [ ] Read Figma frame 2-2141 via Figma MCP before writing any UI
- [ ] `components/feature-detail/StageStepper.tsx` — horizontal lifecycle stage indicators, current stage highlighted
- [ ] `components/feature-detail/ReviewCard.tsx` — review status, reviewer, timestamp, approve/reject/reset buttons
- [ ] `components/feature-detail/TaskTable.tsx` — task rows: ID, title, status, actor type, PR link
- [ ] `app/features/[featureId]/page.tsx` — stage stepper + review card + task table
- [ ] Wire approve/reject/reset to `actions/approve.ts` Server Action
- [ ] Verify optimistic UI update + Next.js revalidatePath after action completes

---

## T8 — New Feature modal

### Description

Implements the New Feature modal: a form for feature name, auto-generated ID slug (kebab-case, editable), and description. Submitting calls `initFeature` Server Action, which scaffolds `docs/features/<id>/` and commits to a new feature branch.

### Required skills
- `frontend-engineer`
- `nextjs-best-practices`
- `heroui-react`
- `typescript-best-practices`
- `figma-mcp`
- `figma:figma-implement-design`

### Figma
- New Feature Modal: https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-1770

### Subtasks
- [ ] Read Figma frame 2-1770 via Figma MCP before writing any UI
- [ ] `components/features/NewFeatureModal.tsx` — modal with name, slug, description fields
- [ ] Auto-generate slug from name (lowercase kebab-case), allow override
- [ ] Client-side validation: non-empty name, valid slug format, no duplicate feature IDs
- [ ] Wire submit to `actions/init-feature.ts` Server Action
- [ ] On success: close modal, revalidate features list; on error: show inline error

---

## T9 — Task Board screen

### Description

Implements the `/tasks` page: a Kanban board with one column per task status (todo, ready, in_progress, blocked, in_review, done). Task cards show title, repo badge, actor type, and PR link. Filter row for feature and repo selectors.

### Required skills
- `frontend-engineer`
- `nextjs-best-practices`
- `heroui-react`
- `typescript-best-practices`
- `figma-mcp`
- `figma:figma-implement-design`

### Figma
- Task Board: https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-825
- Select (dropdown for filters): https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-1314

### Subtasks
- [ ] Read Figma frames 2-825 and 2-1314 via Figma MCP before writing any UI
- [ ] `components/task-board/TaskCard.tsx` — title, repo badge, actor type badge, PR link
- [ ] `components/task-board/KanbanColumn.tsx` — status column header + stacked task cards
- [ ] `components/task-board/KanbanBoard.tsx` — all six columns with horizontal scroll
- [ ] Filter row: feature selector + repo selector using Select dropdown component
- [ ] `app/tasks/page.tsx` — filter row + kanban board, server-rendered task data from all features

---

## T10 — docker-compose service entry

### Description

Adds the `digital-factory-ui` service to `docker-compose.yml` in the `workflow` (agent-workflow) repo root. Requires a bind-mount for `WORKSPACE_SCAN_ROOT` (workspace data access) and `SSH_KEY_PATH` (git push auth). Config-only task; no UI work. Runs in the `workflow` repo, not `digital-factory-ui`.

### Required skills

_(none — configuration-only task)_

### Subtasks
- [ ] Locate `docker-compose.yml` in the workflow repo root
- [ ] Add `digital-factory-ui` service: build context = `DIGITAL_FACTORY_UI_LOCAL_PATH`, port 3000:3000
- [ ] Add env vars: WORKSPACE_SCAN_ROOT, GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, SSH_KEY_PATH
- [ ] Add bind-mount: host WORKSPACE_SCAN_ROOT → container /workspaces
- [ ] Add bind-mount: host SSH key file → container at configured path
- [ ] Verify `docker compose up digital-factory-ui` starts and app is reachable at localhost:3000
