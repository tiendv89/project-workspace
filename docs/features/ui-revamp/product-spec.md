# Product Specification

## Feature
- Feature ID: `ui-revamp`
- Title: `Delivery IDE — UI Revamp`

## Summary

Re-platform the existing Digital Factory dashboard (`digital-factory-ui`) into an
**agent-native, IDE-style workspace** ("Delivery IDE"). The new design keeps every
capability the current product already ships (board, agent chat, feature/task tracking,
member management, auth) and reorganises them into a dark, VS Code–like shell, while
introducing a set of net-new surfaces (an inbox of actionable agent requests, a code
diff + PR review view, team channels, an agents/team dashboard, org-level management,
and a command palette).

This spec scopes the revamp into **two tiers**:

1. **Implement immediately** — surfaces that map to data and APIs the product already
   has (re-shell + re-skin of existing, working features), **plus** org & workspace
   settings administration, which is built full-stack in this feature (new
   `user-service` endpoints + frontend) because the product owner requires it and no
   backing API exists yet.
2. **Placeholder** — net-new surfaces that depend on backend capabilities we do not yet
   have. These are built as visual shells (disabled / mock-backed) so the IDE layout is
   complete and navigable, then wired up in later milestones.

> The feature is therefore **multi-repo**: primarily a `digital-factory-ui` re-platform,
> with a focused backend slice in `user-service` for the admin API behind surface #14.

## Design

The design is a contract. All UI work in this feature must match it.

### Figma
- **Design Brief for IDE** — https://www.figma.com/design/KM1nnUk4kJttQlPnIvsHW9/Design-Brief-for-IDE
  - Covers all screens listed in the scope tables below: app shell (NavRail + Topbar),
    Board (kanban + list), Feature IDE (explorer + chat/thread + docs viewer + activity
    dock), Task Review (diff + review thread), Inbox, Agents/Team, Settings, Login,
    Command Palette, and the Org/Workspace setup + settings modals.

> The technical design (Phase 1) must carry this Figma URL forward into a `## Figma`
> section, and every frontend UI task must reference the relevant frame(s) per the
> workspace Figma propagation rules.

### Source material
- New design (drafted React/Figma export): `~/Downloads/design-brief/src/app`
- Current production app (real backend wiring): `digital-factory-ui` (Next.js 16, React 19,
  Tailwind v4, HeroUI v3, React Query, SSE chat)

## Problem

The current `digital-factory-ui` works but is structured as a conventional three-panel
kanban dashboard. As the product becomes more agent-driven, the interaction model needs
to change:

- Humans and agents collaborate on the **same artifacts** (spec, tech design, tasks,
  logs) but the current UI scatters them across modal sheets and tabs rather than a
  single workbench.
- Agents now **ask for decisions** (gate approvals, blocking questions) that have no
  dedicated, actionable surface — they are buried in a read-only activity feed.
- Code review and PR state are **read-only references** today; reviewers cannot see a
  diff or a review thread in-product.
- There is no first-class view of **who (human or agent) is doing what right now**.
- Navigation is mouse-driven; power users expect a **command palette** and an IDE feel.

The revamp adopts an IDE metaphor so that specs, tasks, agent conversations, code, and
decisions live in one coherent workbench.

## Goals

- **Preserve parity.** Every capability that ships today in `digital-factory-ui` remains
  available after the revamp, with no loss of real-data functionality.
- **Adopt the new shell.** Ship the dark IDE shell (NavRail + Topbar + breadcrumb +
  org/workspace switcher + command palette entry) as the new app frame.
- **Consolidate the feature workbench.** Combine feature artifacts (spec / tech-design /
  tasks / logs / handoffs), the task list, agent sessions, and a live activity dock into
  a single "Feature IDE" view.
- **Surface agent decisions.** Provide an Inbox view for gate requests, questions, and
  blocks. v1 is a **visual placeholder** (the layout and item types ship, actions are
  stubbed); it becomes actionable once a decision/gate API exists.
- **Ship full org + workspace administration, full-stack.** Build the org/workspace
  settings UI **and** the new `user-service` admin endpoints it needs (org members,
  role-change, settings, danger zone) in this feature — see surface #14. (Existing
  workspace member/invitation management is already real.)
- **Establish placeholders for net-new surfaces** (diff/review, team channels, agents
  dashboard, org/billing/security settings) so the layout is complete and the backlog is
  visible, without faking functionality that doesn't exist.
- **Match the design.** Visual output (layout, spacing, color tokens, typography, states)
  matches the Figma brief.

## Non-goals

- **No new backend *services* in this feature.** The revamp is primarily a frontend
  re-platforming. The **one** backend exception in scope is adding org/workspace **admin
  endpoints to the existing `user-service`** (surface #14) — not a new service. All other
  net-new backend capabilities (diff/PR-content API, team channels, agent-workload
  telemetry, billing, 2FA/API-token/audit, agent-default config) are explicitly **out of
  scope** here and tracked as their own future features.
- **No change to the workflow state machine.** Task/feature lifecycle statuses and
  transitions are unchanged (the new design's status set already matches the current
  workflow: `todo … cancelled`, `in_design … cancelled`).
- **Not a rewrite of working logic.** Existing API clients, React Query hooks, auth, and
  SSE chat plumbing are reused; this is a re-shell, not a from-scratch build.
- **No new org data model.** Org switching and org administration reuse the existing
  membership model (`org_id` / `org_slug` / `role`); no new org entity or schema is
  introduced. (Org *billing* and *security* remain placeholder — see scope tables.)

## Delivery & migration

- **Repo target: in-place, multi-repo.** The frontend revamp is delivered inside the
  existing `digital-factory-ui` app — same Next.js codebase, reusing its API clients,
  React Query hooks, auth, and SSE chat. The admin API for surface #14 is added to the
  existing **`user-service`** (Go). Both repos are already registered in `workspace.yaml`;
  no new repo and no `workspace.yaml` change is required.
- **Cutover: big-bang shell swap.** The new IDE shell replaces the current three-panel
  layout in one switch rather than an incremental, route-by-route, flag-gated migration.
  Task breakdown should therefore sequence: (1) shell + theme + routing skeleton, (2)
  port each existing surface into the new shell, (3) net-new placeholder surfaces. The
  old layout is removed once the new shell reaches parity — there is no long-lived dual
  layout behind a flag.

## Scope — Implement immediately (real data, parity with current app)

These surfaces back onto APIs and hooks that already exist in `digital-factory-ui`
(workflow-backend REST + user-service + SSE chat). They are re-skinned to the new design
and ship functional.

| # | Surface | New design source | Maps to existing capability |
|---|---|---|---|
| 1 | **App shell** — NavRail, Topbar, breadcrumb, dark VS Code theme | `Shell.tsx` | New frame around existing routes; replaces `WorkspaceHeader` |
| 2 | **Login / OAuth** (Google, GitHub) | `LoginPage.tsx` | `/login` + `/auth/{provider}/start` (real) |
| 3 | **Org / Workspace switcher** (select + switch) | `Shell.tsx` Topbar switcher | Existing `WorkspaceSwitcher` + membership `org_id/org_slug` data |
| 4 | **Board** — kanban (status columns) + list view, status filters, search, feature/task modes, pagination | `BoardView.tsx` | Existing `KanbanBoard`, status-filter store, board hooks (real) |
| 5 | **New Feature** creation (name, description, start stage) | `BoardView.tsx` NewFeatureModal | Maps to feature creation / `init-feature` flow |
| 6 | **Feature IDE — Explorer** (artifacts: spec/tech-design/tasks/logs/handoffs + scrollable task list) | `FeatureIDE.tsx` left panel | Existing feature detail + documents + tasks (real) |
| 7 | **Feature IDE — Docs/Spec viewer** with tabs (Product Spec, Tech Design, Tasks, Logs) | `FeatureIDE.tsx` right panel | Existing `FeatureDocumentPanel` markdown rendering (real) |
| 8 | **Feature IDE — Activity dock** (live status changes, agent actions, PR/CI events) | `FeatureIDE.tsx` bottom dock | Existing `ActivityFeed` + activity endpoint (real) |
| 9 | **Agent sessions** (private 1:1 agent chat per feature/task, streaming, tool calls, model/context bar, slash commands) | `FeatureIDE.tsx` center panel (Sessions) | Existing `AgentChatPanel` + SSE chat service (real) |
| 10 | **Task detail / navigation** (open task, status, repos, PR refs, blocked reason) | `BoardView` → `FeatureIDE`/`TaskReview` routing | Existing `TaskDetailSheet` (read-only) |
| 11 | **Workspace member management** (members table, invite by email + role, remove, pending invitations, cancel invite) | `WorkspaceModals.tsx` Members tab | Existing `/api/admin/workspace/{id}/members` + `/invitations` (m1-admin-panel, **verified**) |
| 12 | **Settings — Account** (display name, email, theme toggle, current workspace) | `SettingsPage.tsx` Account | Existing `Me` endpoint + profile (real) |
| 13 | **Command palette — navigation** (go to feature/task/view) | `CommandPalette.tsx` Navigate group | New, but navigation-only over existing routes |
| 14 | **Org & Workspace settings — administration** (org + workspace General; org Members + in-place role-change; Workspaces list; Danger zone: rename/transfer/delete) | `WorkspaceModals.tsx` Org/Workspace settings | **Full-stack, in scope.** Frontend in `digital-factory-ui`; **new admin endpoints built in `user-service`** (currently absent — see below). *Excludes* Billing (I) & Security (H) tabs |

### Org & workspace administration — full-stack work in scope

Surface #14 is the one in-scope item that is **not** already backed. The product decision
is to build it end-to-end **in this feature**, across two repos (both already registered
in `workspace.yaml`):

- **`digital-factory-ui`** — the org/workspace settings UI (`WorkspaceModals.tsx`:
  General, Members, Workspaces, Danger zone tabs) wired to the new endpoints.
- **`user-service`** — new admin endpoints. Today only workspace member/invitation
  management exists (`/api/admin/workspace/{id}/members` + `/invitations`); the store
  layer (`internal/organizations`) has org primitives but they are not exposed over HTTP.
  New capabilities required (exact routes/shapes are Phase-1 tech-lead design):
  - **Org admin:** list org members; invite to org; **change member role**; remove member;
    get/update org (name, slug); list org workspaces; transfer ownership; delete org.
  - **Workspace settings:** update workspace (name/slug/color); **in-place member
    role-change**; delete/transfer workspace.

> Per the workspace one-repo-per-task rule, this splits into paired tasks — a
> `user-service` backend task and a dependent `digital-factory-ui` frontend task — for
> each capability group. Sequence the backend endpoint ahead of the frontend that
> consumes it.

## Scope — Placeholder (net-new; build the shell, defer the wiring)

These surfaces are part of the new design but require backend capabilities that do not
exist today. Build them to the Figma design as **visual placeholders** — disabled
controls, "coming soon" / empty states, or clearly-labelled mock content — so the IDE is
complete and navigable. Each becomes its own future feature.

| # | Surface | New design source | Why placeholder (missing backend) |
|---|---|---|---|
| A | **Task Review — code diff viewer** (file diffs, +/- gutter, multi-repo PR switcher) | `TaskReview.tsx` left | No diff/PR-content API; today PRs are read-only refs. Show real PR metadata, placeholder diff body |
| B | **Review thread / inline PR comments** (approve / request changes / merge) | `TaskReview.tsx` right | Needs GitHub review-API integration + write actions |
| C | **Team channels** (async Slack-style team chat on a feature) | `FeatureIDE.tsx` Channels | No channels backend; distinct from agent sessions which DO exist |
| D | **Inbox** (gate/question/block/fyi list + filters + Approve/Reply/Resolve/Dismiss) | `InboxView.tsx` | **v1 = placeholder.** Build the full view (layout, filter tabs, item types, grouped-by-feature) with mock/empty content; all actions stubbed. Wire to a real decision/gate + notifications API in a later feature |
| E | **Decision cards** (in-thread agent "Shall I proceed?" Approve/Reject) | `FeatureIDE.tsx` sessions | Needs gate/decision API to persist the verdict |
| F | **Agents / Team dashboard — workload** (live workload %, idle/working telemetry) | `AgentsView.tsx` | Member roster is real; per-agent live workload/telemetry has no source. Show roster, placeholder workload |
| G | **Settings — Agent defaults** (default model, auto-assign, gate-all-PRs, max concurrent) | `SettingsPage.tsx` | No agent-config persistence API |
| H | **Settings — Security** (2FA, API tokens, active sessions, audit log) | `SettingsPage.tsx` | No security/token/audit backend |
| I | **Billing / Plans** (Free/Pro/Enterprise, usage, upgrade) — both org and workspace Billing tabs | `WorkspaceModals.tsx` Billing | No billing backend |
| J | **Command palette — action execution** (approve design, mark ready, request changes) | `CommandPalette.tsx` Actions/Agent | Navigation is real; mutating commands need the same APIs as D/B/E |
| K | **Topbar layout toggles** (column/panel/sidebar visibility) | `Shell.tsx` Topbar | Cosmetic; ship as no-op toggles or defer |

> **Org/Workspace settings:** the full administration surface (org + workspace General,
> Members, role-change, Workspaces, Danger zone) is **in scope full-stack** — see
> "Org & workspace administration" below. Only the **Billing** (I) and **Security** (H)
> tabs within those modals remain placeholder.

## Decision rationale

The split is drawn on one line: **does the data/API already exist in production today?**

- If yes → **implement now.** The revamp's risk there is purely visual/structural
  (re-shell + re-skin), and shipping it real avoids a regression against the current app.
- If no → **placeholder.** Faking functionality (mock approvals, fake diffs that don't
  reflect the repo, invented workload numbers) would mislead users and create trust
  debt. A clearly-labelled placeholder keeps the design whole and the gap honest, and
  lets each capability be promoted to "real" in its own feature with its own backend.

## Dependencies & related features

This revamp consumes the output of features that have **already shipped** — which is
exactly why their surfaces qualify for immediate scope (the backend exists today):

- `m3-agent-chat` / `m3-agent-chat-v2` — **done.** Agent sessions / streaming chat (feeds surface #9)
- `m1-admin-panel` — **done.** Workspace member & invitation management (feeds surface #11)
- `tasks-api-integration` — **done.** Task & feature data source (feeds #4, #6–#10)

One dependency is still in progress:

- `workflow-db` — **ready_for_implementation** (not done). Task/feature persistence
  backing #4 and #6–#10 is being migrated to Postgres. The revamp reads the same
  workflow-backend REST API regardless of the underlying store, so this is not a hard
  blocker, but Phase 1 should confirm no API-shape changes land mid-revamp.

Placeholders A–K each imply a future backend feature (diff/PR-content API, channels
service, gate/decision API, agent telemetry, agent-config store, security/audit,
billing). These are **named here but specced separately** — they are not part of
`ui-revamp`. (The org/workspace admin API is the exception — it is pulled **into** this
feature as surface #14, not deferred.)

## Resolved decisions

These were confirmed with the product owner and are now binding for Phase 1/2:

1. **Org layer depth → full org administration, built full-stack in this feature.** The
   product owner requires full org + workspace settings. A check of `user-service` (route
   table verified) confirms the backing API does **not** exist today — only workspace
   member/invitation management. Decision: rather than defer, **build the missing admin
   endpoints in `user-service` and the settings UI in `digital-factory-ui` as part of
   this feature** (surface #14). This makes `ui-revamp` multi-repo. Org *switching* (#3)
   and existing workspace *member management* (#11) were already real.
2. **Inbox v1 → placeholder.** Build the full Inbox view to the design with stubbed
   actions; wire to a real decision/gate + notifications API in a later feature.
3. **Repo target → in-place in `digital-factory-ui`.** No new repo; reuse the existing
   app's clients, hooks, auth, and SSE chat. No `workspace.yaml` change needed.
4. **Cutover → big-bang shell swap.** Replace the current layout in one switch once the
   new shell reaches parity; no long-lived dual layout behind a flag.

> Per the product-spec write boundary, no workspace files (`workspace.yaml`, repo
> registration, `CLAUDE.md`, `.env`) were modified while drafting this spec. None are
> required given decision #3 (in-place delivery).

## For the tech lead (Phase 1 dependencies to confirm)

- **Org/workspace admin API — to be built in this feature (surface #14).** A check of
  `user-service` (`internal/handler/router.go`, `cmd/api/api.go`) confirms the current
  admin route table is workspace member/invitation management only:
  `GET/DELETE /api/admin/workspace/{id}/members`, `GET/POST/DELETE .../invitations`.
  There is no org-scoped admin route, no workspace-settings route, and no role-change
  route. Org operations exist at the DB-store layer (`internal/organizations`) but are
  not exposed over HTTP. Phase 1 must **design the new endpoint set** (org members,
  role-change, org/workspace settings, danger zone) and Phase 2 must break it into paired
  `user-service` → `digital-factory-ui` tasks (backend before dependent frontend).
- **Auth/permission model for admin actions.** New mutations (role-change, delete org,
  transfer ownership) need an authorization policy — who can perform them at org vs
  workspace scope. The existing `RequireAdminAuth` guard covers workspace admin; org-scope
  authorization must be defined in Phase 1.
