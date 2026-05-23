# Tasks - Slack Thread Notifications for Feature Runs

Feature status reference: `in_tdd`; stage status: `technical_design/awaiting_approval`, `tasks/draft`. Machine state lives in `tasks/T<n>.yaml`; this file is narrative only.

## Index

| ID | Wave | Repo | Title | Depends on |
|---|---:|---|---|---|
| T1 | 1 | workflow | Slack Web API client and threaded config | [] |
| T2 | 1 | workflow | Redis feature-thread store | [] |
| T3 | 2 | workflow | Threaded notification service and task notifier adapter | [T1, T2] |
| T4 | 3 | workflow | Task, reviewer, and drift notification call-site migration | [T3] |
| T5 | 3 | workflow | Feature lifecycle thread creation and completion cleanup | [T3] |
| T6 | 4 | workflow | Tests, templates, and operator documentation | [T4, T5] |

---

## T1 - Slack Web API client and threaded config

### Description

Add the Slack Web API boundary needed for threaded notifications. This task owns config parsing for `SLACK_BOT_TOKEN` and `SLACK_CHANNEL_ID`, a focused `chat.postMessage` client, and structured failure behavior for invalid Slack responses.

It fits the design by replacing the webhook-only send primitive with an API client that can return the Slack message `ts` required for feature-thread routing.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Inspect current Slack webhook helper and notifier tests.
- [ ] Add a Slack Web API client module under `runtime/orchestrator/src`.
- [ ] Read `SLACK_BOT_TOKEN` and `SLACK_CHANNEL_ID` through a small config boundary.
- [ ] Implement `chat.postMessage` with bearer-token auth and JSON payload support.
- [ ] Validate Slack responses: require HTTP success, `ok: true`, and a non-empty `ts`.
- [ ] Ensure missing Slack config is represented as disabled threaded Slack, not as a thrown startup error.
- [ ] Add unit tests for success, HTTP failure, `ok: false`, missing `ts`, and disabled config.
- [ ] Run the orchestrator test target for the affected tests.

---

## T2 - Redis feature-thread store

### Description

Add the Redis-backed store for feature-to-thread mappings. This task owns the key policy, Redis dependency/config, and store behavior for get/set/delete.

It fits the design by keeping Slack routing state transient and outside feature/task YAML while allowing any task event for a feature to locate the existing Slack thread.

### Required skills

- typescript-best-practices
- backend-engineer

### Subtasks

- [ ] Add the Node Redis client dependency to `runtime/orchestrator/package.json` and lockfile.
- [ ] Add Redis config parsing for `REDIS_URL` without making it mandatory at startup.
- [ ] Implement a feature-thread store with `get`, `set`, and `delete` operations.
- [ ] Use key shape `slack:feature_thread:<workspaceId>:<featureId>`.
- [ ] Ensure Redis connection/read/write/delete failures return structured errors to callers.
- [ ] Add fake/in-memory store support for unit tests.
- [ ] Add unit tests for get/set/delete, missing key, connection failure, write failure, and delete failure.
- [ ] Run the orchestrator test target for the affected tests.

---

## T3 - Threaded notification service and task notifier adapter

### Description

Build the service boundary that composes the Slack client and Redis store. This task owns `ensureFeatureThread`, threaded task posting, feature posting, `closeFeatureThread`, lazy thread creation, and the adapter that preserves the existing `TaskNotifierPort` call-site contract.

It fits the design by making the rest of the orchestrator call one notification abstraction instead of knowing Slack API or Redis details.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Define the threaded notification service interface and event payload shapes.
- [ ] Implement `ensureFeatureThread(featureId, context)`.
- [ ] Implement task message posting with Redis lookup and Slack `thread_ts`.
- [ ] Implement missing-key fallback: lazily create the feature thread when Slack and Redis are configured.
- [ ] Implement skip behavior for disabled Slack or unavailable Redis.
- [ ] Implement `closeFeatureThread(featureId, finalMessage)` that posts final status then deletes the key.
- [ ] Replace or wrap `SlackTaskNotifier` with a threaded adapter that still satisfies `TaskNotifierPort`.
- [ ] Emit structured events for created, posted, skipped, failed, and deleted outcomes.
- [ ] Add unit tests for idempotent ensure, task post into existing thread, lazy thread creation, disabled config, and Redis failure.

---

## T4 - Task, reviewer, and drift notification call-site migration

### Description

Migrate task-level and review-related notification call sites to the threaded notification service. This task covers executor completion, reviewer pass/done, reviewer escalation, and feature drift escalation.

It fits the design by routing the highest-volume follow-up messages into the feature thread while preserving task state transitions and failure isolation.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Update `dispatchExecutorResult()` to use the threaded task notifier for `in_review` and `blocked`.
- [ ] Update `dispatchReviewResult()` to use the threaded task notifier for `done`.
- [ ] Update reviewer escalation handling to use the threaded service instead of direct webhook posting.
- [ ] Update feature drift escalation to post into the feature thread when possible.
- [ ] Preserve existing structured failure events or replace them with equivalent threaded-event names.
- [ ] Ensure notification failures never nack broker completions or block task mutations.
- [ ] Update existing tests for dispatch, review result, escalation handler, feature review cycle, and post-task Slack behavior.
- [ ] Run the orchestrator unit tests covering these call sites.

---

## T5 - Feature lifecycle thread creation and completion cleanup

### Description

Wire feature-level lifecycle events to the threaded notification service. This task creates or ensures the thread at the first active feature lifecycle signal and deletes the Redis mapping after the final feature completion notification.

It fits the design by giving each feature a stable parent thread and by cleaning transient Redis state when the workflow closes the feature.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Identify the earliest safe active-feature signal in the lifecycle manager without changing feature status semantics.
- [ ] Call `ensureFeatureThread()` when an eligible feature enters active orchestration.
- [ ] Keep handoff transition notifications in the thread but do not delete the key during handoff.
- [ ] Update `handleFeatureDone()` to call `closeFeatureThread()` after all PRs are merged and before or alongside `feature_done` emission.
- [ ] Ensure already-done or skipped features do not create new Slack threads.
- [ ] Ensure Redis delete failure is emitted but does not prevent feature completion.
- [ ] Add tests for feature start/ensure, handoff non-cleanup, done final message, delete success, and delete failure.
- [ ] Run the orchestrator unit tests covering lifecycle manager and feature done watcher.

---

## T6 - Tests, templates, and operator documentation

### Description

Complete release readiness for threaded Slack notifications. This task owns cross-cutting test coverage, env templates, Docker Compose wiring, and operator docs.

It fits the design by making the feature deployable and understandable without changing task/feature YAML schemas.

### Required skills

- typescript-best-practices
- backend-engineer

### Subtasks

- [ ] Add `SLACK_BOT_TOKEN`, `SLACK_CHANNEL_ID`, and `REDIS_URL` to relevant `.env.template` files.
- [ ] Pass the optional Slack threading env vars into local-subprocess and local-docker orchestrator services.
- [ ] Document webhook fallback as legacy non-threaded behavior.
- [ ] Document local-docker Redis reuse and local-subprocess Redis requirements.
- [ ] Add or update operator docs for enabling threaded Slack notifications.
- [ ] Add an end-to-end unit/integration-style test for feature start -> task update -> feature done using mocked Slack and fake Redis.
- [ ] Run `npm test` or the repo-equivalent orchestrator test command.
- [ ] Run `npm run build` or `npm run typecheck` for the orchestrator package.
