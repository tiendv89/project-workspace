# Product Specification

## Feature

- Feature ID: `workspace-tabs-chat`
- Title: `Workspace Tabs, Work Item Tabs, and Agent Chat`

## Problem

Users need to move between the workspace board, saved workspaces, task sessions, feature sessions, and scoped agent conversations without losing context. Today these flows are easy to confuse because quick detail views, persistent work sessions, workspace switching, and chat scope are not separated clearly enough.

This feature defines the product-level user journeys for workspace tabs, task tabs, feature tabs, and task/feature-scoped agent chat. Technical layout details, data models, persistence keys, event handling, accessibility roles, and API payloads should be handled later in technical design.

## Goals

- Make the workspace tab the clear way to return to the current workspace board.
- Let users switch between saved workspaces from the workspace tab.
- Let users import a new workspace from a repository.
- Let users inspect tasks and features quickly without opening persistent sessions.
- Let users open persistent task and feature tabs when they want deeper work context.
- Keep task and feature tab behavior predictable across single click, double click, and context menu actions.
- Keep the board sidebar limited to the workspace board, not task or feature tabs.
- Let users read task and feature context inside their respective work item tabs.
- Let users open agent chat only from task or feature context.
- Let users start new scoped chats, choose a model, mention workflow skills, paste images, resize chat, and close or reopen chat.
- Ensure chat UI prepares the correct task or feature context for a future real agent API without showing fake assistant responses.

## Non-goals

- No workspace-scope agent chat.
- No real backend or LLM response integration in this stage.
- No mock assistant response behavior.
- No workflow lifecycle, approval gate, task status, or task YAML ownership changes.
- No broad dashboard redesign outside workspace tabs, work item tabs, and scoped chat.
- No implementation detail such as exact routes, event handlers, storage keys, payload schema, component layout values, or accessibility role definitions in this product spec.
- No `deployment-checklist.md` at this stage.

## User Journey

### Journey 1 - Return to the workspace board

1. The user is viewing a task tab or feature tab.
2. The user clicks the workspace tab.
3. The app returns to the board for the current workspace.
4. The workspace tab becomes active.
5. The task and feature tabs remain available so the user can return to them later.

Expected result: the user can get back to the board quickly without closing open work item tabs.

### Journey 2 - Open the workspace switcher

1. The user is on the dashboard with a workspace selected.
2. The user opens the workspace switcher from the workspace tab.
3. The app shows saved workspaces and a way to search them.
4. The active workspace is clearly marked.
5. The user can either choose a saved workspace or start importing a new one.

Expected result: the user understands where they are and can move to another workspace from the same header area.

### Journey 3 - Search and select a saved workspace

1. The user opens the workspace switcher.
2. The user searches for a workspace.
3. The app filters the saved workspace list.
4. If there is no match, the app shows an empty state.
5. The user selects a workspace from the results.
6. The app switches to that workspace and returns to the board view.
7. Task and feature tabs from the previous workspace are not shown in the newly selected workspace.

Expected result: workspace switching is fast and does not leak tabs or context from another workspace.

### Journey 4 - Close the workspace switcher

1. The workspace switcher is open.
2. The user clicks outside it or dismisses it.
3. The switcher closes.
4. The active workspace does not change.

Expected result: the user can back out of workspace switching without side effects.

### Journey 5 - Start importing a workspace

1. The user opens the workspace switcher.
2. The user chooses the import workspace action.
3. The switcher closes.
4. The import workspace modal opens directly to the import form.

Expected result: importing a workspace is reachable from the same place users manage workspace switching.

### Journey 6 - Submit an imported workspace

1. The user provides the repository information needed to create a workspace.
2. The user provides access credentials when needed.
3. The user submits the form.
4. If the import succeeds, the app adds the workspace to the saved workspace list.
5. The user can switch to the imported workspace from the workspace switcher.

Expected result: the new workspace becomes available without requiring the user to restart the dashboard.

### Journey 7 - Handle import failure

1. The user submits the import form.
2. The import fails because the repository cannot be used or accessed.
3. The modal stays open.
4. The app shows a clear error.
5. The user edits the input and tries again.

Expected result: the user can recover from import errors without losing form context.

### Journey 8 - Cancel workspace import

1. The import modal is open.
2. The user closes the modal.
3. The modal state resets.
4. The active workspace remains unchanged.

Expected result: cancelling import does not change the current workspace.

### Journey 9 - Inspect a task quickly from the board

1. The user is on the workspace board in task-oriented mode.
2. The user single-clicks a task.
3. The app opens a quick task detail view.
4. The user reviews the task at a glance.
5. The user closes the quick view and remains on the board.

Expected result: the user can inspect a task quickly without creating a persistent tab.

### Journey 10 - Open a task tab from the board

1. The user is on the workspace board.
2. The user double-clicks a task.
3. The app opens a task tab for that task.
4. If the task tab already exists, the app focuses the existing tab.
5. The user can return to the board by clicking the workspace tab.

Expected result: double click starts or restores a persistent task work session.

### Journey 11 - Open a task tab from a context menu

1. The user opens the context menu for a task.
2. The user chooses the action to open the task in a new tab.
3. The app opens a task tab for that task.
4. The context menu closes.

Expected result: users have an explicit context-menu path for opening a task work session.

### Journey 12 - Use task items from the sidebar

1. The user is on the workspace board where the sidebar is visible.
2. The sidebar shows important task groups.
3. The user single-clicks a sidebar task item to inspect it quickly.
4. The user double-clicks a sidebar task item to open or focus its task tab.
5. The user can also open a task tab from the sidebar task context menu.

Expected result: sidebar task items follow the same product behavior as task cards on the board.

### Journey 13 - Inspect a feature quickly in Task Mode

1. The user is viewing task-level board content.
2. The user single-clicks a feature row.
3. The app opens a quick feature detail view.
4. The user reviews the feature at a glance.
5. Double-clicking the feature in this mode does not open a feature tab.

Expected result: Task Mode remains focused on task work while still allowing quick feature inspection.

### Journey 14 - Switch to Feature Mode

1. The user changes the board to Feature Mode.
2. The board shows feature-level content instead of task-level content.
3. The user scans features by their overall state.

Expected result: the user can review feature-level progress without task-level noise.

### Journey 15 - Open a feature tab in Feature Mode

1. The user is in Feature Mode.
2. The user single-clicks a feature to inspect it quickly.
3. The user double-clicks a feature to open or focus its feature tab.
4. The user can also open a feature tab from the feature context menu.

Expected result: Feature Mode supports both quick inspection and persistent feature work sessions.

### Journey 16 - Activate an existing task tab

1. A task tab is visible in the header.
2. The user clicks the task tab.
3. The task tab becomes active.
4. The main content shows the task work session.
5. The sidebar is hidden.
6. If chat is open, chat follows task scope.

Expected result: the user returns to the same task work session without losing task context.

### Journey 17 - Read task tab content

1. The user opens a task tab.
2. The app shows the task identity and current task state.
3. The user reviews task context, execution context, dependency or blocked state, related PR state, and task activity when available.
4. Missing optional information is shown as empty or unavailable rather than breaking the view.

Expected result: the user can understand the task without reading raw workflow files.

### Journey 18 - Copy task identity

1. The user is inside a task tab.
2. The user copies the task identity from the task header.
3. The app gives short feedback that the copy action succeeded.

Expected result: the user can quickly reference the task in chat, issues, PRs, or documents.

### Journey 19 - Open chat from a task tab

1. The user is inside a task tab.
2. The user opens agent chat.
3. Chat opens beside the task content.
4. Chat uses the current task as its scope.
5. The user can ask about the task without leaving the task tab.

Expected result: the user can discuss or prepare work using the current task context.

### Journey 20 - Leave a task tab

1. The user closes a task tab or uses Back from inside a task tab.
2. If the task was opened from a feature tab, the app returns to that feature tab when possible.
3. Otherwise, the app returns to the workspace board or another relevant open tab.

Expected result: leaving a task tab preserves the most useful previous context.

### Journey 21 - Activate an existing feature tab

1. A feature tab is visible in the header.
2. The user clicks the feature tab.
3. The feature tab becomes active.
4. The main content shows the feature work session.
5. The sidebar is hidden.
6. If chat is open, chat follows feature scope.

Expected result: the user returns to the same feature work session without losing feature context.

### Journey 22 - Read feature tab content

1. The user opens a feature tab.
2. The app shows the feature identity and current feature state.
3. The user can move between feature views such as product spec, technical design, tasks, and logs or status.
4. Source documents are readable inside the dashboard.
5. Feature history and task summary are visible when available.

Expected result: the user can review feature context without leaving the feature tab.

### Journey 23 - Understand feature stage state

1. The user is inside a feature tab.
2. The user opens or hovers the current stage summary.
3. The app shows which feature stages are complete, current, or not yet complete.
4. The user dismisses the stage summary and remains in the feature tab.

Expected result: the user can understand the feature stage without reading raw status files.

### Journey 24 - Open a task from a feature tab

1. The user is inside a feature tab.
2. The user opens the feature tasks view.
3. The user selects a task.
4. The app opens or focuses the corresponding task tab.
5. When the user goes Back from that task, the app returns to the originating feature tab when possible.

Expected result: the user can drill down from feature context into task context and return cleanly.

### Journey 25 - Copy feature identity

1. The user is inside a feature tab.
2. The user copies the feature identity from the feature header.
3. The app gives short feedback that the copy action succeeded.

Expected result: the user can quickly reference the feature in chat, issues, PRs, or documents.

### Journey 26 - Open chat from a feature tab

1. The user is inside a feature tab.
2. The user opens agent chat.
3. Chat opens beside the feature content.
4. Chat uses the current feature as its scope.
5. The user can ask about the active feature view without leaving the feature tab.

Expected result: the user can discuss or prepare feature work using the current feature context.

### Journey 27 - Close a feature tab

1. The user closes a feature tab.
2. The feature tab is removed from the header.
3. If related task tabs are open, they remain available unless a later product decision changes that behavior.
4. The user remains in the same workspace.

Expected result: closing a feature tab does not unexpectedly close task work sessions or change workspace.

### Journey 28 - Start a new scoped chat

1. The user has chat open from a task or feature tab.
2. The user starts a new chat.
3. The new conversation starts in the same task or feature scope.
4. The user can begin a fresh prompt without leaving the current tab.

Expected result: the user can start a clean conversation while preserving the current task or feature context.

### Journey 29 - Send a chat message

1. The user writes a message in scoped chat.
2. The user sends the message.
3. The message appears in the conversation.
4. The chat UI prepares the selected model and current task or feature context for a future real API call.
5. If no real chat API is connected, the UI does not show a fake assistant answer.

Expected result: user messages are captured without implying a fake agent response.

### Journey 30 - Write multiline chat input

1. The user writes in the chat composer.
2. The user inserts a line break.
3. The message remains unsent until the user explicitly sends it.

Expected result: the user can write longer prompts comfortably.

### Journey 31 - Resize or expand chat

1. Chat is open beside a task or feature tab.
2. The user adjusts the chat size.
3. The active task or feature content remains accessible.
4. The user can expand chat for more reading space.
5. The user can return chat to the normal split view.

Expected result: the user can control workspace between content and chat without losing the conversation.

### Journey 32 - Choose a chat model

1. The user opens the model selector in chat.
2. The user chooses a model.
3. The model applies to the current chat session.
4. The user continues the conversation in the same task or feature scope.

Expected result: the user can choose the model for the current scoped conversation.

### Journey 33 - Mention a workflow skill

1. The user is writing in chat.
2. The user starts a workflow skill mention.
3. The app shows matching workflow skills.
4. The user selects a skill.
5. The skill mention is inserted into the prompt.

Expected result: the user can reference workflow skills without leaving the composer.

### Journey 34 - Paste an image attachment

1. The user pastes an image into chat.
2. The app adds the image as a pending attachment.
3. The user can remove it before sending.
4. When the user sends the prompt, the image is included with the user message.

Expected result: the user can include visual context in a scoped chat prompt.

### Journey 35 - Close and reopen chat

1. The user closes chat.
2. The task or feature tab remains active.
3. The user later opens chat again from the same task or feature.
4. The app restores the scoped chat state when persistence is available.

Expected result: closing chat removes the panel without intentionally discarding the active scoped conversation.

## Acceptance Criteria

- The workspace tab returns the user from any task or feature tab to the current workspace board.
- The workspace switcher lets the user search saved workspaces, switch workspace, and cancel without changing workspace.
- Workspace import lets the user add a repository-backed workspace and recover from import errors.
- Single-clicking a task or feature opens quick inspection rather than a persistent tab.
- Double-clicking a task opens or focuses a task tab.
- Double-clicking a feature opens or focuses a feature tab only in Feature Mode.
- Task and feature context menus provide a clear path to open work item tabs where supported.
- Sidebar task items follow the same task inspection and task tab behavior as board task cards.
- Task tabs and feature tabs preserve work sessions and can be activated, closed, and navigated from predictably.
- The sidebar is visible on the workspace board and hidden in task and feature tabs.
- Task tabs let the user understand task identity, state, related work, and history.
- Feature tabs let the user understand feature identity, stage state, source documents, tasks, and history.
- Opening a task from a feature tab lets the user return to the originating feature tab when possible.
- Agent chat opens only from task or feature scope.
- Chat supports new scoped conversations, model choice, workflow skill mentions, image attachments, resizing, expanding, closing, and reopening.
- Chat does not show fake assistant responses before a real chat API exists.
- Product-level behavior is documented here; detailed UI structure, technical data contracts, routes, storage, events, and API integration are deferred to technical design.
