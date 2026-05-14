# Tasks - Workspace Tabs, Work Item Tabs, and Agent Chat

Feature status reference: `in_tdd`; stage status: `technical_design/awaiting_approval`. Machine state lives in `tasks/T<n>.yaml`; this file is narrative only.

## Index

| ID | Wave | Title | Depends on |
|---|---:|---|---|
| T1 | 1 | Workspace shell and tab session foundation | [] |
| T2 | 2 | Workspace dropdown and import modal | [T1] |
| T3 | 2 | Work item click interactions and context menus | [T1] |
| T4 | 3 | Task tab page and task session content | [T1, T3] |
| T5 | 3 | Feature tab page and source-backed views | [T1, T3] |
| T6 | 4 | Scoped agent chat panel and session persistence | [T4, T5] |
| T7 | 5 | Composer tools, skill mentions, model selector, and attachments | [T6] |
| T8 | 6 | Integration tests and browser QA | [T2, T3, T4, T5, T6, T7] |

---

## T1 - Workspace shell and tab session foundation

### Description

Build the shared frontend foundation that lets the workspace board, Task tabs, Feature tabs, and scoped chat reason about the same active workspace without mixing contexts.

This task owns the route-backed shell and state model. It should keep the Kanban Board as the default workspace view, hide the sidebar on Task/Feature tab pages, and isolate open tabs per workspace.

Deliverables:

- Add or update a workspace shell that distinguishes board, task tab, and feature tab surfaces.
- Support route-backed Task tab and Feature tab pages compatible with `/workspaces/:workspaceId/task-tab` and `/workspaces/:workspaceId/feature-tab`.
- Maintain per-workspace open work item tabs, active tab, originating feature context, and close behavior.
- Workspace tab click returns to the default Kanban Board.
- Switching workspace clears or hides tabs and chat context from the previous workspace.
- Sidebar remains visible only in the default Kanban Board surface.
- Provide typed helpers for opening, focusing, cloning, and closing Task/Feature tabs.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Identify current workspace routing, board shell, and tab/header state.
- [ ] Define a typed work item tab model for Task and Feature tabs.
- [ ] Add session state for open tabs, active tab, active workspace, and originating feature context.
- [ ] Add route/page shells for Task tab and Feature tab surfaces.
- [ ] Ensure workspace tab click returns to the board for the current workspace.
- [ ] Ensure sidebar is hidden on Task tab and Feature tab pages.
- [ ] Ensure switching workspace removes previous workspace tabs and chat context from the active UI.
- [ ] Add unit tests for tab open/focus/close and workspace isolation.
- [ ] Typecheck passes.

---

## T2 - Workspace dropdown and import modal

### Description

Implement the workspace dropdown and import modal behavior from the approved product parameters.

This task depends on T1 because the dropdown must switch the active workspace and return to the workspace board without leaking work item tabs or chat context.

Deliverables:

- Workspace dropdown opens from the right-side icon/control of the workspace tab, not from the whole tab click.
- Dropdown title is `Switch workspace`.
- Search input auto-focuses and filters saved workspaces immediately.
- Workspace rows show initials/avatar, name, repo URL or role/description, and check icon for active workspace.
- Empty search state shows `No workspace matches this search.`
- Click outside closes the dropdown and resets search query.
- Footer action opens the `Import workspace` modal.
- Import modal shows repository URL and GitHub Personal Access Token inputs.
- Repository URL is required and uses placeholder `https://github.com/owner/repo`.
- Token input uses password type and is never displayed after entry.
- Submit validates empty URL, unsupported format, duplicate workspace, token/access errors, private repo access, and network/API errors.
- Error clears when repository URL or token changes.
- Successful import adds a saved workspace and closes the modal.
- Closing the modal resets repository URL, token, and error state.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Wire the workspace tab click to board navigation and a separate icon/control to dropdown open.
- [ ] Build dropdown layout with title, search, workspace rows, active check, empty state, and footer action.
- [ ] Implement immediate search filtering.
- [ ] Implement click-outside and Escape close behavior.
- [ ] Build `Import workspace` modal with header, description, close button, and direct form body.
- [ ] Implement repository URL normalization and validation.
- [ ] Implement token password input and non-display behavior after entry.
- [ ] Implement duplicate workspace and access/network error states.
- [ ] Add component tests for filtering, active check, empty state, import validation, error clearing, and close/reset.
- [ ] Typecheck passes.

---

## T3 - Work item click interactions and context menus

### Description

Make task and feature entry points behave consistently across board, sidebar, Task Mode, and Feature Mode.

This task depends on T1 because click handlers must open or focus persistent work item tabs through the shared tab session API.

Deliverables:

- Task card single click opens quick task detail modal/sheet immediately.
- Task card double click uses native `dblclick` to open or focus a Task tab.
- Task card right click suppresses browser context menu and opens a custom menu with `New tab`.
- Sidebar task item single click opens quick task detail modal/sheet.
- Sidebar task item double click opens or focuses a Task tab.
- Sidebar task item right click opens the same custom `New tab` action.
- Task Mode feature single click opens quick feature detail modal/sheet.
- Task Mode feature double click does not open Feature tab.
- Feature Mode feature single click opens quick feature detail modal/sheet.
- Feature Mode feature double click opens or focuses a Feature tab.
- Feature Mode feature right click opens a custom menu with `New tab`.
- Click-outside and Escape close context menus.
- Single click should not be artificially delayed to detect double click.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Identify all task and feature click entry points on board and sidebar.
- [ ] Add shared context menu primitive or reuse existing menu component.
- [ ] Wire task single click to quick detail.
- [ ] Wire task `dblclick` to open/focus Task tab.
- [ ] Wire task right click to custom `New tab` menu.
- [ ] Wire sidebar task interactions to match task card behavior.
- [ ] Wire Task Mode feature single click to quick feature detail only.
- [ ] Wire Feature Mode feature double click and right click to Feature tab creation.
- [ ] Ensure context menus close on outside click and Escape.
- [ ] Add tests for single click, double click, right click, Feature Mode gating, and no duplicate tab behavior.
- [ ] Typecheck passes.

---

## T4 - Task tab page and task session content

### Description

Build the route-backed Task tab work session page.

This task depends on T1 for the no-sidebar tab shell and T3 for opening/focusing Task tabs from user interactions.

Deliverables:

- Header with Back button, task title, copy task id icon, temporary check feedback, task id badge, status badge, optional priority badge, updated time, and chat icon.
- Content order: header, task information section, Pull Requests section, Activity Timeline section, and optional footer actions.
- Task information section rendered as compact details grid or grouped cards.
- Task metadata fields: Repository, Branch, Next Action, Executed By, Depends On, Blocked Reason, and Blocked Context.
- Missing metadata shows `None`, except missing execution owner shows `Unassigned`.
- Depends On renders dependency task ids as badges.
- Blocked Reason uses warning/destructive styling only when present.
- Pull Requests section with Workspace PR and Repository PR cards, clickable only when URL exists.
- PR cards without URL are disabled and do not look clickable.
- Activity Timeline with action, timestamp, actor, and note.
- Timeline uses status-colored dots/icons for blocked, cancelled, done, and in-review actions.
- Empty timeline state `No activity logs available.`
- Optional Done-state footer actions for `Approve Workspace` and `Approve Repo` only if compatible with existing product actions.
- Back behavior returns to originating Feature tab when the task was opened from a Feature tab Tasks view; otherwise returns to board or previous context.
- Task tab close behavior follows header tab rules: fallback to nearest tab or board.
- Chat anchor area supports the later 50% / 50% split view from T6.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Build Task tab route/page shell without sidebar.
- [ ] Render header with Back, copy, badges, updated time, and chat icon.
- [ ] Implement copy task id feedback from copy icon to check icon.
- [ ] Render task information section with Repository, Branch, Next Action, Executed By, Depends On, Blocked Reason, and Blocked Context.
- [ ] Render `None` fallbacks and `Unassigned` execution owner fallback.
- [ ] Render dependency task ids as badges.
- [ ] Render blocked reason as warning/destructive block when present.
- [ ] Render Workspace PR and Repository PR cards with enabled/disabled link states.
- [ ] Render Activity Timeline with status-colored dots/icons and empty state.
- [ ] Render optional Done-state footer actions only when compatible with existing product actions.
- [ ] Implement Back behavior to originating Feature tab when present.
- [ ] Add tests for header, copy feedback, metadata fallbacks, PR link states, timeline, and back behavior.
- [ ] Typecheck passes.

---

## T5 - Feature tab page and source-backed views

### Description

Build the route-backed Feature tab work session page with source-backed document and status views.

This task depends on T1 for the no-sidebar tab shell and T3 for opening/focusing Feature tabs from Feature Mode user interactions.

Deliverables:

- Header with Back button, feature title, copy feature id icon, temporary check feedback, feature status pill, current stage pill, modified time, active-view summary, and chat icon.
- Content order: header, stage popover trigger, view tablist, active view content, and optional scoped chat split.
- Current stage hover popover with `STAGES` header, Product spec, Technical design, Tasks, Handoff rows, uppercase status labels, current badge, and green/gray state styling.
- View tabs: `Product Spec`, `Technical Design`, `Tasks`, `Logs`.
- Green check indicator inside `Product Spec` and `Technical Design` tabs when the corresponding stage is approved.
- Product Spec view shows `SOURCE product-spec.md` and renders markdown as readable UI similar to GitHub markdown preview.
- Technical Design view shows `SOURCE technical-design.md` and renders markdown with the same document preview treatment.
- Tasks view shows `Feature tasks`, total count, and task list UI with task id, status badge, title, repo, branch, latest activity, and next action or blocked reason.
- Clicking a task in Tasks view opens the corresponding Task tab and records originating Feature tab and active Tasks view.
- Logs view shows `SOURCE status.yaml` when available and renders feature activity timeline with action, stage, actor, timestamp, and note.
- Logs empty state: `No feature logs are available.`
- Chat anchor area supports the later 50% / 50% split view from T6.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Build Feature tab route/page shell without sidebar.
- [ ] Render header with Back, copy, status pill, current stage pill, modified time, summary, and chat icon.
- [ ] Implement copy feature id feedback from copy icon to check icon.
- [ ] Build current stage hover popover with ordered stage rows and current badge.
- [ ] Implement view tabs and active view state.
- [ ] Render Product Spec view with source badge and formatted markdown preview.
- [ ] Render Technical Design view with source badge and formatted markdown preview.
- [ ] Add green check indicators for approved Product Spec and Technical Design stages.
- [ ] Render Tasks view with title, total count, task metadata list, and task item click behavior.
- [ ] Preserve originating Feature tab context for Task tab Back behavior.
- [ ] Render Logs view with source badge, activity timeline, and empty state.
- [ ] Add tests for stage popover, view switching, markdown rendering, task drilldown, logs, and copy feedback.
- [ ] Typecheck passes.

---

## T6 - Scoped agent chat panel and session persistence

### Description

Build the scoped Agent chat panel and its task/feature session persistence.

This task depends on T4 and T5 because chat needs stable Task tab and Feature tab anchors plus scoped context from those pages.

Deliverables:

- Chat opens only from Task tab/detail or Feature tab/detail.
- No chat entry point appears on the workspace board.
- Opening chat changes the page to a 50% content / 50% chat split on desktop.
- Chat panel appears on the right and aligns height with the active tab content.
- Resize handle on the left edge supports horizontal drag with min/max width constraints.
- Fullscreen/expand action increases chat space and changes icon to minimize/exit fullscreen.
- Escape exits fullscreen.
- Close button hides the panel without deleting the active scoped session.
- New chat action is represented by a plus icon, not a visible `New chat` label.
- New chat creates a fresh conversation in the same task/feature scope.
- Session title starts as `New Chat` and updates from the first user message.
- Persist session id, title, updatedAt, messages, input draft, attachment draft metadata, and selectedModelId.
- Feature chat key uses `workspaceId + featureId`.
- Task chat key uses `workspaceId + featureId + taskId`.
- Clone tab/session uses a unique key suffix.
- Send appends user message and prepares selected model plus scoped context for future API integration.
- No fake assistant response is generated when no real API is connected.
- Typing indicator appears only when a real request is active in a later integration.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Add scoped chat state and persistence helpers.
- [ ] Add chat open/close lifecycle from Task tab and Feature tab headers.
- [ ] Implement 50% / 50% split layout when chat is open.
- [ ] Implement resize handle with min/max width constraints.
- [ ] Implement fullscreen/expand, minimize, Escape exit, and close behavior.
- [ ] Implement plus-icon new chat action and session creation.
- [ ] Implement session title update from first user message.
- [ ] Persist drafts, messages, selected model, and attachment draft metadata by scope key.
- [ ] Prepare scoped context payload for task and feature sessions without calling a real API.
- [ ] Ensure no workspace board chat entry point exists.
- [ ] Add tests for scope keys, session restore, new chat, resize state, fullscreen, close, and no fake assistant response.
- [ ] Typecheck passes.

---

## T7 - Composer tools, skill mentions, model selector, and attachments

### Description

Implement the Agent chat composer interactions that make scoped chat usable for workflow work.

This task depends on T6 because the composer must write into scoped chat sessions and use the chat panel lifecycle.

Deliverables:

- Composer textarea supports Enter to send and Shift+Enter for newline.
- Send button is disabled when there is no text and no attachment.
- Model selector menu shows:
  - `GPT-5.5` - `Extra High`.
  - `GPT-5.4` - `Balanced`.
  - `GPT-5.4 Mini` - `Fast`.
  - `GPT-5.3 Codex` - `Code`.
- Selected model shows a check icon and persists per active session.
- Clicking outside or Escape closes the model menu without changing model.
- `$` mention opens `Skills`.
- Skill menu supports filtering, max 7 visible options, click selection, Enter selection, Escape close, and trailing space insertion.
- Skill options include `$resume-feature`, `$init-feature`, `$approve-feature`, `$tech-lead`, `$start-implementation`, `$pr-create`, `$pr-self-review`, and `$list-features`.
- Skill selection inserts value plus trailing space and keeps composer focus.
- Pasted `image/*` clipboard items become preview attachments above the textarea.
- Attachment previews can be removed with `X`.
- Sending clears text and previews.

### Required skills

- frontend-engineer
- typescript-best-practices

### Subtasks

- [ ] Implement composer Enter and Shift+Enter behavior.
- [ ] Implement disabled send state for empty text and no attachments.
- [ ] Build model selector menu with four model options and selected check.
- [ ] Persist selected model per active chat session.
- [ ] Implement `$` skill mention trigger, filtering, selection, Escape, and max visible options.
- [ ] Ensure Enter selects active mention instead of sending while a mention menu is open.
- [ ] Implement pasted image attachment previews and remove actions.
- [ ] Clear input and previews after send.
- [ ] Add tests for keyboard behavior, model menu, skill filtering/selection, image paste, preview removal, and send clearing.
- [ ] Typecheck passes.

---

## T8 - Integration tests and browser QA

### Description

Run final integration tests and browser QA across the full workspace tabs, work item tabs, and scoped chat flows.

This task depends on all UI implementation tasks. It owns regression fixes directly caused by this feature.

Deliverables:

- Unit test suite passes.
- TypeScript typecheck passes.
- Production build passes.
- Browser QA verifies workspace dropdown search, switch, outside click, active check, and import modal.
- Browser QA verifies task single click, double click, right click, sidebar task behavior, and no duplicate default tab.
- Browser QA verifies Feature Mode feature single click, double click, right click, and Task Mode feature double-click gating.
- Browser QA verifies Task tab header, metadata, PR cards, timeline, copy feedback, close behavior, and Back behavior.
- Browser QA verifies Feature tab header, stage popover, view tabs, markdown views, Tasks view, Logs view, copy feedback, task drilldown, and Back behavior.
- Browser QA verifies chat scoped to task/feature, no workspace chat, 50% / 50% split, resize, fullscreen, close/restore, plus-icon new chat, model selector, `$` skill mentions, multiline, and image paste.
- Browser QA verifies workspace switching removes previous workspace tabs and chat context from the active UI.
- Screenshots or notes are captured for key Figma/reference surfaces where practical.

### Required skills

- frontend-engineer
- browser-qa-frontend

### Subtasks

- [ ] Run unit tests.
- [ ] Run TypeScript typecheck.
- [ ] Run production build.
- [ ] Start local app and import or use a workspace with representative features and tasks.
- [ ] Verify workspace dropdown and import modal flows.
- [ ] Verify task click, double-click, and right-click flows from board and sidebar.
- [ ] Verify feature click, double-click, and right-click flows in Task Mode and Feature Mode.
- [ ] Verify Task tab page content, copy feedback, PR cards, timeline, Back, close, and no-sidebar layout.
- [ ] Verify Feature tab page content, stage popover, view tabs, markdown rendering, task drilldown, Back, close, and no-sidebar layout.
- [ ] Verify Agent chat split, resize, fullscreen, close/restore, new chat plus icon, no workspace chat, and no fake assistant response.
- [ ] Verify model selector, `$` skill mentions, multiline input, and image paste attachment previews.
- [ ] Fix feature-owned regressions found during QA.
