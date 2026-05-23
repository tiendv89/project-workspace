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

## Goals

- Replace one-off Slack messages with explicit feature-level and task-level Slack threads.
- Send the first feature-start notification via Slack Web API so the workflow receives the feature `thread_ts`.
- Send the first task notification via Slack Web API so the workflow receives a task-specific `task_thread_ts`.
- Store Redis mappings for `featureId -> thread_ts` and `(featureId, taskId) -> task_thread_ts`.
- Route feature notifications only into the feature thread.
- Route task notifications, task review escalations, and task PR updates only into the task's own thread.
- Format feature messages with title, status, next action, task summary rows (reusing existing task fields), a defined `feature` display field, and PR reference.
- Delete transient Redis mappings after the related feature or task terminal notification is posted or attempted.
- Keep Slack optional: if Slack config is missing or the Slack API call fails, workflow execution must continue and emit a structured skip/failure event.

## Non-goals

- Replacing workflow state with Redis. Redis only stores transient Slack thread routing state.
- Persisting Slack thread history in YAML, Postgres, or Git.
- Changing task status transitions, PR review logic, handoff rules, or feature lifecycle semantics.
- Posting every internal runtime event to Slack.
- Supporting multiple Slack channels per feature in the first version.

## User Stories

As an operator, I want the first notification for a feature to create a Slack thread so I can track feature-level status, next action, task summary, and feature PR in one place.

As an executor or reviewer workflow, I want each task to create or reuse its own Slack thread so task updates stay grouped without flooding the feature thread.

As a workflow maintainer, I want thread mappings deleted when their feature or task is done so Redis does not accumulate stale notification keys.

## Acceptance Criteria

- Feature start sends a Slack Web API `chat.postMessage` call and captures the returned message timestamp as `thread_ts`.
- Redis stores a feature-scoped mapping equivalent to `featureId -> thread_ts`.
- Feature-level Slack messages include: title, status, next action, task summary rows, `feature`, and PR reference.
- The `feature` display field uses `status.yaml -> feature_id`; task summary rows reuse each task YAML's existing `title` and `status` fields (no new task fields required).
- Feature-level Slack messages look up the feature mapping and include the feature `thread_ts` when present.
- First task-level Slack send creates a top-level task message and captures the returned timestamp as `task_thread_ts`.
- Redis stores task-scoped mappings equivalent to `(featureId, taskId) -> task_thread_ts`.
- Subsequent task-level Slack sends look up the task mapping and include that task's `task_thread_ts` when present.
- Task-level notifications do not post into the feature thread; the feature thread may include task status summaries only as part of a feature-level message.
- If a mapping is missing, notifications fall back to a clear configured behavior: lazily create the correct scope thread or emit a structured skip event.
- Feature completion deletes the Redis mapping for that feature after the final completion notification is posted.
- Task completion deletes the Redis mapping for that task after the final task notification is posted.
- The old webhook-only path is not used for threaded notifications because incoming webhooks do not provide the returned `thread_ts` needed for this flow.
- Tests cover: successful feature thread creation, feature message formatting, successful task thread creation, task post into the task thread, missing Redis key, Slack API failure, Redis failure, task key deletion, and feature key deletion on completion.
