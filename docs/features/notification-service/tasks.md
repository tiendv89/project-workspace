
# Tasks — notification-service

## Feature
- Feature ID: `notification-service`
- Title: Activity Center — In-App Notifications for Mentions, Messages, and Feature Lifecycle Events

## Dependency diagram

```
T1 (scaffold repo)
 └─> T2 (DB schema + migrations)
       ├─> T3 (producer-facing API + preference gating)
       │     ├─> T5 (email sending: SMTP adapter + worker loop)
       │     ├─> T6 (hermes-agent producer wiring)
       │     └─> T7 (agent-workflow producer wiring)
       └─> T4 (user-facing API: feed, read state, preferences)
             ├─> T8 (digital-factory-ui Activity panel)
             └─> T9 (digital-factory-ui Notification Settings page)
```

`notification-service` is already registered in `workspace.yaml` and indexed in GitNexus
(starter commit present) — no separate registration task is needed.

## Index

| Task | Title | Repo | Depends on | Actor |
|---|---|---|---|---|
| T1 | Scaffold `notification-service` repo | notification-service | — | agent |
| T2 | DB schema + goose migrations | notification-service | T1 | agent |
| T3 | Producer-facing API + preference gating | notification-service | T2 | agent |
| T4 | User-facing API (feed, read state, preferences) | notification-service | T2 | agent |
| T5 | Email sending: SMTP adapter + worker loop | notification-service | T3 | agent |
| T6 | `hermes-agent` producer wiring | hermes-agent | T3 | agent |
| T7 | `agent-workflow` producer wiring | agent-workflow | T3 | agent |
| T8 | `digital-factory-ui` Activity panel | digital-factory-ui | T4 | agent |
| T9 | `digital-factory-ui` Notification Settings page | digital-factory-ui | T4 | agent |

---

## T1 — Scaffold `notification-service` repo

### Description
Build out the `notification-service` Go repo (`git@github.com:tiendv89/notification-service.git`,
already created with a starter commit) following the `go-microservice` template conventions
already adopted by `user-service`. Establish the folder layout from the technical design:

```
notification-service/
  cmd/
    main.go          # cobra root; registers api, worker, migration subcommands
    api/api.go        # `run()` — Gin HTTP server, routes; no email loop
    worker/worker.go  # `run()` — email ticker/claim loop; no HTTP server
  configs/            # viper config, env overrides
  internal/
    httpapi/
    notifications/
    preferences/
    email/
    userlookup/
    serviceauth/
  database/
    schema.dbml
    migrations/
  Dockerfile
  go.mod / go.sum
```

`cmd/api/api.go` and `cmd/worker/worker.go` may be stub `run()` functions at this stage (fleshed
out in T3/T5) — this task delivers the skeleton, module setup, Dockerfile (single image,
`ENTRYPOINT` arg selects `api` or `worker`), and CI/lint scaffolding, not business logic.

### Required skills
- go-best-practices

### Subtasks
- [ ] Initialize Go module (`go.mod`); add pgx, gin, viper, cobra, `pressly/goose/v3` dependencies
- [ ] Create `cmd/main.go` cobra root registering `api`, `worker`, `migration` subcommands
- [ ] Create `cmd/api/api.go` and `cmd/worker/worker.go` with stub `run()` entrypoints
- [ ] Create `configs/` package (viper load, env overrides, `.env.template`)
- [ ] Create empty `internal/{httpapi,notifications,preferences,email,userlookup,serviceauth}` packages
- [ ] Create `database/schema.dbml` placeholder and `database/migrations/` directory
- [ ] Add `Dockerfile` (single image, subcommand selected via `ENTRYPOINT` arg)
- [ ] Add `.golangci.yml`, `Makefile` (`run-api`, `run-worker`, `migrate-up`, `lint`, `test`)
- [ ] Push commit; confirm `go build ./...` and `golangci-lint run` succeed

---

## T2 — DB schema + goose migrations

### Description
Implement the `notification_db` schema per the technical design's Chosen Design section:
`notifications`, `notification_preferences` (with `in_app_enabled`/`email_enabled` columns,
default `true`/`false` respectively), and `email_deliveries`. Add the three goose migrations
exactly as specified in the technical design (`00001_create_notifications.sql`,
`00002_create_notification_preferences.sql`, `00003_create_email_deliveries.sql`), including all
indexes (`idx_notifications_feed`, `idx_notifications_feed_category`, `idx_notifications_unread`,
`idx_email_deliveries_retry`) and the `pgcrypto` extension for `gen_random_uuid()`.

### Required skills
- go-best-practices
- postgres-best-practices

### Subtasks
- [ ] Write `00001_create_notifications.sql` (up/down) with all three indexes
- [ ] Write `00002_create_notification_preferences.sql` (up/down) with `in_app_enabled`/`email_enabled`
- [ ] Write `00003_create_email_deliveries.sql` (up/down) with retry index
- [ ] Update `database/schema.dbml` to reflect the three tables
- [ ] Verify `cmd/main.go migration up` applies cleanly against a local Postgres instance
- [ ] Integration test: migrations apply and roll back cleanly (up/down/up)

---

## T3 — Producer-facing API + preference gating

### Description
Implement `POST /internal/notifications` and `POST /internal/notifications/bulk`
(service-token auth via `internal/serviceauth/`), per the technical design. On each call: look
up `notification_preferences` for `(user_id, workspace_id, category)`; insert into
`notifications` only if `in_app_enabled` (default true when no row exists); if `email_enabled`
(default false when no row exists) **and** the `NOTIFY_EMAIL_ENABLED` global flag is true, insert
a `pending` row into `email_deliveries` (actual sending is T5's job — this task only inserts the
row). Endpoint returns 200 whether or not anything was inserted (no-op is not an error).
Implement the `NOTIFY_EMAIL_ENABLED` config flag (default `false`) read at `cmd/api` startup.

### Required skills
- go-best-practices
- postgres-best-practices

### Subtasks
- [ ] Implement `internal/serviceauth/` service-token middleware for `/internal/*` routes
- [ ] Implement `internal/notifications/` domain logic: preference lookup, insert, no-op path
- [ ] Implement `POST /internal/notifications` handler
- [ ] Implement `POST /internal/notifications/bulk` handler (array body, same preference-gate logic per entry)
- [ ] Add `NOTIFY_EMAIL_ENABLED` config flag (default false), wired into the preference-gate check
- [ ] Unit tests: `in_app_enabled=false` → no insert; `email_enabled=true` + flag=true → `email_deliveries` row inserted; flag=false → no `email_deliveries` row regardless of preference
- [ ] Integration test against seeded Postgres

---

## T4 — User-facing API (feed, read state, preferences)

### Description
Implement the cookie/session-auth user-facing endpoints per the technical design:
`GET /api/notifications?view=all|dms|mentions&status=unread|all`,
`POST /api/notifications/:id/read`, `POST /api/notifications/read-all`,
`GET /api/notifications/unread-count`, `GET /api/notification-preferences`,
`PUT /api/notification-preferences`. Preferences endpoint returns/accepts the two-dimensional
(category × {in_app_enabled, email_enabled}) shape.

### Required skills
- go-best-practices
- postgres-best-practices

### Subtasks
- [ ] Implement `internal/httpapi/` route registration for the user-facing surface
- [ ] Implement `GET /api/notifications` with `view`/`status` query filters using the feed/category indexes
- [ ] Implement `POST /api/notifications/:id/read` and `POST /api/notifications/read-all`
- [ ] Implement `GET /api/notifications/unread-count` (uses the partial unread index)
- [ ] Implement `GET /api/notification-preferences` / `PUT /api/notification-preferences`
- [ ] Unit + integration tests for each endpoint, including default-row-absent behavior (in_app default true, email default false)

---

## T5 — Email sending: Gmail/Workspace SMTP adapter + worker loop

### Description
Implement `internal/email/` per the technical design: the `EmailSenderPort` interface with a
Gmail/Google Workspace SMTP adapter (`smtp.gmail.com:587`, STARTTLS, app password from `.env`:
`SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_APP_PASSWORD`, `SMTP_FROM_ADDRESS`), the 7
category email templates, and the `cmd/worker/worker.go` ticker/claim loop
(`SELECT ... FOR UPDATE SKIP LOCKED`, `attempts < 5` cap, `EMAIL_WORKER_POLL_INTERVAL` /
batch-size env config, graceful shutdown). Implement `internal/userlookup/` — the service-token
client resolving `user_id → email` against `user-service`'s internal lookup surface, used only to
populate `email_deliveries.to_email` at send time. When `NOTIFY_EMAIL_ENABLED` is false, the
worker's ticker must no-op (no claim query issued).

### Required skills
- go-best-practices
- postgres-best-practices

### Subtasks
- [ ] Implement `EmailSenderPort` interface + Gmail/Workspace SMTP adapter
- [ ] Implement 7 category email templates (plain-text/simple-HTML), rendered from `summary`/`link`/`feature_id`/`task_id`
- [ ] Implement `internal/userlookup/` client against `user-service`'s internal API
- [ ] Implement `cmd/worker/worker.go` ticker loop with `FOR UPDATE SKIP LOCKED` claim query, attempts cap, and `NOTIFY_EMAIL_ENABLED` no-op guard
- [ ] Implement graceful shutdown (finish in-flight batch on SIGTERM)
- [ ] Add `EMAIL_WORKER_POLL_INTERVAL` / batch-size env config
- [ ] Unit tests: claim query respects `attempts < 5`; failed sends increment attempts and stay `failed` after cap; worker no-ops when `NOTIFY_EMAIL_ENABLED=false`
- [ ] Manual verification: send one real test email via a configured Gmail/Workspace test account

---

## T6 — `hermes-agent` producer wiring (mentions, DMs, channel messages)

### Description
Add a fire-and-forget call to `notification-service`'s `POST /internal/notifications(/bulk)`
right after `persist_mentions` / `append_message` in `src/db/store.py`, per the technical design.
Emit `mention` for `MessageMention` rows, `channel_message` for other `session_members`
(excluding the author), and `dm` for DM session type (per `agent-general-chat`). No schema
change to `hermes-agent`'s own tables — this is additive HTTP-call wiring only.

### Required skills
- python-best-practices

### Subtasks
- [ ] Add a thin `notification-service` HTTP client to `hermes-agent` (service-token auth)
- [ ] Wire `mention` category emission from `MessageMention` rows in `persist_mentions`
- [ ] Wire `channel_message` category emission to `session_members` (excluding author) on channel messages
- [ ] Wire `dm` category emission for DM session messages
- [ ] Ensure the call is fire-and-forget (does not block message-save path on notification-service latency/errors)
- [ ] Unit tests covering each category's trigger condition and payload shape
- [ ] Integration test against a mock/local notification-service instance

---

## T7 — `agent-workflow` producer wiring (feature lifecycle approvals, task done)

### Description
Add a second `NotificationPort` implementation, `InAppNotificationAdapter`, calling
`POST /internal/notifications`, per the technical design. Wire it into
`src/feature/notification-watcher.ts:runFeatureNotificationStep` to detect
`product_spec`/`technical_design`/`tasks` stage transitions to `approved` (reading `status.yaml`)
and emit `spec_approved`/`design_approved`/`tasks_approved` to the feature's session members.
Wire it into `src/feature/check-tasks-done.ts` to emit `task_done` to the task's assignee
(`execution.last_updated_by` / task log author) on task completion. Reuses the existing poll
cycle and status-detection logic — no new polling loop.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Implement `InAppNotificationAdapter` conforming to the existing `NotificationPort` interface
- [ ] Register `InAppNotificationAdapter` alongside the existing Slack adapter (parallel sink, not a replacement)
- [ ] Extend `runFeatureNotificationStep` to detect stage-approval transitions and emit `spec_approved`/`design_approved`/`tasks_approved`
- [ ] Extend `check-tasks-done.ts` to emit `task_done` to the task's assignee
- [ ] Resolve "who is watching" per the technical design (feature session members for approvals; task assignee/last-updated-by for task_done)
- [ ] Unit tests for each new trigger scenario, mirroring the existing Slack notification test coverage
- [ ] Confirm existing Slack notification behavior is unchanged (regression tests pass)

---

## T8 — `digital-factory-ui` Activity panel

### Description
Add the new **Activity** nav-rail entry (alongside Channels, Team Chat) rendering three tabs —
All, DMs, Mentions — backed by `GET /api/notifications`. Add
`src/services/notification-service/client.ts` + `useNotifications` hook (TanStack Query),
following the existing `workflow-backend` client/hook pattern. Mark-as-read on entry open; nav
navigates to the source thread/feature/task via the notification's `link`. Update the nav-rail
unread badge to use (or merge with) `GET /api/notifications/unread-count`.

### Required skills
- typescript-best-practices
- react-best-practices

### Subtasks
- [ ] Add `src/services/notification-service/client.ts` (listNotifications, markRead, markAllRead, unreadCount)
- [ ] Add `useNotifications` / `useUnreadCount` hooks (TanStack Query)
- [ ] Add `Activity` nav-rail entry and route
- [ ] Build the All/DMs/Mentions tabbed feed component
- [ ] Wire mark-as-read on open + navigation to `link`
- [ ] Update nav-rail unread badge to incorporate `GET /api/notifications/unread-count`
- [ ] Unit tests for the feed component (tab filtering, read/unread rendering, empty state)
- [ ] E2E test: mention triggers a feed entry, opening it marks it read and navigates correctly

---

## T9 — `digital-factory-ui` Notification Settings page

### Description
Add a **Notification Settings** section to the Settings page backed by
`GET/PUT /api/notification-preferences`. Each category (Mentions, Channel messages, DMs,
Feature lifecycle approvals, Task done) shows two independent toggles: **In-app** (default on)
and **Email** (default off, per product spec's opt-in requirement).

### Required skills
- typescript-best-practices
- react-best-practices

### Subtasks
- [ ] Add `useNotificationPreferences` hook (TanStack Query) to `src/services/notification-service/client.ts`
- [ ] Build the Notification Settings section: one row per category, In-app + Email toggle each
- [ ] Wire toggle changes to `PUT /api/notification-preferences`
- [ ] Default rendering: In-app on, Email off when no preference row exists yet
- [ ] Unit tests: toggle state reflects backend defaults and persists changes correctly
- [ ] E2E test: disabling Email for a category and confirming no email preference regression on reload
