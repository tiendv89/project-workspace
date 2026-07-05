
# Technical Design

## Feature
- Feature ID: `notification-service`
- Title: Activity Center — In-App Notifications for Mentions, Messages, and Feature Lifecycle Events

## Current State

Notification-adjacent logic today is scattered across four repos with no shared owner:

- **`hermes-agent`** (Python/FastAPI, async SQLAlchemy) owns the conversation domain:
  `src/db/models.py:SessionMember`, `MessageMention` (mention persistence),
  `src/services/author_resolver.py:attach_authors`, `src/db/store.py:persist_mentions` /
  `append_message`. `src/api/routers/messages.py:_should_trigger_agent` is the closest thing to
  an event dispatch point, but it only decides whether the agent is triggered — nothing consumes
  `MessageMention` rows to notify the mentioned *human*.
- **`digital-factory-ui`** computes an unread-mention count today
  (`src/components/shell/nav-rail.tsx:useWorkspaceUnreadCount` →
  `src/services/hermes-agent/chat.ts:getUnreadMentions`) and separately renders a generic
  workspace activity feed (`ActivityFeed`, wired via `useActivity` → `listActivity`, from
  `m1-client-delivery-visibility`/T8) fed by `workflow-backend`'s
  `GET /api/workspaces/:workspaceId/activity`. Neither is a personal, cross-source, readable feed.
- **`workflow-backend`** (Go, pgx + sqlc, stdlib `net/http`) owns `workspace_activity_events` and
  `internal/handler/workspace.go:ListActivity` (`?audience=client|internal` allowlist +
  relabeling, from `m1-client-delivery-visibility`/T2). It has no concept of a user-scoped
  "notification" or read/unread state, and no fan-out — it is a pull-only audit log.
- **`agent-workflow`** (TypeScript orchestrator, `runtime/orchestrator`) already has a working
  **event → notify** pipeline for Slack: `NotificationPort` (`src/notification/port.ts`),
  `ThreadedNotificationService` (`src/notification/slack/service.ts`), and trigger call sites —
  `src/feature/notification-watcher.ts:runFeatureNotificationStep` (feature_start,
  feature_summary_changed, handoff_submitted), `src/feature/check-tasks-done.ts` (task done →
  `handleFeatureDone`/`checkFeatureTasksDone`), and the stage-approval commit path in
  `approve-feature` (writes `status.yaml` on product_spec/technical_design/tasks approval; see
  `schemas/status.yaml.example`). Today this pipeline's only sink is Slack.
- **`user-service`** (Go, Gin, pgx, goose, per `m1-identity-and-workspaces`) is the identity
  system of record — `users`, `organizations`, `workspace_memberships` — but owns no
  notification or preference data today. It already stores each user's email
  (`internal/users/users.go:Store.FindByEmail`) and exposes an internal user-lookup surface
  (`internal/handler/workspace.go:Handler.ListUsersByIDs`) that a service-token caller can use
  to resolve `user_id → email` — this is the natural source of truth for the email channel
  rather than duplicating email addresses into a new store.
- No email-sending infrastructure (SMTP client, transactional-email provider integration,
  templates) exists in any indexed repo today — `workflow-backend` and `user-service` were
  searched for mailer/SMTP/SendGrid/SES code and none was found. Email delivery is new
  infrastructure for this feature, not a reuse of an existing sender.

There is no single service a producer (hermes-agent, the orchestrator) can call to say "notify
user X about event Y," no per-user preference store, and no unified read API for an Activity UI.

## Constraints

- Must not require hermes-agent, workflow-backend, or agent-workflow to duplicate each other's
  fan-out or preference logic — one shared write path, one shared read path.
- Must not change existing Slack notification behavior (`slack-thread-notifications`,
  `go-orchestrator-slack-notifications`) — this is an additive, separate in-app sink.
- Must not require a new realtime transport; the Activity UI polls or reuses existing SSE, per
  the product spec's non-goals.
- New Go repo must follow the `workflow/templates/go-microservice` conventions already adopted
  by `user-service` (`workflow-sync-go-templates`, `m1-identity-and-workspaces`): Go, Gin,
  pgx, `pressly/goose/v3` migrations, `internal/` layout, cookie/service-token auth boundary —
  not the older stdlib/sqlc style still present in `workflow-backend`.
- Repo name is `notification-service` (`git@github.com:tiendv89/notification-service.git`) —
  must be registered in `workspace.yaml` under that name before task work can target it.
- Producers (`hermes-agent`, `agent-workflow`) must be decoupled from the notification service's
  schema — they call a small, stable HTTP API, not the DB directly.
- Email delivery must not block or fail the producer's fire-and-forget call — email send is
  best-effort and asynchronous relative to the `POST /internal/notifications` response; a
  provider outage must not cause producers to see errors or retries pile up.
- Email provider credentials (API key / SMTP creds) are resolved from `notification-service`'s
  own `.env`, per the workspace's existing environment-resolution convention — not hardcoded,
  not shared with other services.

## Options Considered

### Option A — Extend `workflow-backend` (`workspace_activity_events`) with per-user fan-out
- Pros: reuses an existing table and endpoint; no new repo/service to deploy.
- Cons: `workflow-backend` doesn't own chat/mention data (that's hermes-agent's), so mention/DM
  notifications would require a cross-service write into workflow-backend from hermes-agent
  anyway — no real coupling savings. Conflates the audit-log concern (workspace-wide, no
  per-user read state) with the personal-notification concern (per-user, read/unread,
  preferences). `workspace_activity_events` schema and its client-audience allowlist
  (`m1-client-delivery-visibility`) are tuned for a different consumer (external client
  dashboards) and would need incompatible changes.

### Option B — Add notification/preferences tables to `user-service`
- Pros: `user-service` is already the identity system of record; natural home for "preferences."
- Cons: `user-service`'s scope today is auth/org/membership (`m1-identity-and-workspaces`), not
  event ingestion or feed delivery; bolting a write-heavy, high-fanout notification/read-state
  table onto the identity DB risks coupling auth latency/availability to notification volume.
  Still requires a second component somewhere to do the actual routing/allowlist/preference-gate
  logic, so it only solves half the problem.

### Option C (chosen) — New standalone service: `notification-service`
- Pros: single owner for notification fan-out, per-user preferences, and read/unread state,
  independent of hermes-agent's and workflow-backend's own schemas and deploy cadence. Producers
  (hermes-agent, agent-workflow orchestrator) integrate through one small internal HTTP API,
  mirroring how `agent-workflow`'s `NotificationPort` already abstracts "notify" away from event
  producers for Slack — this is the same shape, a new sink. Matches the already-adopted
  `go-microservice` template (Go, Gin, pgx, goose) used by `user-service`, so it plugs into
  existing infra (Docker, CI, workspace.yaml repo registration) with no new stack to support.
- Cons: one more service to deploy/monitor; requires a new Postgres database; requires wiring
  three producers (hermes-agent, agent-workflow, and — for approvals — the workflow lifecycle
  itself) instead of one.

**Chosen: Option C.** It is the only option that gives notification fan-out, preferences, and
read state a single, coherent owner without overloading either the identity DB or the workspace
audit-log DB with a concern neither currently owns.

### Email delivery channel — options considered

#### Option D — SMTP relay (e.g. company Google Workspace / generic SMTP)
- Pros: no new third-party account; works with an existing company mail domain if one exists.
- Cons: no delivery/bounce visibility, weaker deliverability reputation management, more manual
  setup (DKIM/SPF) than a transactional provider; no indexed evidence any SMTP relay is already
  configured anywhere in the workspace.

#### Option E (chosen) — Transactional email API provider (e.g. SendGrid/SES/Postmark; provider
name left to implementation — the design only requires an HTTP-API transactional sender)
- Pros: simple HTTP API call from Go (no SMTP client/connection pooling to manage), built-in
  delivery/bounce/complaint tracking, better default deliverability, matches the "call an HTTP
  API with a token from `.env`" pattern this workspace already uses for other integrations
  (GitHub token for `pr-create`, Slack bot token for `go-orchestrator-slack-notifications`).
- Cons: adds a third-party account/credential to provision and monitor.

**Chosen: Option E.** The specific provider is an implementation/ops choice (SES, SendGrid, or
Postmark are all viable); the design commits only to the shape — an `EmailSenderPort` interface
with one HTTP-API-based adapter — so swapping providers later is a one-adapter change.

## Chosen Design

### New repo: `notification-service`

`git@github.com:tiendv89/notification-service.git` — Go 1.22+, following the `go-microservice`
template used by `user-service`:

```
notification-service/
  cmd/server/main.go            # HTTP entrypoint (cobra: api, migration subcommands)
  configs/                      # viper config, env overrides (incl. email provider API key)
  internal/
    httpapi/                    # gin routes
    notifications/              # domain: create, list, mark-read, fan-out-gate logic
    preferences/                # per-user category + channel on/off settings
    email/                      # EmailSenderPort + provider adapter, templates
    userlookup/                 # thin client to user-service (resolve user_id -> email)
    serviceauth/                # service-token middleware for producer-facing endpoints
  database/
    schema.dbml
    migrations/                 # pressly/goose/v3
  Dockerfile
  go.mod / go.sum
```

**Data model** (new Postgres DB, `notification_db`). Follows the same conventions as
`user-service`'s `migrations/00001_initial_identity_schema.sql`: `pressly/goose/v3` numbered SQL
migrations under `database/migrations/`, `gen_random_uuid()` PKs (via `pgcrypto`, already the
assumed extension given `user-service` uses UUID PKs), `timestamptz` for all timestamps, plain
SQL (no ORM).

- **`notifications`** — one row per fanned-out notification, per recipient.
  - `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
  - `workspace_id UUID NOT NULL`
  - `user_id UUID NOT NULL` — recipient
  - `category TEXT NOT NULL` — `mention` | `channel_message` | `dm` | `spec_approved` |
    `design_approved` | `tasks_approved` | `task_done` (`CHECK` constraint, not an enum type, to
    keep future category additions migration-free)
  - `source_type TEXT NOT NULL` — `message` | `feature` | `task` (`CHECK` constraint)
  - `source_id TEXT NOT NULL` — id of the message/feature/task in its owning system (hermes-agent
    session/message id is not a UUID in all cases, so this is `TEXT`, not `UUID`)
  - `feature_id TEXT NULL` — feature identifier (matches the feature-id string used across
    `workflow-backend`/`agent-workflow`, not a UUID)
  - `task_id TEXT NULL`
  - `summary TEXT NOT NULL` — short feed-row text
  - `link TEXT NOT NULL` — deep link back to the thread/feature/task
  - `actor_user_id UUID NULL` — who caused it; null for system-generated events (e.g. approvals
    triggered by CI rather than a human)
  - `read_at TIMESTAMPTZ NULL`
  - `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`
  - Indexes: `(workspace_id, user_id, created_at DESC)` for the main feed query;
    `(workspace_id, user_id, category, created_at DESC)` for the Mentions/DMs tab filters;
    partial index `(user_id, workspace_id) WHERE read_at IS NULL` for the unread-count query.

- **`notification_preferences`** — per-user category on/off; absence of a row means default-on
  for the `in_app` channel and default-off for the `email` channel (per product-spec: email is
  opt-in).
  - `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
  - `user_id UUID NOT NULL`
  - `workspace_id UUID NOT NULL`
  - `category TEXT NOT NULL` — same `CHECK` constraint as `notifications.category`
  - `in_app_enabled BOOLEAN NOT NULL DEFAULT true`
  - `email_enabled BOOLEAN NOT NULL DEFAULT false`
  - `updated_at TIMESTAMPTZ NOT NULL DEFAULT now()`
  - `UNIQUE (user_id, workspace_id, category)` — one row per (user, workspace, category); the
    preference-gate lookup in `POST /internal/notifications` is a single indexed point read on
    this uniqueness key, and now gates two independent booleans (in-app insert, email send)
    rather than one.

- **`email_deliveries`** — audit/status trail for outbound email attempts, decoupled from
  `notifications` so an email provider outage never blocks or rolls back the in-app row.
  - `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
  - `notification_id UUID NOT NULL` — references `notifications.id` (app-layer reference; same
    DB, so a real `FOREIGN KEY` is used here — unlike the cross-service identifiers below)
  - `to_email TEXT NOT NULL` — snapshot of the resolved address at send time (so a later email
    change in `user-service` doesn't retroactively alter delivery history)
  - `status TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','sent','failed'))`
  - `provider_message_id TEXT NULL` — id returned by the transactional email provider
  - `error TEXT NULL` — last error message, when `status = 'failed'`
  - `attempts INT NOT NULL DEFAULT 0`
  - `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`
  - `sent_at TIMESTAMPTZ NULL`
  - Index: `(status) WHERE status IN ('pending','failed')` for a lightweight retry sweep.

### Migrations (`database/migrations/`, goose)

```
00001_create_notifications.sql
00002_create_notification_preferences.sql
00003_create_email_deliveries.sql
```

`00001_create_notifications.sql`:
```sql
-- +goose Up
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE notifications (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id   UUID NOT NULL,
    user_id        UUID NOT NULL,
    category       TEXT NOT NULL CHECK (category IN (
                       'mention', 'channel_message', 'dm',
                       'spec_approved', 'design_approved', 'tasks_approved', 'task_done'
                   )),
    source_type    TEXT NOT NULL CHECK (source_type IN ('message', 'feature', 'task')),
    source_id      TEXT NOT NULL,
    feature_id     TEXT NULL,
    task_id        TEXT NULL,
    summary        TEXT NOT NULL,
    link           TEXT NOT NULL,
    actor_user_id  UUID NULL,
    read_at        TIMESTAMPTZ NULL,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_notifications_feed
    ON notifications (workspace_id, user_id, created_at DESC);

CREATE INDEX idx_notifications_feed_category
    ON notifications (workspace_id, user_id, category, created_at DESC);

CREATE INDEX idx_notifications_unread
    ON notifications (user_id, workspace_id)
    WHERE read_at IS NULL;

-- +goose Down
DROP TABLE IF EXISTS notifications;
```

`00002_create_notification_preferences.sql`:
```sql
-- +goose Up
CREATE TABLE notification_preferences (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id        UUID NOT NULL,
    workspace_id   UUID NOT NULL,
    category       TEXT NOT NULL CHECK (category IN (
                       'mention', 'channel_message', 'dm',
                       'spec_approved', 'design_approved', 'tasks_approved', 'task_done'
                   )),
    in_app_enabled BOOLEAN NOT NULL DEFAULT true,
    email_enabled  BOOLEAN NOT NULL DEFAULT false,
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (user_id, workspace_id, category)
);

-- +goose Down
DROP TABLE IF EXISTS notification_preferences;
```

`00003_create_email_deliveries.sql`:
```sql
-- +goose Up
CREATE TABLE email_deliveries (
    id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    notification_id     UUID NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
    to_email            TEXT NOT NULL,
    status              TEXT NOT NULL DEFAULT 'pending'
                            CHECK (status IN ('pending', 'sent', 'failed')),
    provider_message_id TEXT NULL,
    error               TEXT NULL,
    attempts            INT NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    sent_at             TIMESTAMPTZ NULL
);

CREATE INDEX idx_email_deliveries_retry
    ON email_deliveries (status)
    WHERE status IN ('pending', 'failed');

-- +goose Down
DROP TABLE IF EXISTS email_deliveries;
```

Note: `workspace_id`, `user_id`, and `actor_user_id` are UUIDs matching `user-service`'s /
`workflow-backend`'s existing identifiers, but this DB holds **no foreign keys** across service
boundaries — `notification-service` does not share a Postgres instance with `user-service` or
`workflow-backend`, so referential integrity to `users`/`workspaces` is enforced at the
application layer (the producer-facing API validates `workspace_id`/`user_id` shape, not
existence — matching the loosely-coupled, service-per-database pattern already used between
`workflow-backend` and `user-service` today).

**Producer-facing API** (service-token auth, called by `hermes-agent` and `agent-workflow`):
- `POST /internal/notifications` — `{workspace_id, user_id, category, source_type, source_id,
  feature_id?, task_id?, summary, link, actor_user_id?}`. The service checks
  `notification_preferences` for that `(user_id, workspace_id, category)` before inserting —
  if `in_app_enabled` is false, no `notifications` row is inserted; if `email_enabled` is true,
  the service additionally resolves the recipient's email via `userlookup` (see below), inserts
  an `email_deliveries` row, and enqueues the send. Both checks happen in this one call — this
  is the single preference-gate chokepoint referenced in the product spec's open question;
  gating happens here, not in each producer. Returns 200 whether or not anything was inserted
  (no-op is not an error).
- `POST /internal/notifications/bulk` — same shape, array body, for fan-out to N channel/thread
  members in one call (used by hermes-agent when a channel message needs to notify every member
  except the author).

**Email sending** (`internal/email/`):
- `EmailSenderPort` interface — `Send(ctx, to, subject, body) (providerMessageID string, err
  error)` — one adapter implementation calling the chosen transactional provider's HTTP API
  (see Option E above) with the API key from `.env`.
- Sends are processed **asynchronously** relative to the producer's HTTP call: the producer-
  facing endpoint inserts the `email_deliveries` row as `pending` and returns immediately; an
  **in-process worker loop** (same `notification-service` binary — not a separate deployable,
  unlike `workspace-github-adapter`'s dual-binary pattern) performs the actual provider call and
  updates `status`/`provider_message_id`/`error`/`sent_at`. This satisfies the "must not block
  the producer's fire-and-forget call" constraint without requiring a message queue or a second
  service for v1.

#### Worker design (`internal/email/worker.go`)

- **Lifecycle**: started as a goroutine from `cmd/server/main.go` alongside the Gin HTTP server
  (same process, same `api` subcommand) — not a separate `cmd/worker/main.go` binary. If v1 load
  ever requires horizontal scaling of the worker independent of the API, splitting it into its
  own `cmd/worker/main.go` (mirroring `workspace-github-adapter`'s `adapter-worker`) is a
  straightforward follow-up; the query pattern below is already safe for that.
- **Trigger**: a `time.Ticker` polling every `EMAIL_WORKER_POLL_INTERVAL` (env-configurable,
  default 5s) — no push/pubsub needed since email is not latency-critical.
- **Claim query** — to be safe even if `notification-service` is ever run with >1 replica (so
  the design doesn't silently break under horizontal scaling later), each tick claims a batch
  with `SELECT ... FOR UPDATE SKIP LOCKED`, not a plain unlocked `SELECT`:
  ```sql
  SELECT id, notification_id, to_email, attempts
  FROM email_deliveries
  WHERE status IN ('pending', 'failed') AND attempts < 5
  ORDER BY created_at
  LIMIT 20
  FOR UPDATE SKIP LOCKED;
  ```
  This runs inside a transaction; claimed rows are immediately marked with an `attempts + 1`
  update before the provider call, so a crash mid-send does not cause an infinite same-row retry
  loop within one tick.
- **Send + update**: for each claimed row, call `EmailSenderPort.Send`; on success set
  `status = 'sent'`, `provider_message_id`, `sent_at = now()`; on error set `status = 'failed'`,
  `error = <message>` and leave `attempts` incremented (already done in the claim step) so the
  next tick's `WHERE attempts < 5` naturally stops retrying once the cap is hit.
- **Backoff**: none beyond the fixed poll interval for v1 — a failed row is simply eligible again
  on the very next tick (bounded by the `attempts < 5` cap, so worst case is 5 sends across
  ~5 × poll-interval seconds). Exponential backoff is a follow-up if provider rate-limiting
  becomes an issue; not needed for v1's stated scope.
- **Batch size** (`LIMIT 20`) and **poll interval** (5s) are both env-configurable constants, not
  hardcoded, so ops can tune them without a code change.
- **Terminal failure**: after `attempts` reaches 5, the row stays `failed` and is excluded from
  future claims (`attempts < 5` no longer matches) — left for manual/ops inspection via direct
  DB query. No dead-letter queue or alerting in v1, matching the product spec's non-goal of deep
  deliverability hardening.
- **Shutdown**: the worker goroutine listens on the same context/signal handling `main.go`
  already uses to stop the HTTP server, so `SIGTERM` stops new ticks but lets an in-flight batch
  finish before exit (no half-sent batches abandoned mid-transaction).

- Template: one plain-text/simple-HTML template per category (7 templates), rendered from the
  same `summary`/`link`/`feature_id`/`task_id` fields already stored on the `notifications` row
  — no separate template-data model.

**`userlookup`** (`internal/userlookup/`):
- Thin service-token HTTP client to `user-service`'s existing internal user-lookup surface
  (`internal/handler/workspace.go:Handler.ListUsersByIDs` shape — resolve `user_id → email` by
  ID). No email address is stored redundantly in `notification-service`'s own tables outside of
  the point-in-time snapshot in `email_deliveries.to_email` (kept only as delivery-history
  evidence, never used as a live source of truth for the next send).

**User-facing API** (cookie/session auth via `workflow-bff`, matching the `user-service` /
`workflow-backend` auth boundary pattern):
- `GET /api/notifications?view=all|dms|mentions&status=unread|all` — powers the Activity panel's
  three tabs.
- `POST /api/notifications/:id/read` and `POST /api/notifications/read-all`.
- `GET /api/notifications/unread-count` — extends, not replaces, the existing
  `useWorkspaceUnreadCount`/`getUnreadMentions` nav-rail badge; the nav rail calls this endpoint
  in addition to (or as a superset of) the existing mention-only count.
- `GET /api/notification-preferences` / `PUT /api/notification-preferences` — the per-user
  settings screen. Preferences are now two-dimensional (channel × category): each category row
  in the UI shows an **In-app** toggle and an **Email** toggle (Mentions / Channel messages /
  DMs / Feature lifecycle approvals / Task done × {In-app, Email}).

### Producer integration points

**`hermes-agent`** (mentions, DMs, channel messages):
- `src/services/author_resolver.py` / `src/db/store.py:persist_mentions` already resolves
  mentioned users when a message is saved. Add a call to
  `POST /internal/notifications(/bulk)` right after `persist_mentions` / `append_message` in
  `src/db/store.py`, keyed off `MessageMention` rows for `mention`, off `session_members` for
  `channel_message`, and off DM session type (per `agent-general-chat`) for `dm`. This is an
  additive fire-and-forget HTTP call from the existing message-write path — no schema change to
  `hermes-agent`'s own tables.

**`agent-workflow` orchestrator** (feature lifecycle approvals, task done):
- Reuse the existing `NotificationPort` shape: add a second implementation,
  `InAppNotificationAdapter` (parallel to the Slack adapter), that calls
  `POST /internal/notifications`. Wire it at the same trigger points already instrumented for
  Slack:
  - `src/feature/notification-watcher.ts:runFeatureNotificationStep` — extend to detect
    `product_spec`/`technical_design`/`tasks` stage transitions to `approved` (read from
    `status.yaml`, the same source `handoff-trigger.ts:readProductSpecSummary` already reads)
    and emit `spec_approved` / `design_approved` / `tasks_approved` categories to the feature's
    members/owner.
  - `src/feature/check-tasks-done.ts` — extend the existing task-done detection (already used
    for `handleFeatureDone`) to also emit a `task_done` category notification to the task's
    assignee/owner (`execution.last_updated_by` / task log author) via the new adapter.
- This reuses the orchestrator's existing poll cycle and status-detection logic — no new
  polling loop, just a second `NotificationPort` consumer registered alongside Slack.

**"Who is watching" resolution** (per product-spec open question):
- Feature-level notifications (spec/design/tasks approved) fan out to the feature's session
  members in its `hermes-agent` feature thread (the existing `SessionMember` set is already the
  membership model for "who is part of this feature's conversation").
- Task-done notifications fan out to the task's assignee (`execution.last_updated_by` in the
  task YAML) plus whoever is recorded as having claimed/worked it in the task `log`.

### Frontend (`digital-factory-ui`)
- New `Activity` nav-rail entry (alongside Channels, Team Chat) rendering three tabs — All, DMs,
  Mentions — backed by `GET /api/notifications`.
- New `src/services/notification-service/client.ts` + `useNotifications` /
  `useNotificationPreferences` hooks (TanStack Query), following the same client/hook pattern as
  `src/services/workflow-backend/client.ts` / `useActivity`.
- New **Notification Settings** section (Settings page) backed by
  `GET/PUT /api/notification-preferences` — a per-category row with independent In-app / Email
  toggles.
- Nav-rail unread badge switches to (or merges with) `GET /api/notifications/unread-count`.

## Dependency Analysis

- `notification-service` must exist (repo scaffolded, migrated, deployed, registered in
  `workspace.yaml`) before any producer integration work can land — it is the hard dependency
  root.
- `hermes-agent` producer wiring and `agent-workflow` producer wiring are independent of each
  other (different repos, different trigger points) and can proceed in parallel once the
  service's producer-facing API is live.
- `digital-factory-ui` read-side work (Activity panel, settings page) depends only on the
  user-facing API being live — it does not depend on producer wiring being complete (it can be
  built/tested against seeded data), but end-to-end verification needs at least one producer
  wired.
- No changes required to `workflow-backend`'s existing `workspace_activity_events` /
  `ListActivity` — left untouched, per the "must not change Slack/audit behavior" constraint.
- Email sending depends on `userlookup` reaching `user-service`'s internal API — if
  `user-service` is unreachable, the affected `email_deliveries` row is retried (marked
  `failed`, picked up by the next worker sweep) rather than blocking the in-app notification,
  which is already inserted independently.

## Parallelization / Blocking Analysis

- **Wave 1 (parallel):** scaffold `notification-service` (repo, schema, migrations,
  producer + user-facing API, service-token auth) — this is the single blocking task for
  everything else.
- **Wave 2 (parallel once Wave 1 lands):**
  - `hermes-agent`: wire mention/DM/channel-message fan-out calls into
    `persist_mentions`/`append_message`.
  - `agent-workflow`: add `InAppNotificationAdapter`, wire stage-approval and task-done trigger
    points.
  - `digital-factory-ui`: Activity panel (All/DMs/Mentions tabs), unread badge, notification
    settings page — can be built against the user-facing API with seeded/mock data in parallel
    with Wave 2's producer work.
- **Wave 3:** end-to-end verification once at least one producer (recommend `agent-workflow`,
  since it's the simplest integration — reuses `NotificationPort`) is wired, followed by the
  second producer.
