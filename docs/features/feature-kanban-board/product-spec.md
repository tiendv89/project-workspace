# Kanban Board Feature Mode Product Spec

## 1. Goal

This change adds a `Feature` mode to the Kanban Board.

The `Feature` mode displays features as a simple list of rows. Each feature appears on one row and has one current feature status.

This mode is focused only on feature-level visibility.

It does not display or manage tasks.

The main goal is to let the user quickly scan all features and understand the current status of each feature without opening task-level details.

---

## 2. Scope of Change

This change only affects the `Feature` mode inside the Kanban Board.

Feature Mode includes:

- Board mode toggle to switch to `Feature` mode.
- Feature list displayed as rows.
- Feature status displayed on each feature row.
- Search by feature title or feature id using Feature Mode search state.
- Filter by feature status using Feature Mode filter state.
- Default Feature Mode filter selects all feature statuses except `Done`.
- Feature detail sheet/modal opened from a feature row.
- Empty/loading/error states for the feature list.

No changes are made to:

- Task Mode behavior.
- Task card display.
- Task status logic.
- Task detail sheet behavior.
- Task update behavior.
- Import workspace flow.
- Workspace switching behavior.
- Data model, unless separately specified.

Feature Mode does not include:

- Task cards.
- Task rows.
- Task status columns.
- Task progress bar.
- Done/total task count.
- Task segment bar.
- Task status updates.
- Task detail sheet.

---

## 3. Feature Mode Display

### 3.1 Default State

When the user switches to `Feature` mode, the board displays a list of feature rows.

Each feature is shown on one row.

The user sees feature-level information only.

Task information is not shown in this mode.

---

### 3.2 Board Mode Toggle

The Kanban Board has a mode toggle with two options:

1. `Task`
2. `Feature`

When the user selects `Feature`:

- The `Feature` option becomes active.
- The board displays feature rows.
- The filter menu uses Feature Mode filter state and feature status filters.
- Task rows and task cards are not displayed.

When the user selects `Task`, the board returns to the existing Task Mode behavior.

---

### 3.3 Feature Row Layout

Each feature row displays one feature.

The row is split into two visual areas:

- Left side: feature identity.
- Right side: feature status and optional metadata.

Example layout logic:

- Left side: `feature icon + feature title + feature id`
- Right side: `feature status pill + last updated`

The exact optional metadata can depend on available data and design needs.

---

### 3.4 Left Side of Feature Row

The left side of the feature row displays:

1. Feature/project icon, if available.
2. Feature title.
3. Feature id or short code, if available.

The feature title should be the most prominent text in the row.

The user should be able to identify the feature quickly while scanning the list.

---

### 3.5 Right Side of Feature Row

The right side of the feature row displays secondary feature-level information.

Display order from left to right inside the right-side group:

1. Feature status pill.
2. Last updated time, if feature-level data is available.
3. Additional feature-level metadata, if required by design.

The right side must not display task-level information.

Do not show:

- Done/total task count.
- Task segment bar.
- Task assignee.
- Task status.
- Task progress.

---

### 3.6 Feature Status Pill

Each feature row displays a status pill for the feature.

The status pill includes:

- Status color dot, if supported by the design system.
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

Purpose: the user can understand the current status of the feature directly from the row.

Rules:

- Each feature has one status at a time.
- The status is the feature status, not a task status.
- The status must include a text label and not rely only on color.
- If a feature has an unknown status, the board should not crash.

---

### 3.7 Feature Row Click Behavior

When the user clicks a feature row:

1. The selected feature is set.
2. The Feature Detail sheet/modal opens.
3. The user sees feature-level detail for the selected feature.
4. Closing the sheet/modal returns the user to the feature list.

Clicking a feature row must not open Task Detail.

Feature Mode does not expand rows to show tasks.

---

## 4. Search and Filter Behavior

### 4.1 Feature Mode Search State

Search in Feature Mode uses the new Feature Mode search state.

This state is separate from Task Mode search/filter behavior.

Search applies only to feature-level fields:

- Feature title.
- Feature id or short code.

Search does not apply to:

- Task title.
- Task description.
- Task status.
- Task assignee.

Rules:

- Search is case-insensitive.
- Search trims leading and trailing whitespace.
- If the Feature Mode search state is empty, all features are shown unless filtered by Feature Mode filter state.
- Changing Task Mode search behavior must not change Feature Mode search results.
- Changing Feature Mode search state must not change Task Mode task filtering behavior.

---

### 4.2 Feature Mode Filter State

Filter in Feature Mode uses the new Feature Mode filter state.

By default, Feature Mode selects all feature statuses except `Done`.

This means completed features are hidden from the default Feature Mode list, while active, blocked, cancelled, and in-progress lifecycle states remain visible.

The filter menu in Feature Mode displays feature status filters.

Each filter option displays:

- Checkbox state.
- Status color dot.
- Status label.
- Count of features with that status, if available.

Rules:

- The default selected statuses are `In Design`, `In TDD`, `Ready`, `In Progress`, `Handoff`, `Blocked`, and `Cancelled`.
- `Done` is not selected by default.
- The user can manually select `Done` if they want to see completed features.
- The user can select or deselect one or more feature statuses.
- If no feature status is selected, no features are shown unless the product defines a separate fallback behavior.
- Feature Mode search state and Feature Mode filter state can be applied together.
- Clearing filters in Feature Mode clears Feature Mode filter state only.
- Task Mode filter state is not used in Feature Mode.
- Task status filters are not used in Feature Mode.

---

### 4.3 Mode Switching State Rules

Search and filter state must follow the active board mode.

Rules:

- When `Feature` mode is active, the board applies Feature Mode search state and Feature Mode filter state.
- When `Task` mode is active, the board applies existing Task Mode search/filter behavior.
- Switching from `Task` mode to `Feature` mode must not accidentally apply task status filters to feature rows.
- Switching from `Feature` mode to `Task` mode must not accidentally apply feature status filters to task rows.
- Active filter count should reflect the active mode only.
- Clear filter should clear filters for the active mode only.

---

### 4.4 Empty Search / Filter State

If no features match the active search or filter, the board displays an empty state.

Text:

`No features match your search.`

The empty state should make it clear that the user can adjust or clear search/filter conditions.

---

## 5. Data Requirements

### 5.1 Minimum Feature Data

Each feature requires:

- `id`
- `title`
- `status`

### 5.2 Optional Feature Data

The following data can be used when available:

- `description`
- `summary`
- `updatedAt`
- `metadata`
- `history`

Optional data should only be displayed if it improves feature-level understanding.

Feature Mode must not depend on task data to render the feature list.

---

### 5.3 Status Values

Supported feature status values:

- `in_design`
- `in_tdd`
- `ready_for_implementation`
- `in_implementation`
- `in_handoff`
- `done`
- `blocked`
- `cancelled`

Display labels:

- `In Design`
- `In TDD`
- `Ready`
- `In Progress`
- `Handoff`
- `Done`
- `Blocked`
- `Cancelled`

---

## 6. What Changed Compared to Task Mode

### 6.1 Removed / Not Shown

The following task-level elements are not shown in Feature Mode:

- Task rows.
- Task cards.
- Task status columns.
- Task detail sheet.
- Done/total task count.
- Task segment bar.
- Task progress bar.
- Task assignee.
- Task status update controls.

### 6.2 Added / Changed

The following feature-level behavior is added:

- User can switch to `Feature` mode.
- Features are displayed as rows.
- Each feature row shows one feature status.
- Search uses Feature Mode search state and applies to feature title/id.
- Filter uses Feature Mode filter state and applies to feature status.
- Feature Mode filter defaults to all statuses except `Done`.
- Clicking a feature row opens Feature Detail.

---

## 7. User Journey

### Journey 1: User Opens Feature Mode

#### Step 1

The user opens the Kanban Board.

#### Step 2

The user selects `Feature` from the board mode toggle.

#### Step 3

The board displays a list of feature rows.

#### Step 4

Each feature row displays:

- Feature title.
- Feature id or short code, if available.
- Feature status.
- Optional feature-level metadata, if available.

#### Expected Result

The user can quickly scan all features and understand the current status of each feature.

---

### Journey 2: User Checks Feature Status

#### Step 1

The user looks at a feature row.

#### Step 2

The user checks the status pill on the row.

#### Step 3

The user understands the current feature status, for example `In Progress`, `Blocked`, or `Done`.

#### Expected Result

The user can understand the feature status directly from the feature row.

---

### Journey 3: User Searches for a Feature

#### Step 1

The user enters a keyword in the search input while `Feature` mode is active.

#### Step 2

The board updates the Feature Mode search state.

#### Step 3

The board filters the feature list by feature title or feature id.

#### Step 4

Only matching feature rows remain visible.

#### Expected Result

The user can quickly find a specific feature without scanning the full list.

Task Mode search/filter state is not affected.

---

### Journey 4: User Filters by Feature Status

#### Step 1

The user opens `Feature` mode.

#### Step 2

By default, the board applies Feature Mode filter state with all statuses selected except `Done`.

#### Step 3

The user opens the filter menu while `Feature` mode is active.

#### Step 4

The user selects or deselects one or more feature statuses.

#### Step 5

The board updates the Feature Mode filter state.

#### Step 6

The board displays only features with the selected statuses.

#### Expected Result

The user can focus on features in specific states, such as `Blocked`, `In Progress`, or `Ready`.

By default, `Done` features are hidden until the user selects the `Done` filter.

Task Mode filters are not affected.

---

### Journey 5: User Opens Feature Detail

#### Step 1

The user clicks a feature row.

#### Step 2

The Feature Detail sheet/modal opens.

#### Step 3

The user views feature-level information for the selected feature.

#### Step 4

The user closes the Feature Detail sheet/modal.

#### Expected Result

The user can inspect a feature without leaving Feature Mode or opening task-level details.

---

### Journey 6: User Sees No Matching Features

#### Step 1

The user applies search or filter conditions.

#### Step 2

No features match the active conditions.

#### Step 3

The board displays the empty state message.

#### Expected Result

The user understands that no features match and can adjust or clear the search/filter.

---

## 8. Acceptance Criteria

- The user can switch to `Feature` mode from the board mode toggle.
- The `Feature` toggle shows an active state when Feature Mode is selected.
- Feature Mode displays features as rows.
- Each feature appears on one row only.
- Each feature row shows the feature title.
- Each feature row shows the feature status pill.
- The status pill shows the feature status, not task status.
- Feature Mode does not display task rows.
- Feature Mode does not display task cards.
- Feature Mode does not display task status columns.
- Feature Mode does not display done/total task count.
- Feature Mode does not display task segment bar.
- Search in Feature Mode uses Feature Mode search state.
- Search in Feature Mode matches feature title and feature id only.
- Search in Feature Mode does not match task data.
- Filter in Feature Mode uses Feature Mode filter state.
- Filter in Feature Mode uses feature status only.
- Feature Mode default filter selects all statuses except `Done`.
- `Done` features are hidden by default in Feature Mode.
- The user can manually select `Done` to show completed features.
- Task status filters are not used in Feature Mode.
- Task Mode search/filter state is not applied to Feature Mode.
- Feature Mode search/filter state is not applied to Task Mode.
- Active filter count reflects the active board mode only.
- Clear filter clears filters for the active board mode only.
- If no feature matches search/filter, the board displays `No features match your search.`
- Clicking a feature row opens Feature Detail.
- Clicking a feature row does not open Task Detail.
- Closing Feature Detail returns the user to Feature Mode.
- Feature Mode does not require task data to render the feature list.
- All existing Task Mode behavior remains unchanged.

---

## 9. References

### Figma

- Kanban Feature: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=103-2&m=dev
- Feature Detail: https://www.figma.com/design/KUVm6tSK6eyT89tZGuSko1/Dashboard-Workflow-UI?node-id=103-190&m=dev

