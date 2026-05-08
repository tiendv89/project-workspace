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

### 2.2 Layout Behavior

The sidebar should feel like a stable companion panel for the Kanban Board, not a separate page or a replacement for the board.

On desktop-sized workspace screens, the sidebar should take approximately 15% of the available content width, and the Kanban Board should take the remaining approximately 85%.

The 15% / 85% split is the target layout ratio for the main workspace area below the header. The implementation may use sensible minimum and maximum widths so the sidebar remains readable and the Kanban Board remains usable on narrower screens.

The sidebar should take enough space for users to scan important task groups, while the Kanban Board remains the primary workspace on the right.

The sidebar and Kanban Board should stay visually separated so users can clearly understand which tasks are being shown in the sidebar and which tasks belong to the full board view.

When the sidebar contains many tasks, users should be able to scroll the sidebar task list without losing their current Kanban Board context.

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

### 2.8 Data Refresh

The 3 sidebar status rows must refresh automatically every 60 seconds.

The refresh updates the task list and task counts for:

- `IN PROGRESS`
- `IN REVIEW`
- `READY`

The automatic refresh should not reset:

- Collapse/expand state.
- Search text.
- Status filter state.
- The currently open task detail modal.
- The current Kanban Board scroll position, when possible.

Manual sync still refreshes immediately when the user clicks the sync action.

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
- On desktop-sized workspace screens, the sidebar uses approximately 15% width and the Kanban Board uses approximately 85% width.
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
- The 3 sidebar status rows refresh automatically every 60 seconds.
- A section with no tasks displays `No tasks.` when expanded.

# Kanban Board Product Spec

## 1. Goal

This change only updates how the `Feature Row` is displayed on the Kanban Board.

All other Kanban Board behavior remains unchanged, including:

- Header.
- Sidebar.
- Search/filter.
- Task card.
- Task detail sheet.
- Import workspace flow.

The main goal is to make each feature row show important information more clearly while collapsed, before the user needs to expand the row to view task details.

## 2. Scope of Change

Only the layout and displayed information inside the `Feature Row` are changed.

No changes are made to:

- Data model.
- Task status logic.
- Sidebar behavior.
- Task detail modal/sheet behavior.
- Search/filter logic.
- Workspace switching.
- Import workspace flow.

## 3. Feature Row Display

### 3.1 Default State

Each feature row is collapsed by default.

The user only sees the feature summary and does not see the task list inside the feature.

### 3.2 Left Side of Feature Row

The left side of the feature row displays:

1. Expand/collapse icon.
2. Feature/project icon.
3. Feature ID.

The feature ID should stay close to the icon so the user can easily identify which project/feature the row represents.

The displayed feature label must use `feature_id`, not a separate feature title.

### 3.3 Right Side of Feature Row

Secondary information is grouped on the right side of the feature row.

Display order from left to right inside the right-side group:

1. Feature status pill.
2. Done/total task count.
3. Status segment bar.
4. Last modified time, if data is available.

Example layout logic:

- Left side: `chevron + icon + feature_id`
- Right side: `status pill + 2/5 + segment bar + Modified Dec 10 14:30`

### 3.4 Feature Status Pill

The feature row displays a status pill for the feature.

The status pill includes:

- Status color dot.
- Status label.
- Background, border, and text color based on the status.

Possible statuses:

- `In Design`
- `In TDD`
- `Ready`
- `In Progress`
- `Handoff`
- `Done`
- `Blocked`
- `Cancelled`

Purpose: the user can understand the overall status of the feature without expanding the row.

### 3.5 Done / Total Count

The feature row displays the number of completed tasks over the total number of tasks.

Format:

`doneTasks/totalTasks`

Example:

`2/5`

Rules:

- `doneTasks` is the number of tasks with status `done`.
- `totalTasks` is the total number of tasks in the feature.

### 3.6 Status Segment Bar

The old progress bar is replaced by a status segment bar.

The status segment bar shows the status distribution of all tasks in the feature.

Rules:

- Each task corresponds to one segment.
- Each segment color is based on the task status.
- All segments have equal width.
- Hovering over a segment highlights that segment.
- Hovering over a segment shows a tooltip with that segment's status.

Purpose: the user can quickly see which task statuses exist inside the feature without expanding the row.

### 3.7 Last Modified Time

The feature row displays the most recent update time if data is available.

Text format:

`Modified MMM d HH:mm`

Data sources used to calculate last modified time:

- `task.execution.last_updated_at`
- `task.log[].at`

Rules:

- Use the latest timestamp across all tasks in the feature.
- If there is no valid timestamp, hide the last modified text.
- If the timestamp is from today, use a more prominent style so the user can notice recently updated features.

## 4. Expand Behavior

When the user clicks the feature row:

1. The row changes from collapsed to expanded.
2. The task grid below the row is displayed.
3. Each task appears in the correct status column.
4. Clicking the row header again collapses the row.

The purpose of expand/collapse behavior remains unchanged: the user only opens a row when they want to see detailed tasks.

## 5. What Changed Compared to Previous Feature Row

### 5.1 Removed / Replaced

The following old elements are no longer the focus of the feature row:

- Progress bar that only shows linear completion.
- Status count badges that only appear when the row is collapsed.

### 5.2 Added / Moved

The following elements were added or moved:

- Feature status pill is added to the row summary.
- Done/total count is placed inside the right-side information group.
- Status segment bar replaces the old progress bar.
- Last modified time is added at the end of the right-side information group.
- Feature rows are collapsed by default to keep the board cleaner.

## 6. User Journey

### Journey 1: User Opens the Kanban Board

#### Step 1

The user opens the Kanban Board.

#### Step 2

The board displays feature rows in the collapsed state.

#### Step 3

Each feature row displays a summary with:

- Feature ID.
- Feature status.
- Done/total task count.
- Status segment bar.
- Last modified time, if available.

#### Expected Result

The user can quickly scan the state of multiple features without expanding each row.

### Journey 2: User Checks Overall Feature Status

#### Step 1

The user looks at a feature row.

#### Step 2

The user checks the status pill on the right side of the row.

#### Step 3

The user understands the overall feature status, for example `In Progress`, `Blocked`, or `Done`.

#### Expected Result

The user can understand the feature status directly from the row summary.

### Journey 3: User Checks Task Distribution Quickly

#### Step 1

The user looks at the status segment bar in a feature row.

#### Step 2

The user sees colored segments that represent task statuses inside the feature.

#### Step 3

The user hovers over a segment if they want to know the exact status of that segment.

#### Expected Result

The user can quickly understand which task statuses exist in the feature without expanding the row.

### Journey 4: User Checks Recent Activity

#### Step 1

The user looks at the `Modified ...` text at the end of the feature row.

#### Step 2

If the feature was updated today, the timestamp uses a more prominent style.

#### Step 3

The user knows which features have recent activity.

#### Expected Result

The user can more easily prioritize features that were updated recently.

### Journey 5: User Expands Feature Row

#### Step 1

The user clicks the feature row header.

#### Step 2

The feature row expands.

#### Step 3

The task grid is displayed below the row.

#### Step 4

Each task appears in the correct column based on its current status.

#### Expected Result

The user can switch from summary scanning to detailed task viewing when needed.

## 7. Acceptance Criteria

- Feature rows are collapsed by default.
- The left side of each row shows the chevron, feature icon, and `feature_id`.
- The right side of each row shows the feature status pill, done/total count, status segment bar, and last modified time when available.
- The status segment bar replaces the old percentage progress bar.
- Hovering over a segment shows the corresponding task status tooltip.
- Last modified time is calculated from task execution timestamps and task log timestamps.
- If no valid timestamp exists, the last modified text is hidden.
- Clicking the feature row header expands/collapses the row.
- The expanded row still places tasks in the correct status columns.
- All other Kanban Board behavior remains unchanged.

# Default Filter Status Product Spec

## 1. Goal

Help users focus on unfinished items by hiding `Done` status by default, while preserving the status filter state selected by the user.

When users first open the workflow/task list, they should immediately see active work instead of completed items. If users choose to include `Done`, that preference should be remembered and restored later.

## 2. Scope of Change

This change only affects the default and persisted behavior of the status filter.

No changes are made to:

- Task status definitions.
- Task status transitions.
- Search behavior.
- Sidebar layout.
- Kanban feature row layout.
- Task detail modal/sheet behavior.

## 3. Default Filter Behavior

When the user opens the screen for the first time and no saved filter exists, the status filter should check all statuses except `Done`.

Items with status `Done` should not be displayed by default.

The user can check `Done` again if they want to view completed items.

If no saved filter exists, the system always uses the default filter: all statuses except `Done`.

## 4. Saved Filter Behavior

When the user changes the status filter, the system saves the current filter state.

When the user reloads the page or returns to the screen, the system restores the latest saved filter state.

The saved filter takes priority over the default filter. The default filter is only used when no saved filter exists.

## 5. User Journey

### Journey 1: User Opens the Screen for the First Time

#### Step 1

The user opens the workflow/task list.

#### Step 2

The system has no saved filter.

#### Step 3

The system automatically checks all statuses except `Done`.

#### Step 4

The list only shows unfinished items.

#### Expected Result

The user can focus on active work without manually hiding completed items.

### Journey 2: User Wants to View Done Items

#### Step 1

The user opens the status filter.

#### Step 2

The user checks the `Done` checkbox.

#### Step 3

The list displays items with status `Done`.

#### Step 4

The system saves the new filter state.

#### Step 5

The next time the user returns, `Done` remains checked.

#### Expected Result

The user can intentionally include completed items and keep that preference across reloads or return visits.

### Journey 3: User Wants to Hide Done Items Again

#### Step 1

The user opens the status filter.

#### Step 2

The user unchecks the `Done` checkbox.

#### Step 3

The list hides items with status `Done`.

#### Step 4

The system saves the new filter state.

#### Step 5

The next time the user returns, `Done` remains hidden.

#### Expected Result

The user can return to an unfinished-work view and keep that preference across reloads or return visits.

### Journey 4: User Reloads the Page

#### Step 1

The user has previously updated the status filter.

#### Step 2

The user reloads the page.

#### Step 3

The system reads the saved filter.

#### Step 4

The list is displayed based on the saved filter state.

#### Expected Result

The user sees the same status-filtered list after reload, instead of being reset unexpectedly.

## 6. Acceptance Criteria

- On the first visit, all statuses are checked except `Done`.
- Items with status `Done` are not displayed by default.
- The user can check or uncheck each status.
- When the filter changes, the list updates accordingly.
- The filter state is saved after the user changes it.
- When the user reloads or returns to the screen, the filter is restored correctly.
- If no saved filter exists, the system uses the default filter that excludes `Done`.
