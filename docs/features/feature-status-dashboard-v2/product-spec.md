# Product Specification

## Feature
- Feature ID: `workspace-interface`
- Title: `Workspace Interface — Web UI for Workspace Management`

## Problem

The agent workflow system is entirely file-driven. Humans and tech leads manage features and tasks by editing YAML files directly and running CLI commands. There is no visual surface to:

- See the status of all features at a glance
- Navigate from a feature's lifecycle stage into its tasks
- Approve or reject stage reviews (product spec, technical design, tasks, handoff)
- Understand the cross-feature task backlog as a kanban board
- Create a new feature without knowing the file layout

This creates friction for non-technical stakeholders reviewing work, and makes it hard to get a quick situational overview of what is in progress, blocked, or awaiting approval across features.

Additionally, the system manages **multiple workspaces** (each with its own `workspace.yaml`, repos, and `docs/features/` tree). There is currently no way to switch between workspaces without manually changing directories or config files.

## Goals

1. **Workspace picker** — On first load (and via a switcher in the sidebar), show a list of all known workspaces. Each workspace entry is discovered by scanning a configured root directory for `workspace.yaml` files. Selecting a workspace loads its `workspace.yaml`, resolves the `docs/features/` path, and scopes every subsequent view (Dashboard, Features, Task Board) to that workspace. The active workspace name and ID are shown persistently in the sidebar header and can be switched at any time without a full page reload.

2. **Dashboard** — Show an at-a-glance summary of the selected workspace: total features by lifecycle status, tasks by task status, recently updated items, and blocked items requiring attention.

3. **Features list** — Display all features for the workspace in a filterable, searchable table showing feature name, feature ID, lifecycle status, current stage + review status, task progress (completed/total with a gradient progress bar), and last-updated time.

4. **Feature detail** — Drill into a single feature to see its stage progress stepper (Product Spec → Technical Design → Tasks → Handoff), the current stage review card (reviewer, reviewed-at, review comment, Approve / Reject / Reset actions), and the full task list in list or kanban view.

5. **New feature creation** — A modal form that collects title, feature ID (auto-generated slug, editable), description, owner, default reviewer, target repos, priority, default actor type, and lifecycle start point. Submitting scaffolds `docs/features/<id>/` via `init-feature`.

6. **Task Board** — A cross-feature kanban board grouped by task status (Todo → Ready → In Progress → In Review → Blocked → Done → Cancelled), with filter dropdowns for feature and repo, and an actor toggle (All / Agent / Human). Task cards show feature tag, task ID, actor, title, repo, dependency count, and status badge.

## Non-goals

- This UI does not execute agent tasks or trigger workflow skills directly (no "run task" button).
- This UI does not edit task YAML files or approve tasks as done (done-marking remains a human+git operation per the workflow rules).
- No authentication / multi-user support in v1 — single-user local tool.
- No real-time agent log streaming in v1.
- No mobile / responsive layout — desktop-first at 1440px width.

## Screens

### 0. Workspace Picker (`/` on first load, or via sidebar switcher)
- Shown when no workspace is selected (first visit) or when the user clicks the workspace name in the sidebar.
- Displays a list of discovered workspaces: each card shows workspace name, workspace ID, repo path, and a brief status summary (e.g. "5 features · 2 in progress").
- Workspaces are discovered by scanning a user-configurable root directory (set in app settings or `.env`) for `workspace.yaml` files.
- Selecting a card sets the active workspace and redirects to the Dashboard.
- A **Search** field filters the list by workspace name or ID.
- The sidebar switcher: the "Workspace / Tracker" label at the top of the sidebar is a clickable element that opens the picker (as a dropdown or a modal overlay).

### 1. Dashboard (`/`)
- Sidebar: "Workspace / Tracker" branding — the workspace name and "Tracker" subtitle are a **clickable workspace switcher** that opens the Workspace Picker. Gradient icon, nav links (Dashboard active, Features, Task Board), Settings link, user avatar + name + role at bottom.
- Header bar: page title "Dashboard", subtitle, global search input with ⌘K shortcut, notification bell.
- Summary stat cards: Active Features, In Progress Tasks, Awaiting Approval, Blocked Tasks.
- Recent activity table or feed.
- All data is scoped to the currently selected workspace.

### 2. Features (`/features`)
- Same sidebar + header (header shows "Features / Browse and manage all features").
- Filter pill row: All · In Design · In TDD · Ready · In Implementation · In Handoff · Done · Blocked · Cancelled. Active pill is filled `#5465e8`.
- Secondary search input inside the filter row.
- Table with columns: **Feature** (title + monospace ID below), **Status** (colored badge), **Stage** (stage name + review-status badge stacked), **Tasks** (x/y count + blue→green gradient progress bar), **Last Updated** (relative time), and a `>` chevron.
- `+ New Feature` button (primary, top-right).

### 3. Feature Detail (`/features/:featureId`)
- Breadcrumb: `Features > <feature-id>` (monospace slug).
- Feature title + status badge + `<id> · last updated Xm ago` subtitle.
- **Stage stepper** — horizontal track with four nodes: Product Spec, Technical Design, Tasks, Handoff. Completed stages show a green circle with ✓ and a green connecting line. Current stage shows a blue-numbered circle (task count) and an amber "Awaiting Approval" badge. Each stage node shows a review badge below it.
- **Current stage review card** — stage name, review status badge (top-right), Reviewed By, Reviewed At, blockquote review comment. Action buttons: **Approve** (blue), **Reject** (red), **Reset** (grey text).
- **Tasks section** — heading "Tasks (N)" with List / Kanban toggle. Default list view is a table: ID (monospace), Title, Status badge, Repo, Actor (icon + label), PR link, Deps, Updated.

### 4. New Feature Modal (overlay on `/features`)
- Centered modal, 640 px wide. Header: gradient icon + "New Feature" + subtitle "Seed a feature at the start of the lifecycle", close ×.
- Fields:
  - **Title** (required text input) — placeholder "e.g. Agent Observability Dashboard"
  - **Feature ID** (required text, monospace font) — auto-generated from title as kebab-case slug; helper text "Auto-generated from title. Click to customize."
  - **Description** (textarea) — helper "Short summary shown on the feature list"
  - **Owner** (dropdown)
  - **Default Reviewer** (dropdown)
  - **Target Repos** (multi-chip selector, chips show repo IDs in monospace)
  - **Priority** segmented: Low / Med / High (default Med)
  - **Actor** segmented: Agent / Human / Either (default Agent)
  - **Start at** segmented: Spec / Design (default Spec)
- Footer: helper text "Will create `docs/features/<id>`", Cancel button, **Create feature** button (disabled until Title + ID filled).

### 5. Task Board (`/tasks`)
- Header: "Task Board / All tasks across all features".
- Filter row: **Features** dropdown (checkbox list of feature name + ID), **Repos** dropdown, **Actor** segmented toggle (All / Agent / Human).
- Horizontal scrollable kanban with 7 columns: Todo, Ready, In Progress, In Review (amber), Blocked (red tinted column), Done, Cancelled. Each column header shows status badge + count.
- **Task card**: 3 px color-coded left border (blue = done/ready, amber = in-review, red = blocked), feature tag chip (monospace, grey), task ID + actor icon, title (body text), repo border chip, dep-count pill, status badge.
- Empty column shows dashed border placeholder "Empty".

## Figma

Design file: **Agent Workspace design** — `qYFglR3hJRmB8VuAPt5Rjs`

| Frame | URL | Covers |
|---|---|---|
| Dashboard | https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-2 | Sidebar, header bar, dashboard overview |
| Features | https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-574 | Features list table, filter pills, search |
| Feature Detail | https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-2141 | Stage stepper, review card, task table |
| New Feature | https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-1770 | Create feature modal form |
| Task Board | https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-825 | Kanban board, task cards, filters |
| Select (dropdown) | https://www.figma.com/design/qYFglR3hJRmB8VuAPt5Rjs/Agent-Workspace-design?node-id=2-1314 | Feature/repo dropdown interaction state |

## Design tokens (from Figma)

| Token | Value |
|---|---|
| Primary | `#5465e8` |
| Primary light bg | `#e4e8fb` |
| Primary gradient (sidebar icon) | `135deg, #5465e8 → #6c7fff` |
| Success | `#17a674` |
| Success bg | `#dff5eb` |
| Warning | `#b3741a` |
| Warning bg | `#fbefd9` |
| Danger | `#e04865` |
| Danger bg | `#fce4e9` |
| Ready | `#2595cc` |
| Ready bg | `#e3f2fb` |
| Surface | `#ffffff` |
| Background | `#f7f8fb` |
| Surface secondary | `#fafbfd` |
| Border | `#e4e7ef` |
| Text primary | `#1a1d27` |
| Text secondary | `#5a6380` |
| Text muted | `#8892b5` |
| Progress bar | gradient `#5465e8 → #17a674` |
| Font: body | Inter |
| Font: mono | Cousine |
| Sidebar width | 240 px |
| Header height | 64 px |
| Border radius card | 14 px |
| Border radius button | 8 px |

## Data sources

| Screen | Source |
|---|---|
| Workspace picker | Scan a user-configured root directory for `workspace.yaml` files; each file defines one workspace |
| Active workspace config | `<workspace-root>/workspace.yaml` — name, workspace_id, repos, roles |
| Feature list | `<workspace-root>/docs/features/*/status.yaml` |
| Feature detail — stages | `<workspace-root>/docs/features/<id>/status.yaml` |
| Feature detail — tasks | `<workspace-root>/docs/features/<id>/tasks/*.yaml` |
| Task board | All `<workspace-root>/docs/features/*/tasks/*.yaml` merged |

## Success criteria

- All 5 screens render live data from the management repo YAML files.
- Approve / Reject / Reset actions write the correct fields to `status.yaml` and commit to the feature branch.
- New Feature modal creates the directory scaffold (`init-feature` output) and commits to a new feature branch.
- Filter and search on the Features page are client-side (no server round-trip).
- Task Board columns reflect real task status from all task YAML files.
