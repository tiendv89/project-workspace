# Technical Design

## Feature
- Feature ID: `ui-revamp`
- Title: `Delivery IDE — UI Revamp`

> **Pre-flight note:** the RAG MCP (`mcp__rag-server__rag_query`) and GitNexus MCP
> (`mcp__gitnexus__*`) were not available in this session; design grounding was done by
> direct reads of `digital-factory-ui`, `user-service`, and `workflow-backend`. No prior
> RAG decisions were injected.

## Figma

Per the product spec's design contract (Figma propagation rule), the design source of
truth is the **Dashboard-Workflow-UI** Figma file. Each in-scope screen maps to a
specific frame node below.

- **Dashboard-Workflow-UI** — https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI

> The earlier `Design-Brief-for-IDE` file (`KM1nnUk4…`) was the prototype/code-export
> used for the product spec; `Dashboard-Workflow-UI` (above) is the authoritative,
> per-frame design and supersedes it for implementation.

Frame → screen mapping (every surface in scope; `node-id` links are the per-task design
contract):

| Screen | Figma frame (`node-id`) | Tier | Tech-design section |
|---|---|---|---|
| Sign in / Login | [`122-2`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-2&m=dev) | real | §4 Login |
| Features tab — Kanban view | [`122-70`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-70&m=dev) | real | §4 Board |
| Features tab — List view | [`122-529`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-529&m=dev) | real | §4 Board |
| Feature IDE | [`122-1160`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-1160&m=dev) | real | §4 Feature IDE |
| Feature IDE — agent **channel** chat open | [`122-1527`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-1527&m=dev) | **placeholder** (channels) | §4 Feature IDE |
| Feature IDE — agent **session** chat open | [`123-9317`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=123-9317&m=dev) | real (sessions) | §4 Feature IDE |
| Feature code review | [`122-2029`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-2029&m=dev) | **placeholder** (diff/thread) | §4 Task Review |
| Notifications / Inbox | [`122-971`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-971&m=dev) | **placeholder** | §4 Inbox |
| Team | [`122-2344`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-2344&m=dev) | partial (roster real, workload placeholder) | §4 Agents |
| Search command (⌘K) | [`122-8762`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-8762&m=dev) | nav real, actions placeholder | §4 Command palette |
| Settings | [`122-2543`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-2543&m=dev) | Account real; Security/Agent-defaults placeholder | §4 Settings |
| **Org settings — General** | [`122-3735`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-3735&m=dev) | real (#14, `user-service`) | §4 #14 |
| **Org settings — Members** | [`122-4310`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-4310&m=dev) | real (#14) | §4 #14 |
| **Org settings — Workspaces** | [`122-4916`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-4916&m=dev) | real (#14) | §4 #14 |
| **Org settings — Delete (Danger zone)** | [`122-5495`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-5495&m=dev) | real (#14) | §4 #14 |
| Workspace — Create | [`122-7652`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-7652&m=dev) | see note¹ | §4 #14 |
| Workspace settings — General | [`122-6046`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-6046&m=dev) | **placeholder** (D2 — entity in workflow-backend) | §4 #14 |
| Workspace settings — Members | [`122-6576`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-6576&m=dev) | real (#11 + role-change via #14) | §4 #14 |
| Workspace settings — Danger zone | [`122-7136`](https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=122-7136&m=dev) | **placeholder** (D2) | §4 #14 |

¹ **Workspace Create** — workspace creation today is `POST /api/workspaces/import` on
`workflow-backend`. The Create UI ships, wired to the existing import path; net-new
fields in the Figma (plan, color) that have no backend are placeholder.

Every frontend task in the Phase-2 breakdown that implements one of these surfaces must
carry a `### Figma` subsection naming the relevant frame `node-id`(s) (frontend Figma
rule). When `FIGMA_PERSONAL_ACCESS_TOKEN` is set, the implementing agent must read the
frame via the Figma MCP before writing UI (Figma MCP usage rule).

---

## 1. Current state

### 1.1 `digital-factory-ui` (frontend — Next.js 16, React 19)
- **App Router** with routes: `/` (redirects to `/board`), `/login`, `/board`,
  `/admin/members`, `/admin/connect`, `/feature/[sessionId]`, `/task/[sessionId]`,
  `/api/content/fetch`. Layout in `src/app/layout.tsx`; providers in
  `src/app/providers/AppProviders.tsx` (workspace context, session auth, React Query).
- **Three-panel board** (`src/app/board/page.tsx`): `TaskTrackingPanel` ‖ `KanbanBoard`
  ‖ `AgentChatPanel`, under a `WorkspaceHeader`.
- **Feature/task detail** rendered as sheets/tab views (`FeatureTabView` with
  documents/tasks/logs/activity panels; `TaskDetailSheet` read-only).
- **Agent chat** (`src/features/agent-chat/AgentChatPanel.tsx`) over SSE
  (`@microsoft/fetch-event-source`) — sessions, tool calls, slash commands.
- **Styling** is already **CSS-variable-token based**: `tailwind.config.ts` maps
  Tailwind colors to `var(--color-*)`; HeroUI v3 + Tailwind v4 + Framer Motion +
  Lucide. This matters — re-theming is largely a **token swap**, not a rewrite.
- **State**: React Context (`WorkspaceContext`, `SessionContext`, `BoardContext`) +
  React Query v5 + localStorage stores (board mode, status filter, tab state).
- Real backend wiring to two services (below). No mock data.

### 1.2 `user-service` (Go — identity / org)
- Route table (`internal/handler/router.go`, `cmd/api/api.go`) is small and authoritative:
  - `GET /auth/:provider/start|callback`, `POST /auth/logout`, `GET /api/me`
  - `POST /internal/sessions/validate`
  - **Admin (workspace-scoped only):** `GET /api/admin/workspace/:id/members`,
    `DELETE …/members/:userId`, `GET …/invitations`, `POST …/invitations`,
    `DELETE …/invitations/:invitationId`
- **Schema** (`migrations/00001_initial_identity_schema.sql`): `users`,
  `auth_identities`, `organizations`, `memberships` (user↔org, carries `role`),
  `workspace_memberships` (user↔workspace_id; **no role column**),
  `organization_invitations`, `sessions`.
- **Store** (`internal/organizations/organizations.go`) has org primitives
  (`CreateOrganization`, `FindOrganizationByID/BySlug`, `EnsureMembership`,
  `MembershipsByUser`, `CreateInvitation`, `WorkspaceMembers`,
  `DeleteWorkspaceMembership`, …) but **no** `UpdateOrganization`, `DeleteOrganization`,
  `ChangeMembershipRole`, or `RemoveOrgMembership`.
- **Auth guard** `RequireAdminAuth` (`internal/handler/admin.go`) is **workspace-scoped**
  and checks the caller holds `admin`/`platform_admin` on *some* org. There is no
  org-scoped admin guard.

### 1.3 `workflow-backend` (workspace + feature/task data)
- Owns the **workspace entity** and feature/task data. Routes include
  `/api/workspaces` (`import`, `:id`, `:id/sync`), `/features…`, `/tasks…`,
  `/…/chat…` (SSE). There is **no workspace update / rename / delete** endpoint — a
  workspace is created via `import` and refreshed via `sync` only.

### 1.4 The new design (`~/Downloads/design-brief`)
- Figma-exported React prototype ("Delivery IDE"): dark VS Code aesthetic, oklch tokens,
  a left **NavRail** + top **Topbar** shell, and six primary views (Board, Feature IDE,
  Inbox, Agents/Team, Task Review, Settings) plus Login, Command Palette, and
  org/workspace setup + settings modals. Navigation in the prototype is **client-side
  view state** (a `view` enum in `App.tsx`), not routes. All data is seed/mock.

---

## 2. Problem framing

### What must change
- Replace the current three-panel board shell with the dark **NavRail + Topbar** IDE
  shell and re-skin every existing surface to the Figma design.
- Consolidate feature artifacts + tasks + agent sessions + activity into a single
  **Feature IDE** workbench.
- Add net-new surfaces as **placeholders** (Task Review diff, Inbox, Team channels,
  Agents workload, Billing, Security, Agent defaults).
- Build **org & workspace settings administration (#14)** full-stack — the only in-scope
  surface lacking an API today.

### What must remain stable
- The workflow state machine (task/feature lifecycle statuses) — unchanged; the new
  design's status set already matches.
- Existing API clients, React Query hooks, auth, and SSE chat plumbing — **reused**, not
  rewritten.
- Deep-linkability of features/tasks (existing `/feature/[id]`, `/task/[id]` routes).

### Fixed assumptions (from product spec — Resolved decisions)
- **In-place** in `digital-factory-ui`; **big-bang** cutover (no long-lived dual layout).
- **Inbox v1 = placeholder.**
- **Full org administration is wanted** — pulled into this feature (#14), not deferred.

---

## 3. Options considered

### Decision A — Routing model: routes vs. prototype's client-side view state

- **A1 — Keep Next App Router routes; implement the shell as a persistent layout.**
  Map NavRail items to routes (`board→/board`, `feature-ide→/feature/[id]`,
  `inbox→/inbox`, `agents→/team`, `task-review→/task/[id]`, `settings→/settings`). The
  NavRail/Topbar live in a shared layout (`src/app/(shell)/layout.tsx`).
  - Pros: preserves deep-linking, SSR, existing routes and `WorkspaceContext` tab state;
    smallest behavioral regression risk; aligns with Next idioms.
  - Cons: more wiring than a single-page view switch; must adapt the prototype's
    `view`-enum logic into route segments.
- **A2 — Port the prototype's single-page client `view` state.** One route renders an
  `App`-like switch.
  - Pros: 1:1 with the prototype; fast to assemble.
  - Cons: throws away deep-linking and the existing routed pages; SEO/SSR regression;
    fights the framework. Rejected.

**Chosen: A1.**

### Decision B — Component strategy: import prototype code vs. rebuild on existing stack

- **B1 — Treat the prototype as Figma reference; rebuild surfaces on the app's HeroUI +
  Tailwind-token stack.** The prototype uses hand-rolled components + shadcn tokens; the
  app uses HeroUI v3.
  - Pros: one component system; reuses existing tested components
    (`KanbanBoard`, `AgentChatPanel`, `FeatureDocumentPanel`, `ActivityFeed`); design
    fidelity enforced via the Figma rule, not via copy-paste.
  - Cons: more implementation effort than copy-paste.
- **B2 — Import prototype `.tsx` wholesale.** Pulls in a second, parallel component
  system + shadcn deps; diverges from HeroUI; mock data baked in. Rejected.

**Chosen: B1** (with the new oklch token set ported into the Tailwind theme layer).

### Decision C — Theme migration

- The app is already token-driven (`var(--color-*)`). **Port the design brief's dark
  oklch palette into `globals.css` + `tailwind.config.ts`**, dark as default. Low risk;
  no component-by-component restyle needed beyond the new shell. (No real alternative
  worth listing — a hardcoded restyle would be strictly worse.)

### Decision D — Scope of #14 (org & workspace administration) — the key decision

The product owner asked for "full org settings." Grounding shows the capability splits
across **three** possible repos, with very different cost:

| Capability | Data owner | Exists today? | Repo |
|---|---|---|---|
| Org General (name/slug), members list, invite, **role-change**, remove, delete org, transfer | `organizations` / `memberships` / `organization_invitations` | Schema yes; **endpoints no** | `user-service` |
| Workspace member management (list/invite/remove) | `memberships` + `workspace_memberships` | **Yes** (#11) | `user-service` |
| Workspace **entity** settings (rename / slug / color / delete) | workspace entity in workflow-backend DB | **No update/delete endpoint**; entity not in user-service | `workflow-backend` |

- **D1 — Full three-repo build.** Org admin in `user-service` + workspace-entity
  settings in `workflow-backend` + UI in `digital-factory-ui`.
  - Pros: every tab in the Figma settings modals is real.
  - Cons: drags `workflow-backend`'s workspace-entity model (created only via `import`)
    into a UI revamp; larger blast radius; workspace rename/delete is comparatively
    low-value governance.
- **D2 — Org admin full-stack now; workspace-entity settings stay placeholder.**
  Implement all **org** administration + **member role-change** in `user-service` +
  `digital-factory-ui`; render the workspace **General/Danger-zone** tab to the design
  but disabled ("managed via import/sync"), pending a future `workflow-backend` slice.
  - Pros: delivers the high-value governance surface (org membership, roles, org
    lifecycle) using the existing user-service schema; keeps the feature to **two**
    repos; honest about the workspace-entity gap.
  - Cons: workspace rename/delete not yet real (it isn't today either).

**Chosen: D2.** It satisfies the intent of the decision ("full org settings") with the
data model that actually exists, and contains scope to two repos. Workspace-entity
settings are flagged as a fast-follow `workflow-backend` feature. *If the human prefers
D1 at design approval, add `workflow-backend` tasks — both repos are already registered.*

> **Role model note:** roles live on the **org** membership (`memberships.role`);
> `workspace_memberships` has no role column. So "change a member's role" is an
> org-scoped operation. The UI may present it under either the org or workspace Members
> tab, but it mutates `memberships.role`.

---

## 4. Chosen design

### Shell & routing
- New route group `src/app/(shell)/layout.tsx` renders **NavRail** (left) + **Topbar**
  (breadcrumb, org/workspace switcher, command-palette trigger, layout toggles) and a
  `<main>` slot. Dark theme default.
- Existing routed pages move under the group and render into `<main>`:
  `board`, `feature/[id]` (→ Feature IDE), `task/[id]` (→ Task Review), plus new
  `inbox`, `team`, `settings`. `/login` stays outside the shell.
- `WorkspaceContext` (selected workspace, open tabs) and `SessionContext` are reused; the
  org/workspace switcher reads memberships from `/api/me`.

### Board
- Re-skin `KanbanBoard` + `BoardHeader` into the shell; keep status-filter store, search,
  feature/task modes, pagination. Add the **List** view (hierarchical feature→task
  table) from the design. `New Feature` modal maps to the existing feature-creation path.

### Feature IDE (`/feature/[id]`)
- Four-pane composition reusing existing components:
  - **Explorer (left):** artifacts (spec/tech-design/tasks/logs/handoffs) + task list —
    from `FeatureTabView` data. **Channels** + **Sessions** sections; Channels =
    placeholder (no backend), Sessions = real.
  - **Chat/Thread (center):** **Sessions** → existing `AgentChatPanel` (SSE, tool calls,
    model/context bar, slash commands). **Channels** → placeholder composer (disabled).
  - **Docs/Spec viewer (right):** tabs (Product Spec / Tech Design / Tasks / Logs) →
    existing `FeatureDocumentPanel` markdown rendering.
  - **Activity dock (bottom):** existing `ActivityFeed` over the activity endpoint.

### Task Review (`/task/[id]`) — placeholder diff
- Header + multi-repo PR pills render **real** PR metadata (`pr.url`, status, repo,
  branch from task data). **Diff body and review thread are placeholder** (no diff/PR
  content API; placeholder A/B in spec). Clearly labelled.

### Inbox (`/inbox`) — placeholder
- Full view to the design (filter tabs: All/Gate/Questions/Blocks/FYI; grouped by
  feature; item rows with action buttons) rendered from **empty/mock** state; all actions
  disabled/stubbed. No backend call. (Spec decision #2.)

### Agents / Team (`/team`) — partial
- Member **roster is real** (from org/workspace members via `/api/me` + member APIs).
  **Workload %, idle/working** indicators are placeholder (no telemetry source).

### Settings (`/settings`)
- **Account** (display name, theme, current workspace) — real (`/api/me`).
- **Notifications** prefs — local persisted (no server need for v1).
- **Security**, **Agent defaults** — placeholder (no backend).
- **Org & Workspace settings administration** — see #14 below.

### Login (`/login`)
- Re-skin to the Figma `LoginPage`; existing OAuth (`/auth/{provider}/start`) unchanged.

### Command palette
- Global ⌘K modal. **Navigate** group routes to existing pages (real). **Actions/Agent**
  groups render with permission gating but execution is **stubbed** (placeholder J).

### #14 — Org & workspace administration (full-stack, `user-service` + `digital-factory-ui`)

**Backend (`user-service`) — new, building on existing store + schema:**
- New store methods in `internal/organizations`: `UpdateOrganization(name, slug)`,
  `DeleteOrganization`, `ChangeMembershipRole(userID, orgID, role)`,
  `RemoveMembership(userID, orgID)`, `TransferOwnership(orgID, newOwnerUserID)`,
  `OrgMembers(orgID)`, `OrgWorkspaces(orgID)`.
- New org-scoped HTTP routes under `/api/admin/org/:orgId` (illustrative — exact shapes
  are Phase-2/implementation detail):
  - `GET /api/admin/org/:orgId` · `PATCH /api/admin/org/:orgId` (name/slug)
  - `GET /api/admin/org/:orgId/members`
  - `POST /api/admin/org/:orgId/invitations` (org invite)
  - `PATCH /api/admin/org/:orgId/members/:userId` (role-change)
  - `DELETE /api/admin/org/:orgId/members/:userId`
  - `GET /api/admin/org/:orgId/workspaces`
  - `POST /api/admin/org/:orgId/transfer` · `DELETE /api/admin/org/:orgId`
- New **`RequireOrgAdminAuth`** guard: authorize against `memberships.role` for the
  **path** org (not "some org" as the current workspace guard does). Define the policy:
  e.g. `admin`/`platform_admin` may manage members & settings; only an `owner`/the
  platform may transfer or delete. This authorization model is a **blocking design
  decision** to confirm at approval.

**Frontend (`digital-factory-ui`):**
- Org/Workspace settings modals (`WorkspaceModals` design): General, Members
  (list/invite/role-change/remove), Workspaces (list), Danger zone (transfer/delete org).
  Workspace **entity** General/Danger (rename/delete) rendered **disabled/placeholder**
  per Decision D2.
- New `user-service` client methods + React Query hooks mirroring `useAdminMembers`.

---

## 5. Dependency analysis

**Internal:**
- Frontend surfaces (Board, Feature IDE, Task Review, Settings) **depend on the shell**
  (route group + NavRail/Topbar) landing first.
- `#14` frontend (org settings UI) **depends on** the new `user-service` org-admin
  endpoints + the org-admin auth guard.
- Re-theme tokens are foundational to the shell's visual fidelity (soft dependency).

**External / cross-repo:**
- `user-service` org-admin endpoints — **new in this feature** (no blocker beyond build).
- `workflow-backend` workspace-entity settings — **out of scope (D2)**; only needed if
  the human elects D1.

**Blocking decisions (must resolve at design approval):**
1. **D2 vs D1** — is workspace-entity rename/delete in scope (adds `workflow-backend`)?
   Default: D2 (placeholder).
2. **Org-admin authorization policy** — who may role-change / transfer / delete at org
   scope. No existing org-scoped guard to inherit.
3. **`workflow-db` API stability** — `workflow-db` is `ready_for_implementation`; confirm
   no breaking shape change to the workflow-backend REST responses the frontend consumes
   mid-revamp. Not a hard blocker (same REST contract), but to be watched.

**Configuration / tooling:** no new env vars expected for the frontend. `user-service`
changes require a DB migration only if a column is added (none anticipated — role-change
mutates existing `memberships.role`; org slug/name columns already exist).

**Unresolved:** the org-admin authorization policy (#2) is genuinely unresolved and must
be answered before the `user-service` task can be marked `ready`.

---

## 6. Parallelization / blocking analysis

> Provisional decomposition (Phase 1). Phase 2 formalizes IDs, the one-repo-per-task
> split, and `tasks/T<n>.yaml`. Repos: `dfu` = `digital-factory-ui`, `usv` = `user-service`.

```
D-AUTH: Confirm org-admin authorization policy (who may role-change/transfer/delete) ──┐
D-SCOPE: Confirm D2 vs D1 (workspace-entity settings in scope?)                        ──┘ resolve at design approval; gate TB1 / T13

T1: Theme tokens + dark VS Code theme — dfu
  └── Can begin now — no blockers
  │
T2: App shell — NavRail + Topbar + switcher + breadcrumb + route group — dfu
      └── BLOCKED on T1 (shell needs the token palette for fidelity)
      │
      ├── T3: Board (kanban + list) reskin into shell — dfu
      │     └── BLOCKED on T2 (renders inside the shell layout)
      │
      ├── T4: Feature IDE (explorer + docs viewer + activity dock + agent sessions) — dfu
      │     └── BLOCKED on T2 (renders inside the shell layout)
      │     │
      │     └── T11: Team channels placeholder (in Feature IDE) — dfu
      │           └── BLOCKED on T4 (lives in the Feature IDE explorer/center pane)
      │
      ├── T5: Task Review (real PR metadata; diff + thread placeholder) — dfu
      │     └── BLOCKED on T2
      │
      ├── T6: Settings — Account real; Security/Agent-defaults placeholder — dfu
      │     └── BLOCKED on T2
      │
      ├── T8: Inbox (placeholder view) — dfu
      │     └── BLOCKED on T2
      │
      ├── T9: Agents/Team (roster real; workload placeholder) — dfu
      │     └── BLOCKED on T2
      │
      └── T10: Command palette (navigation real; actions placeholder) — dfu
            └── BLOCKED on T2

T7: Login page reskin — dfu
  └── BLOCKED on T1 (theme tokens); independent of the shell (renders outside it)

TB1: user-service — org-admin store methods + routes + RequireOrgAdminAuth — usv
  └── BLOCKED on D-AUTH (authorization policy must be locked before the guard is written)
  └── Otherwise independent of all dfu work — runs in parallel with T1–T11
  │
  T12: Org settings UI wired to org-admin endpoints — dfu
        └── BLOCKED on T2 (shell) AND TB1 (endpoints must exist)
  │
  T13: Workspace settings UI — member mgmt + role-change real; entity settings placeholder — dfu
        └── BLOCKED on T2 (shell) AND TB1 (role-change endpoint)
        └── BLOCKED on D-SCOPE (if D1 chosen, add a workflow-backend task upstream)
```

- **Can start immediately:** `T1` and (once `D-AUTH` is answered) `TB1` — frontend
  foundation and backend slice run in parallel.
- **Fan-out after `T2`:** `T3, T4, T5, T6, T8, T9, T10` are mutually independent and run
  in parallel (each renders into the shell).
- **Tail dependencies:** `T11` after `T4`; `T12`/`T13` after both `T2` and `TB1`.

---

## 7. Repository impact

| Repo (`workspace.yaml` id) | Why |
|---|---|
| `digital-factory-ui` | All frontend: shell, theme, every surface, #14 settings UI |
| `user-service` | New org-admin endpoints + store methods + org-scope auth guard (#14) |
| `workflow-backend` | **Only if Decision D1** is chosen (workspace-entity rename/delete). Default D2: no change |

All three are already registered in `workspace.yaml`; no registration change needed.
Per the one-repo-per-task rule, `#14` is split into a `user-service` backend task (`TB1`)
and dependent `digital-factory-ui` frontend tasks (`T12`, `T13`).

## 8. Validation and release impact

- **Testing:**
  - `digital-factory-ui`: Vitest + Testing Library for components; Playwright for the
    shell navigation, board, feature IDE, and settings flows. Visual parity against Figma
    frames is a review criterion (frontend Figma rule).
  - `user-service`: Go handler + store tests for every new endpoint (authz allow/deny,
    role-change, delete/transfer), following the existing `admin_test.go` patterns.
    `golangci-lint run` zero-errors before each commit (workspace Go rule).
- **Migration/config:** no DB migration anticipated (org name/slug columns exist;
  role-change mutates existing `memberships.role`). Confirm during `TB1` implementation;
  if a column is needed, add a migration under `user-service/migrations`.
- **Rollout (big-bang):** all work lands on a `feature/ui-revamp` branch per repo; the
  shell swap merges once parity is reached. No long-lived feature flag (spec decision #4).
  Because the cutover is big-bang, the **handoff gate** should verify full parity with the
  current app's real-data surfaces before the feature branch merges.
- **Backward compatibility:** existing routes (`/board`, `/feature/[id]`, `/task/[id]`)
  remain valid (mapped into the shell). The `user-service` changes are **additive** (new
  routes; existing workspace-admin routes untouched), so other consumers are unaffected.
- **Operational:** placeholders must be visibly labelled (not silently empty) so users and
  reviewers can tell "not built yet" from "broken."
