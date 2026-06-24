# Tasks — UI Revamp (`ui-revamp`)

> **Feature status (reference):** `in_tdd` → task planning (`current_stage: tasks`).
> **Stage status:** `tasks` draft, pending human approval.
> **Machine-mutable state lives in `tasks/T<n>.yaml`** — status, depends_on, branch,
> pr, and log are owned by the per-task YAML files, not this document. This file is the
> stable narrative (descriptions, required skills, Figma frames, subtasks).

Repos (`workspace.yaml` ids): `digital-factory-ui` (frontend), `user-service` (Go
identity/org), `workflow-backend` (workspace/feature/task data).

Design source of truth: **Dashboard-Workflow-UI** Figma file —
https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI
(see `technical-design.md` → `## Figma` for the full frame map).

## Index

| ID | Wave | Title | Repo | Depends on |
|---|---|---|---|---|
| T1 | 1 | Theme tokens + dark VS Code theme | digital-factory-ui | — |
| T15 | 1 | Org-admin endpoints + `RequireOrgAdminAuth` + org create | user-service | — |
| T16 | 1 | Blank workspace create (`POST /api/workspaces`) | workflow-backend | — |
| T2 | 2 | App shell — NavRail + Topbar + switcher + route group | digital-factory-ui | T1 |
| T7 | 2 | Login page reskin | digital-factory-ui | T1 |
| T3 | 3 | Board (Kanban + List) reskin into shell | digital-factory-ui | T2 |
| T4 | 3 | Feature IDE workbench | digital-factory-ui | T2 |
| T5 | 3 | Task Review (real PR meta; diff/thread placeholder) | digital-factory-ui | T2 |
| T6 | 3 | Settings (Account real; Security/Agent-defaults placeholder) | digital-factory-ui | T2 |
| T8 | 3 | Inbox (placeholder view) | digital-factory-ui | T2 |
| T9 | 3 | Agents/Team (roster real; workload placeholder) | digital-factory-ui | T2 |
| T10 | 3 | Command palette (nav real; actions placeholder) | digital-factory-ui | T2 |
| T11 | 4 | Feature IDE — channels placeholder | digital-factory-ui | T4 |
| T12 | 4 | Org settings UI (wired to org-admin endpoints) | digital-factory-ui | T2, T15 |
| T13 | 4 | Workspace settings UI (member mgmt real; entity placeholder) | digital-factory-ui | T2, T15 |
| T14 | 4 | Create-org + create-workspace flows | digital-factory-ui | T2, T15, T16 |

**Wave summary**
- **Wave 1 (start now, parallel):** `T1`, `T15`, `T16` — no blockers.
- **Wave 2 (after T1):** `T2` (shell) and `T7` (login) run in parallel.
- **Wave 3 (after T2):** `T3, T4, T5, T6, T8, T9, T10` — mutually independent, parallel.
- **Wave 4:** `T11` (after T4); `T12`, `T13` (after T2 + T15); `T14` (after T2 + T15 + T16).

All frontend tasks must follow the **frontend Figma implementation rule**: read the
listed frame(s) via the Figma MCP before writing UI when `FIGMA_PERSONAL_ACCESS_TOKEN`
is set; if it is set and a task carries a `### Figma` subsection, reading is mandatory.

---

## T1 — Theme tokens + dark VS Code theme

### Description
Port the design brief's dark **oklch** palette into the app's existing token layer
(`globals.css` + `tailwind.config.ts`), dark as default (Decision C). The app is already
token-driven (`var(--color-*)`), so this is a token swap, not a component rewrite. This is
the visual foundation every shell/surface task depends on for fidelity. No layout or
component structural changes here — only the token set, theme variables, and dark-default
wiring. Verify HeroUI v3 dark theme variables map to the new oklch values.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp

### Figma
Extract design tokens (oklch color variables, spacing, typography) via the Figma MCP
(`get_variable_defs`) across the **Dashboard-Workflow-UI** file. Representative frames for
visual token grounding:
- Board / Kanban — `node-id=122-70`
- Feature IDE — `node-id=122-1160`

No hardcoded hex/px that exist as Figma variables (no-orphan-values rule).

### Subtasks
- [ ] Read oklch variables from Figma via `get_variable_defs`; map to `--color-*` tokens.
- [ ] Update `globals.css` token definitions (dark palette) and set dark as default.
- [ ] Reconcile `tailwind.config.ts` color mappings with the new variables.
- [ ] Verify HeroUI v3 theme variables resolve against the new oklch tokens.
- [ ] Sanity-check existing surfaces render with the new tokens (no broken contrast).

---

## T15 — Org-admin endpoints + `RequireOrgAdminAuth` + org create (user-service)

### Description
Build org administration full-stack on `user-service`, on top of the existing
`organizations` / `memberships` / `organization_invitations` schema (Decisions D2, E,
B, D-AUTH). New store methods, new HTTP routes grouped under `/api/orgs` (no `/admin`
prefix; per-route authorization), the org-scoped `RequireOrgAdminAuth` guard, and the
self-serve org-create endpoint. Existing workspace-admin routes
(`/api/admin/workspace/...`) are left untouched for backward compatibility.

Store methods: `UpdateOrganization(name, slug)`, `DeleteOrganization`,
`ChangeMembershipRole(userID, orgID, role)`, `RemoveMembership(userID, orgID)`,
`TransferOwnership(orgID, newOwnerUserID)`, `OrgMembers(orgID)`, `OrgWorkspaces(orgID)`.

Routes (exact shapes are an implementation detail; each `/:orgId/*` route applies
`RequireOrgAdminAuth`):
- `POST /api/orgs` — **authenticated only, no org-admin guard** (Decision E): create org +
  `EnsureMembership(creator, "admin")` in one transaction.
- `GET /api/orgs/:orgId` · `PATCH /api/orgs/:orgId` (name/slug)
- `GET /api/orgs/:orgId/members` · `POST /api/orgs/:orgId/invitations`
- `PATCH /api/orgs/:orgId/members/:userId` (role-change, `member`↔`admin` only)
- `DELETE /api/orgs/:orgId/members/:userId`
- `GET /api/orgs/:orgId/workspaces`
- `POST /api/orgs/:orgId/transfer` · `DELETE /api/orgs/:orgId`

Authorization (D-AUTH): authorize against `memberships.role` for the **path** org. `admin`
or `platform_admin` on that org may perform all org-admin actions; `member` is read-only.
No new role, no migration (reuse `platform_admin`/`admin`/`member`). `platform_admin` acts
on any org and is **not assignable via the API** (admin-email list only); role-change
accepts only `member`/`admin`. **Last-admin guard:** reject any change that would leave an
org with zero `admin`s (`409`/`422`).

### Required skills
- backend-engineer
- go-best-practices
- postgres-best-practices

### Subtasks
- [ ] Add store methods in `internal/organizations` (Update/Delete/ChangeRole/Remove/Transfer/OrgMembers/OrgWorkspaces).
- [ ] Implement `RequireOrgAdminAuth` (path-org scoped) in `internal/handler`.
- [ ] Wire `/api/orgs` routes in `router.go` / `cmd/api/api.go`; apply per-route guard.
- [ ] Implement `POST /api/orgs` (authenticated, transactional create + admin membership).
- [ ] Enforce slug uniqueness + validation; enforce last-admin guard on role-change/remove/transfer.
- [ ] Go handler + store tests per endpoint (authz allow/deny, role-change, delete/transfer, last-admin) following `admin_test.go`.
- [ ] Confirm no migration needed; if a column is required, add one under `migrations/`.
- [ ] `golangci-lint run` zero-errors before each commit.

---

## T16 — Blank workspace create `POST /api/workspaces` (workflow-backend)

### Description
Add a **blank-create** workspace endpoint `POST /api/workspaces` on `workflow-backend`
(Decision F), distinct from the existing `POST /api/workspaces/import`. `name`/`slug` map
to the workspace entity; `color`/`plan` are placeholder unless the entity gains those
columns. The existing `import` path is unchanged (used for repo-backed workspaces).
Workspace-entity **settings** (rename/delete) remain out of scope (Decision D2) — this task
adds **create only**.

> **Stack note (open item):** `workflow-backend`'s language was not resolvable from the
> local environment during planning. The implementing agent must detect the stack first
> (`go.mod` → Go; `package.json`/Nest → TypeScript) and apply the matching idiom skill.
> Coordinate timing with any in-flight `workflow-db` work (shared workflow-backend REST
> contract) — same REST shape, not a hard blocker.

### Required skills
- backend-engineer
- postgres-best-practices

### Subtasks
- [ ] Detect the repo stack (`go.mod` vs `package.json`) and load the matching language skill.
- [ ] Add `POST /api/workspaces` (blank create: `name`/`slug`; `color`/`plan` placeholder).
- [ ] Reuse the existing workspace entity/store; do not alter the `import` path.
- [ ] Slug/name validation + uniqueness consistent with existing workspace creation.
- [ ] Handler + store tests for the new endpoint; run the repo's full test + lint suite.

---

## T2 — App shell: NavRail + Topbar + switcher + route group

### Description
Replace the three-panel board shell with the dark **NavRail (left) + Topbar (top)** IDE
shell as a persistent layout (Decision A1). Create the `src/app/(shell)/layout.tsx` route
group rendering NavRail + Topbar (breadcrumb, org/workspace switcher, command-palette
trigger, layout toggles) and a `<main>` slot. Move existing routed pages under the group;
add new route segments (`inbox`, `team`, `settings`). `/login` stays outside the shell.
Reuse `WorkspaceContext` (selected workspace, open tabs) and `SessionContext`; the
org/workspace switcher reads memberships from `/api/me`. This is the layout/navigation
chassis only — individual surface reskins are T3–T10.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma
- App shell (NavRail + Topbar) as seen on Board — `node-id=122-70`
- Shell on Feature IDE — `node-id=122-1160`
- Org/workspace switcher + command-palette trigger live in the Topbar of the above frames.

### Subtasks
- [ ] Read shell frames via Figma MCP before implementing.
- [ ] Create `(shell)` route group + `layout.tsx` with NavRail + Topbar + `<main>` slot.
- [ ] Map NavRail items to routes (board, feature/[id], task/[id], inbox, team, settings).
- [ ] Org/workspace switcher in Topbar wired to `/api/me` memberships.
- [ ] Breadcrumb + layout toggles; command-palette trigger (opens T10 palette).
- [ ] Move existing routed pages under the group; keep `/login` outside.
- [ ] Playwright smoke for shell navigation across routes.

---

## T7 — Login page reskin

### Description
Re-skin `/login` to the Figma `LoginPage`. Existing OAuth (`/auth/{provider}/start`)
behavior is unchanged — visual reskin only. Renders **outside** the shell, so it depends
only on the theme tokens (T1), not the shell (T2).

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma
- Sign in / Login — `node-id=122-2`

### Subtasks
- [ ] Read the Login frame via Figma MCP.
- [ ] Reskin `/login` to the design; keep OAuth start/callback wiring intact.
- [ ] Verify all interactive states (default, hover, focus, disabled, error).

---

## T3 — Board (Kanban + List) reskin into shell

### Description
Re-skin `KanbanBoard` + `BoardHeader` into the new shell; keep the status-filter store,
search, feature/task modes, and pagination. Add the **List** view (hierarchical
feature→task table) from the design. `New Feature` modal maps to the existing
feature-creation path. Renders into the shell `<main>`.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma
- Features tab — Kanban view — `node-id=122-70`
- Features tab — List view — `node-id=122-529`

### Subtasks
- [ ] Read Kanban + List frames via Figma MCP.
- [ ] Reskin `KanbanBoard` + `BoardHeader`; preserve filter/search/mode/pagination stores.
- [ ] Implement the List view (feature→task hierarchical table).
- [ ] Wire `New Feature` modal to the existing feature-creation path.
- [ ] Playwright coverage for board interactions and view switching.

---

## T4 — Feature IDE workbench

### Description
Consolidate feature artifacts + tasks + agent sessions + activity into a single Feature
IDE at `/feature/[id]` (Decision A1/B1), reusing existing components. Four panes:
- **Explorer (left):** artifacts (spec/tech-design/tasks/logs/handoffs) + task list from
  `FeatureTabView` data; **Sessions** section (real) and a **Channels** section header
  (placeholder content is T11).
- **Chat/Thread (center):** Sessions → existing `AgentChatPanel` (SSE, tool calls,
  model/context bar, slash commands).
- **Docs/Spec viewer (right):** tabs (Product Spec / Tech Design / Tasks / Logs) → existing
  `FeatureDocumentPanel` markdown rendering.
- **Activity dock (bottom):** existing `ActivityFeed` over the activity endpoint.

Reuse, don't rewrite, the existing chat/doc/activity components. Channels placeholder wiring
is split into T11.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma
- Feature IDE — `node-id=122-1160`
- Feature IDE — agent **session** chat open — `node-id=123-9317`

### Subtasks
- [ ] Read Feature IDE frames via Figma MCP.
- [ ] Compose four-pane layout into the shell `<main>` at `/feature/[id]`.
- [ ] Explorer: artifacts + task list from `FeatureTabView`; Sessions section (real).
- [ ] Center: mount existing `AgentChatPanel` for Sessions (SSE preserved).
- [ ] Right: `FeatureDocumentPanel` doc tabs; Bottom: `ActivityFeed` dock.
- [ ] Leave a Channels section placeholder hook for T11.
- [ ] Playwright coverage for the Feature IDE panes + session chat.

---

## T5 — Task Review (real PR metadata; diff + thread placeholder)

### Description
Re-skin `/task/[id]` to the Task Review design. Header + multi-repo **PR pills** render
**real** PR metadata (`pr.url`, status, repo, branch from task data). The **diff body and
review thread are placeholder** (no diff/PR-content API today) — rendered to the design but
clearly labelled "not built yet" (placeholder, not silently empty).

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma
- Feature code review — `node-id=122-2029`

### Subtasks
- [ ] Read the Task Review frame via Figma MCP.
- [ ] Render header + PR pills from real task `pr` data (url/status/repo/branch).
- [ ] Render diff body + review thread as a clearly-labelled placeholder.
- [ ] Verify against existing `/task/[id]` route data.

---

## T6 — Settings (Account real; Security / Agent-defaults placeholder)

### Description
Re-skin `/settings` to the design. **Account** (display name, theme, current workspace) is
real (`/api/me`). **Notifications** prefs are locally persisted (no server in v1).
**Security** and **Agent defaults** are placeholder (no backend) — labelled. Org & workspace
settings administration is delivered separately in T12/T13; this task is the Settings shell
+ Account/Notifications.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma
- Settings — `node-id=122-2543`

### Subtasks
- [ ] Read the Settings frame via Figma MCP.
- [ ] Account tab wired to `/api/me` (display name, theme, current workspace).
- [ ] Notifications prefs persisted locally.
- [ ] Security + Agent-defaults rendered as labelled placeholders.
- [ ] Leave entry points for org/workspace settings (T12/T13) without implementing them.

---

## T8 — Inbox (placeholder view)

### Description
Implement the full Inbox view to the design (filter tabs: All / Gate / Questions / Blocks /
FYI; grouped by feature; item rows with action buttons) rendered from **empty/mock** state.
All actions are disabled/stubbed; **no backend call** (spec decision #2, Inbox v1 =
placeholder). Must be visibly labelled as not-yet-built, not silently empty.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma
- Notifications / Inbox — `node-id=122-971`

### Subtasks
- [ ] Read the Inbox frame via Figma MCP.
- [ ] Build the `/inbox` view: filter tabs, feature grouping, item rows.
- [ ] Render from empty/mock state; disable/stub all actions; no backend call.
- [ ] Add a clear "placeholder / not yet wired" affordance.

---

## T9 — Agents / Team (roster real; workload placeholder)

### Description
Implement `/team`. The member **roster is real** (org/workspace members via `/api/me` +
member APIs). **Workload %, idle/working** indicators are placeholder (no telemetry source)
— labelled. Note: `agent` rows shown in Figma are not a `memberships.role`; the roster
reflects real human members from the member APIs.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma
- Team — `node-id=122-2344`

### Subtasks
- [ ] Read the Team frame via Figma MCP.
- [ ] Render the real member roster from `/api/me` + member APIs.
- [ ] Render workload/idle indicators as labelled placeholders.

---

## T10 — Command palette (navigation real; actions placeholder)

### Description
Global ⌘K command palette modal. The **Navigate** group routes to existing pages (real,
wired to the shell routes). **Actions / Agent** groups render with permission gating but
execution is **stubbed** (placeholder J). Triggered from the Topbar command-palette button
(T2) and the ⌘K shortcut.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma
- Search command (⌘K) — `node-id=122-8762`

### Subtasks
- [ ] Read the Command palette frame via Figma MCP.
- [ ] Global ⌘K modal; Navigate group routes to real shell pages.
- [ ] Actions/Agent groups: permission-gated UI, execution stubbed + labelled.
- [ ] Wire the Topbar trigger and the keyboard shortcut.

---

## T11 — Feature IDE — channels placeholder

### Description
Add the **Channels** placeholder inside the Feature IDE (explorer Channels section + center
placeholder composer, disabled). Channels have **no backend** — render to the design, clearly
labelled, composer disabled. Lives inside the Feature IDE built in T4, hence the dependency.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma
- Feature IDE — agent **channel** chat open — `node-id=122-1527`

### Subtasks
- [ ] Read the channel-chat frame via Figma MCP.
- [ ] Populate the Channels section in the Feature IDE explorer (placeholder list).
- [ ] Center pane: disabled placeholder composer for channels, clearly labelled.

---

## T12 — Org settings UI (wired to org-admin endpoints)

### Description
Implement the Org settings modals (`WorkspaceModals` design) wired to the new T15
`user-service` endpoints: **General** (name/slug edit), **Members**
(list / invite / role-change / remove), **Workspaces** (list), **Danger zone**
(transfer / delete org). Add `user-service` client methods + React Query hooks mirroring
`useAdminMembers`. Authorization affordances must follow the §4 #14 matrix (read-only for
`member`; admin actions for `admin`/`platform_admin`; last-admin guard surfaced as a clear
error). Depends on the shell (T2) and the endpoints (T15).

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma
- Org settings — General — `node-id=122-3735`
- Org settings — Members — `node-id=122-4310`
- Org settings — Workspaces — `node-id=122-4916`
- Org settings — Delete (Danger zone) — `node-id=122-5495`

### Subtasks
- [ ] Read all four org-settings frames via Figma MCP.
- [ ] Add user-service client methods + React Query hooks for the org-admin endpoints.
- [ ] General tab: name/slug edit (`PATCH /api/orgs/:orgId`).
- [ ] Members tab: list / invite / role-change (`member`↔`admin`) / remove.
- [ ] Workspaces tab: list (`GET /api/orgs/:orgId/workspaces`).
- [ ] Danger zone: transfer ownership + delete org, with confirmation.
- [ ] Gate UI by role per the authorization matrix; surface last-admin guard errors.
- [ ] Playwright coverage for the org settings flows.

---

## T13 — Workspace settings UI (member mgmt + role-change real; entity settings placeholder)

### Description
Implement the Workspace settings modals: **Members** is real (workspace member
list/invite/remove via the existing #11 APIs; role-change mutates `memberships.role` via the
T15 org endpoint). **General** (rename/slug/color) and **Danger zone** (rename/delete) are
**placeholder/disabled** per Decision D2 — rendered to the design but labelled "managed via
import/sync," pending a future `workflow-backend` slice. Depends on the shell (T2) and the
T15 role-change endpoint.

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma
- Workspace settings — Members — `node-id=122-6576` (real)
- Workspace settings — General — `node-id=122-6046` (placeholder, D2)
- Workspace settings — Danger zone — `node-id=122-7136` (placeholder, D2)

### Subtasks
- [ ] Read the three workspace-settings frames via Figma MCP.
- [ ] Members tab: real list/invite/remove (existing #11 APIs); role-change via T15 org endpoint.
- [ ] General + Danger-zone tabs: rendered disabled/placeholder, labelled (D2).
- [ ] Surface the org-role note (role lives on org membership) where role-change appears.
- [ ] Playwright coverage for the real member-management path.

---

## T14 — Create-org + create-workspace flows

### Description
Wire the **Create org** (Decision E → `POST /api/orgs`) and **Create workspace**
(Decision F → `POST /api/workspaces`) flows into the switcher / SetupScreen (NoOrgState).
"Import workspace" remains available via the existing `/admin/connect` import path.
`color`/`plan` on workspace create are placeholder unless the entity gains those columns.
Depends on the shell (T2), the org-create endpoint (T15), and the workspace-create
endpoint (T16).

### Required skills
- frontend-engineer
- nextjs-best-practices
- heroui-react
- typescript-best-practices
- figma-mcp
- browser-qa-frontend

### Figma
- Workspace — Create — `node-id=122-7652`
- Create-org flow renders in the switcher / SetupScreen (NoOrgState); no dedicated frame —
  follow the SetupScreen design and the Workspace-Create frame for form styling.

### Subtasks
- [ ] Read the Workspace-Create frame via Figma MCP; follow SetupScreen styling for create-org.
- [ ] Create-org form wired to `POST /api/orgs` (authenticated; creator becomes admin).
- [ ] Create-workspace form wired to `POST /api/workspaces` (blank create; color/plan placeholder).
- [ ] Keep "Import workspace" available via the existing `/admin/connect` path.
- [ ] Handle the no-org state (NoOrgState) → create-org entry point.
- [ ] Playwright coverage for create-org and create-workspace happy paths.
