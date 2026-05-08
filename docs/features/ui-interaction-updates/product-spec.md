# Sidebar Product Spec

## Feature
- Feature ID: `ui-interaction-updates`
- Title: UI Interaction Updates

## 1. Goal

The sidebar helps users quickly monitor important tasks by status without leaving the Kanban Board.

The sidebar is no longer a navigation menu where users click each item to change the content on the right. Instead, the sidebar directly displays task groups by status, allows users to collapse/expand each group, and lets users click a task to open the task detail modal.

## 2. How the Sidebar Is Displayed

### 2.1 Position

The sidebar is displayed on the left side of the workspace screen, directly below the header.

The Kanban Board is displayed on the right side of the sidebar. The Kanban Board is always visible and is not replaced when users interact with the sidebar.

Overall layout:

- Header at the top.
- Sidebar on the left.
- Kanban Board on the right.

### 2.2 Size and Layout Behavior

The sidebar should not use fixed height or rigid layout sizing that may cause the layout to look misaligned on larger screens.

The sidebar should use a percentage-based width relative to the total layout width, for example around `15%` of the screen width. The remaining space, around `85%`, is reserved for the Kanban Board on the right.

Min/max width can be combined with the percentage-based width to ensure the sidebar is not too narrow on smaller screens and not too wide on larger screens. However, the primary sizing model should still be based on percentage rather than hard-coding one absolute size for every screen.

The sidebar has a right border to visually separate it from the Kanban Board.

If the task list inside the sidebar is taller than the viewport, the sidebar should have its own scroll area. Scrolling the sidebar should not affect the Kanban Board on the right.

### 2.3 Sidebar Header

The top section of the sidebar displays:

- An icon representing tasks/projects.
- Title: `Tasks Sidebar`.
- Short description: `Expand each status to view tasks directly in the sidebar.`

The purpose of this section is to help users understand that the sidebar is used to quickly view tasks by status.

### 2.4 Status Groups in the Sidebar

The sidebar only displays 3 primary status groups:

1. `IN PROGRESS`
2. `IN REVIEW`
3. `READY`

This order reflects operational priority:

- `IN PROGRESS`: tasks currently being worked on.
- `IN REVIEW`: tasks waiting for review.
- `READY`: tasks ready to be started.

Each status group is a collapsible/expandable section.

By default, when the user opens a workspace, all 3 sections are expanded so the task lists are immediately visible:

- `IN PROGRESS` is expanded.
- `IN REVIEW` is expanded.
- `READY` is expanded.

Users can collapse each section later if they want to reduce the amount of visible information.

### 2.5 Structure of a Status Section

Each status section has 2 parts:

#### Section Header

The section header displays:

- Collapse/expand icon.
- Status icon.
- Status name.
- Number of tasks in that status.

When the section is expanded:

- A down arrow icon is displayed.
- The task list inside the section is displayed.
- This is the default state of all sections when the sidebar is loaded for the first time.

When the section is collapsed:

- A right arrow icon is displayed.
- The task list inside the section is hidden.

#### Task List

The task list is displayed below the section header.

Each task is displayed as a small card.

### 2.6 Task Card in the Sidebar

Each task card in the sidebar displays the key task information:

- Task name.
- Feature/project name that contains the task.
- Priority, if available.
- Actor type, if available, for example `Agent` or `Human`.
- Next action or blocked reason, if available.

The task card has a hover state to indicate that it is clickable.

When hovering over a task card:

- The background changes slightly.
- The border becomes more visible.
- The cursor is a pointer.

When clicking a task card:

- The task detail modal opens.

### 2.7 Empty State

If a status has no tasks, the section is still displayed.

When the section is expanded and has no tasks, show the empty state:

`No tasks.`

Do not hide a status section just because it has no tasks.

## 3. User Journey When Interacting with the Sidebar

### Journey 1: User Opens a Workspace

#### Step 1

The user opens a workspace.

#### Step 2

The screen displays the header at the top, the sidebar on the left, and the Kanban Board on the right.

#### Step 3

The sidebar displays 3 status groups:

- `IN PROGRESS`
- `IN REVIEW`
- `READY`

These status groups are expanded by default so users can immediately see important task lists. This means `IN PROGRESS`, `IN REVIEW`, and `READY` are all expanded when the workspace is loaded for the first time.

#### Expected Result

The user can see important tasks in the sidebar while also seeing the overall Kanban Board on the right.

### Journey 2: User Expands a Status Section

#### Step 1

The user clicks the header of a collapsed status section, for example `READY`.

#### Step 2

The section expands.

#### Step 3

The list of tasks belonging to that status is displayed below the header.

#### Expected Result

The user can quickly view tasks in the selected status directly inside the sidebar without changing the Kanban Board on the right.

### Journey 3: User Collapses a Status Section

#### Step 1

The user clicks the header of an expanded status section, for example `IN PROGRESS`.

#### Step 2

The section collapses.

#### Step 3

The task list inside the section is hidden.

#### Expected Result

The user can reduce unnecessary information in the sidebar and focus on other status groups.

### Journey 4: User Clicks a Task in the Sidebar

#### Step 1

The user sees a task in the sidebar.

#### Step 2

The user clicks the task card.

#### Step 3

The task detail modal opens.

#### Step 4

The Kanban Board on the right remains unchanged behind the modal.

#### Step 5

The user views the task detail information.

#### Step 6

The user closes the task detail modal.

#### Expected Result

The user can view task details from the sidebar without losing the current Kanban Board context.

## 4. Interaction Rules

### 4.1 Clicking a Status Section

Clicking a status section only collapses or expands that section.

It does not open a modal.

It does not change the Kanban Board on the right.

It does not navigate to another page.

### 4.2 Clicking a Task Card

Clicking a task card in the sidebar opens the task detail modal.

The task detail modal is displayed on top of the current layout.

After closing the modal, the user returns to the previous sidebar and Kanban Board state.

### 4.3 Kanban Board Always Remains Visible

The Kanban Board on the right always remains visible while the user interacts with the sidebar.

The sidebar does not replace the Kanban Board with a status detail view.

### 4.4 Collapse/Expand State

The default state of all sidebar items/status sections is expanded.

When the user collapses or expands a section, that state should be preserved during the current session.

If the user opens the task detail modal and then closes it, the sidebar collapse/expand state should not reset.

## 5. Acceptance Criteria

- The sidebar is displayed on the left side of the Kanban Board.
- The sidebar displays exactly 3 statuses: `IN PROGRESS`, `IN REVIEW`, `READY`.
- Each status can be collapsed/expanded.
- All 3 status sections are expanded by default when opening a workspace.
- Each status displays the number of tasks it contains.
- Tasks are displayed directly inside their corresponding status section.
- Clicking a status only collapses/expands that section.
- Clicking a task opens the task detail modal.
- The Kanban Board on the right always remains visible.
- Search updates the task list in the sidebar.
- Filter updates the task list in the sidebar.
- A section with no tasks displays `No tasks.` when expanded.
