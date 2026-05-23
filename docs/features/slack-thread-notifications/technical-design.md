# Technical Design

## Feature
- Feature ID: `slack-thread-notifications`
- Title: Slack Thread Notifications for Feature Runs

## Current State

The implementation target is the `workflow` repo, specifically the TypeScript orchestrator under `runtime/orchestrator`.

Current notification behavior is task-centered and webhook-based:

- `runtime/orchestrator/src/ports/task-notifier.port.ts` defines `TaskNotifierPort` for task events only: `in_review`, `blocked`, and `done`.
- `runtime/orchestrator/src/adapters/slack-task-notifier.ts` constructs a notifier only when `SLACK_WEBHOOK_URL` is set.
- `runtime/orchestrator/src/side-effects/post-task-slack.ts` sends Slack incoming webhook payloads and cannot receive a Slack message timestamp.
- `dispatchExecutorResult()` and `dispatchReviewResult()` use the task notifier for task state notifications.
- `handleEscalation()` and `runFeatureReviewCycle()` still post directly to `SLACK_WEBHOOK_URL`.
- `handleFeatureDone()` emits `feature_done`, but does not notify Slack or clean up notification state.

Redis exists in the local-docker topology as the broker backing store, but the TypeScript orchestrator currently has no Redis client dependency. The Go broker owns completion-queue state only; it does not expose a general key-value API for Slack thread mappings.

The management workspace currently has `WORKFLOW_LOCAL_PATH` blank in `.env`, while `workspace.yaml` declares the `workflow` repo with `local_path: env:WORKFLOW_LOCAL_PATH`. That does not block planning, but it must be configured before tasks against `repo: workflow` can be executed by `start-implementation`.

## Problem Framing

Slack notifications need to become feature-scoped without changing workflow state ownership.

The implementation must:

- Create or reuse one Slack thread per feature.
- Capture the Slack `ts` returned by `chat.postMessage` for the first feature message.
- Store transient routing state in Redis, not in YAML or Git.
- Post task, reviewer escalation, feature drift, handoff, and final completion messages into the feature thread when possible.
- Delete the thread mapping after the final feature completion notification.
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
- First version supports one Slack channel per configured orchestrator deployment.

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

### Option B: Slack Web API Client Plus Redis Thread Store in the Orchestrator

Add a Slack Web API client, a Redis-backed feature-thread store, and a higher-level notification service inside `runtime/orchestrator`.

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

- Medium. Introduces a notification service boundary and migrates task/reviewer/feature side effects to it.

Dependency impact:

- Requires `SLACK_BOT_TOKEN`, `SLACK_CHANNEL_ID`, and `REDIS_URL` for threaded mode.
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

Use Option B: Slack Web API client plus Redis thread store in the TypeScript orchestrator.

Add these runtime boundaries:

- `SlackWebApiClient`
  - Owns `chat.postMessage`.
  - Takes `SLACK_BOT_TOKEN` and `SLACK_CHANNEL_ID`.
  - Returns the Slack `ts` string and rejects `ok: false` or missing `ts`.

- `FeatureThreadStore`
  - Owns Redis read/write/delete for feature thread mappings.
  - Uses key shape `slack:feature_thread:<workspaceId>:<featureId>`.
  - Stores only the Slack thread timestamp.

- `ThreadedNotificationService`
  - Owns `ensureFeatureThread(featureId, context)`.
  - Owns `postTaskMessage(featureId, taskContext, messageContext)`.
  - Owns `postFeatureMessage(featureId, messageContext)`.
  - Owns `closeFeatureThread(featureId, finalMessage)`.
  - Emits structured skip/failure events and never throws in a way that blocks workflow progression.

- `TaskNotifierPort` adapter
  - Keeps the existing task notifier call sites stable.
  - Replaces the webhook-backed notifier with a threaded Slack notifier when threaded config is present.

Thread creation behavior:

1. Read Redis key `slack:feature_thread:<workspaceId>:<featureId>`.
2. If present, reuse it.
3. If absent and Slack plus Redis are configured, post the first feature message with `chat.postMessage`.
4. Store the returned `ts` as the thread mapping.
5. Emit `feature_slack_thread_created`.

Task message behavior:

1. Look up the feature thread mapping.
2. If present, call `chat.postMessage` with `thread_ts`.
3. If missing, lazily call `ensureFeatureThread()` and then post into the created thread.
4. If Slack or Redis is unavailable, emit a structured skip event and continue.

Feature completion behavior:

1. `handleFeatureDone()` posts the final feature completion message through `closeFeatureThread()`.
2. The service posts into the existing thread if one exists.
3. After the final message attempt, the service deletes the Redis key.
4. Delete failure emits `feature_slack_thread_delete_failed`; the workflow still completes.

Compatibility:

- `SLACK_WEBHOOK_URL` remains a legacy path for deployments that have not enabled threaded Slack config.
- Threaded notifications must use `SLACK_BOT_TOKEN`, `SLACK_CHANNEL_ID`, and `REDIS_URL`.
- If bot/channel config exists, task/reviewer/feature Slack paths should prefer the threaded service, not the webhook helper.
- If only `SLACK_WEBHOOK_URL` exists, existing webhook behavior may continue, but that is explicitly non-threaded legacy behavior.

Operational impact:

- Local-docker deployments can reuse the existing Redis service by passing `REDIS_URL=redis://redis:6379` to the orchestrator container.
- Local-subprocess deployments need a reachable `REDIS_URL` to enable threading; without it Slack threading skips gracefully.
- `.env.template`, Docker Compose templates, and operator docs must describe the new optional Slack threading configuration.

## Dependency Analysis

Internal dependencies:

- `runtime/orchestrator/src/side-effects/post-task-slack.ts` and `slack-task-notifier.ts` are the existing task notification boundary.
- `dispatchExecutorResult()` and `dispatchReviewResult()` are task notification call sites.
- `handleEscalation()` is a reviewer escalation call site that currently posts directly to webhook Slack.
- `runFeatureReviewCycle()` posts feature drift Slack messages directly.
- `handleFeatureDone()` is the final feature completion call site where mapping cleanup belongs.
- `checkFeatureTasksDone()` is a handoff transition signal; it should not close the Slack thread because the feature is not done yet.

External dependencies:

- Slack Web API `chat.postMessage`.
- Slack bot token with `chat:write`.
- Slack channel ID for the first version.
- Redis reachable from the orchestrator process.

Vendor/tooling choices:

- Add the Node Redis client to the orchestrator package rather than extending the Go broker.
- Keep tests in Vitest with mocked Slack fetch and fake Redis store adapters.

Configuration dependencies:

- `SLACK_BOT_TOKEN`
- `SLACK_CHANNEL_ID`
- `REDIS_URL`
- Optional legacy `SLACK_WEBHOOK_URL`
- `WORKFLOW_LOCAL_PATH` in this management workspace before executing tasks against `repo: workflow`.

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
T1: Slack Web API client and threaded config - workflow
  └── Can begin now - no implementation blockers after tasks approval
  │
T2: Redis feature-thread store - workflow
  └── Can begin now - no implementation blockers after tasks approval
  └── T1 and T2 run in parallel
  │
  T3: Threaded notification service and task notifier adapter - workflow
    └── BLOCKED on T1 (Slack client must return validated message timestamps)
    └── BLOCKED on T2 (thread mapping store must be available)
    │
    T4: Task, reviewer, and drift notification call-site migration - workflow
      └── BLOCKED on T3 (call sites need the service interface and fallback contract)
    │
    T5: Feature lifecycle thread creation and completion cleanup - workflow
      └── BLOCKED on T3 (feature lifecycle needs ensure/close operations)
      └── T4 and T5 run in parallel
      │
      T6: Tests, templates, and operator documentation - workflow
        └── BLOCKED on T4 (task/reviewer/drift call sites define expected event coverage)
        └── BLOCKED on T5 (feature completion cleanup defines final lifecycle coverage)
```

## Repository Impact

Affected implementation repo:

- `workflow`
  - Add Slack Web API client, Redis store, threaded notification service, call-site migration, tests, and runtime template docs under `runtime/orchestrator`.
  - Task repo values use `workflow`, which matches `workspace.yaml -> repos[].id`.

Affected management repo:

- `management-repo`
  - This tech-lead pass updates planning artifacts only: `technical-design.md`, `tasks.md`, `tasks/T<n>.yaml`, and `status.yaml`.

Unaffected repos:

- `digital-factory-ui`
- `workflow-backend`
- `rag-service`
- `git-nexus`
- `workspace-github-adapter`

## Validation and Release Impact

Testing expectations:

- Unit tests for Slack Web API success, `ok: false`, HTTP failure, and missing `ts`.
- Unit tests for Redis store get/set/delete and failure handling through fake adapters.
- Unit tests for lazy thread creation when a task message finds no mapping.
- Unit tests for task notification events posting with `thread_ts`.
- Unit tests for reviewer escalation and feature drift using the threaded service instead of direct webhook calls.
- Unit tests for `handleFeatureDone()` posting the final message before deleting the Redis mapping.
- Existing orchestrator unit suite should still pass with no Slack or Redis env configured.

Migration/config impact:

- Add optional env vars to templates: `SLACK_BOT_TOKEN`, `SLACK_CHANNEL_ID`, and `REDIS_URL`.
- Keep `SLACK_WEBHOOK_URL` documented as legacy non-threaded fallback.
- Add Redis client dependency to `runtime/orchestrator/package.json` and lockfile.

Rollout concerns:

- Missing Slack or Redis config must emit structured skip events and must not fail the orchestration loop.
- Redis delete failure after feature completion should be observable but non-blocking.
- Shared Redis deployments need workspace-scoped keys to prevent feature ID collisions.

Backward compatibility constraints:

- Existing task notifier call sites must keep compiling.
- Existing webhook-only installations should continue operating until they opt into threaded Slack.
- Feature state and task YAML schemas must not gain Slack-specific fields.

Deployment/handoff implications:

- Rebuild orchestrator images after dependency and env-template changes.
- For local-docker, pass `REDIS_URL=redis://redis:6379` to orchestrator services.
- Handoff must call out that the feature is enabled only when bot-token Slack config and Redis are present.
