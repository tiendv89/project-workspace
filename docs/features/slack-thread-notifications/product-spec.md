# Product Specification

## Feature

- Feature ID: `slack-thread-notifications`
- Title: Slack Thread Notifications for Feature Runs

## Problem

Agent workflow notifications currently behave like independent Slack messages. When a feature starts, tasks progress, escalations happen, and the feature completes, the notification trail can spread across multiple top-level Slack messages. That makes it harder for humans to follow one feature end to end, and it makes task-level progress noisy when every task update lands in the same feature thread.

The desired behavior is scope-separated Slack threading:

1. When a feature begins, the workflow sends the first Slack message through the Slack API.
2. Slack returns `thread_ts` for that message, and the workflow stores the feature-to-thread mapping in Redis.
3. Feature-level notifications post only into the feature thread for that `thread_ts`.
4. When a task first needs a Slack notification, the workflow sends a top-level task message, captures its `task_thread_ts`, and stores a task-to-thread mapping in Redis.
5. Subsequent task notifications for that task post only into that task's `task_thread_ts`.
6. When a feature or task reaches a terminal state, the workflow cleans up the related transient Redis mappings after the final Slack notification attempt.

Feature-level Slack notifications are sent only for feature lifecycle signals, not for task status changes or every internal task log. In the first version, the feature thread receives messages for: feature start, feature-level summary changes, handoff submission, and final feature completion. Routine poll cycles, task status transitions, task stdout/stderr, executor progress logs, and task-specific PR/review updates do not create feature-thread messages; those belong in task threads, feature-reviewer handling, or structured runtime events.

The top-level message for each feature thread and each task thread is a living state snapshot: it is created on first notification and updated in place via `chat.update` on every subsequent event so the thread header always reflects current state when a viewer opens the thread. Replies into either thread carry only the fields that changed in that event, providing a change history. Drift details, per-task status updates, task progress counts, task logs, and task-thread detail stay out of the feature thread.

## Message Contract

| Thread | Operation | Triggered by | Fields |
|---|---|---|---|
| Feature thread top-level | `chat.postMessage` (create) | `feature_start` | `title`, `status`, `next_action`, `total_task_count` |
| Feature thread top-level | `chat.update` (update in place) | `feature_summary_changed`, `handoff_submitted`, `feature_completed` | Full current state: `title`, `status`, `next_action` (if active), `blocked_reason` (if blocked), `handoff` (if in_handoff), `feature_pr` (if set), `total_task_count` |
| Feature thread reply | `chat.postMessage` (reply) | `feature_summary_changed`, `handoff_submitted`, `feature_completed` | Only changed feature-level fields for that event, such as `status`, `blocked_reason`, `handoff`, `feature_pr`, `last_updated_at` |
| Task thread top-level | `chat.postMessage` (create) | `task_start` | `title`, `status`, `repo`, `branch`, `execution.last_updated_by` |
| Task thread top-level | `chat.update` (update in place) | `task_status_changed`, `task_pr_changed`, `task_review_changed`, `task_completed` | Full current state: `title`, `status`, `repo`, `branch`, `execution.last_updated_by`, `pr` (if set), `blocked_reason` (if blocked) |
| Task thread reply | `chat.postMessage` (reply) | `task_status_changed`, `task_pr_changed`, `task_review_changed`, `task_completed` | Only changed task-level fields for that event, such as `status`, `pr`, `blocked_reason`, `review_status`, `last_updated_at`, `execution.last_updated_by` |

## Status Icons

When a message renders a `Status` line, prefix the status value with the icon that matches the current status.

| Status family | Icon |
|---|---|
| ready, active, in progress | `:large_green_circle:` |
| review | `:mag:` |
| handoff | `:handshake:` |
| blocked | `:warning:` |
| done, completed | `:white_check_mark:` |
| unknown or fallback | `:grey_question:` |

## Goals

- Replace one-off Slack messages with explicit feature-level and task-level Slack threads.
- Send the first feature-start notification via Slack Web API so the workflow receives the feature `thread_ts`.
- Send the first task notification via Slack Web API so the workflow receives a task-specific `task_thread_ts`.
- Store Redis mappings for `featureId -> thread_ts` and `(featureId, taskId) -> task_thread_ts`.
- Route feature notifications only into the feature thread.
- Route task notifications, task review escalations, and task PR updates only into the task's own thread.
- Format the top-level feature message with title, status, next action, and total task count; update it in place via `chat.update` on every subsequent feature event so the thread header always reflects current state.
- Format the first task-thread message with task title, status, repo, branch, and execution email from `execution.last_updated_by`; update it in place via `chat.update` on every subsequent task event so the thread header always reflects current state.
- Format feature-thread and task-thread replies as changed-field updates only to provide a change history alongside the always-current top-level message.
- Delete transient Redis mappings after the related feature or task terminal notification is posted or attempted.
- Keep Slack optional: if Slack config is missing or the Slack API call fails, workflow execution must continue and emit a structured skip/failure event.

## Non-goals

- Replacing workflow state with Redis. Redis only stores transient Slack thread routing state.
- Persisting Slack thread history in YAML, Postgres, or Git.
- Changing task status transitions, PR review logic, handoff rules, or feature lifecycle semantics.
- Posting every internal runtime event to Slack.
- Supporting multiple Slack channels per feature in the first version.

## User Stories

As an operator, I want the first notification for a feature to create a Slack thread with only basic feature context: title, status, next action, and task count.

As an executor or reviewer workflow, I want each task to create or reuse its own Slack thread so task updates stay grouped without flooding the feature thread.

As a workflow maintainer, I want thread mappings deleted when their feature or task is done so Redis does not accumulate stale notification keys.

## Acceptance Criteria

- Feature start sends a Slack Web API `chat.postMessage` call and captures the returned message timestamp as `thread_ts`.
- Redis stores a feature-scoped mapping equivalent to `featureId -> thread_ts`.
- The initial top-level feature Slack message includes: title, status, next action, and total task count.
- On each subsequent feature event (`feature_summary_changed`, `handoff_submitted`, `feature_completed`), the top-level feature message is updated in place via `chat.update` to reflect full current state: title, status, next_action (if active), blocked_reason (if blocked), handoff (if in_handoff), feature_pr (if set), and total_task_count.
- Feature-thread replies include only changed feature-level fields for that event to provide a change history.
- Feature-level Slack messages look up the feature mapping and include the feature `thread_ts` when present.
- First task-level Slack send creates a top-level task message and captures the returned timestamp as `task_thread_ts`.
- The initial top-level task Slack message includes: title, status, repo, branch, and execution email from `execution.last_updated_by`.
- On each subsequent task event (`task_status_changed`, `task_pr_changed`, `task_review_changed`, `task_completed`), the top-level task message is updated in place via `chat.update` to reflect full current state: title, status, repo, branch, execution.last_updated_by, pr (if set), and blocked_reason (if blocked).
- Redis stores task-scoped mappings equivalent to `(featureId, taskId) -> task_thread_ts`.
- Subsequent task-level Slack sends look up the task mapping and include that task's `task_thread_ts` when present.
- Task-thread replies include only changed task-level fields for that event to provide a change history.
- Task-level notifications do not post into the feature thread; task status changes, PR updates, review updates, and completion messages must post only into the corresponding task thread.
- If a mapping is missing, notifications fall back to a clear configured behavior: lazily create the correct scope thread or emit a structured skip event.
- Feature completion deletes the Redis mapping for that feature after the final completion notification is posted.
- Task completion deletes the Redis mapping for that task after the final task notification is posted.
- Tests cover: successful feature thread creation, feature message formatting, chat.update on top-level feature message on subsequent events, successful task thread creation, task post into the task thread, chat.update on top-level task message on subsequent events, missing Redis key, Slack API failure, Redis failure, task key deletion, and feature key deletion on completion.
