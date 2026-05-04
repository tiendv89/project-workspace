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

The current Workflow Dashboard web app is a local demo dashboard built with TanStack Router and Vite. It has useful UI foundations for login, workspace selection, workspace import, a Kanban-style workflow board, task details, and fallback screens, but most data is still local or hardcoded:

- Authentication is simulated through `localStorage.isLoggedIn`.
- Workspace records are stored in `localStorage.workspaces`.
- First load seeds demo workspaces.
- Repository import only parses and stores a repository URL; it does not clone, sync, or call a backend.
- The workspace detail board uses hardcoded sample feature/task data instead of loading real workspace-specific feature and task YAML.
- Existing chat components are present in source but are not mounted.
- Toast calls may not be visible because the app does not mount a toaster.

This creates a polished visual prototype, but not yet a production-ready workflow dashboard. Users can navigate and inspect sample workflow data, but they cannot trust the board as the source of truth for a real workspace repository.

## Goals

- Preserve the current page structure and visual direction from the supplied Figma references.
- Document all current routes, states, interactions, dropdowns, sheets, empty states, and limitations as the baseline product behavior.
- Clarify the expected v1 product scope for a Workflow Dashboard Web app before technical design begins.
- Keep the current app focused on reading, filtering, and inspecting workflow data.
- Make clear which features are intentionally local/demo behavior and which capabilities are missing from production scope.
- Provide acceptance criteria that can be used later to design and implement backend-backed workspace and workflow data loading.

## Non-goals

- Do not design backend APIs in this product spec.
- Do not define the repository sync implementation, Git provider integration, or file parsing architecture here.
- Do not add drag-and-drop Kanban status updates in this stage.
- Do not add create/edit/delete feature or task flows in this stage.
- Do not define real authentication, organization membership, or multi-user permission handling in this stage.
- Do not mount or connect a real AI chat backend in this stage.
- Do not treat the current repository import flow as a real clone/sync operation.

## Current Application Overview

The app currently contains the following user-visible routes and fallback states:

| Route / Screen | Access State | Main Functionality | Source Files |
|---|---|---|---|
| `/` | Public redirect route | Checks `isLoggedIn`; redirects logged-in users to `/workspaces`, otherwise redirects to `/login`. No standalone UI. | `src/routes/index.tsx` |
| `/login` | Public, redirects if already logged in | Demo login form, writes `isLoggedIn=true` to `localStorage`, then navigates to the workspace list. | `src/routes/login.tsx` |
| `/workspaces` | Protected | Workspace list, import repository URL into a workspace, remove workspace, sign out. | `src/routes/workspaces/index.tsx` |
| `/workspaces/:workspaceId` | Protected | Kanban-style feature/task board, search, status filter, workspace switcher, task detail sheet. | `src/routes/workspaces/$workspaceId.tsx`, `src/components/KanbanBoard.tsx` |
| 404 Not Found | Public fallback | Shows a missing page message and a `Go home` button. | `src/routes/__root.tsx` |
| Error boundary | App fallback | Shows a runtime error state with `Try again` and `Go home`; in dev mode it also displays the error message. | `src/router.tsx` |

## Current Data And State

- Auth state is stored through `src/lib/auth.ts` and uses `localStorage.isLoggedIn`.
- Workspace state is stored through `src/lib/workspaces.ts` and uses `localStorage.workspaces`.
- First workspace-list load seeds 3 default workspaces: `Acme Corp`, `Personal Dashboard`, and `Startup Project`.
- Importing a repository URL creates a local workspace object only.
- The app parses repository names from GitHub, GitLab, and Bitbucket HTTPS or SSH URLs.
- Imported workspaces receive derived initials, role `Owner`, and an avatar color from the configured palette order.
- `/workspaces/:workspaceId` uses `workspaceId` only to select the header workspace identity; the board data is still sample data.
- The sample board has 4 features, 16 tasks, and 7 status columns: `TODO`, `READY`, `IN PROGRESS`, `BLOCKED`, `IN REVIEW`, `DONE`, and `CANCELLED`.

## Functional Requirements

### `/` Redirect Entry

- The root route must not render standalone UI.
- If `auth.isLoggedIn()` returns `true`, it must redirect to `/workspaces`.
- If the user is not logged in, it must redirect to `/login`.
- The auth check must remain based on `localStorage.getItem("isLoggedIn") === "true"` until real auth is designed.
- Users should effectively see the destination page immediately after redirect.

### `/login`

- The login page must be public.
- If an already logged-in user visits `/login`, the route must redirect to `/workspaces`.
- Layout must be a full-height centered screen with content capped at `360px`.
- The top area must include a `Zap` icon in a light primary container, title `Welcome back`, and subtitle `Sign in to your account to continue`.
- The form must be placed in a card with card background, border, rounded corners, padding, and subtle shadow.
- Email input must be `type="email"`, required, placeholder `name@example.com`, and default value `demo@example.com`.
- Password input must be `type="password"`, required, and default value `password123`.
- Input focus must remove the default outline and show a ring using the ring color.
- Submitting a valid form must prevent default submission, call `auth.login()`, set `localStorage.isLoggedIn = "true"`, and navigate to `/workspaces`.
- The `Sign In` button must be full width, primary colored, height `h-10`, and use a darker primary hover state.
- The login page must not include modal, tooltip, dropdown, toast, or real server validation.

### `/workspaces`

- The workspace list route must be protected; unauthenticated users must be redirected to `/login`.
- Header height must be `h-14`, with bottom border and card background.
- The header should not include a generic app title, workspace icon, or workspace name.
- The right side of the header must show a `Sign out` button with `LogOut` icon.
- Signing out must remove `localStorage.isLoggedIn` and navigate to `/login`.
- Main content must be centered, max width `3xl`, padded, and visually positioned below the header.
- Intro copy must include `Welcome back!` and a subtitle instructing the user to choose or import a workspace.

### Workspace Import

- The import area must be a standalone card.
- Card header must include a link icon and title `Import from Repository`.
- Description must tell the user to paste a GitHub, GitLab, or Bitbucket repository URL.
- Repository URL input must use placeholder `https://github.com/owner/repo`.
- Input must be disabled while importing.
- Editing the input while an error is visible must clear the error.
- Focus state must show a soft primary ring and primary-tinted border.
- The form must include a `Private repository` switch row below the repository URL input.
- The private repository switch is off by default.
- The switch row must match the compact visual shape from the reference image: left-aligned switch control followed by monospace label text `Private repository`.
- When the private repository switch is on, show a token field below it:
  - Label: `GITHUB PERSONAL ACCESS TOKEN`.
  - Placeholder: `ghp_xxxxxxxxxxxxxxxxxxxx`.
  - Single-line input with full width and the same focus styling as the repository URL input.
  - Disabled while importing.
- When the private repository switch is off, hide the token field and clear any visible token error.
- The `Import` button must be disabled while importing or when the input is empty.
- Button hover must darken the primary background.
- Active state must slightly scale to `0.97`.
- Disabled state must use 50% opacity and `cursor-not-allowed`.
- While importing, the button must show a spinning `Loader2` icon and text `Importing...`.

Import behavior:

- Trim the input before validation.
- If empty, show `Please enter a repository URL`.
- If the URL does not start with `https://`, `http://`, or `git@`, show `URL must start with https://, http://, or git@`.
- If the exact repository URL already exists, show `"workspace name" already imported`.
- If `Private repository` is enabled and the token is empty, show `GitHub personal access token is required for private repositories`.
- The token validation must only require a non-empty value for now; it must not reject fine-grained GitHub tokens such as `github_pat_...`.
- If valid, clear the error, set `importing=true`, wait 400ms, parse the repo name, derive initials, assign role `Owner`, assign avatar color, save to `localStorage.workspaces`, clear the input, and stop loading.
- For current local-only import, do not persist the raw token into `localStorage.workspaces`.
- Imported private workspaces may store safe metadata only, such as `privateRepository: true` and `tokenConfigured: true`.
- Workspace cards must not display or reveal the token.

### Workspace Cards

- Each workspace must be displayed as a clickable card row.
- Cards must include a colored `12x12` avatar, initials, workspace name, role, and a monospaced repository URL preview for imported workspaces.
- Clicking a card must navigate to `/workspaces/:workspaceId`.
- Card hover must change border to a soft primary color, add a subtle shadow, change workspace name to primary, change the right arrow to primary, and reveal the delete button.
- The delete button must use the `Trash2` icon.
- Deleting must call `preventDefault()` and `stopPropagation()` so the card does not navigate.
- Deleting must remove the workspace from `localStorage.workspaces`.
- Delete hover must use soft destructive background and destructive icon/text color.
- Delete tooltip must be the native browser tooltip `title="Remove workspace"`.
- `ArrowRight` must remain as the visual cue that the card opens the detail page.

### `Create a new workspace` Placeholder

- Display the button below the workspace list.
- The button must use dashed border, plus icon, title `Create a new workspace`, and subtitle `Start fresh with a new team`.
- Hover must use soft accent background.
- It remains a visual placeholder for now and must not create a real workspace until that flow is designed.

### Workspace Empty State

- No dedicated empty state is required while default seeding exists.
- If all workspaces are removed, the page may show only the `Workspaces` heading and the `Create a new workspace` button.

### `/workspaces/:workspaceId`

- The workspace detail route must be protected.
- The route must read `workspaceId` from the URL and pass it into `KanbanBoard`.
- `KanbanBoard` must find the workspace from localStorage by `workspaceId`.
- If the workspace is not found, it may fall back to the first workspace.
- On board load, the app must force light theme by removing the `dark` class from `document.documentElement` and setting `localStorage.theme = "light"`.

### Board Header

- The board header must be sticky, height `h-14`, and contain:
  - Workspace switcher on the left.
  - Feature/task counters in the middle-left.
  - Search and filter controls on the right.
- The board must represent workspace identity through the workspace avatar and name, and must not repeat a generic app logo/title.
- Counters must show totals from current sample data: `4 features` and `16 tasks`.
- Counter text must be small and monospaced, with numbers stronger than labels.

### Workspace Switcher Dropdown

- The switcher button must be the current workspace initials avatar.
- Avatar must be square `size-8`, small radius, workspace-specific color, and use native tooltip `title={currentWorkspace.name}`.
- Hover must add a soft primary ring and active state must scale to 95%.
- Open state must add a stronger primary ring.
- Clicking the avatar opens a custom dropdown below the avatar.
- Dropdown must be width `w-64`, bordered, shadowed, and use a light fade/slide animation.
- Dropdown header must show current workspace avatar, workspace name, role, and demo email `demo@example.com`.
- If there are at least 2 workspaces, show a `Switch workspace` section with other workspaces.
- Each switch item must show small avatar, name, and role.
- Clicking a workspace item closes the dropdown and navigates to that workspace detail route.
- Actions must include `Add workspace`.
- Clicking `Add workspace` closes the dropdown and opens an `Add workspace` modal.
- If current workspace role is `Owner`, actions must include `Delete workspace`; clicking it removes the workspace and navigates to `/workspaces`.
- Actions must always include `Sign out`; clicking clears auth and navigates to `/login`.
- Action hover states must use soft destructive background and destructive text.
- Clicking outside the dropdown must close it.
- No confirmation dialog is required for deletion in the current scope.

### Add Workspace Modal

- The modal opens from the board workspace switcher `Add workspace` action.
- The modal must be centered over a dim overlay and must not navigate away from the current board.
- Modal title must be `Add workspace`.
- Modal content must offer two choices:
  - `Import repository`
  - `Create workspace`
- `Import repository` is enabled and uses the same local repository import behavior as the `/workspaces` import card.
- The import form must accept GitHub, GitLab, or Bitbucket repository URLs.
- The modal import form must include the same `Private repository` switch and `GITHUB PERSONAL ACCESS TOKEN` field behavior as the `/workspaces` import card.
- Import validation must match the `/workspaces` import flow:
  - Empty input shows `Please enter a repository URL`.
  - URLs not starting with `https://`, `http://`, or `git@` show `URL must start with https://, http://, or git@`.
  - Duplicate repository URLs show `"workspace name" already imported`.
  - Private repository enabled with an empty token shows `GitHub personal access token is required for private repositories`.
- Successful modal import must create a new workspace in `localStorage.workspaces`, close the modal, and navigate to the newly created `/workspaces/:workspaceId` board.
- Successful modal import must also avoid persisting the raw token; only safe private-repo metadata may be stored locally.
- `Create workspace` must be visible but disabled for now.
- The disabled create option must use muted text, disabled cursor, and a short helper such as `Coming soon`.
- The modal must provide a close `X` button and close on overlay click.
- Closing the modal without importing must preserve the current workspace and board state.

### Search

- Search input must sit on the right side of the board header.
- It must show a `Search` icon inside the input.
- Placeholder must be `Search features or tasks...`.
- Width must be `w-64`; height must be `h-8`.
- Focus state must show a soft primary ring.
- Query matching must be lowercased.
- Search must not be debounced.
- Search state must not be persisted in the URL or localStorage.
- If the query matches a feature title, that feature must keep all of its tasks after status filtering is applied.
- If the query does not match the feature title, tasks must be filtered by `task.title` or `task.id`.
- If no results remain, the board must show `No tasks or features match your search.`

### Status Filter Dropdown

- The `Filter` button must include the `Filter` icon.
- With no filters active, the button uses normal border and muted text.
- With active filters, the button uses primary border/text and a small circular badge showing selected status count.
- Hover must use foreground text and stronger muted border.
- Clicking `Filter` opens a custom right-aligned dropdown, width `w-56`, with border and shadow.
- Dropdown header text must be `Status`.
- If filters are selected, a `Clear` button with `X` icon must appear.
- `Clear` must remove all selected statuses.
- The dropdown must show all 7 statuses with custom checkbox, status color dot, label, and count.
- Counts must be calculated from all sample features, not the current search/filter result.
- Clicking a status toggles that status.
- Multiple statuses can be selected with OR logic.
- Active checkbox must use primary background and `Check` icon.
- Row hover must use soft accent background.
- Clicking outside the dropdown must close it.

### Board Columns

The board must have 7 fixed columns:

1. `TODO`
2. `READY`
3. `IN PROGRESS`
4. `BLOCKED`
5. `IN REVIEW`
6. `DONE`
7. `CANCELLED`

Each column header must include:

- Status-specific color dot.
- Uppercase label with letter spacing.
- Small count badge calculated from all sample data.
- `bg-surface` header background.
- Dividers created by `gap-px bg-border`.

### Feature Rows

- Each feature must render as an expandable/collapsible row.
- Collapsed row must show chevron, `Layers` icon, uppercase feature name, lifecycle pill, progress text, segment bar, and first active task next action on large screens.
- Lifecycle pill statuses must include `In Design`, `In TDD`, `Ready`, `In Progress`, `Handoff`, `Done`, `Blocked`, and `Cancelled`.
- Lifecycle pills must include color dot, border, and soft background.
- Progress text must use `doneTasks/totalTasks`.
- Segment bar must include one segment per task.
- Clicking the row toggles expand/collapse.
- Hover must use soft accent background.

### Segment Bar Tooltip

- Segment tooltip must be custom, not Radix Tooltip.
- Bar width must be `w-24`; visible height must be `6px`.
- Hover zone must be taller than the visible bar.
- Hovering over a segment must brighten that segment and increase vertical scale.
- Tooltip must appear above the segment with status dot, uppercase status label, arrow, border, shadow, popover background, and fast fade-in animation.
- Mouse leave must hide the tooltip.

### Expanded Feature Grid

- Expanded feature rows must render a 7-column grid matching board statuses.
- Each task must create one logical row.
- A task card appears only in the column matching its status.
- Other cells remain empty.
- Cells must have small padding, `min-h-[64px]`, and card background.
- No drag/drop, reorder, or click-to-update-status behavior is included in current scope.

### Task Card

- Task cards must use small border, elevated background, small radius, and padding.
- Title must include a small monospace `T{index+1}` prefix.
- If the status has a hardcoded transition, the card must show the next workflow action:
  - `todo`: `Approve stage`
  - `ready`: `Claim by agent`
  - `inprogress`: `Submit for review`
  - `blocked`: `Resolve block`
  - `inreview`: `Approve review`
  - `done`: no action
  - `cancelled`: no action
- If `execution.actor_type` exists, show an actor badge on the right.
- Agent actor badge uses soft purple background and native tooltip `title="Agent"`.
- Human actor badge uses soft blue background and native tooltip `title="Human"`.
- Hover must use accent background, stronger border, and 150ms transition.
- Cursor must be pointer.
- Active click state must scale slightly to `0.98`.
- Clicking a task card opens the task detail sheet.

### Task Detail Sheet

- Task detail must be a right-side sheet implemented through the local `Sheet` component using Radix Dialog primitives.
- Clicking a task card sets `selectedTask` and renders the detail sheet.
- Sheet must be open by default when rendered.
- It must slide in from the right and use a `black/80` overlay.
- Close `X` button must appear in the top-right corner.
- Clicking overlay or closing the dialog must call `onClose` and clear `selectedTask`.
- Mobile width must be full; responsive max widths must use `sm:max-w-md`, `md:max-w-lg`, and `lg:max-w-xl`.

Sheet header requirements:

- Card background, bottom border, and padding.
- Uppercase task id badge, for example `T1`.
- Uppercase status badge using status-specific color.
- Task title in larger `text-xl` text.
- `SheetDescription` must contain screen-reader text and be visually hidden with `sr-only`.

Meta information requirements:

- Content must be inside a scroll area.
- Meta grid must use 2 columns.
- `Repository` shows `Layers` icon and muted italic `None` if missing.
- `Branch` shows `GitBranch` icon; branch text is emerald when present and muted italic `None` if missing.
- `Next Action` shows primary arrow icon and task next action when available, otherwise `None`.
- `Executed By` shows agent/human state, actor icon, capitalized actor type, and optional last-updated time formatted as `MMM d, HH:mm`.
- `Depends On` shows dependency badges or `None`.
- `Blocked Reason` shows a destructive alert with `AlertCircle` when present, otherwise `None`.
- `Blocked Context` shows a soft amber whitespace-preserving box when present, otherwise `None`.

Pull request requirements:

- Show `Workspace PR` and `Repository PR` link cards.
- Cards with URLs must open in a new tab and use soft primary hover border.
- Cards without URLs must have 70% opacity and `pointer-events-none`.
- PR status badge `open` must be emerald; other statuses are muted.
- Repository PR card must use `GitPullRequest` icon.

Timeline requirements:

- If `task.log` exists, render a vertical activity timeline.
- Timeline dot colors:
  - `blocked`: destructive
  - `cancelled`: muted
  - `done`: emerald
  - other actions: primary
- A line must connect timeline dots.
- Each entry must show action, formatted time `MMM d, HH:mm`, `by <actor>`, and note inside a muted box.
- If there is no log, show italic text `No activity logs available.`

Footer actions:

- Footer buttons only appear when `task.status === "done"`.
- Buttons are `Approve Workspace` and `Approve Repo`.
- Clicking either button calls `toast.success("Code approved and merged")`.
- Visible toast support is out of scope until toaster mounting is addressed.

### 404 Not Found

- Render when no TanStack Router route matches.
- Full-screen centered layout.
- Show large title `404`, subtitle `Page not found`, and description `The page you're looking for doesn't exist or has been moved.`
- `Go home` button links to `/`.
- Hovering `Go home` changes background to `bg-primary/90`.
- Navigating to `/` follows normal auth-based redirect behavior.
- No modal, tooltip, or toast is required.

### Error Boundary

- Render when the router catches an unexpected runtime error.
- Full-screen centered layout.
- Show warning icon inside a soft destructive circle.
- Title must be `Something went wrong`.
- Description must be `An unexpected error occurred. Please try again.`
- In dev mode, if `error.message` exists, show a scrollable `pre` with muted background and destructive text.
- `Try again` must call `router.invalidate()` and `reset()`.
- `Go home` must link to `/`.

### AI Chat Components

- `ChatModal` and `ChatPanel` exist in source but are not mounted in any current route.
- Current product behavior must treat chat as unavailable in the mounted UI.
- Chat remains mock-only and does not call a real AI/backend.
- Mounting chat, connecting a backend, or adding a real workspace agent is out of scope for this product spec.

## Tooltip, Modal, And Dropdown Inventory

Visible in mounted UI:

- Workspace switcher avatar uses native `title` with workspace name.
- Remove workspace button uses native `title="Remove workspace"`.
- Actor badge on task cards uses native `title="Agent"` or `title="Human"`.
- Feature segment bar uses a custom tooltip with status dot/label, arrow, shadow, and fade-in animation.
- Task detail sheet is the only mounted modal/sheet.
- Workspace switcher and status filter are custom dropdowns/popovers.

Available but not mounted:

- Radix tooltip wrapper in `src/components/ui/tooltip.tsx`.
- Sidebar tooltip logic.
- `ChatModal`.
- `ChatPanel`.

## Design Requirements

- Light theme is prioritized on the board.
- Overall radius should remain small through `--radius: 0.25rem`.
- The UI should feel dense, operational, and dashboard-oriented.
- Primary color should remain green/teal and be used for actions, focus rings, logo accents, and hover states.
- Body font should remain Inter/system sans-serif.
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

## Current Limitations To Preserve Until Designed

- No backend API.
- No GitHub/GitLab/Bitbucket repository sync.
- No secure backend token storage; private repository token collection is UI/validation scope only and raw tokens must not be stored in localStorage.
- No real workspace-specific feature/task loading.
- No real workspace creation from the `Create a new workspace` button or the disabled modal `Create workspace` option.
- No create/edit/delete feature or task flow.
- No task status transition mutation.
- No Kanban drag/drop.
- No confirmation dialog for workspace deletion.
- No mounted chat assistant.
- No real AI/chat backend.
- Toast may not be visible if no `Toaster` is mounted.

## Acceptance Criteria

- `/` redirects based on `localStorage.isLoggedIn` and renders no standalone UI.
- `/login` matches the described centered demo login flow and redirects logged-in users.
- `/workspaces` supports seeded workspaces, local import validation, local import persistence, workspace deletion, and sign out.
- Workspace import supports a `Private repository` switch that reveals a GitHub personal access token input.
- Private repository import requires a non-empty token but does not persist the raw token locally.
- Repository import remains local-only and does not claim to clone or sync repositories.
- `/workspaces/:workspaceId` renders the selected workspace identity and sample Kanban data.
- Workspace switcher `Add workspace` opens a modal with enabled repository import and disabled create-workspace option.
- Add workspace modal import includes the same private repository switch and token validation as the workspace-list import card.
- Successful modal import saves the workspace locally and navigates to the new workspace board.
- Board search and multi-status filter behave exactly as documented.
- Feature rows expand/collapse and preserve the 7-column status grid layout.
- Segment bar tooltip, task cards, workspace switcher dropdown, filter dropdown, and task detail sheet match the specified interactions.
- Task detail sheet shows metadata, PR cards, timeline, and done-state footer actions.
- 404 and error boundary states remain available and match the specified UI behavior.
- Chat components remain unmounted unless a later approved scope explicitly adds them.
- The product spec clearly separates current implemented behavior from missing production capabilities.
