# Product Specification

## Feature
- Feature ID: `slack-thread-notifications`
- Title: Slack Thread Notifications for Feature Runs

## Problem

Agent workflow notifications currently behave like independent Slack messages. When a feature starts, tasks progress, escalations happen, and the feature completes, the notification trail can spread across multiple top-level Slack messages. That makes it harder for humans to follow one feature end to end, and it prevents later task-level notifications from being attached to the original feature context.

The desired behavior is feature-scoped threading:

1. When a feature begins, the workflow sends the first Slack message through the Slack API.
2. Slack returns `thread_ts` for that message.
3. The workflow stores the feature-to-thread mapping in Redis.
4. Subsequent task notifications for that feature post into the stored `thread_ts`.
5. When the feature is complete, the workflow deletes the Redis mapping for that feature.

## Goals

- Replace one-off top-level Slack task messages with a feature-scoped Slack thread.
- Send the first feature-start notification via Slack Web API so the workflow receives a `thread_ts`.
- Store a Redis mapping from `featureId` to `thread_ts`.
- Route task notifications, review escalations, handoff notices, and feature completion notices into the feature thread when the mapping exists.
- Delete the Redis mapping when the feature reaches a terminal completion state.
- Keep Slack optional: if Slack config is missing or the Slack API call fails, workflow execution must continue and emit a structured skip/failure event.

## Non-goals

- Replacing workflow state with Redis. Redis only stores transient Slack thread routing state.
- Persisting Slack thread history in YAML, Postgres, or Git.
- Changing task status transitions, PR review logic, handoff rules, or feature lifecycle semantics.
- Posting every internal runtime event to Slack.
- Supporting multiple Slack channels per feature in the first version.

## User Stories

As an operator, I want the first notification for a feature to create a Slack thread so I can track the whole feature in one place.

As an executor or reviewer workflow, I want task-level messages to reuse the feature's Slack thread automatically without carrying Slack-specific state through every task file.

As a workflow maintainer, I want the thread mapping deleted when the feature is done so Redis does not accumulate stale feature notification keys.

## Acceptance Criteria

- Feature start sends a Slack Web API `chat.postMessage` call and captures the returned message timestamp as `thread_ts`.
- Redis stores a feature-scoped mapping equivalent to `featureId -> thread_ts`.
- Task-level Slack sends look up the feature mapping before posting and include `thread_ts` when present.
- If the mapping is missing, task-level notifications fall back to a clear configured behavior: either create the feature thread lazily or emit a structured skip event.
- Feature completion deletes the Redis mapping for that feature after the final completion notification is posted.
- The old webhook-only path is not used for threaded notifications because incoming webhooks do not provide the returned `thread_ts` needed for this flow.
- Tests cover: successful start thread creation, task post into thread, missing Redis key, Slack API failure, Redis failure, and key deletion on feature completion.
