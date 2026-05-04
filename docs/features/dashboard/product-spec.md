# Product Specification

## Feature
- Feature ID: `dashboard`
- Title: `Workflow Dashboard Web`

## References
- Login page Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=14-2&t=l6DiKoWXEtl6DNSM-0
- Workspace page Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=34-490&t=l6DiKoWXEtl6DNSM-0
- Workspace detail page Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=34-537&t=l6DiKoWXEtl6DNSM-0
- Filter task Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=35-752&t=l6DiKoWXEtl6DNSM-0
- Switch workspace Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=36-935&t=l6DiKoWXEtl6DNSM-0
- Task detail Figma: https://www.figma.com/design/hEMJ8kLThTC8zlHyQxG1f3/Untitled?node-id=36-1108&t=l6DiKoWXEtl6DNSM-0

## Problem

The current Workflow Dashboard is a local demo app built with React, Vite, and TanStack Router. It has useful UI foundations — login, workspace selection, workspace import, a Kanban-style workflow board, task details, and fallback screens — but it has no backend. All state is local or hardcoded:

- Authentication is simulated through `localStorage.isLoggedIn`.
- Workspace records are stored in `localStorage.workspaces`.
- First load seeds demo workspaces; there is no server-side record.
- Repository import only parses and stores a repository URL; it does not clone, sync, or call a backend.
- The workspace detail board uses hardcoded sample feature and task data instead of loading real YAML from the linked repository.
- Private repository tokens are collected in the UI but cannot be stored safely in the browser.
- There is no server to clone repositories, parse workflow YAML, or serve real feature and task state.

This is a prototype, not a production system. Users can navigate and inspect sample data, but cannot trust the board as the source of truth for a real workspace repository.

## Goals

- Deliver a complete end-to-end workflow dashboard: frontend UI backed by a real server API.
- Replace all `localStorage` state with server-backed storage — workspaces, features, and tasks.
- Implement real repository import: clone the linked Git repository on the server, parse workflow YAML files, and serve the result to the frontend.
- Support private repository import by storing GitHub personal access tokens securely on the server.
- Serve real feature and task data from the parsed repository YAML on every board load.
- Keep the current page structure and visual direction from the supplied Figma references.
- Preserve the existing route layout: login, workspace list, workspace detail board, task detail sheet, 404, and error boundary.

## Non-goals

- Authentication design is deferred — see the `## Authentication` section.
- Drag-and-drop Kanban status updates are not in scope.
- Create, edit, or delete feature and task flows are not in scope.
- Organisation membership, team management, or multi-user permission handling is not in scope.
- AI chat backend integration is not in scope.
- Real-time board sync (websockets, SSE) is not in scope; a manual refresh or sync-on-load is sufficient.
- The `Create workspace` option in the Add Workspace modal remains a visible but disabled placeholder.

## Authentication

> **TBD — auth strategy to be decided separately before technical design begins.**
>
> All API endpoints that operate on user-owned resources (workspaces, features, tasks) must be protected. The frontend must carry the session credential on every API request. The login page UI requirements below remain valid regardless of the auth mechanism chosen.

## Data Model

### User

| Field | Type | Notes |
|---|---|---|
| `id` | string (UUID) | Primary key |
| `email` | string | Unique |
| `createdAt` | ISO 8601 timestamp | |

Auth-specific fields (password hash, tokens, etc.) are deferred to the auth decision.

### Workspace

| Field | Type | Notes |
|---|---|---|
| `id` | string (UUID) | Primary key |
| `userId` | string | Owner |
| `name` | string | Derived from repo name at import time |
| `repoUrl` | string | Full Git clone URL |
| `initials` | string | Derived from name |
| `avatarColor` | string | Assigned from palette on creation |
| `role` | string | Always `Owner` in v1 |
| `isPrivate` | boolean | Whether the repo requires a token |
| `tokenConfigured` | boolean | True if a GitHub token has been stored server-side |
| `lastSyncedAt` | ISO 8601 timestamp or null | Time of last successful YAML parse |
| `createdAt` | ISO 8601 timestamp | |

The raw GitHub personal access token must never be returned to the frontend. Only `tokenConfigured: true/false` is exposed.

### Feature

Parsed from `docs/features/<featureId>/status.yaml` in the workspace repository.

| Field | Type | Notes |
|---|---|---|
| `featureId` | string | Directory name under `docs/features/` |
| `workspaceId` | string | Parent workspace |
| `title` | string | From `status.yaml` |
| `featureStatus` | string | Lifecycle status from `status.yaml` |
| `currentStage` | string | Current stage from `status.yaml` |
| `tasks` | Task[] | All tasks belonging to this feature |

### Task

Parsed from `docs/features/<featureId>/tasks/T<n>.yaml` in the workspace repository.

| Field | Type | Notes |
|---|---|---|
| `taskId` | string | e.g. `T1` |
| `featureId` | string | Parent feature |
| `workspaceId` | string | Parent workspace |
| `title` | string | From task YAML |
| `status` | string | Task lifecycle status |
| `branch` | string or null | |
| `dependsOn` | string[] | Task IDs |
| `blockedReason` | string or null | |
| `execution` | object | `actorType`, `lastUpdatedBy`, `lastUpdatedAt` |
| `pr` | object | `url`, `status` |
| `log` | LogEntry[] | Activity timeline |

### LogEntry

| Field | Type |
|---|---|
| `action` | string |
| `by` | string |
| `at` | ISO 8601 timestamp |
| `note` | string or null |

## Backend API

All endpoints are prefixed `/api`. All request and response bodies are JSON. All protected endpoints require the session credential resolved from the auth decision. Error responses use the shape `{ "error": "<message>" }`.

### Authentication

> **TBD** — endpoints will be defined once the auth strategy is decided.

### Workspaces

#### `GET /api/workspaces`

Returns all workspaces owned by the authenticated user, sorted by `createdAt` descending.

Response `200`:
```json
[
  {
    "id": "uuid",
    "name": "project-workspace",
    "repoUrl": "https://github.com/org/repo",
    "initials": "PW",
    "avatarColor": "#4f46e5",
    "role": "Owner",
    "isPrivate": false,
    "tokenConfigured": false,
    "lastSyncedAt": "2026-05-04T10:00:00+07:00",
    "createdAt": "2026-05-04T09:00:00+07:00"
  }
]
```

#### `POST /api/workspaces`

Import a new workspace by cloning its repository and parsing its YAML.

Request body:
```json
{
  "repoUrl": "https://github.com/org/repo",
  "isPrivate": false,
  "token": "ghp_xxxx"
}
```

- `token` is required when `isPrivate` is `true`; omit or send `null` otherwise.
- The server clones the repository using the supplied token if private, then parses all feature and task YAML files.
- The raw token must be stored encrypted server-side and never returned to the client.
- If the repository URL is already imported for this user, return `409` with `{ "error": "already imported" }`.
- If clone fails due to auth, return `422` with `{ "error": "repository access denied — check token" }`.
- If clone fails for any other reason, return `422` with an appropriate error message.

Response `201`:
```json
{
  "id": "uuid",
  "name": "repo",
  "repoUrl": "https://github.com/org/repo",
  "initials": "R",
  "avatarColor": "#0891b2",
  "role": "Owner",
  "isPrivate": false,
  "tokenConfigured": false,
  "lastSyncedAt": "2026-05-04T10:00:00+07:00",
  "createdAt": "2026-05-04T10:00:00+07:00"
}
```

#### `DELETE /api/workspaces/:id`

Removes the workspace record, deletes the cloned repository from the server, and deletes the stored token if present.

Response `204` (no body).

Returns `404` if the workspace does not exist or does not belong to the authenticated user.

#### `POST /api/workspaces/:id/sync`

Re-pulls the repository and re-parses all YAML files. Updates `lastSyncedAt`.

Response `200` — same shape as the single workspace object.

### Features

#### `GET /api/workspaces/:id/features`

Returns all features parsed from the workspace repository, each including its tasks.

Response `200`:
```json
[
  {
    "featureId": "runtime-portable-architecture",
    "workspaceId": "uuid",
    "title": "Runtime Portable Architecture",
    "featureStatus": "in_implementation",
    "currentStage": "tasks",
    "tasks": [
      {
        "taskId": "T1",
        "title": "Dockerfile and entrypoint setup",
        "status": "done",
        "branch": "feature/runtime-portable-architecture-T1",
        "dependsOn": [],
        "blockedReason": null,
        "execution": {
          "actorType": "agent",
          "lastUpdatedBy": "agent",
          "lastUpdatedAt": "2026-05-04T08:00:00+07:00"
        },
        "pr": { "url": "https://github.com/org/repo/pull/12", "status": "open" },
        "log": []
      }
    ]
  }
]
```

## Current Application Overview

The app contains the following user-visible routes and fallback states. The data source for each route changes from `localStorage` to the backend API described above.

| Route / Screen | Access State | Main Functionality |
|---|---|---|
| `/` | Public redirect | Checks session; redirects authenticated users to `/workspaces`, others to `/login`. No standalone UI. |
| `/login` | Public, redirects if authenticated | Login form. Auth mechanism TBD. |
| `/workspaces` | Protected | Workspace list fetched from `GET /api/workspaces`. Import repository via `POST /api/workspaces`. Remove workspace via `DELETE /api/workspaces/:id`. Sign out. |
| `/workspaces/:workspaceId` | Protected | Kanban board loaded from `GET /api/workspaces/:id/features`. Workspace switcher, search, status filter, task detail sheet. |
| 404 Not Found | Public fallback | Missing page message with `Go home` button. |
| Error boundary | App fallback | Runtime error state with `Try again` and `Go home`; dev mode shows error message. |

## Functional Requirements

### `/` Redirect Entry

- The root route must not render standalone UI.
- If the user has a valid session, redirect to `/workspaces`.
- If not authenticated, redirect to `/login`.

### `/login`

- The login page must be public.
- If an authenticated user visits `/login`, redirect to `/workspaces`.
- Layout must be a full-height centered screen with content capped at `360px`.
- The top area must include a `Zap` icon in a light primary container, title `Welcome back`, and subtitle `Sign in to your account to continue`.
- The form must be placed in a card with card background, border, rounded corners, padding, and subtle shadow.
- Email input: `type="email"`, required, placeholder `name@example.com`.
- Password input: `type="password"`, required.
- Input focus must remove the default outline and show a ring using the ring color.
- The `Sign In` button must be full width, primary colored, height `h-10`, and use a darker primary hover state.
- On submit, the frontend sends credentials to the auth endpoint (TBD) and stores the session credential.
- On auth failure, display an inline error below the form.

### `/workspaces`

- Protected; unauthenticated users redirected to `/login`.
- On mount, call `GET /api/workspaces` and render the result.
- Show a loading state while the request is in flight.
- Show an error state if the request fails.
- Header height `h-14`, with bottom border and card background.
- The right side of the header shows a `Sign out` button with `LogOut` icon. Signing out clears the session and navigates to `/login`.
- Main content centered, max width `3xl`, padded.
- Intro copy: `Welcome back!` with a subtitle instructing the user to choose or import a workspace.

### Workspace Import

- The import area must be a standalone card.
- Card header includes a link icon and title `Import from Repository`.
- Description tells the user to paste a GitHub, GitLab, or Bitbucket repository URL.
- Repository URL input: placeholder `https://github.com/owner/repo`, disabled while importing.
- Editing the input while an error is visible clears the error.
- Focus state shows a soft primary ring and primary-tinted border.
- A `Private repository` switch row appears below the URL input — off by default.
- When the switch is on, show a token field:
  - Label: `GITHUB PERSONAL ACCESS TOKEN`
  - Placeholder: `ghp_xxxxxxxxxxxxxxxxxxxx`
  - Single-line, full width, same focus styling.
  - Disabled while importing.
- When the switch is off, hide and clear the token field.
- The `Import` button is disabled while importing or when the input is empty.
- While importing, show a spinning `Loader2` icon and text `Importing...`.

Import behavior (frontend validation, then API call):

- Trim the input before validation.
- If empty: show `Please enter a repository URL`.
- If URL does not start with `https://`, `http://`, or `git@`: show `URL must start with https://, http://, or git@`.
- If private switch is on and token is empty: show `GitHub personal access token is required for private repositories`.
- If frontend validation passes, call `POST /api/workspaces` with the URL, `isPrivate`, and `token`.
- On `409` from the API: show `"<workspace name>" already imported`.
- On `422` from the API: show the error message returned by the server.
- On success: add the returned workspace to the list, clear the input, and stop loading.
- The raw token is never stored in the browser.

### Workspace Cards

- Each workspace must be a clickable card row.
- Cards include a colored `12x12` avatar, initials, workspace name, role, and a monospaced repository URL preview.
- `lastSyncedAt` may be shown as a secondary label (e.g. `Synced 5 min ago`).
- Clicking a card navigates to `/workspaces/:workspaceId`.
- Card hover: primary border, subtle shadow, workspace name turns primary, right arrow turns primary, delete button reveals.
- Delete button uses the `Trash2` icon; clicking calls `DELETE /api/workspaces/:id`, then removes the card from the list on success.
- Delete must call `preventDefault()` and `stopPropagation()`.
- Delete hover: soft destructive background and destructive icon/text.
- Native `title="Remove workspace"` tooltip on the delete button.

### `Create a new workspace` Placeholder

- Displayed below the workspace list.
- Dashed border, plus icon, title `Create a new workspace`, subtitle `Start fresh with a new team`.
- Hover uses soft accent background.
- Remains a placeholder — no create flow in this scope.

### `/workspaces/:workspaceId`

- Protected route.
- On mount, call `GET /api/workspaces/:id/features` and render the result on the Kanban board.
- Show a loading state while the request is in flight.
- Show an error state if the request fails, with a `Retry` action that re-calls the endpoint.
- A `Sync` button in the board header calls `POST /api/workspaces/:id/sync` and refreshes the board on success.
- On board load, force light theme by removing the `dark` class from `document.documentElement`.

### Board Header

- Sticky, height `h-14`, containing:
  - Workspace switcher on the left.
  - Feature and task counters in the middle-left (totals from the API response).
  - `Sync` button.
  - Search and filter controls on the right.
- Counter text: small, monospaced, numbers stronger than labels.

### Workspace Switcher Dropdown

- Button: current workspace initials avatar, square `size-8`, small radius, workspace-specific color, native `title={currentWorkspace.name}`.
- Hover: soft primary ring; active: scale to 95%; open: stronger primary ring.
- Dropdown below avatar: width `w-64`, bordered, shadowed, light fade/slide animation.
- Header: current workspace avatar, name, role, and user email.
- If at least 2 workspaces, show `Switch workspace` section with other workspaces. Switching navigates to that workspace and calls `GET /api/workspaces/:id/features`.
- Actions: `Add workspace` (opens Add Workspace modal), `Delete workspace` (if role is `Owner` — calls `DELETE /api/workspaces/:id` and navigates to `/workspaces`), `Sign out`.
- Click outside closes the dropdown.

### Add Workspace Modal

- Opened from the workspace switcher `Add workspace` action.
- Centered over a dim overlay; does not navigate away from the current board.
- Title: `Add workspace`.
- Offers two choices: `Import repository` (enabled) and `Create workspace` (disabled, `Coming soon` label).
- Import form: same URL input, private repository switch, token field, and validation as the `/workspaces` import card.
- Import calls `POST /api/workspaces`; on success, closes the modal and navigates to the newly created `/workspaces/:workspaceId`.
- Close `X` button and overlay click close the modal without side effects.

### Search

- Right side of the board header, `Search` icon inside the input, placeholder `Search features or tasks...`, width `w-64`, height `h-8`.
- Focus: soft primary ring.
- Matching is lowercased, not debounced, not persisted.
- If a query matches a feature title, keep all of its tasks.
- If it does not match the feature title, filter tasks by `task.title` or `task.taskId`.
- No results: show `No tasks or features match your search.`

### Status Filter Dropdown

- `Filter` button with `Filter` icon.
- No filters active: normal border and muted text. Active filters: primary border/text, circular badge with count.
- Clicking opens a right-aligned dropdown, width `w-56`, with border and shadow.
- Header text: `Status`. With active filters, a `Clear` button with `X` icon removes all selections.
- All 7 statuses shown with custom checkbox, status color dot, label, and count (calculated from the full API response, not the current filtered view).
- Selecting toggles that status; multiple statuses use OR logic.
- Active checkbox: primary background with `Check` icon. Row hover: soft accent background.
- Click outside closes the dropdown.

### Board Columns

Seven fixed columns: `TODO`, `READY`, `IN PROGRESS`, `BLOCKED`, `IN REVIEW`, `DONE`, `CANCELLED`.

Each column header includes a status-specific color dot, uppercase label with letter spacing, and a small count badge from the API response.

### Feature Rows

- Each feature renders as an expandable/collapsible row.
- Collapsed: chevron, `Layers` icon, uppercase feature name, lifecycle pill, progress text (`doneTasks/totalTasks`), segment bar, first active task next action on large screens.
- Lifecycle pills: `In Design`, `In TDD`, `Ready`, `In Progress`, `Handoff`, `Done`, `Blocked`, `Cancelled`.
- Clicking toggles expand/collapse. Hover: soft accent background.

### Segment Bar Tooltip

- Bar width `w-24`, visible height `6px`, hover zone taller than the visible bar.
- Hovering a segment: brightens that segment, increases vertical scale, shows custom tooltip above with status dot, uppercase status label, arrow, border, shadow, and fast fade-in.
- Mouse leave hides the tooltip.

### Expanded Feature Grid

- 7-column grid matching board statuses.
- Each task occupies one logical row; its card appears only in the column matching its status. Other cells are empty.
- Cells: small padding, `min-h-[64px]`, card background.

### Task Card

- Small border, elevated background, small radius, padding.
- Title with small monospace task ID prefix (`T1`, `T2`, …).
- Next workflow action label based on status:
  - `todo`: `Approve stage`
  - `ready`: `Claim by agent`
  - `in_progress`: `Submit for review`
  - `blocked`: `Resolve block`
  - `in_review`: `Approve review`
  - `done` / `cancelled`: no action
- If `execution.actorType` is set, show an actor badge: agent (soft purple, `title="Agent"`), human (soft blue, `title="Human"`).
- Hover: accent background, stronger border, 150ms transition. Active: scale to `0.98`.
- Clicking opens the task detail sheet.

### Task Detail Sheet

- Right-side sheet using Radix Dialog primitives.
- Slides in from the right, `black/80` overlay.
- Close `X` in the top-right; overlay click also closes.
- Mobile: full width. Responsive max widths: `sm:max-w-md`, `md:max-w-lg`, `lg:max-w-xl`.

Sheet header:
- Card background, bottom border, padding.
- Uppercase task ID badge.
- Uppercase status badge with status-specific color.
- Task title in `text-xl`.
- `SheetDescription` with screen-reader text (`sr-only`).

Meta grid (2 columns, inside a scroll area):
- `Repository`: `Layers` icon, muted italic `None` if missing.
- `Branch`: `GitBranch` icon; emerald when present, muted italic `None` if missing.
- `Next Action`: primary arrow icon and action label, or `None`.
- `Executed By`: actor icon, capitalized actor type, optional `lastUpdatedAt` formatted as `MMM d, HH:mm`.
- `Depends On`: dependency badges or `None`.
- `Blocked Reason`: destructive alert with `AlertCircle` when present, otherwise `None`.
- `Blocked Context`: soft amber whitespace-preserving box when present, otherwise `None`.

Pull request section:
- `Workspace PR` and `Repository PR` link cards.
- Cards with URLs open in a new tab, soft primary hover border.
- Cards without URLs: 70% opacity, `pointer-events-none`.
- PR status `open`: emerald badge. Other statuses: muted.

Timeline:
- If `task.log` is non-empty, render a vertical activity timeline.
- Dot colors: `blocked` → destructive, `cancelled` → muted, `done` → emerald, others → primary.
- A line connects dots.
- Each entry shows action, formatted time, `by <actor>`, and note in a muted box.
- Empty log: italic `No activity logs available.`

Footer actions:
- Visible only when `task.status === "done"`.
- Buttons: `Approve Workspace` and `Approve Repo`.
- Clicking either shows a success toast: `Code approved and merged`.
- A `Toaster` must be mounted at the app root so toasts are visible.

### 404 Not Found

- Full-screen centered layout.
- Large title `404`, subtitle `Page not found`, description `The page you're looking for doesn't exist or has been moved.`
- `Go home` links to `/`. Hover: `bg-primary/90`.

### Error Boundary

- Full-screen centered layout.
- Warning icon in a soft destructive circle.
- Title `Something went wrong`, description `An unexpected error occurred. Please try again.`
- Dev mode: scrollable `pre` with error message.
- `Try again` calls `router.invalidate()` and `reset()`. `Go home` links to `/`.

### AI Chat Components

- `ChatModal` and `ChatPanel` exist in source but are not mounted.
- Chat remains unavailable in the mounted UI until a later approved scope adds it.

## Design Requirements

- Light theme is prioritized on the board.
- Overall radius: `--radius: 0.25rem`.
- Feel: dense, operational, dashboard-oriented.
- Primary color: green/teal — used for actions, focus rings, logo accents, and hover states.
- Body font: Inter/system sans-serif.
- Main surfaces:
  - `background`: page background
  - `card`: cards, sheet, header
  - `surface`: column headers and dropdown header
  - `surface-elevated`: inputs and small cards
- Status colors:
  - Todo: blue
  - Ready: purple
  - In progress: amber
  - Blocked: red
  - In review: magenta/purple
  - Done: emerald/teal
  - Cancelled: neutral

## Limitations And Deferred Scope

- Authentication strategy is TBD — all protected routes and API endpoints must be secured once decided.
- No real-time board sync; manual sync via the `Sync` button is sufficient for v1.
- No create/edit/delete feature or task flow.
- No task status transition from the UI.
- No Kanban drag/drop.
- No confirmation dialog for workspace deletion.
- No mounted chat assistant.
- `Create workspace` option remains disabled.

## Acceptance Criteria

### Authentication
- Protected routes redirect unauthenticated users to `/login`.
- Session credentials are carried on every API request.
- Sign out clears the session and redirects to `/login`.
- (Specific auth AC to be added once the auth strategy is decided.)

### Workspace List (`/workspaces`)
- On mount, workspaces are loaded from `GET /api/workspaces`, not from `localStorage`.
- A loading state is shown during the request.
- Import calls `POST /api/workspaces`; validation errors from both frontend and API are displayed inline.
- Private repository import sends a token to the server; the raw token is never stored in the browser.
- Import success adds the new workspace to the list without a full page reload.
- Delete calls `DELETE /api/workspaces/:id` and removes the card from the list on success.

### Workspace Board (`/workspaces/:workspaceId`)
- On mount, features and tasks are loaded from `GET /api/workspaces/:id/features`.
- A loading state is shown during the request; an error state with a `Retry` action is shown on failure.
- Feature and task counters in the board header reflect real data from the API.
- The `Sync` button calls `POST /api/workspaces/:id/sync` and refreshes the board.
- Workspace switcher, search, multi-status filter, segment bar tooltip, and task detail sheet function as specified.

### Task Detail Sheet
- All metadata fields (branch, PR links, execution, dependencies, blocked reason, log) are rendered from real API data.
- The `Toaster` is mounted at the app root so toast messages are visible.
- Footer approve buttons appear only when `task.status === "done"` and show a visible success toast on click.

### Server / API
- `GET /api/workspaces` returns only workspaces belonging to the authenticated user.
- `POST /api/workspaces` clones the repository server-side, parses YAML, and persists the workspace and its features/tasks.
- Private repository tokens are stored encrypted server-side and never returned to the client.
- `DELETE /api/workspaces/:id` removes the workspace record and the cloned repository from the server.
- `POST /api/workspaces/:id/sync` re-pulls the repository and updates parsed feature/task data.
- `GET /api/workspaces/:id/features` returns the current parsed state of all features and tasks.

### Fallback States
- 404 and error boundary states match the specified UI and remain accessible.
- Chat components remain unmounted.
