# Tasks — feature-status-dashboard

> Feature status: `in_tdd` — technical design pending approval.
> Task stage: **draft** — awaiting human approval.
>
> Narrative (description + required skills + subtasks) lives in this file. Machine-readable state (status, deps, branch, log, PR) lives per-task in `tasks/T<n>.yaml`. Agents mutate only the YAML files; this document stays stable unless scope changes.
>
> All tasks target the `digital-factory-ui` repo, which starts as an empty git project and is initialized by T1.

---

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Initialize Next.js project in digital-factory-ui | — |
| T2 | 2 | Mock data UI prototype — both pages with hardcoded data | T1 |
| T3 | 2 | Data layer — types, FeatureRepository interface, FilesystemFeatureRepository | T1 |
| T4 | 3 | Features list page (`/`) — wire real data | T2, T3 |
| T5 | 4 | Feature detail page (`/features/[id]`) — wire real data | T4 |
| T6 | 5 | GitHub Actions deployment — static export + GitHub Pages | T5 |

T2 and T3 are in Wave 2 and can run in parallel — both depend only on T1.

---

## T1 — Initialize Next.js project in digital-factory-ui

### Description
Bootstrap the `digital-factory-ui` repo from its current empty state into a working Next.js 14+ project with TypeScript, Tailwind CSS v4, HeroUI v3, and ESLint. This is the foundation all subsequent tasks build on.

The task must:
- Run `create-next-app` (or equivalent manual scaffold) with App Router, TypeScript, Tailwind, and ESLint enabled
- Install `@heroui/react` and configure the HeroUI provider in the root layout
- Install `js-yaml` and `@types/js-yaml`
- Create `.env.local.example` documenting the `WORKSPACE_MGMT_PATH` variable
- Confirm `next dev` starts cleanly and the default page loads

No application logic in this task — scaffold only.

### Required skills
- nextjs-best-practices
- heroui-react

### Subtasks
- [ ] Scaffold Next.js 14+ project with App Router, TypeScript strict mode, Tailwind CSS v4, ESLint
- [ ] Install `@heroui/react` and its peer dependencies
- [ ] Configure `HeroUIProvider` in `app/layout.tsx` with default light/dark theme support
- [ ] Install `js-yaml` + `@types/js-yaml`
- [ ] Create `.env.local.example` with `WORKSPACE_MGMT_PATH=` documented
- [ ] Remove boilerplate content from `app/page.tsx` (replace with a placeholder heading)
- [ ] Verify `next dev` starts without errors
- [ ] Verify `tsc --noEmit` passes

---

## T2 — Mock data UI prototype — both pages with hardcoded data

### Description
Build both dashboard pages using hardcoded mock data — no data layer, no filesystem reads, no API routes. The goal is a visual prototype the product owner can review before any real wiring happens.

This task deliberately skips the data layer so feedback on layout, badge colors, column choices, and row styling can be collected early. T4 and T5 will replace the mock data with real repository calls.

**Mock data to include:**
- 4–5 fake features covering all lifecycle stages (`in_design`, `in_tdd`, `in_implementation`, `blocked`, `done`)
- One feature with 4–5 tasks spanning all task statuses (`todo`, `ready`, `in_progress`, `blocked`, `in_review`, `done`)
- At least one blocked task with a `blocked_reason`
- At least one task with unmet dependencies

**Features list page** (`app/page.tsx`):
- HeroUI `Table` with columns: Feature ID (link), Title, Stage, Status badge, Review status badge, Tasks summary (e.g. `3 done · 1 blocked · 2 ready`)
- Reusable `StatusBadge` component mapping status → HeroUI `Chip` color:
  - `blocked` → red (`danger`)
  - `in_progress` → blue (`primary`)
  - `ready` → green (`success`)
  - `done` → grey (`default`)
  - `in_review` → amber (`warning`)
  - `in_design`, `in_tdd` → purple (`secondary`)
  - all others → `default`

**Feature detail page** (`app/features/[id]/page.tsx`):
- Feature header: title, stage, review status, next action
- HeroUI `Table` for tasks: ID, Title, Status badge, Repo, Actor type, Depends on, PR link
- Blocked rows visually distinct (red tint or danger color row); `blocked_reason` shown below the title cell
- Tasks with unmet deps: dependency IDs listed with an amber "waiting" label

No API routes in this task.

### Required skills
- nextjs-best-practices
- heroui-react
- typescript-best-practices

### Subtasks
- [ ] Create `src/components/status-badge.tsx` — reusable HeroUI `Chip` with status-to-color mapping
- [ ] Define inline mock data types in `src/lib/mock/data.ts` (Feature, Task shapes; no external types yet)
- [ ] Build `app/page.tsx` as Server Component rendering features list from mock data
- [ ] Build `app/features/[id]/page.tsx` as Server Component rendering task detail from mock data
- [ ] Verify both pages render in browser with `next dev`
- [ ] Verify `tsc --noEmit` passes

---

## T3 — Data layer — types, FeatureRepository interface, FilesystemFeatureRepository

### Description
Define all TypeScript types that mirror the YAML schema, declare the `FeatureRepository` interface, and implement `FilesystemFeatureRepository` — the concrete class that reads `status.yaml` and `tasks/T<n>.yaml` from disk using `js-yaml`.

This is the sole place that knows about the filesystem. T4 and T5 depend on this abstraction. Future DB migration replaces only this implementation, not the pages.

Can run in parallel with T2 — both depend only on T1.

**Type definitions** (`src/lib/types/`):
- `feature.ts`: `FeatureStatus`, `ReviewStatus`, `StageInfo`, `HistoryEntry`, `Feature`, `FeatureSummary` (Feature + computed task counts: total, done, blocked, ready, in_progress)
- `task.ts`: `TaskStatus`, `ExecutionInfo`, `PRInfo`, `LogEntry`, `Task`

**Repository interface** (`src/lib/repositories/feature.repository.ts`):
```typescript
export interface FeatureRepository {
  findAll(): Promise<FeatureSummary[]>
  findById(id: string): Promise<Feature | null>
  findTasksByFeatureId(id: string): Promise<Task[]>
}
```

**Filesystem implementation** (`src/lib/repositories/filesystem-feature.repository.ts`):
- Reads `process.env.WORKSPACE_MGMT_PATH` — throws a descriptive error if missing
- Scans `<WORKSPACE_MGMT_PATH>/docs/features/` for subdirectories
- Parses `status.yaml` and `tasks/*.yaml` with `js-yaml.load()`
- `findAll()` computes task count summary per feature

**Unit tests** using real fixture YAML files in a temp directory:
- `findAll()` returns correct feature count and task summaries
- `findById()` returns correct feature or null for unknown ID
- `findTasksByFeatureId()` returns correct tasks
- Missing `WORKSPACE_MGMT_PATH` throws a clear error

### Required skills
- typescript-best-practices
- nextjs-best-practices

### Subtasks
- [ ] Define types in `src/lib/types/feature.ts` and `src/lib/types/task.ts` matching actual YAML field names
- [ ] Declare `FeatureRepository` interface in `src/lib/repositories/feature.repository.ts`
- [ ] Implement `FilesystemFeatureRepository` in `src/lib/repositories/filesystem-feature.repository.ts`
- [ ] Export `getFeatureRepository(): FeatureRepository` factory from `src/lib/repositories/index.ts`
- [ ] Write unit tests with fixture YAML files
- [ ] Verify `tsc --noEmit` and tests pass

---

## T4 — Features list page (`/`) — wire real data

### Description
Replace the hardcoded mock data in `app/page.tsx` with real `FeatureRepository` calls. Add the three API routes. The UI components and layout from T2 stay as-is — this task only swaps the data source.

**Changes:**
- `app/page.tsx`: replace mock import with `getFeatureRepository().findAll()`; update types to use `FeatureSummary` from T3
- `src/lib/mock/data.ts`: can be removed or retained as a dev fallback (team preference)
- Add `app/api/features/route.ts` — `GET /api/features` returning `FeatureSummary[]`
- Add `app/api/features/[id]/route.ts` — `GET /api/features/:id` returning `Feature`
- Add `app/api/features/[id]/tasks/route.ts` — `GET /api/features/:id/tasks` returning `Task[]`

### Required skills
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Update `app/page.tsx` to call `getFeatureRepository().findAll()` instead of mock data
- [ ] Align component prop types with `FeatureSummary` from T3
- [ ] Create `app/api/features/route.ts`
- [ ] Create `app/api/features/[id]/route.ts`
- [ ] Create `app/api/features/[id]/tasks/route.ts`
- [ ] Verify features list page loads with real management repo data
- [ ] Verify `tsc --noEmit` and `next build` pass

---

## T5 — Feature detail page (`/features/[id]`) — wire real data

### Description
Replace the hardcoded mock data in `app/features/[id]/page.tsx` with real `FeatureRepository` calls. UI components and layout from T2 stay as-is.

**Changes:**
- `app/features/[id]/page.tsx`: replace mock import with `findById(id)` + `findTasksByFeatureId(id)`; call `notFound()` if feature is null
- Align prop types with `Feature` and `Task` from T3

### Required skills
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Update `app/features/[id]/page.tsx` to call repository instead of mock data
- [ ] Handle `notFound()` for unknown feature IDs
- [ ] Align component prop types with `Feature` and `Task` from T3
- [ ] Verify feature detail page loads for a real feature ID with tasks
- [ ] Verify `tsc --noEmit` and `next build` pass

---

## T6 — GitHub Actions deployment — static export + GitHub Pages

### Description
Add a GitHub Actions workflow that builds the dashboard as a static export and deploys it to GitHub Pages. This requires switching `FilesystemFeatureRepository` to a build-time data generation step — the app cannot read from the local filesystem at runtime on Pages.

**Architecture change:**
- Add `next.config.ts` flag: `output: 'export'`
- Add `scripts/generate-data.ts` — reads `WORKSPACE_MGMT_PATH` at build time and writes `public/data/features.json` + `public/data/features/<id>/tasks.json`
- Replace runtime `fs` reads in `FilesystemFeatureRepository` with `fetch('/data/features.json')` (or equivalent static JSON reads) so the production bundle has no Node `fs` dependency
- Keep the runtime `FilesystemFeatureRepository` for local `next dev` use (behind an env flag or `IS_STATIC_BUILD`)

**GitHub Actions workflow** (`.github/workflows/deploy.yml`):
- Trigger: push to `main`
- Steps: checkout → install → set `WORKSPACE_MGMT_PATH` from Actions secret → run `generate-data.ts` → `next build` → deploy `out/` to `gh-pages` branch via `peaceiris/actions-gh-pages` or equivalent

**Required secrets in the repo:**
- `WORKSPACE_MGMT_PATH` — path to a checked-out management repo on the Actions runner, or a separate checkout step that clones the workspace repo

### Required skills
- nextjs-best-practices
- typescript-best-practices

### Subtasks
- [ ] Add `output: 'export'` to `next.config.ts`
- [ ] Write `scripts/generate-data.ts` that reads YAML at build time and emits static JSON under `public/data/`
- [ ] Add `StaticFeatureRepository` (reads pre-generated JSON via `fetch`) for static export context
- [ ] Add env flag to select repository implementation: `NEXT_PUBLIC_DATA_SOURCE=static|filesystem`
- [ ] Create `.github/workflows/deploy.yml` with checkout → generate-data → build → deploy steps
- [ ] Document required secrets in README
- [ ] Verify `next build` with `output: 'export'` succeeds locally
- [ ] Verify generated `out/` contains index and feature detail HTML files
