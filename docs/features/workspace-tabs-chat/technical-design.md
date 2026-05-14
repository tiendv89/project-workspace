# Technical Design

## Feature

- Feature ID: `workspace-tabs-chat`
- Title: `Workspace Tabs, Work Item Tabs, and Agent Chat`

## 1. Current State

The management workspace is in `technical_design` for this feature. The product spec has been approved and the implementation target is the `digital-factory-ui` repo declared in `workspace.yaml`.

Today the dashboard already has workspace, board, feature, task, and chat-adjacent concepts, but the approved behavior requires a clearer separation between the workspace board and persistent work item sessions. The user-provided product spec is the source for this design pass. It fixes these important constraints:

- The workspace tab returns the user to the default Kanban Board.
- The workspace dropdown opens only from the icon/right-side control on the workspace tab.
- Sidebar is visible only on the default Kanban Board, never inside `Task tab` or `Feature tab` pages.
- `Task tab` and `Feature tab` may be route-backed pages, with examples `/workspaces/:workspaceId/task-tab` and `/workspaces/:workspaceId/feature-tab`.
- Work item data comes from imported GitHub workspace data, not mock data.
- Agent chat is scoped only to a task or feature. There is no workspace board chat.
- Agent chat is UI-only in this stage: prepare scoped context and user messages, but do not integrate a real chat API and do not generate fake assistant responses.

Current limitations:

- Workspace switching, work item tab state, context menus, route-backed tab pages, and scoped chat persistence are not yet specified as a coherent frontend architecture.
- Single click, double click, and right click need a shared interaction contract so task/feature entry points behave consistently.
- The task and feature tab pages need enough structure to support the detailed sections, 50/50 chat split, copy feedback, view tabs, stage popover, timeline, PR cards, and back behavior.

## 2. Problem Framing

The system needs to support three connected workflows without losing context:

1. Workspace management: switch saved workspaces, search workspaces, and import a repository from the workspace dropdown.
2. Work item sessions: open task and feature detail sessions as tabs, keep board quick-detail behavior separate from persistent sessions, and preserve per-workspace isolation.
3. Scoped agent chat: open chat only from a task or feature session, keep its state scoped, support composer tools, and prepare context for a later real API without showing fake assistant output.

What must remain stable:

- Existing workflow lifecycle, approval gates, task status, and task YAML ownership remain unchanged.
- Imported GitHub workspace data remains the source of task and feature context.
- The management repo only stores feature planning artifacts. UI implementation work happens in `digital-factory-ui`.
- Task execution still starts only after task-stage approval and task activation.

Fixed assumptions:

- Desktop default split when chat is open is 50% content / 50% chat.
- Chat resize uses a left-edge horizontal handle with min/max width constraints.
- Double click uses native `dblclick` behavior, not delayed single-click detection.
- Model selector display options are `GPT-5.5`, `GPT-5.4`, `GPT-5.4 Mini`, and `GPT-5.3 Codex`.
- Workflow-skill mentions use `$`.

## 3. Options Considered

### Option A - Keep everything inline inside the board route

This approach keeps task detail, feature detail, tabs, and chat panels inside the existing board route.

Pros:

- Smallest routing change.
- Lower initial navigation complexity.
- Existing board data context may be reused directly.

Cons:

- Harder to hide the sidebar only for work item sessions without fragile layout branching.
- Deep work sessions become tightly coupled to the board layout.
- Back behavior from Task tab to originating Feature tab is harder to model cleanly.
- Route examples in the product spec are not honored.

Implementation impact:

- Most changes concentrate in existing board components and shared state.
- High risk of large files and fragile conditional rendering.

Dependency impact:

- Later chat and tab work depend heavily on board refactors, increasing merge conflict risk.

### Option B - Route-backed tab shell with shared workspace/session state

This approach introduces a route-backed workspace shell. The board remains the default workspace view. Task and feature tabs use dedicated pages or page-like route shells while sharing workspace data and tab/session state.

Pros:

- Matches the product direction that Task tab and Feature tab may be pages.
- Cleanly hides sidebar outside the board.
- Gives Task tab and Feature tab independent layout control.
- Supports explicit back behavior and originating feature context.
- Gives scoped chat a stable parent context.

Cons:

- Requires a shared tab/session state model before detail pages can be built.
- Needs careful per-workspace cleanup when switching or deleting workspaces.

Implementation impact:

- Requires a foundation task for workspace session state, open tab registry, active tab, and route shell.
- Lets later tasks own smaller surfaces independently.

Dependency impact:

- Once the shell exists, workspace dropdown, click interactions, Task tab, Feature tab, and chat work can proceed in clear waves.

### Option C - Build chat as backend-first integration now

This approach adds a real chat API path while building the panel.

Pros:

- End-to-end chat behavior could be tested earlier.
- Typing indicator and agent response flows would be real.

Cons:

- Conflicts with the supplied stage scope: current work is UI layer only, with no real backend/LLM response integration.
- Requires payload/API choices that are explicitly not needed for this stage.
- Increases blast radius into backend repos and deployment.

Implementation impact:

- Would require backend/API tasks, secrets handling, and failure semantics now.

Dependency impact:

- Adds unresolved backend and LLM dependencies. Not chosen.

## 4. Chosen Design

Choose Option B: route-backed work item tabs with shared workspace/session state, plus scoped chat UI that prepares context but does not call a real agent API in this stage.

### Workspace Shell

The workspace shell owns:

- Current workspace identity.
- Saved workspace list.
- Active top-level surface: board, task tab, or feature tab.
- Open work item tabs for the active workspace only.
- Active task/feature session metadata.
- Cleanup behavior when workspace changes or is deleted.

The default board view keeps the sidebar visible. Task and Feature tab pages render without the sidebar.

### Workspace Dropdown and Import Modal

The workspace tab itself navigates back to the board. The right-side dropdown icon opens the switcher.

Dropdown behavior:

- Title: `Switch workspace`.
- Search input auto-focuses.
- Workspace list filters immediately.
- Active workspace shows a check icon.
- Empty state: `No workspace matches this search.`
- Footer action opens `Import workspace`.

Import modal behavior:

- Modal title: `Import workspace`.
- Description: `Import a repository to create a new workspace.`
- Form fields: repository URL and GitHub Personal Access Token.
- Repository URL is required.
- Token is password type and never displayed after entry.
- Duplicate workspace, invalid URL, missing/invalid token, private repo access, and network errors render inline without closing the modal.

### Work Item Interaction Model

Task entry points:

- Single click opens quick task detail modal/sheet.
- Double click opens or focuses a Task tab.
- Right click opens a custom context menu with `New tab`.

Feature entry points:

- In Task Mode, single click opens quick feature detail. Feature double click does not open a Feature tab.
- In Feature Mode, single click opens quick feature detail, double click opens/focuses a Feature tab, and right click offers `New tab`.

Use native `dblclick` for double-click handling. Do not delay single-click behavior to infer double-clicks. If both single and double click occur, double click wins the persistent session behavior and the UI must avoid leaving a confusing modal focus state.

### Task Tab Page

Task tab content is a full work session, not a modal. It includes:

- Back button.
- Task title.
- Copy task id icon with temporary check feedback.
- Task id badge.
- Status badge, priority badge if available, and updated time if available.
- Chat icon when chat is closed.
- Repository, Branch, Next Action, Executed By, Depends On, Blocked Reason, and Blocked Context.
- Pull Requests section with Workspace PR and Repository PR cards.
- Activity Timeline with action, timestamp, actor, and note.
- Optional Done-state footer actions `Approve Workspace` and `Approve Repo` if those actions are available in the existing product surface.

#### Task tab content layout

The Task tab page has one primary content column when chat is closed. On desktop, the content should use a readable max width inside the no-sidebar tab shell rather than stretching every text block across the full viewport. When chat opens, this same content column becomes the left pane in the 50% / 50% split.

Task tab content order:

1. Header area.
2. Task information section.
3. Pull Requests section.
4. Activity Timeline section.
5. Optional footer actions for review/approval when task status is `Done` and the product action is available.

Header area:

- Back button sits at the top-left of the tab content.
- Task title is the main headline.
- Copy icon sits next to the task title and copies the task id.
- Copy feedback swaps the copy icon to a check icon for a short confirmation window.
- Task id badge appears near the title, for example `T4`.
- Status badge appears near the task id badge.
- Priority badge appears only when source data provides priority.
- Updated time appears only when recent activity data exists.
- Chat icon appears at the right side of the header when chat is closed.

Task information section:

- Render as a compact details grid or grouped cards below the header.
- Fields: `Repository`, `Branch`, `Next Action`, `Executed By`, `Depends On`, `Blocked Reason`, and `Blocked Context`.
- Missing values show `None`, except `Executed By`, which shows `Unassigned` when no owner exists.
- `Executed By` maps source actor data to `Agent`, `Human`, or `Unassigned`.
- `Depends On` renders dependency task ids as small badges; empty dependencies show `None`.
- `Blocked Reason` uses warning/destructive styling only when a blocked reason exists.
- `Blocked Context` renders the detailed block context if present; otherwise it shows `None`.

Pull Requests section:

- Render two PR cards: `Workspace PR` and `Repository PR`.
- Each card shows status, for example `open`, `merged`, or `None`.
- A card is clickable only when a URL exists.
- Clicking a PR opens it in a new browser tab.
- Cards without URL use disabled visual state and do not look clickable.

Activity Timeline section:

- Render a vertical timeline ordered by activity time.
- Each row shows action, timestamp, actor, and note/description.
- Blocked, cancelled, done, and in-review actions use status-colored dots or icons.
- Empty state text is exactly `No activity logs available.`

Footer actions:

- Only show review footer actions when task status is `Done` and existing product behavior supports the actions.
- Candidate actions are `Approve Workspace` and `Approve Repo`.
- These controls must not mutate workflow YAML unless a later approved technical design explicitly adds that mutation path.

When chat opens from Task tab:

- The layout becomes 50% Task content and 50% Agent chat.
- Chat header title is the task title.
- Chat subtitle is short task context such as `taskId · parent feature` or current task status.
- Resize uses the chat panel left edge.

### Feature Tab Page

Feature tab content is also a full work session. It includes:

- Back button.
- Feature title.
- Copy feature id icon with temporary check feedback.
- Feature status pill.
- Current stage pill.
- Modified time.
- Short active-view summary.
- Chat icon when chat is closed.

#### Feature tab content layout

The Feature tab page has one primary content column when chat is closed. On desktop, the document/content area should keep a readable measure for markdown and timeline content. When chat opens, the feature content becomes the left pane in the 50% / 50% split.

Feature tab content order:

1. Header area.
2. Stage popover trigger in the header.
3. View tablist.
4. Active view content.
5. Optional scoped chat split when chat is open.

Header area:

- Back button sits at the top-left of the tab content.
- Feature title is the main headline.
- Copy icon sits next to the feature title and copies the feature id.
- Copy feedback swaps the copy icon to a check icon for a short confirmation window.
- Feature status pill appears near the title.
- Current stage pill appears near the status pill.
- Modified time appears only when source data has a valid latest activity timestamp.
- Active-view summary is short and changes with `Product Spec`, `Technical Design`, `Tasks`, or `Logs`.
- Chat icon appears at the right side of the header when chat is closed.

The Current stage pill opens a hover popover:

- Header `STAGES`.
- Stage rows in order: Product spec, Technical design, Tasks, Handoff.
- Approved stages show green dot/text and uppercase `APPROVED`.
- Current stage has light green background and `Current` badge.
- Draft/future stages show gray dot/text and uppercase `DRAFT`.

Feature view tabs:

- `Product Spec`.
- `Technical Design`.
- `Tasks`.
- `Logs`.

Product Spec and Technical Design render source markdown as readable UI similar to GitHub markdown preview. Completion indicators are green check icons inside the relevant tab item when that stage is approved.

Product Spec view:

- Default view when a feature has a product spec.
- Shows a source badge such as `SOURCE product-spec.md`.
- Renders markdown hierarchy with clear headings, paragraphs, lists, inline code, code blocks, links, and spacing.
- Does not show raw unformatted markdown unless rendering fails.

Technical Design view:

- Shows a source badge such as `SOURCE technical-design.md`.
- Renders the technical design markdown with the same document preview treatment as Product Spec.
- Preserves code blocks and tables where the markdown renderer supports them.

Tasks view renders source-backed task list UI with task id, status badge, title, repo, branch, latest activity, and next action or blocked reason. Clicking a task opens a Task tab and records the originating Feature tab so Task tab Back can return to the same feature and preferably the Tasks view.

Tasks view content:

- Section title is `Feature tasks`.
- Shows total task count.
- Renders each task as a list item/card, not raw YAML.
- Each task item shows task id, status badge, task title, repo, branch, latest activity time, and next action or blocked reason.
- Clicking a task item opens or focuses the Task tab for that task.
- The originating Feature tab and active `Tasks` view are recorded for Task tab Back behavior.

Logs view renders feature activity from status/log data. Empty state is `No feature logs are available.`

Logs view content:

- Shows a source badge such as `SOURCE status.yaml` when status data is available.
- Renders feature history/activity as a vertical timeline.
- Each log item shows action, stage, actor, timestamp, and note.
- Empty state text is exactly `No feature logs are available.`

When chat opens from Feature tab:

- The layout becomes 50% Feature content and 50% Agent chat.
- Chat title is the feature title.
- Chat subtitle is `featureId · active view`, such as `FEATURE-KANBAN-BOARD · Product Spec`.
- No long scope card is shown above the messages.

### Agent Chat UI

Agent chat is available only from Task tab/detail or Feature tab/detail.

Chat panel contains:

- Header title/subtitle from the current scope.
- Message list.
- Composer textarea.
- Model selector.
- Send button.
- Fullscreen/expand button.
- Close button.
- New chat action represented by a plus icon.

New chat creates a new conversation in the same task/feature scope. It resets active messages and draft attachments for that new session. The default model is `GPT-5.5` unless the current scope/session already has a selected model.

Sending a message:

- Disabled when there is no text and no attachment.
- Appends the user message to the scoped conversation.
- Clears input and attachment previews.
- Prepares selected model and scoped context for a future chat adapter.
- Does not create mock assistant responses.
- Shows typing only when a real request is active in a later integration.

Persistence keys:

- Feature chat: `workspaceId + featureId`.
- Task chat: `workspaceId + featureId + taskId`.
- Clone tab/session uses a unique suffix so it does not overwrite the base scope.

Persisted session fields:

- `id`.
- `title`.
- `updatedAt`.
- `messages`.
- `input`.
- `attachments`.
- `selectedModelId`.

### Composer Tools

Model selector:

- `GPT-5.5` - `Extra High`.
- `GPT-5.4` - `Balanced`.
- `GPT-5.4 Mini` - `Fast`.
- `GPT-5.3 Codex` - `Code`.

Skill mention:

- `$` opens `Skills`.
- Query filters skill value, title, or detail.
- Limit visible options to 7.
- Enter selects the active option instead of sending the message while menu is open.

Attachments:

- Pasted `image/*` clipboard items become preview attachments.
- Each preview has remove action.
- Sending clears attachment previews.

## 5. Dependency Analysis

Internal dependencies:

- Workspace shell state must exist before workspace dropdown switching, tab opening, Task tab, Feature tab, or chat state can be integrated.
- Work item click behavior depends on the open/focus/close tab API from the session shell.
- Task and Feature tab pages depend on source-backed task/feature data from the imported workspace.
- Agent chat depends on Task/Feature context surfaces to provide scoped context.
- Composer mentions depend on available skill list and task/feature data from the current workspace.

External dependencies:

- `digital-factory-ui` is the only implementation repo affected.
- GitHub workspace data remains the content source for task/feature information.
- There is no backend/LLM dependency in this stage. Chat API integration is intentionally deferred.
- Figma screenshots and Figma links under `docs/features/workspace-tabs-chat/references/` remain visual references, but the detailed behavior and measurements in the user-provided spec drive this design.

Blocking decisions:

- None for planning. The real chat API contract remains unresolved by design and is out of scope for this stage.
- Product must approve whether Done-state footer actions `Approve Workspace` and `Approve Repo` are active buttons or read-only placeholders if the current UI does not already support those actions.

Vendor/tooling choices:

- Use existing React/TypeScript stack in `digital-factory-ui`.
- Use existing Markdown rendering approach if one exists; otherwise add a small Markdown renderer in the implementation task that owns Feature tab source views.
- Avoid introducing a chat transport dependency in this feature.

Configuration dependencies:

- Saved workspace and imported GitHub token handling must reuse the app's existing workspace storage rules where possible.
- Chat session persistence must remain local frontend state/storage unless a later feature introduces backend sync.

Release dependencies:

- This feature should ship behind normal frontend release flow.
- No database migration or backend deployment is expected.

## 6. Parallelization / Blocking Analysis

External decisions:

- D1: Real chat API is deferred - no blocker for UI work; do not build fake assistant responses.
- D2: `Approve Workspace` / `Approve Repo` footer behavior may need product confirmation if no existing action exists - only blocks those optional controls, not the Task tab structure.

T1: Workspace shell, tab session state, and route foundations
  └── Can begin now - no blockers
  │
  T2: Workspace dropdown and import modal
    └── BLOCKED on T1 (workspace shell must expose active workspace, saved workspaces, and board navigation)
  T3: Work item interactions and context menus
    └── BLOCKED on T1 (open/focus/close tab API and active surface state must exist)
    └── T2 and T3 run in parallel after T1
    │
    T4: Task tab page and task session content
      └── BLOCKED on T1 (route-backed task page and no-sidebar shell must exist)
      └── BLOCKED on T3 (task double-click/right-click must create or focus task sessions)
    T5: Feature tab page and source-backed views
      └── BLOCKED on T1 (route-backed feature page and no-sidebar shell must exist)
      └── BLOCKED on T3 (Feature Mode double-click/right-click must create or focus feature sessions)
      └── T4 and T5 run in parallel
      │
      T6: Scoped agent chat panel, resize, fullscreen, and persistence
        └── BLOCKED on T4/T5 (task and feature pages must provide stable scoped context and split-view anchors)
        │
        T7: Composer tools, skill mentions, model selector, and attachments
          └── BLOCKED on T6 (composer shell, scoped session state, and chat panel lifecycle must exist)
          │
          T8: Integration tests and browser QA
            └── BLOCKED on T2 (workspace dropdown and import modal must be testable)
            └── BLOCKED on T3 (click and context-menu behavior must be testable)
            └── BLOCKED on T4/T5 (task and feature tab pages must be complete enough for flow QA)
            └── BLOCKED on T6/T7 (chat panel and composer tools must be complete enough for flow QA)

## 7. Repository Impact

Affected repo:

- `digital-factory-ui`: implements all frontend UI, route shell, tab/session state, workspace dropdown, import modal, Task tab, Feature tab, scoped chat UI, composer tooling, persistence, and browser QA.

Unaffected repos:

- `workflow-backend`: no real chat API or backend workspace mutation is added in this stage.
- `management-repo`: only planning artifacts under `docs/features/workspace-tabs-chat/` are updated.
- `workflow`, `rag-service`, `git-nexus`: no implementation impact.

## 8. Validation and Release Impact

Testing expectations:

- TypeScript typecheck.
- Unit/component tests for session state, workspace filtering, import validation, tab creation/focus/close, context menu behavior, stage popover, view switching, chat persistence, skill mentions, model selector, and attachment previews.
- Browser QA for desktop flows: workspace switch/import, single/double/right click task and feature flows, Task tab, Feature tab, chat open/resize/fullscreen/close, `$` skill mentions, multiline send, image paste, and workspace switch cleanup.
- Responsive sanity check for tab header overflow and chat split constraints.

Migration/config impact:

- No database migration.
- No backend config.
- Local frontend persistence keys may be added for open tabs and scoped chat sessions.

Rollout concerns:

- Preserve existing board behavior when no work item tabs are open.
- Ensure workspace switching clears old workspace tabs and chat context.
- Ensure no fake assistant response is shown in this UI-only stage.
- Ensure tokens are never displayed after entry.

Backward compatibility:

- Existing imported workspace data remains readable.
- Existing task/feature data shape should be adapted through selectors/helpers instead of hardcoding mock fields.

Handoff implications:

- After implementation tasks finish, handoff should include browser QA evidence and screenshots for the reference surfaces.
