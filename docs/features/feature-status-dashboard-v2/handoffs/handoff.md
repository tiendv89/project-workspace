# Handoff — feature-status-dashboard-v2

**Feature:** Feature Status Dashboard v2 — Web UI for Workspace Management
**Completed:** 2026-04-27
**All tasks:** T1–T10 done (10/10)

---

## What was built

A complete rewrite of the Feature Status Dashboard as a Next.js 16 App Router application. v2 replaces the v1 codebase (archived to the `v1-archive` branch of `digital-factory-ui`) with a fully implemented five-screen web UI that reads live data from workspace YAML files and writes back via Server Actions + `simple-git`.

### Problem summary

| Gap | Before (v1) | After (v2) |
|---|---|---|
| Screen coverage | Incomplete — not all 5 screens implemented | All 5 screens fully implemented per Figma design |
| Write-back | Read-only — no Approve/Reject/Reset | Server Actions write to `status.yaml` and commit to feature branch |
| Multi-workspace | Hard-coded to single workspace path | `WORKSPACE_SCAN_ROOT` discovery; workspace switcher in sidebar |
| Stack | Outdated, pre-HeroUI v3 | Next.js 16, React 19, Tailwind CSS v4, HeroUI v3 |
| Docker | No Dockerfile or docker-compose entry | Dockerfile + service entry in `workflow` repo docker-compose |

### Screens delivered

| Screen | Route | Task |
|---|---|---|
| Workspace Picker | `/` (first load) | T4 |
| Dashboard | `/` | T5 |
| Features list | `/features` | T6 |
| Feature Detail + Review actions | `/features/:featureId` | T7 |
| New Feature modal | overlay on `/features` | T8 |
| Task Board (kanban) | `/tasks` | T9 |

### Architecture

**Stack:** Next.js 16 App Router · TypeScript (strict) · Tailwind CSS v4 · HeroUI v3 · `js-yaml` · `simple-git` · Node.js 20+

**Key structure:**

```
digital-factory-ui/
├── app/                        # Next.js App Router routes
│   ├── layout.tsx              # Root layout: sidebar + header shell
│   ├── page.tsx                # Dashboard / workspace picker
│   ├── features/[featureId]/   # Feature detail
│   └── tasks/                  # Task Board
├── components/                 # UI components by screen
├── lib/                        # workspace.ts, features.ts, tasks.ts, git.ts
├── actions/                    # Server Actions: approve.ts, init-feature.ts
├── types/                      # workspace.ts, feature.ts, task.ts
└── Dockerfile                  # node:20-alpine production image
```

**Active workspace state:** stored in `localStorage` (`active_workspace_id`) + `WorkspaceContext` — scopes all views without full page reload.

**Write flow (Approve/Reject/Reset):**
1. User clicks action on Feature Detail review card
2. Server Action reads `status.yaml` → updates fields → writes YAML → `git add + commit` on the feature branch via `simple-git`

**Write flow (New Feature):**
1. User submits modal form
2. Server Action scaffolds `docs/features/<id>/` directory structure → commits to new feature branch

### T10 — docker-compose

Added `digital-factory-ui` service to `docker-compose.yml` in the `workflow` repo (PR [#55](https://github.com/tiendv89/agent-workflow/pull/55)). Bind-mounts `WORKSPACE_SCAN_ROOT` and SSH key from host.

---

## Operational notes

### Running locally

```bash
cd digital-factory-ui
cp .env.local.example .env.local
# Edit .env.local: set WORKSPACE_SCAN_ROOT, GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, SSH_KEY_PATH
pnpm install && pnpm dev
# Open http://localhost:3000
```

### Running via docker-compose

```bash
docker compose up digital-factory-ui
```

Requires `WORKSPACE_SCAN_ROOT` in the root `.env` file. Bind-mounts the workspace root and SSH key from host.

### Configuration

```env
# digital-factory-ui/.env.local
WORKSPACE_SCAN_ROOT=/path/to/workspaces   # directory scanned for workspace.yaml files
GIT_AUTHOR_NAME=Your Name
GIT_AUTHOR_EMAIL=you@example.com
SSH_KEY_PATH=~/.ssh/id_ed25519
```

`WORKSPACE_SCAN_ROOT` is scanned one level deep for `workspace.yaml` files — each file defines one workspace entry in the picker.

### v1 rollback

The v1 codebase is preserved on the `v1-archive` branch of `digital-factory-ui`. To roll back: `git checkout v1-archive` and run as before.

### No automated test suite

v2 is a local developer tool. Manual acceptance testing per screen is the validation approach — no automated test suite was added in this release.

---

## Key design decisions

**D1 — Next.js 16 App Router over Electron or Vite+Express:**
Single process, single `pnpm dev` command. Server Components access `fs` directly — no API glue. Server Actions handle all writes without explicit API routes.

**D2 — `simple-git` for write-back:**
All UI-triggered state changes (Approve/Reject/Reset, New Feature) commit to the correct feature branch via `simple-git`. The YAML files are never written without a corresponding git commit — the management repo remains the authoritative record.

**D3 — `WORKSPACE_SCAN_ROOT` as the only required env var:**
Discovering workspaces by scanning a root directory avoids hard-coding workspace paths and supports any number of workspaces without config changes.

**D4 — No database or caching layer:**
The management repo YAML files are the source of truth. The UI reads them on every Server Component render. For a local single-user tool with low request volume, this is simpler and always consistent.

**D5 — v1 archive to branch (not deleted):**
`v1-archive` branch preserves the v1 history so a rollback is one `git checkout` away. The `main` branch receives a clean v2 scaffold with no v1 artifacts.

---

## What is NOT done (out of scope for v2)

- **Real-time agent log streaming** — no live log view; planned for a future version
- **Task done-marking via UI** — marking tasks `done` remains a human+git operation per workflow rules; the UI does not expose this action
- **Authentication / multi-user** — single-user local tool only
- **Mobile / responsive layout** — desktop-first at 1440px; no breakpoints
- **Automated test suite** — manual acceptance testing only for this release
- **`pr-create` skill in agent container** — noted as a known gap in the workflow; tracked separately

---

## PRs delivered

| Task | Repo | PR |
|---|---|---|
| T1 — v1 archive + v2 scaffold | digital-factory-ui | [#7](https://github.com/tiendv89/digital-factory-ui/pull/7) |
| T2 — Server data layer | digital-factory-ui | [#8](https://github.com/tiendv89/digital-factory-ui/pull/8) |
| T3 — App shell | digital-factory-ui | [#9](https://github.com/tiendv89/digital-factory-ui/pull/9) |
| T4 — Workspace Picker screen | digital-factory-ui | [#10](https://github.com/tiendv89/digital-factory-ui/pull/10) |
| T5 — Dashboard screen | digital-factory-ui | [#16](https://github.com/tiendv89/digital-factory-ui/pull/16) |
| T6 — Features list screen | digital-factory-ui | [#17](https://github.com/tiendv89/digital-factory-ui/pull/17) |
| T7 — Feature detail screen | digital-factory-ui | [#13](https://github.com/tiendv89/digital-factory-ui/pull/13) |
| T8 — New Feature modal | digital-factory-ui | [#14](https://github.com/tiendv89/digital-factory-ui/pull/14) |
| T9 — Task Board screen | digital-factory-ui | [#15](https://github.com/tiendv89/digital-factory-ui/pull/15) |
| T10 — docker-compose service entry | workflow | [#55](https://github.com/tiendv89/agent-workflow/pull/55) |
