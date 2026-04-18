# Technical Design

## Feature
- Feature ID: `feature-status-dashboard`
- Title: Feature & Task Status Visualization Dashboard

---

## 1. Current State

The `digital-factory-ui` repo (`git@github.com:tiendv89/digital-factory-ui.git`) is an **empty git project** — no framework, no dependencies, no files beyond the initial commit (if any). This feature bootstraps it from zero.

Feature and task state is stored as YAML files in the management repo (`workspace` — `~/workspace/workspace`):

```
docs/features/<feature_id>/status.yaml       — lifecycle stage, review status, history
docs/features/<feature_id>/tasks/T<n>.yaml   — one file per task; status, deps, log, PR
```

There is currently no way to view this state without navigating the filesystem directly.

**Constraints:**
- No existing code to build on in `digital-factory-ui`
- Data is file-based; the management repo local clone must be accessible at a configurable path
- No authentication required
- No staging or production environment in this phase — local dev only
- YAML schema is stable but not formally versioned; the type definitions must reflect the actual field names used in existing files

---

## 2. Problem Framing

### What needs to change
- `digital-factory-ui` must be initialized as a Next.js application
- A web UI must read `status.yaml` and `tasks/T<n>.yaml` from the management repo and render them
- The data layer must be abstracted behind a repository interface so the underlying store can be replaced with a relational DB later without touching the UI

### What must remain stable
- The YAML file schema (this design reads it, does not own it)
- The management repo directory structure (`docs/features/<feature_id>/...`)
- No write operations — the dashboard is strictly read-only

### Fixed assumptions
- `WORKSPACE_MGMT_PATH` env var points to the local management repo clone
- The app runs locally; no deployment infrastructure needed now
- Next.js App Router (RSC-first) is the baseline — no Pages Router

---

## 3. Options Considered

### Option A — Pure server components, no API routes

All data fetching happens in React Server Components via direct `fs` calls. No dedicated API layer.

- **Pros**: simpler, fewer files, no serialization overhead
- **Cons**: no way for the client to refresh data without a full page reload; harder to test the data layer in isolation; API routes would need to be added later if any client-side interaction is needed
- **Implementation impact**: minimal — just server components reading YAML
- **Dependency impact**: none

### Option B — Server components + thin API routes (chosen)

Server components drive the initial render. API routes (`/api/features`, `/api/features/[id]`, `/api/features/[id]/tasks`) are added alongside, backed by the same repository interface. The UI can call these for a lightweight refresh without a full navigation.

- **Pros**: separation of concerns between data layer and rendering; API routes are useful for the DB migration (swap implementation, keep routes); easy to test the repository in isolation
- **Cons**: slightly more boilerplate upfront
- **Implementation impact**: adds a `src/lib/repositories/` layer and three API route handlers
- **Dependency impact**: none

### Option C — External API server (separate NestJS/Express process)

A separate backend process serves the data; the Next.js app calls it over HTTP.

- **Pros**: clean service boundary; easy to scale independently
- **Cons**: over-engineered for a read-only local tool; two processes to start; no benefit until the DB migration happens
- **Implementation impact**: high — two separate repos/projects
- **Dependency impact**: introduces inter-service dependency; complicates dev setup

**Option B chosen.** It hits the right complexity level for phase 1 and makes the DB migration path explicit without forcing a separate service prematurely.

---

## 4. Chosen Design

### Stack

| Layer | Choice | Reason |
|---|---|---|
| Framework | Next.js 14+ App Router | Full-stack, RSC-first, matches the spec |
| Language | TypeScript | Type safety on YAML shapes; required for repository interface pattern |
| UI components | HeroUI v3 (Tailwind CSS v4) | Available skill; consistent component library; badge + table primitives |
| YAML parsing | `js-yaml` | Lightweight; parses YAML to plain JS objects; wide adoption |
| Data layer | Repository interface pattern | Decouples filesystem reads from the UI; enables DB swap |

### Directory structure

```
digital-factory-ui/
  src/
    lib/
      types/
        feature.ts         # FeatureStatus, Feature, Stage, HistoryEntry
        task.ts            # TaskStatus, Task, ExecutionInfo, PRInfo, LogEntry
      repositories/
        feature.repository.ts              # FeatureRepository interface
        filesystem-feature.repository.ts   # fs + js-yaml implementation
    app/
      layout.tsx                   # Root layout with HeroUI provider
      page.tsx                     # Features list (Server Component)
      features/
        [id]/
          page.tsx                 # Feature detail (Server Component)
      api/
        features/
          route.ts                 # GET /api/features
          [id]/
            route.ts               # GET /api/features/[id]
            tasks/
              route.ts             # GET /api/features/[id]/tasks
  .env.local.example               # Documents WORKSPACE_MGMT_PATH
```

### Repository interface

```typescript
// feature.repository.ts
export interface FeatureRepository {
  findAll(): Promise<FeatureSummary[]>        // list + computed task counts
  findById(id: string): Promise<Feature | null>
  findTasksByFeatureId(id: string): Promise<Task[]>
}
```

The `FilesystemFeatureRepository` implementation:
1. Reads `WORKSPACE_MGMT_PATH` from `process.env`
2. Scans `docs/features/` for subdirectories
3. Parses `status.yaml` and `tasks/T<n>.yaml` with `js-yaml`
4. Returns typed objects

### Pages

**`/` — Features list**
- Server Component; calls `repository.findAll()` at render time
- Renders a HeroUI `Table` with columns: Feature ID, Title, Stage, Review status, Tasks summary (done/blocked/ready counts), link to detail
- Status badge colors: `in_progress` → blue, `blocked` → red, `ready` → green, `done` → grey, `in_review` → amber, `in_design`/`in_tdd` → purple

**`/features/[id]` — Feature detail**
- Server Component; calls `repository.findById(id)` and `repository.findTasksByFeatureId(id)`
- Feature header: title, stage, review status, next action
- HeroUI `Table` for tasks: ID, Title, Status badge, Repo, Actor type, Depends on, PR link
- Blocked rows highlighted; `blocked_reason` shown inline
- Tasks with unmet dependencies show dependency IDs as "waiting on T1, T2"

### Environment configuration

```bash
# .env.local
WORKSPACE_MGMT_PATH=/Users/matthew/workspace/workspace
```

No other env vars required in phase 1.

### Affected repositories

| Repo | Change |
|---|---|
| `digital-factory-ui` | Initialized from empty; all source code lives here |
| `management-repo` | Read-only; no changes; provides YAML data |

---

## 5. Dependency Analysis

| Dependency | Type | Status | Notes |
|---|---|---|---|
| `digital-factory-ui` empty repo exists on GitHub | External | Resolved | Confirmed by workspace.yaml |
| Next.js 14+ | Tooling | Resolved | Stable; no version risk |
| HeroUI v3 | Tooling | Resolved | `heroui-react` skill available |
| `js-yaml` + `@types/js-yaml` | Tooling | Resolved | Standard npm package |
| `WORKSPACE_MGMT_PATH` env var | Config | Resolved | Set in local `.env.local` pointing to `~/workspace/workspace` |
| YAML schema stability | Internal | Resolved (assumed) | Schema is read-only from this feature's perspective; actual field names validated by TypeScript types against real files |
| DB migration (future) | External | Not in scope | Repository interface is the seam; no action needed now |

No unresolved blocking dependencies.

---

## 6. Parallelization / Blocking Analysis

```
T1: Initialize Next.js project — digital-factory-ui
  └── Can begin now — no blockers

  T2: Mock data UI prototype — both pages with hardcoded data
  T3: Data layer — types + FeatureRepository interface + FilesystemFeatureRepository
      └── T2 and T3 run in parallel — both depend only on T1
      └── T2: BLOCKED on T1 (scaffold must exist to author pages)
      └── T3: BLOCKED on T1 (scaffold must exist to author src/lib/)

      T4: Features list page (/) — wire real data
          └── BLOCKED on T2 (UI components and page structure must exist to wire into)
          └── BLOCKED on T3 (FeatureRepository must be in place to call findAll())

          T5: Feature detail page (/features/[id]) — wire real data
              └── BLOCKED on T4 (T4 establishes the real-data wiring pattern T5 follows; same repo, sequential)
```

**Note on T2/T3 parallelization:** T2 (mock UI) and T3 (data layer) touch completely different parts of the codebase (`app/` vs `src/lib/`) and can safely run in parallel on separate branches after T1 merges. T4 merges both branches — it requires T2's UI components and T3's repository interface simultaneously.

---

## 7. Repository Impact

| Repo | Impact |
|---|---|
| `digital-factory-ui` | Initialized from scratch: Next.js scaffold, data layer, two pages, three API routes |
| `management-repo` (workspace) | No code changes; read at runtime via filesystem |
| `workflow` | No changes |

---

## 8. Validation and Release Impact

### Testing
- Repository layer: unit tests using test fixture YAML files (copy of real feature directories); no filesystem mocking needed — use a temp directory with real files
- Pages: TypeScript compilation (`tsc --noEmit`) and `next build` as the baseline correctness check
- Manual smoke test: start `next dev`, verify both pages load with real management repo data

### Config impact
- Requires `.env.local` with `WORKSPACE_MGMT_PATH` on first setup; `.env.local.example` documents this

### Rollout
- Local dev only; no deployment pipeline needed
- No backward compatibility concerns — greenfield project

### Handoff implications
- The repository interface is the DB migration seam; a future task can swap `FilesystemFeatureRepository` for a `PostgresFeatureRepository` without touching pages or API routes
