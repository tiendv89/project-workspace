# Technical Design

## Feature
- Feature ID: `slack-thread-notifications`
- Title: Slack Thread Notifications for Feature Runs

## Current State

The implementation target is the `workflow` repo, specifically the TypeScript orchestrator under `runtime/orchestrator`.

Current notification behavior is task-centered and webhook-based:

- `runtime/orchestrator/src/ports/task-notifier.port.ts` defines `TaskNotifierPort` for task-level notifications in the current webhook-based flow.
- `runtime/orchestrator/src/adapters/slack-task-notifier.ts` constructs a notifier only when `SLACK_WEBHOOK_URL` is set.
- `runtime/orchestrator/src/side-effects/post-task-slack.ts` sends Slack incoming webhook payloads and cannot receive a Slack message timestamp.
- `dispatchExecutorResult()` and `dispatchReviewResult()` use the task notifier for task state notifications.
- `handleEscalation()` and `runFeatureReviewCycle()` still post directly to `SLACK_WEBHOOK_URL`.
- `handleFeatureDone()` emits `feature_done`, but does not notify Slack or clean up notification state.

Redis exists in the local-docker topology as the broker backing store, but the TypeScript orchestrator currently has no Redis client dependency. The Go broker owns completion-queue state only; it does not expose a general key-value API for Slack thread mappings.

The management workspace currently has `WORKFLOW_LOCAL_PATH` blank in `.env`, while `workspace.yaml` declares the `workflow` repo with `local_path: env:WORKFLOW_LOCAL_PATH`. That does not block planning, but it must be configured before tasks against `repo: workflow` can be executed by `start-implementation`.

## Problem Framing

Slack notifications need to become scope-separated without changing workflow state ownership.

The implementation must:

- Create or reuse one Slack thread per feature for feature-level notifications.
- Create or reuse one Slack thread per task for task-level notifications.
- Capture the Slack `ts` returned by `chat.postMessage` for the first feature message.
- Capture the Slack `ts` returned by `chat.postMessage` for the first task message.
- Store transient routing state in Redis, not in YAML or Git.
- Post feature start, feature summary, handoff, and final feature completion messages into the feature thread when possible.
- Post task execution, task review escalation, task review result, and task PR updates into the task's own thread when possible.
- Render the top-level feature message with title, status, next action, and total task count.
- Render the first task-thread message with title, status, repo, branch, and execution email from `execution.last_updated_by`.
- Render feature-thread and task-thread replies as changed-field updates.
- Delete thread mappings after the final related feature or task notification.
- Continue workflow execution when Slack or Redis is unavailable.

The implementation must keep these stable:

- Task status transitions and claim protocol.
- Feature lifecycle semantics.
- Per-task YAML source of truth.
- Existing structured event emission for skipped or failed side effects.
- Backward compatibility for installations that have not configured Slack threading.

Fixed assumptions from the product spec:

- Incoming webhooks alone are insufficient for threaded notifications because they do not provide the returned message timestamp needed by this flow.
- Redis is transient coordination state only.
- Slack is optional and must not block task or feature progression.
- First version supports one Slack channel per workspace, declared in `workspace.yaml`.

## Options Considered

### Option A: Keep Incoming Webhooks and Add Thread Metadata Locally

This keeps `SLACK_WEBHOOK_URL` and tries to infer, store, or manually provide thread IDs outside the Slack API response.

Pros:

- Minimal dependency and configuration changes.
- Leaves existing webhook code largely unchanged.

Cons:

- Does not reliably obtain `thread_ts`.
- Cannot satisfy first-message capture from the product spec.
- Encourages brittle manual thread mapping.

Implementation impact:

- Low code impact but incomplete behavior.

Dependency impact:

- No new dependency, but it fails the key Slack API requirement.

### Option B: Slack Web API Client Plus Redis Scope Thread Store in the Orchestrator

Add a Slack Web API client, a Redis-backed feature/task thread store, and a higher-level notification service inside `runtime/orchestrator`.

Pros:

- Directly captures Slack `ts` from `chat.postMessage`.
- Keeps feature-to-thread state transient and outside Git.
- Works with current orchestrator call sites.
- Can fail open with structured events when Slack or Redis is missing.

Cons:

- Adds Slack bot token and channel configuration.
- Adds a Redis client dependency to the TypeScript orchestrator.
- Requires replacing several webhook call sites.

Implementation impact:

- Medium. Introduces a notification service boundary and migrates task/reviewer/feature side effects to scope-aware feature or task threads.

Dependency impact:

- Requires `SLACK_BOT_TOKEN` (env), `notifications.slack.channel_id` (workspace.yaml), and `REDIS_URL` for threaded mode.
- Requires a Node Redis client dependency in `runtime/orchestrator/package.json`.

### Option C: Extend the Go Broker with a Slack Thread Mapping API

Keep Redis access inside the Go broker and expose a small HTTP API to the orchestrator for Slack thread mappings.

Pros:

- Keeps Redis ownership centralized in the broker service.
- Avoids adding a Redis client to the TypeScript orchestrator.

Cons:

- Couples Slack notification routing to the completion broker.
- Does not help local-subprocess mode, where no broker is required.
- Expands broker API surface for a concern unrelated to completion queue semantics.

Implementation impact:

- Medium to high across `runtime/broker` and `runtime/orchestrator`.

Dependency impact:

- Adds broker availability as a dependency for Slack threading even when no broker is otherwise needed.

### Option D: Store `thread_ts` in Feature YAML

Persist the Slack thread timestamp in `docs/features/<featureId>/status.yaml`.

Pros:

- Durable and visible in Git history.
- Avoids Redis lookup on task messages.

Cons:

- Adds noisy Git commits for external notification routing.
- Leaks Slack implementation details into authoritative workflow state.
- Creates avoidable branch contention just to send notifications.

Implementation impact:

- Medium. Requires more management-repo writes from notification paths.

Dependency impact:

- No Redis dependency, but violates the product spec non-goal.

## Chosen Design

Use Option B: Slack Web API client plus Redis scope thread store in the TypeScript orchestrator.

Add these runtime boundaries:

- `SlackWebApiClient`
  - Owns `chat.postMessage` (create a new message, returns `ts`).
  - Owns `chat.update` (edit an existing message by `ts`, used to update top-level messages in place).
  - Takes `SLACK_BOT_TOKEN` from env and `channel_id` from `WorkspaceConfig.notifications.slack.channel_id`.
  - Returns the Slack `ts` string for `chat.postMessage` and rejects `ok: false` or missing `ts`.
  - Rejects `ok: false` or HTTP failure on `chat.update`.
  - `channel_id` is a per-workspace declaration; there is no `SLACK_CHANNEL_ID` env var fallback.

- `NotificationThreadStore`
  - Owns Redis read/write/delete for feature and task thread mappings.
  - Uses key shape `slack:feature_thread:<workspaceId>:<featureId>`.
  - Uses key shape `slack:task_thread:<workspaceId>:<featureId>:<taskId>`.
  - Stores only Slack thread timestamps.

- `ThreadedNotificationService`
  - Owns `ensureFeatureThread(featureId, context)`.
  - Owns `ensureTaskThread(featureId, taskId, context)`.
  - Owns `postFeatureMessage(featureId, trigger, context)` — for `feature_start` creates the top-level message; for all other triggers calls `chat.update` on the top-level then posts a reply.
  - Owns `postTaskMessage(featureId, taskId, trigger, context)` — for `task_start` creates the top-level message; for all other triggers calls `chat.update` on the top-level then posts a reply.
  - Owns `closeTaskThread(featureId, taskId, context)` — update top-level, post final reply, delete Redis key.
  - Owns `closeFeatureThread(featureId, context)` — update top-level, post final reply, delete Redis key.
  - Emits structured skip/failure events and never throws in a way that blocks workflow progression.

- `NotificationPort` (interface — expands and replaces `TaskNotifierPort`)
  - Unified notification contract that all core orchestrator logic depends on.
  - Task methods: `postTaskMessage(featureId, taskId, trigger, context)`, `closeTaskThread(featureId, taskId, context)`.
  - Feature methods: `postFeatureMessage(featureId, trigger, context)`, `closeFeatureThread(featureId, context)`.
  - Core logic never imports Slack, Redis, or formatting modules — only this interface.

- `ThreadedSlackNotifier` (adapter — replaces `SlackTaskNotifier`)
  - Implements `NotificationPort`.
  - Delegates every method call to `ThreadedNotificationService`.
  - Instantiated at startup and injected wherever `NotificationPort` is required.
  - The old `slack-task-notifier.ts` and `post-task-slack.ts` are deleted; this adapter is the only Slack-aware boundary in the call path.

Feature thread creation behavior:

1. Read Redis key `slack:feature_thread:<workspaceId>:<featureId>`.
2. If present, reuse it.
3. If absent and Slack plus Redis are configured, post the first feature message with `chat.postMessage`.
4. Store the returned `ts` as the thread mapping.
5. Emit `feature_slack_thread_created`.

Feature message behavior:

1. Feature messages are lifecycle-driven only in the first version. There is no independent periodic Slack timer.
2. Build the feature message from the current feature snapshot and the triggering lifecycle event.
3. The top-level `feature_start` message includes title, status, next action, and total task count.
4. On all events after `feature_start` (i.e. `feature_summary_changed`, `handoff_submitted`, `feature_completed`), call `chat.update` on the stored top-level message (`ts` = feature `thread_ts`) with the full current feature state: title, status (with icon), next_action (if active), blocked_reason (if blocked), handoff (if in_handoff), feature_pr (if set), and total_task_count.
5. Then post a reply into the feature thread with only the fields that changed for that event (for the audit trail).
6. Look up or lazily create the feature thread before any post or update.
7. Do not post task status changes, task progress counts, task log/progress messages, or task PR/review details into the feature thread. Feature messages may show only the total number of tasks.

Feature notification trigger contract:

| Trigger | When the workflow sends it | Thread behavior | Event-specific context |
|---|---|---|---|
| `feature_start` | First lifecycle-manager poll that observes the feature in active orchestration, for example `ready_for_implementation`, and no feature thread mapping exists yet. Send before or alongside the first task dispatch best-effort. | Creates the top-level feature Slack message via `chat.postMessage` and stores its returned `ts` as `slack:feature_thread:<workspaceId>:<featureId>`. | State that the feature is now active. |
| `feature_summary_changed` | After a persisted feature-level state change. Task status transitions alone do not trigger this message. | Updates the top-level feature message in place via `chat.update` with full current state, then replies in the feature thread. If the mapping is missing, lazily creates the feature thread first. | `chat.update` carries full current state; reply carries changed feature fields only, for example `status`, `blocked_reason`, `feature_pr`, or `last_updated_at`. |
| `handoff_submitted` | All tasks are complete and the workflow generates the handoff document / opens or updates the feature-level PR, transitioning the feature to `in_handoff`. | Updates the top-level feature message in place via `chat.update`, then replies in the feature thread. Keeps the feature thread mapping. | `chat.update` carries full current state; reply carries changed handoff fields only, for example `status`, `handoff`, and `feature_pr`. |
| `feature_completed` | `handleFeatureDone()` confirms all required feature PRs are merged and emits/completes the `feature_done` path. | Updates the top-level message in place via `chat.update`, posts the final feature-thread reply, then deletes the feature Redis mapping after the final send attempt. | `chat.update` carries full current state; reply carries changed completion fields only, for example `status`, `feature_pr`, and `last_updated_at`. |

No feature Slack message is sent for routine poll cycles with no feature-level summary change, task status transitions, task stdout/stderr, task execution progress, task review result details, task PR comments, or task-specific escalation details. Those signals route to their existing reviewer/task handling or remain structured runtime events.

Task notification trigger contract:

| Trigger | When the workflow sends it | Thread behavior | Event-specific context |
|---|---|---|---|
| `task_start` | First task-level notification for a task when no task thread mapping exists yet. | Creates the top-level task Slack message via `chat.postMessage` and stores its returned `ts` as `slack:task_thread:<workspaceId>:<featureId>:<taskId>`. | Basic task context: title, status, repo, branch, and execution email from `execution.last_updated_by`. |
| `task_status_changed` | After a persisted task status transition, such as `in_review`, `blocked`, or another non-terminal task status change. | Updates the top-level task message in place via `chat.update` with full current state, then replies in the task thread. If the mapping is missing, lazily creates the task thread first. | `chat.update` carries full current state; reply carries changed task fields only, for example `status`, `blocked_reason`, `last_updated_at`, and `execution.last_updated_by`. |
| `task_pr_changed` | When a task PR URL or PR status becomes available or changes. | Updates the top-level task message in place via `chat.update` with full current state, then replies in the task thread. If the mapping is missing, lazily creates the task thread first. | `chat.update` carries full current state; reply carries changed task PR fields only, for example `pr.url`, `pr.status`, and `execution.last_updated_by`. |
| `task_review_changed` | When a task review result, reviewer routing result, or task-tied review escalation changes task state. | Updates the top-level task message in place via `chat.update` with full current state, then replies in the task thread. If the mapping is missing, lazily creates the task thread first. | `chat.update` carries full current state; reply carries changed review/task fields only, for example `review_status`, `status`, `blocked_reason`, and `execution.last_updated_by`. |
| `task_completed` | After the task reaches terminal `done` and the final task notification is ready to send. | Updates the top-level task message in place via `chat.update`, posts the final task-thread reply, then deletes the task Redis mapping after the final send attempt. | `chat.update` carries full current state; reply carries changed completion fields only, for example `status`, `pr.url`, `pr.status`, `last_updated_at`, and `execution.last_updated_by`. |

Status icon contract:

| Status family | Icon |
|---|---|
| ready, active, in progress | `:large_green_circle:` |
| review | `:mag:` |
| handoff | `:handshake:` |
| blocked | `:warning:` |
| done, completed | `:white_check_mark:` |
| unknown or fallback | `:grey_question:` |

Render the icon on the `Status:` line as `Status: <status_icon> <status>`.

Slack message payload contract:

- `feature_start` creates the top-level feature Slack message. Later feature messages are replies using `thread_ts=<feature_thread_ts>`.
- The payload contract is split into two clear thread scopes:

### Feature thread

| Shape | Fields | Notes |
|---|---|---|
| Top-level `feature_start` (create) | `title`, `status`, `next_action`, `total_task_count` | `chat.postMessage` — creates the feature thread and stores the returned `ts`. |
| Top-level update (subsequent events) | Full current state: `title`, `status`, `next_action` (if active), `blocked_reason` (if blocked), `handoff` (if in_handoff), `feature_pr` (if set), `total_task_count` | `chat.update` targeting the stored `thread_ts`. Renders only present and relevant fields. |
| Reply to feature thread | Only changed feature-level fields for that event, such as `status`, `blocked_reason`, `handoff`, `feature_pr`, `last_updated_at` | `chat.postMessage` with `thread_ts`. Provides the audit trail. |

### Task thread

| Shape | Fields | Notes |
|---|---|---|
| Top-level `task_start` (create) | `title`, `status`, `repo`, `branch`, `execution.last_updated_by` | `chat.postMessage` — creates the task thread and stores the returned `ts`. |
| Top-level update (subsequent events) | Full current state: `title`, `status`, `repo`, `branch`, `execution.last_updated_by`, `pr` (if set), `blocked_reason` (if blocked) | `chat.update` targeting the stored task `thread_ts`. Renders only present and relevant fields. |
| Reply to task thread | Only changed task-level fields for that event, such as `status`, `pr`, `blocked_reason`, `review_status`, `execution.last_updated_by` | `chat.postMessage` with `thread_ts`. Provides the audit trail. |

`Execution` renders the email address from `execution.last_updated_by` for task notifications. It must not render the actor type label such as `human` or `agent`.

- Excluded fields:
  - Repeated top-level fields in replies.
  - Drift reason/details from `runFeatureReviewCycle()`.
  - Per-task status transition details in the feature thread.
  - Task stdout/stderr or log excerpts.
  - Token usage, agent runtime internals, or raw executor output.
  - Task progress counts in the feature thread.
  - Slack `thread_ts` values, except in structured runtime events for debugging.
- Suggested top-level feature text layout (used for both the initial `feature_start` create and all subsequent `chat.update` calls):

```
Feature: <title>
Status: <status_icon> <feature_status>
Next action: <next_action>          ← omit when not active
Blocked: <blocked_reason>           ← omit when not blocked
Handoff: <handoff>                  ← omit when not in_handoff
PR: <feature_pr>                    ← omit when not set
Tasks: <total_task_count> total
```

Lines with unavailable or irrelevant values are omitted. The `Type:` field is not shown in the top-level message; it appears only in replies.

- Suggested top-level task text layout (used for both the initial `task_start` create and all subsequent `chat.update` calls):

```
Task: <title>
Status: <status_icon> <task_status>
Repo: <repo>
Branch: <branch>
PR: <pr.url> (<pr.status>)          ← omit when not set
Blocked: <blocked_reason>           ← omit when not blocked
Execution: <execution.last_updated_by>
```

- Suggested feature reply text layout:

```
Type: <message_type>
Status: <status_icon> <changed_status>
Handoff: <handoff>
PR: <feature_pr>
Blocked reason: <blocked_reason>
Updated at: <last_updated_at>
```

Only render the lines whose fields changed for that event.

- Suggested task reply text layout:

```
Type: <message_type>
Status: <status_icon> <changed_status>
PR: <pr>
Blocked reason: <blocked_reason>
Execution: <execution.last_updated_by>
```

Only render the lines whose fields changed for that event.

Task thread creation behavior:

1. Read Redis key `slack:task_thread:<workspaceId>:<featureId>:<taskId>`.
2. If present, reuse it.
3. If absent and Slack plus Redis are configured, post the first task message as a top-level Slack message.
4. Store the returned `ts` as the task thread mapping.
5. Emit `task_slack_thread_created`.

Task message behavior:

1. Look up the task thread mapping.
2. If present and the event is not `task_start`, call `chat.update` targeting the stored task `thread_ts` with the full current task state snapshot, then call `chat.postMessage` with `thread_ts` to post the changed-fields reply.
3. If present and the event is `task_start`, call `chat.postMessage` (top-level create only — no prior message to update).
4. If missing, lazily call `ensureTaskThread()` and then post into the created task thread.
5. If Slack or Redis is unavailable, emit a structured skip event and continue.
6. Never fall back by posting the task message into the feature thread.

Task completion behavior:

1. The final task notification is posted into the task thread if one exists or can be created.
2. After the final task message attempt, the service deletes the task Redis key.
3. Delete failure emits `task_slack_thread_delete_failed`; the task transition still completes.

Feature completion behavior:

1. `handleFeatureDone()` posts the final feature completion message through `closeFeatureThread()`.
2. The service posts into the existing thread if one exists.
3. After the final message attempt, the service deletes the Redis key.
4. Delete failure emits `feature_slack_thread_delete_failed`; the workflow still completes.
5. Feature completion may also best-effort delete any remaining task thread keys for that feature using a workspace/feature-scoped Redis key scan.

Compatibility:

- Threaded notifications require `SLACK_BOT_TOKEN` (env), `notifications.slack.channel_id` (workspace.yaml), and `REDIS_URL` (env).
- If any Slack config is absent, all notification paths skip gracefully with structured events.
- The `SLACK_WEBHOOK_URL` incoming-webhook path is removed. The webhook helper and `post-task-slack.ts` are deleted as part of this feature.

Operational impact:

- Local-docker deployments can reuse the existing Redis service by passing `REDIS_URL=redis://redis:6379` to the orchestrator container.
- Local-subprocess deployments need a reachable `REDIS_URL` to enable threading; without it Slack threading skips gracefully.
- `.env.template`, Docker Compose templates, and operator docs must describe the new optional Slack threading configuration.

## Dependency Analysis

Internal dependencies:

- `runtime/orchestrator/src/side-effects/post-task-slack.ts` and `slack-task-notifier.ts` are the existing task notification boundary — both are deleted in T4.
- `dispatchExecutorResult()` and `dispatchReviewResult()` call `NotificationPort` (injected) for task notifications. No direct Slack or Redis imports.
- `handleEscalation()` calls `NotificationPort.postTaskMessage(...)` for task-tied escalation. Feature-level drift/escalation stays outside this Slack notification scope.
- `runFeatureReviewCycle()` keeps its existing reviewer/escalation handling; drift is outside the feature-thread notification scope for this feature.
- The lifecycle manager calls `NotificationPort.postFeatureMessage(...)` for feature-level events (T5). No direct service imports.
- `handleFeatureDone()` calls `NotificationPort.closeFeatureThread(...)` (T9). No direct service imports.
- `checkFeatureTasksDone()` is a handoff transition signal; it calls `NotificationPort.postFeatureMessage('handoff_submitted', ...)` and does not close the thread.

External dependencies:

- Slack Web API `chat.postMessage`.
- Slack bot token with `chat:write`.
- Slack channel ID for the first version.
- Redis reachable from the orchestrator process.

Vendor/tooling choices:

- Add the Node Redis client to the orchestrator package rather than extending the Go broker.
- Keep tests in Vitest with mocked Slack fetch and fake Redis store adapters.

Configuration dependencies:

- `SLACK_BOT_TOKEN` (env — secret, per orchestrator deployment)
- `notifications.slack.channel_id` in `workspace.yaml` (per-workspace, synced to DB by `workspace-github-adapter`)
- `REDIS_URL`
- `WORKFLOW_LOCAL_PATH` in this management workspace before executing tasks against `repo: workflow`.

`workspace.yaml` notifications shape:

```yaml
notifications:
  slack:
    channel_id: C0123456789  # Slack channel ID for this workspace's notifications
```

The orchestrator reads this field via `loadWorkspaceNotificationConfig()` in `workspace-config.ts`. If the field is absent, Slack threading is disabled for that workspace. There is no `SLACK_CHANNEL_ID` env var.

Blocking decisions:

- No unresolved product decision remains for the first version.
- Production rollout still requires a real Slack bot token and channel ID.
- The management workspace must set `WORKFLOW_LOCAL_PATH` before `start-implementation` can claim these workflow tasks.

Release dependencies:

- Orchestrator Docker images must be rebuilt after adding dependencies and env handling.
- Docker Compose templates must pass new optional env vars into orchestrator services.
- Operator documentation must explain that threaded Slack requires bot-token mode and Redis.

## Parallelization / Blocking Analysis

External setup:

```text
D1: Set WORKFLOW_LOCAL_PATH in management .env ── required before start-implementation can resolve repo `workflow`
D2: Provision Slack bot token + channel ID       ── required before production threaded Slack is enabled; tests can use mocks
D3: Provide REDIS_URL for orchestrator runtime   ── required before threaded Slack is enabled; missing value must skip gracefully
```

Task dependency diagram:

```text
T1: Slack Web API client and threaded config - workflow          ┐
T2: Redis feature/task-thread store - workflow                  ├── Wave 1 (parallel)
T7: Workspace notification settings migration - workspace-github-adapter ┘
  │
  T3: Message types and formatters - workflow                   ── Wave 2
    └── BLOCKED on T1 (needs Slack client types settled)
    └── BLOCKED on T2 (needs Redis store interface settled)
    └── Pure TypeScript — no I/O; T7 does not block T3
    │
    T8: Thread management service - workflow                    ── Wave 3
      └── BLOCKED on T3 (uses formatters and service interface types)
      └── T1 and T2 transitively satisfied through T3
      │
      T4: Task and reviewer notification call-site migration     ┐
        └── BLOCKED on T8 (needs postTaskMessage + closeTaskThread)
      T5: Feature lifecycle wiring — start, summary, handoff    ├── Wave 4 (parallel)
        └── BLOCKED on T8 (needs postFeatureMessage)
      T9: Feature completion and cleanup                        ┘
        └── BLOCKED on T8 (needs closeFeatureThread)
        │
        T6: Tests, templates, and operator documentation         ── Wave 5
          └── BLOCKED on T4, T5, and T9
```

## Repository Impact

Affected implementation repos:

- `workflow`
  - Add Slack Web API client, Redis store, threaded notification service, call-site migration, tests, and runtime template docs under `runtime/orchestrator`.
  - Add `loadWorkspaceNotificationConfig()` to `workspace-config.ts` to parse `notifications.slack.channel_id` from `workspace.yaml`.
  - Update `workspace.yaml` template to include the `notifications.slack.channel_id` field.
  - Task repo values use `workflow`, which matches `workspace.yaml -> repos[].id`.

- `workspace-github-adapter`
  - Add migration `00012_workspace_notification_settings.sql` adding `slack_channel_id TEXT` (nullable) to the `workspaces` table.
  - Update all workspace queries (`UpsertWorkspace`, `UpsertWorkspaceByID`, `UpdateWorkspaceByID`, `ListWorkspaces`, `GetWorkspace`, `GetWorkspaceBySlug`) to include `slack_channel_id`.

Affected management repo:

- `management-repo`
  - This tech-lead pass updates planning artifacts only: `technical-design.md`, `tasks.md`, `tasks/T<n>.yaml`, and `status.yaml`.

Unaffected repos:

- `digital-factory-ui`
- `workflow-backend`
- `rag-service`
- `git-nexus`

## Validation and Release Impact

Testing expectations:

- Unit tests for Slack Web API `chat.postMessage`: success, `ok: false`, HTTP failure, and missing `ts`.
- Unit tests for Slack Web API `chat.update`: success, `ok: false`, and HTTP failure.
- Unit tests for Redis feature/task store get/set/delete and failure handling through fake adapters.
- Unit tests for top-level feature message formatting (initial `feature_start` and subsequent full-current-state snapshot): title, status, next action, blocked reason, handoff, feature_pr, total task count — with status-aware field omission.
- Unit tests for top-level task message formatting (initial `task_start` and subsequent full-current-state snapshot): title, status, repo, branch, execution email, pr, blocked_reason — with status-aware field omission.
- Unit tests that `chat.update` is called on the top-level feature message for `feature_summary_changed`, `handoff_submitted`, and `feature_completed`.
- Unit tests that `chat.update` is called on the top-level task message for `task_status_changed`, `task_pr_changed`, `task_review_changed`, and `task_completed`.
- Unit tests for feature-thread and task-thread reply formatting as changed-field updates only.
- Unit tests for lazy task thread creation when a task message finds no mapping.
- Unit tests for task notification events posting with the task `thread_ts`.
- Unit tests for reviewer escalation using the scoped threaded service instead of direct webhook calls.
- Unit tests for `handleFeatureDone()` posting the final message and calling `chat.update` before deleting the Redis mapping.
- Unit tests for final task notification cleanup deleting the task Redis mapping.
- Existing orchestrator unit suite should still pass with no Slack or Redis env configured.

Migration/config impact:

- Add `SLACK_BOT_TOKEN` and `REDIS_URL` to env templates; `SLACK_CHANNEL_ID` is not an env var — it is declared in `workspace.yaml` under `notifications.slack.channel_id`.
- Remove `SLACK_WEBHOOK_URL` from all env templates and documentation; the webhook path is deleted.
- Add `notifications.slack.channel_id` to `workflow/templates/workspace/workspace.yaml` and this management workspace's `workspace.yaml`.
- Add Redis client dependency to `runtime/orchestrator/package.json` and lockfile.
- Run `workspace-github-adapter` migration `00012` against the shared Postgres instance after deployment.

Rollout concerns:

- Missing Slack or Redis config must emit structured skip events and must not fail the orchestration loop.
- Redis delete failure after feature completion should be observable but non-blocking.
- Shared Redis deployments need workspace-scoped feature keys and workspace/feature-scoped task keys to prevent collisions.

Backward compatibility constraints:

- Existing task notifier call sites must keep compiling.
- Existing installations must migrate to bot-token Slack config; the webhook path is not preserved.
- Feature state and task YAML schemas must not gain Slack-specific fields.

Deployment/handoff implications:

- Rebuild orchestrator images after dependency and env-template changes.
- For local-docker, pass `REDIS_URL=redis://redis:6379` to orchestrator services.
- Handoff must call out that the feature is enabled only when bot-token Slack config and Redis are present.
