# Tasks - Slack Thread Notifications for Feature Runs

Feature status reference: `ready_for_implementation`; stage status: `technical_design/approved`, `tasks/approved`. Machine state lives in `tasks/T<n>.yaml`; this file is narrative only.

## Index

| ID | Wave | Repo | Title | Depends on |
|---|---:|---|---|---|
| T1 | 1 | workflow | Slack Web API client and threaded config | [] |
| T2 | 1 | workflow | Redis feature/task-thread store | [] |
| T7 | 1 | workspace-github-adapter | Workspace notification settings migration | [] |
| T3 | 2 | workflow | Message types and formatters | [T1, T2] |
| T8 | 3 | workflow | Thread management service | [T3] |
| T4 | 4 | workflow | Task and reviewer notification call-site migration | [T8] |
| T5 | 4 | workflow | Feature lifecycle wiring — start, summary, handoff | [T8] |
| T9 | 4 | workflow | Feature completion and cleanup | [T8] |
| T6 | 5 | workflow | Tests, templates, and operator documentation | [T4, T5, T9] |

---

## T1 - Slack Web API client and threaded config

### Description

Add the Slack Web API boundary needed for threaded notifications. This task owns config parsing for `SLACK_BOT_TOKEN` (env) and `notifications.slack.channel_id` (from workspace.yaml), a focused `chat.postMessage` and `chat.update` client, and structured failure behavior for invalid Slack responses.

It fits the design by replacing the webhook-only send primitive with an API client that can return the Slack message `ts` required for feature and task thread routing.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Inspect current Slack webhook helper and notifier tests.
- [ ] Add `loadWorkspaceNotificationConfig()` to `runtime/orchestrator/src/config/workspace-config.ts` to parse `notifications.slack.channel_id` from workspace.yaml; return `null` if the field is absent.
- [ ] Add a Slack Web API client module under `runtime/orchestrator/src`.
- [ ] Read `SLACK_BOT_TOKEN` from env; read `channel_id` from `WorkspaceConfig.notifications.slack.channel_id` — there is no `SLACK_CHANNEL_ID` env var.
- [ ] Implement `chat.postMessage` with bearer-token auth and JSON payload support.
- [ ] Implement `chat.update` with bearer-token auth to edit an existing Slack message by `ts`.
- [ ] Validate Slack responses: require HTTP success, `ok: true`, and a non-empty `ts` on `chat.postMessage`; require HTTP success and `ok: true` on `chat.update`.
- [ ] Ensure missing `SLACK_BOT_TOKEN` or absent `notifications.slack.channel_id` is represented as disabled threaded Slack, not as a thrown startup error.
- [ ] Add unit tests for `chat.postMessage`: success, HTTP failure, `ok: false`, missing `ts`, and disabled config.
- [ ] Add unit tests for `chat.update`: success, HTTP failure, and `ok: false`.
- [ ] Add unit tests for `loadWorkspaceNotificationConfig`: field present, field absent, malformed yaml.
- [ ] Run the orchestrator test target for the affected tests.

---

## T2 - Redis feature/task-thread store

### Description

Add the Redis-backed store for feature-to-thread and task-to-thread mappings. This task owns the key policy, Redis dependency/config, and store behavior for get/set/delete.

It fits the design by keeping Slack routing state transient and outside feature/task YAML while allowing feature events to locate the feature thread and task events to locate their own task thread.

### Required skills

- typescript-best-practices
- backend-engineer

### Subtasks

- [ ] Add the Node Redis client dependency to `runtime/orchestrator/package.json` and lockfile.
- [ ] Add Redis config parsing for `REDIS_URL` without making it mandatory at startup.
- [ ] Implement a scope-thread store with `getFeature`, `setFeature`, `deleteFeature`, `getTask`, `setTask`, and `deleteTask` operations.
- [ ] Use key shape `slack:feature_thread:<workspaceId>:<featureId>`.
- [ ] Use key shape `slack:task_thread:<workspaceId>:<featureId>:<taskId>`.
- [ ] Support best-effort scan and delete of all task thread keys for a feature using a workspace/feature-scoped key prefix (used by `closeFeatureThread` in T8 for cleanup on feature completion).
- [ ] Ensure Redis connection/read/write/delete failures return structured errors to callers.
- [ ] Add fake/in-memory store support for unit tests.
- [ ] Add unit tests for feature get/set/delete, task get/set/delete, missing key, connection failure, write failure, delete failure, and feature-scoped task cleanup.
- [ ] Run the orchestrator test target for the affected tests.

---

## T3 - Message types and formatters

### Description

Define the service interface and all message formatting logic. This task owns no I/O — it produces only TypeScript types and pure formatter functions that T8 and tests can import directly.

It fits the design by isolating the formatting contract from the stateful service so formatters can be unit-tested without any Slack or Redis dependencies.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Define `NotificationPort` — the unified interface that core orchestrator logic depends on. Task methods: `postTaskMessage(featureId, taskId, trigger, context)`, `closeTaskThread(featureId, taskId, context)`. Feature methods: `postFeatureMessage(featureId, trigger, context)`, `closeFeatureThread(featureId, context)`. Core code must never import Slack or Redis modules directly.
- [ ] Define the `ThreadedNotificationService` interface and all event payload shape types.
- [ ] Define feature message trigger types: `feature_start`, `feature_summary_changed`, `handoff_submitted`, `feature_completed`.
- [ ] Define task message trigger types: `task_start`, `task_status_changed`, `task_pr_changed`, `task_review_changed`, `task_completed`.
- [ ] Implement feature top-level formatter: full current state snapshot — title, status (with icon), next_action (if active), blocked_reason (if blocked), handoff (if in_handoff), feature_pr (if set), total_task_count. Used for both `feature_start` create and all subsequent `chat.update` calls.
- [ ] Implement feature reply formatter: changed feature fields only for that event (audit trail).
- [ ] Implement task top-level formatter: full current state snapshot — title, status (with icon), repo, branch, execution.last_updated_by, pr (if set), blocked_reason (if blocked). Used for both `task_start` create and all subsequent `chat.update` calls.
- [ ] Implement task reply formatter: changed task fields only for that event (audit trail).
- [ ] Implement status icon rendering for all `Status:` lines using the shared status icon contract.
- [ ] Implement status-aware field omission: absent or irrelevant fields must be omitted, not rendered as blank lines.
- [ ] Add unit tests covering: feature top-level formatting for each trigger type, feature reply changed-field extraction, task top-level formatting for each trigger type, task reply changed-field extraction, status icon mapping for every status family, and field omission for absent/irrelevant values.

---

## T8 - Thread management service

### Description

Implement the stateful service that composes the Slack client (T1), the Redis store (T2), and the formatters (T3a). This task owns all thread lifecycle operations and all failure-isolation behavior.

It fits the design as the concrete implementation behind `ThreadedSlackNotifier` (T4's adapter) — T4, T5, and T9 call `NotificationPort` and never import this service directly.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Implement `ensureFeatureThread(featureId, context)`: read Redis key → if absent and Slack+Redis configured, call `chat.postMessage` with the T3 feature top-level formatter output → store returned `ts` → emit `feature_slack_thread_created`.
- [ ] Implement `ensureTaskThread(featureId, taskId, context)`: same pattern for task thread key.
- [ ] Implement `postFeatureMessage(featureId, trigger, context)`: for `feature_start` call `ensureFeatureThread` only; for all other triggers call `chat.update` on stored `thread_ts` with top-level formatter output, then call `chat.postMessage` with reply formatter output and `thread_ts`.
- [ ] Implement `postTaskMessage(featureId, taskId, trigger, context)`: same pattern — `task_start` creates only; subsequent triggers call `chat.update` on task top-level then post a reply.
- [ ] Implement `closeFeatureThread(featureId, finalContext)`: call `postFeatureMessage` for the terminal event then delete the Redis feature key; emit `feature_slack_thread_deleted` on success or `feature_slack_thread_delete_failed` on failure without blocking completion.
- [ ] Implement `closeTaskThread(featureId, taskId, finalContext)`: same pattern for the task key.
- [ ] Implement missing-key fallback: when a non-`task_start` / non-`feature_start` message finds no Redis key, lazily call `ensureFeatureThread` or `ensureTaskThread` before posting.
- [ ] Ensure task messages never fall back to the feature thread under any code path.
- [ ] Ensure feature messages never include task logs, task PR/review detail, raw executor output, or runtime internals.
- [ ] Implement skip behavior: when `SLACK_BOT_TOKEN` is absent or `notifications.slack.channel_id` is not set, emit a structured skip event and return without throwing.
- [ ] Implement Redis unavailable path: catch Redis errors, emit a structured failure event, and return without throwing.
- [ ] Emit structured events for every outcome: created, updated, posted, skipped, failed, deleted.
- [ ] Add unit tests covering: idempotent `ensureFeatureThread` (key already present), idempotent `ensureTaskThread`, `postFeatureMessage` for `feature_start` (create only, no update), `postFeatureMessage` for a subsequent trigger (`chat.update` + reply both called), `postTaskMessage` for `task_start` (create only), `postTaskMessage` for a subsequent trigger (`chat.update` + reply both called), `closeFeatureThread` (update + reply + delete), `closeTaskThread` (update + reply + delete), lazy thread creation on missing key, task message never routes to feature thread, skip on missing config, Redis read failure, Redis delete failure.

---

## T4 - Task and reviewer notification call-site migration

### Description

Expand `TaskNotifierPort` into the unified `NotificationPort` (defined in T3), replace the old webhook adapter with `ThreadedSlackNotifier`, and migrate task-level call sites to use the injected port.

It fits the design by keeping the hexagonal boundary intact: core orchestrator logic depends only on `NotificationPort` and never imports Slack or Redis modules directly.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Delete `runtime/orchestrator/src/adapters/slack-task-notifier.ts` and `runtime/orchestrator/src/side-effects/post-task-slack.ts` (webhook adapter and helper — replaced by `ThreadedSlackNotifier`).
- [ ] Create `ThreadedSlackNotifier` adapter implementing `NotificationPort`; each method delegates to the corresponding `ThreadedNotificationService` method.
- [ ] Wire startup: instantiate `ThreadedSlackNotifier` (with `ThreadedNotificationService` injected) when Slack+Redis config is present; fall back to a no-op `NullNotifier` adapter when config is absent.
- [ ] Update all injection sites that previously received `TaskNotifierPort` to accept `NotificationPort` instead — call sites (`dispatchExecutorResult`, `dispatchReviewResult`, escalation handlers) require no further changes beyond the type rename.
- [ ] Verify `dispatchExecutorResult()` calls `port.postTaskMessage(...)` and `dispatchReviewResult()` calls `port.postTaskMessage(...)` / `port.closeTaskThread(...)` through the injected port.
- [ ] Verify task-tied reviewer escalation calls `port.postTaskMessage(...)` through the injected port instead of the old direct webhook call.
- [ ] Leave feature drift escalation unchanged; it stays outside this notification scope.
- [ ] Ensure notification failures never nack broker completions or block task mutations.
- [ ] Update existing tests: inject a mock `NotificationPort`, verify correct port methods are called for dispatch, review result, and escalation paths.
- [ ] Run the orchestrator unit tests covering these call sites.

---

## T5 - Feature lifecycle wiring — start, summary, handoff

### Description

Wire the `feature_start`, `feature_summary_changed`, and `handoff_submitted` triggers in the lifecycle manager to the threaded notification service. This task owns the poll-cycle detection logic and the guard rules that prevent spurious Slack messages.

It fits the design by giving the lifecycle manager a clean boundary: detect the condition, call `NotificationPort`, let T3/T8 handle formatting and I/O.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Inject `NotificationPort` into the lifecycle manager.
- [ ] Call `port.postFeatureMessage('feature_start', ...)` on the first lifecycle-manager poll that observes the feature in active orchestration (e.g. `ready_for_implementation`) and no feature thread mapping exists yet.
- [ ] Call `port.postFeatureMessage('feature_summary_changed', ...)` after a persisted feature-level state change.
- [ ] Do not call `postFeatureMessage` for task status transitions alone; those route only to `postTaskMessage`.
- [ ] Call `port.postFeatureMessage('handoff_submitted', ...)` when the handoff document and feature-level PR are created or updated.
- [ ] Do not add an independent periodic Slack timer; routine poll cycles with no feature-summary change must not call the port.
- [ ] Ensure already-done or skipped features do not trigger a `feature_start` call.
- [ ] Add unit tests: inject a mock `NotificationPort`; verify feature_start called on first active poll, feature_summary_changed called after state change, no call on task-only transition, no call on routine poll, handoff_submitted called, no call for already-done feature.
- [ ] Run the orchestrator unit tests covering the lifecycle manager.

---

## T9 - Feature completion and cleanup

### Description

Wire `feature_completed` in `handleFeatureDone()` to `closeFeatureThread()` and handle best-effort task thread key cleanup after the feature closes.

It fits the design by ensuring transient Redis state is cleaned up at the terminal lifecycle point without blocking feature completion if Redis is unavailable.

### Required skills

- typescript-best-practices

### Subtasks

- [ ] Inject `NotificationPort` into `handleFeatureDone()`.
- [ ] Call `port.closeFeatureThread(featureId, context)` in `handleFeatureDone()` after all required PRs are merged and before or alongside `feature_done` emission; the port delegates to `ThreadedNotificationService` which handles `chat.update`, final reply, and key deletion internally.
- [ ] Ensure Redis delete failure emits a structured event but does not block or throw in `handleFeatureDone()`.
- [ ] Ensure `handleFeatureDone()` does not call `closeFeatureThread` more than once (idempotency guard).
- [ ] Add unit tests: inject a mock `NotificationPort`; verify closeFeatureThread called once, Redis delete failure does not block completion, idempotent call guard.
- [ ] Run the orchestrator unit tests covering the feature done watcher.

---

## T6 - Tests, templates, and operator documentation

### Description

Complete release readiness for threaded Slack notifications. This task owns cross-cutting test coverage, env templates, Docker Compose wiring, and operator docs.

It fits the design by making the feature deployable and understandable without changing task/feature YAML schemas.

### Required skills

- typescript-best-practices
- backend-engineer

### Subtasks

- [ ] Add `SLACK_BOT_TOKEN` and `REDIS_URL` to relevant `.env.template` files; `SLACK_CHANNEL_ID` is not an env var — document that it is set via `notifications.slack.channel_id` in `workspace.yaml`.
- [ ] Remove `SLACK_WEBHOOK_URL` from all `.env.template` files and operator docs (file deletion is handled in T4).
- [ ] Pass `SLACK_BOT_TOKEN` and `REDIS_URL` into local-subprocess and local-docker orchestrator services.
- [ ] Document local-docker Redis reuse and local-subprocess Redis requirements.
- [ ] Add or update operator docs for enabling threaded Slack notifications.
- [ ] Add an end-to-end unit/integration-style test covering: `feature_start` (top-level create) → task thread creation → task status transitions (chat.update on task top-level + reply) → feature-level `feature_summary_changed` (chat.update on feature top-level + reply) → `feature_completed` (final chat.update + reply + Redis delete) using mocked Slack and fake Redis.
- [ ] Run `npm test` or the repo-equivalent orchestrator test command.
- [ ] Run `npm run build` or `npm run typecheck` for the orchestrator package.

---

## T7 - Workspace notification settings migration

### Description

Add `slack_channel_id` to the `workspaces` table in `workspace-github-adapter` so workspace-level Slack channel config is persisted to the database when workspace.yaml is synced. This ensures the API layer can serve notification settings alongside other workspace data.

It fits the design by making `notifications.slack.channel_id` a first-class workspace property — declared in workspace.yaml, synced to Postgres by the adapter, and readable by any service via the standard workspace query path.

### Required skills

- postgres-best-practices
- go-best-practices

### Subtasks

- [ ] Add migration `database/migrations/00012_workspace_notification_settings.sql` adding `slack_channel_id TEXT` (nullable, no default) to the `workspaces` table.
- [ ] Update `database/queries/workspaces.sql`: add `slack_channel_id` to the SELECT column list in `ListWorkspaces`, `GetWorkspace`, and `GetWorkspaceBySlug`.
- [ ] Update `UpsertWorkspace`: add `slack_channel_id` to the INSERT columns and the `ON CONFLICT DO UPDATE SET` clause.
- [ ] Update `UpsertWorkspaceByID`: same as `UpsertWorkspace`.
- [ ] Update `UpdateWorkspaceByID`: add `slack_channel_id` to the SET clause.
- [ ] Regenerate sqlc types after query changes (`sqlc generate` or equivalent).
- [ ] Update the adapter's workspace-sync path to read `notifications.slack.channel_id` from the parsed workspace.yaml and pass it to `UpsertWorkspace`/`UpsertWorkspaceByID`.
- [ ] Run the adapter test suite.
