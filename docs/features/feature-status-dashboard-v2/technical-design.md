# Technical Design

## Feature
- Feature ID: `workspace-interface`
- Title: `Workspace Interface — Web UI for Workspace Management`

---

## 1. Current State

The agent workflow system is entirely file-driven. The management repo stores:

- `workspace.yaml` — workspace config, repos, roles
- `docs/features/<id>/status.yaml` — per-feature lifecycle and stage review state
- `docs/features/<id>/product-spec.md`, `technical-design.md`, `tasks.md` — narrative artifacts
- `docs/features/<id>/tasks/T<n>.yaml` — per-task machine-readable state

Humans interact with this system by:
- Running CLI skills (`/tech-lead`, `/approve-feature`, `/start-implementation`, etc.)
- Editing YAML files directly with a text editor
- Running `git` commands to commit and push state changes

There is no visual layer. There is no way to browse features, understand cross-feature task status, or approve stage reviews without knowing the file layout and having a terminal open.

**Current limitations:**
- No at-a-glance status view — requires manual `cat` or IDE file browsing
- Stage approvals are manual YAML edits — error-prone and non-discoverable
- Multi-workspace management requires manual directory switching
- Non-technical stakeholders cannot participate in review without CLI access

**Relevant repo boundary:** The new UI app will live in its own standalone repo: `workspace-interface` (GitHub: `tiendv89/workspace-interface`). The management repo (this repo) remains the file-system source of truth — the UI reads and writes its YAML files on the local filesystem.

---

## 2. Problem Framing

**What must change:**
- A web application must provide all five screens (Workspace Picker, Dashboard, Features list, Feature Detail, Task Board) described in the product spec.
- The app must read live data from workspace YAML files (no caching layer, no database).
- Approve/Reject/Reset actions on stage review cards must write back to `status.yaml` and commit to the feature's branch.
- The New Feature modal must scaffold the `docs/features/<id>/` directory structure on disk.

**What must remain stable:**
- YAML file schemas — the app must not change the shape of `status.yaml` or `tasks/T<n>.yaml`.
- Workflow rule enforcement — the UI surfaces actions permitted by the rules; it does not bypass them (e.g. it does not mark tasks `done`).
- Git as the system of record — all writes go to the correct feature branch via git commit.

**Fixed assumptions:**
- Single-user, local tool only. No authentication or multi-user support in v1.
- Desktop-first at 1440px width. No mobile/responsive breakpoints.
- The app runs as a local Next.js dev server (`npm run dev`) against the host filesystem.
- A `WORKSPACE_SCAN_ROOT` environment variable points to the directory containing workspace subdirectories.

---

## 3. Options Considered

### Option A: Electron app (packaged desktop)

**What it is:** A fully packaged desktop app with direct Node.js file system access, bundled with Chromium.

**Pros:**
- Direct `fs` access to YAML files — no server needed
- Can spawn `git` subprocesses for commit/push natively
- Standalone app, no local server to manage

**Cons:**
- Significantly heavier build pipeline (electron-builder, code signing)
- Slower DX iteration cycle — requires rebuild for code changes
- No HMR without extra tooling
- Overkill for a single-user developer tool; packaging overhead adds friction to CI

**Implementation impact:** Separate Electron main process + renderer process architecture; IPC bridge for file operations
**Dependency impact:** Adds electron, electron-builder; significant devDependency footprint

---

### Option B: Vite + React SPA + Express/Fastify backend

**What it is:** A decoupled frontend SPA (Vite + React) talking to a lightweight Node.js HTTP server that handles filesystem reads/writes and git operations.

**Pros:**
- Clean frontend/backend separation
- Vite HMR is fast
- Familiar REST API mental model

**Cons:**
- Two processes to run and keep in sync
- More boilerplate than necessary for a local tool
- API route management overhead
- No shared types without additional tooling (e.g. tRPC)

**Implementation impact:** Two packages in a monorepo or two repos; CORS config; runtime glue
**Dependency impact:** Adds express/fastify + separate server entry point

---

### Option C: Next.js 16 App Router (chosen)

**What it is:** A single Next.js 16 (App Router) project where Server Components read YAML files on the server, Server Actions handle all writes (status.yaml updates, git commits, directory scaffolding), and the client manages UI state.

**Pros:**
- Single process, single dev command (`npm run dev`)
- Server Components access `fs` directly — no API glue
- Server Actions eliminate the need for explicit API routes for most writes
- Strong TypeScript integration, colocated layouts, suspense boundaries
- HeroUI v3 + Tailwind CSS v4 fit cleanly into the Next.js component model
- Excellent DX with HMR for both server and client components

**Cons:**
- React Server Components mental model has a learning curve (server vs client component boundary)
- Long-running git operations (commit, push) inside Server Actions need explicit timeout handling

**Implementation impact:** Standalone repo `workspace-interface` (`tiendv89/workspace-interface`); single `npm run dev`; env vars configure workspace root; added to local `docker-compose.yml` for optional containerised startup
**Dependency impact:** Next.js 16, React 19, Tailwind CSS v4, HeroUI v3, js-yaml, simple-git

---

## 4. Chosen Design

**Selected approach: Option C — Next.js 16 App Router**

**Why:**
- A single process running on localhost is the simplest possible deployment for a local dev tool.
- Server Components + Server Actions give direct filesystem access without an additional API server.
- Next.js App Router's file-based routing maps 1:1 to the screen hierarchy (`/`, `/features`, `/features/[featureId]`, `/tasks`).
- HeroUI v3 + Tailwind CSS v4 are a natural match for the Figma design tokens (utility-first, component-driven).

### Stack

| Layer | Technology |
|---|---|
| Framework | Next.js 16 (App Router) |
| Language | TypeScript (strict) |
| Styling | Tailwind CSS v4 |
| Component library | HeroUI v3 |
| YAML parsing | js-yaml |
| Git operations | simple-git |
| Fonts | Inter (body), Cousine (mono) via `next/font` |
| Runtime | Node.js 20+ |

### Architecture

The app is a standalone repo (`workspace-interface`):

```
workspace-interface/         # repo root
├── app/
│   ├── layout.tsx               # Root layout: sidebar + header shell
│   ├── page.tsx                 # Dashboard (/), workspace picker on first load
│   ├── features/
│   │   ├── page.tsx             # Features list (/features)
│   │   └── [featureId]/
│   │       └── page.tsx         # Feature detail (/features/:featureId)
│   └── tasks/
│       └── page.tsx             # Task Board (/tasks)
├── components/
│   ├── layout/                  # Sidebar, Header, WorkspaceSwitcher
│   ├── workspace/               # WorkspacePicker, WorkspaceCard
│   ├── dashboard/               # StatCard, RecentActivity
│   ├── features/                # FeaturesTable, FilterPills, NewFeatureModal
│   ├── feature-detail/          # StageStepper, ReviewCard, TaskTable
│   └── task-board/              # KanbanBoard, TaskCard, KanbanColumn
├── lib/
│   ├── workspace.ts             # Workspace discovery (scan WORKSPACE_SCAN_ROOT)
│   ├── features.ts              # Read status.yaml, list features
│   ├── tasks.ts                 # Read tasks/T<n>.yaml
│   └── git.ts                   # simple-git wrapper: commit + push server actions
├── actions/
│   ├── approve.ts               # Server Action: approve/reject/reset status.yaml
│   └── init-feature.ts          # Server Action: scaffold new feature directory
├── types/
│   ├── workspace.ts             # WorkspaceConfig, WorkspaceSummary
│   ├── feature.ts               # FeatureStatus, StageReview
│   └── task.ts                  # TaskYaml, TaskStatus
├── Dockerfile                   # Production image (node:20-alpine, npm run start)
└── .env.local.example           # Template for WORKSPACE_SCAN_ROOT, git config
```

### Active workspace state

The active workspace is stored in `localStorage` (client-side key: `active_workspace_id`) and in a React context (`WorkspaceContext`) so all views scope data to the selected workspace without a full page reload. On first visit (no stored workspace), the app renders the Workspace Picker instead of the Dashboard.

### Write flow (Approve/Reject/Reset)

1. User clicks Approve on a Feature Detail review card.
2. Client calls a Server Action (`approveStage(featureId, stage)`).
3. Server Action:
   a. Reads current `status.yaml` with `js-yaml`.
   b. Updates `review_status`, `reviewed_by` (from `GIT_AUTHOR_EMAIL` env), `reviewed_at`, `review_history`.
   c. Writes updated YAML back to disk.
   d. Uses `simple-git` to `git add` + `git commit` on the feature's branch.
4. Server Action returns `{ ok: true }` or `{ error: string }`.
5. Client invalidates the feature data and re-fetches.

### Write flow (New Feature)

1. User submits the New Feature modal form.
2. Client calls `initFeature(params)` Server Action.
3. Server Action creates the directory scaffold under `docs/features/<id>/` (status.yaml template, empty subdirs).
4. Commits and pushes to a new feature branch.

### Configuration

```env
# workspace-interface/.env.local
WORKSPACE_SCAN_ROOT=/Users/pye/code/kitelabs
GIT_AUTHOR_NAME=pye
GIT_AUTHOR_EMAIL=pentative@gmail.com
SSH_KEY_PATH=~/.ssh/id_ed25519
```

`WORKSPACE_SCAN_ROOT` is scanned recursively (one level deep) for `workspace.yaml` files.

When running via docker-compose, `WORKSPACE_SCAN_ROOT` is bind-mounted into the container (e.g. `/workspaces`) and `SSH_KEY_PATH` is bind-mounted from the host's SSH agent socket or key file.

---

## 5. Dependency Analysis

### Internal dependencies

| Dependency | Type | Status |
|---|---|---|
| `workflow` repo exists at `env:WORKFLOW_LOCAL_PATH` and `workspace-interface/` subdir can be created | Repo existence | Must be confirmed before T1 |
| `status.yaml` schema is stable | File format contract | Stable — product spec confirmed |
| `tasks/T<n>.yaml` schema is stable | File format contract | Stable — workflow rules confirmed |
| YAML field names for Approve/Reject/Reset | Write contract | Confirmed from workflow rules |
| Feature branch naming convention (`feature/<id>`) | Git convention | Confirmed from workspace.yaml |

### External dependencies

| Dependency | Type | Notes |
|---|---|---|
| Node.js 20+ on developer machine | Runtime | Required for Next.js 16 |
| npm/pnpm | Package manager | Standard |
| `simple-git` package | npm package | Mature, no auth complexity for local repos |
| `js-yaml` package | npm package | Standard YAML parser |
| HeroUI v3 | npm package | Requires Tailwind CSS v4; confirmed available |
| Inter + Cousine fonts | Google Fonts via `next/font` | No external service required at runtime |

### Blocking decisions

| Decision | Status | Required before |
|---|---|---|
| Does `tiendv89/workspace-interface` repo already exist with scaffold, or is T1 a fresh init? | **Unresolved** — check `WORKSPACE_INTERFACE_LOCAL_PATH` | T1 |
| Is `pnpm` or `npm` the preferred package manager for the workspace-interface app? | **Unresolved** | T1 |
| Which `docker-compose.yml` file does T10 add the service to? (`workflow` repo root, or a shared root) | **Unresolved** | T10 |

### Configuration dependencies

- `WORKSPACE_SCAN_ROOT` must be set in `.env.local` before the app can discover workspaces.
- `GIT_AUTHOR_NAME` and `GIT_AUTHOR_EMAIL` must be set for commit attribution.
- `SSH_KEY_PATH` must be accessible for push to origin.
- `FIGMA_PERSONAL_ACCESS_TOKEN` is available in project `.env` and will be used during UI implementation per the Figma MCP usage rule.

---

## 6. Parallelization / Blocking Analysis

```
D1: Confirm whether workspace-interface repo exists (fresh scaffold vs. existing)
  └── Unblock before T1. Check WORKSPACE_INTERFACE_LOCAL_PATH from .env.

T1: App scaffold — Next.js 16, TypeScript, Tailwind v4, HeroUI v3, design tokens, fonts, Dockerfile
  └── Can begin now once D1 is resolved — no other blockers
  │
  T2: Server data layer — workspace discovery, YAML readers, Server Actions for status writes + git
  T3: App shell — sidebar, header, WorkspaceContext provider, nav links, workspace switcher
      └── T2 and T3 run in parallel
      └── BLOCKED on T1 (project scaffold and dependencies must exist)
      │
      T4: Workspace picker screen — discovery grid, workspace cards, search filter
      T5: Dashboard screen — stat cards, recent activity feed
      T6: Features list screen — filterable table, filter pills, status badges, progress bars
      T7: Feature detail screen — stage stepper, review card, approve/reject/reset, task table
      T8: New feature modal — form, slug auto-gen, validation, directory scaffold action
      T9: Task Board screen — kanban columns, task cards, feature/repo/actor filters
          └── T4, T5, T6, T7, T8, T9 run in parallel with each other
          └── BLOCKED on T2 (data layer and server actions must be available)
          └── BLOCKED on T3 (sidebar + header layout shell must exist for consistent page structure)

T10: docker-compose — add workspace-interface service to docker-compose.yml in workflow repo
     └── BLOCKED on T1 (Dockerfile must exist before docker-compose service can be defined)
     └── Runs in parallel with T2/T3 and T4-T9 once T1 is done
```

**Wave summary:**

| Wave | Tasks | Parallelism |
|---|---|---|
| Wave 0 | D1 (unblock decision) | Immediate |
| Wave 1 | T1 | Single task |
| Wave 2 | T2, T3, T10 | Fully parallel |
| Wave 3 | T4, T5, T6, T7, T8, T9 | Fully parallel |

---

## 7. Repository Impact

| Repo | Impact | Reason |
|---|---|---|
| `workspace-interface` | Primary — T1–T9 write here | The web app is this standalone repo |
| `workflow` | T10 only — adds docker-compose service entry | docker-compose.yml lives in the workflow repo |
| `management-repo` | Read-only at runtime; written by Server Actions via `simple-git` | The app reads and writes `status.yaml`, `tasks/T<n>.yaml`, scaffolds feature dirs |

No changes are required to `rag-service`.

The `management-repo` is mutated only via `simple-git` running inside Next.js Server Actions — not via direct file writes without git tracking. This ensures all state changes remain committed artifacts.

---

## 8. Validation and Release Impact

### Testing expectations
- No automated test suite is required for v1 (local dev tool, single user).
- Manual acceptance testing: verify each screen renders live data, approve/reject/reset writes correct fields to `status.yaml` and commits, New Feature modal produces the correct directory scaffold.

### Migration / config impact
- No migration required — the app reads existing YAML files without schema changes.
- `.env.local` must be added to `agent-workflow/workspace-interface/` with `WORKSPACE_SCAN_ROOT` and git config.

### Rollout
- Delivered as a local Next.js dev server. No deployment infrastructure needed.
- The workspace owner runs `npm run dev` (or equivalent) to start the UI.

### Backward compatibility
- YAML file schemas are not changed. Existing CLI-based workflow continues to function in parallel.
- The UI is additive: it can be adopted incrementally without disrupting the file-driven workflow.

### Deployment / handoff implications
- T1 sets up the standalone repo and Dockerfile; subsequent tasks run in parallel once T1 is done.
- T10 wires the app into docker-compose so the full stack can be started with a single `docker compose up`.
- Each screen is a self-contained Next.js route — agents can implement and test screens independently before integration.

---

## Figma

Design file: **Agent Workspace design** — `qYFglR3hJRmB8VuAPt5Rjs`

| Frame | URL | Covers |
|---|---|---|
| Dashboard | https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-2 | Sidebar layout, header bar, dashboard stat cards, recent activity |
| Features | https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-574 | Features list table, filter pills, search, status badges, progress bar |
| Feature Detail | https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-2141 | Stage stepper, review card, approve/reject buttons, task table |
| New Feature Modal | https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-1770 | Modal form, field layout, footer actions |
| Task Board | https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-825 | Kanban columns, task cards, filter row |
| Select (dropdown) | https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-1314 | Dropdown interaction state for feature/repo filters |

Tasks T4–T9 each implement one of the above screens. The Figma MCP must be used before implementing any UI component in those tasks (`FIGMA_PERSONAL_ACCESS_TOKEN` is available in project `.env`).
