
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
  notification or preference data today.

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

## Chosen Design

### New repo: `notification-service`

`git@github.com:tiendv89/notification-service.git` — Go 1.22+, following the `go-microservice`
template used by `user-service`:

```
notification-service/
  cmd/server/main.go            # HTTP entrypoint (cobra: api, migration subcommands)
  configs/                      # viper config, env overrides
  internal/
    httpapi/                    # gin routes
    notifications/              # domain: create, list, mark-read, fan-out-gate logic
    preferences/                # per-user category on/off settings
    serviceauth/                # service-token middleware for producer-facing endpoints
  database/
    schema.dbml
    migrations/                 # pressly/goose/v3
  Dockerfile
  go.mod / go.sum
```

**Data model** (new Postgres DB, `notification_db`):
- `notifications` — `id`, `workspace_id`, `user_id` (recipient), `category`
  (`mention` | `channel_message` | `dm` | `spec_approved` | `design_approved` |
  `tasks_approved` | `task_done`), `source_type` (`message` | `feature` | `task`), `source_id`,
  `feature_id` (nullable), `task_id` (nullable), `summary` (short text for the feed row),
  `link` (deep link back to the thread/feature/task), `actor_user_id` (who caused it, nullable
  for system events), `read_at` (nullable), `created_at`.
- `notification_preferences` — `user_id`, `workspace_id`, `category`, `enabled` (bool, default
  true) — one row per (user, workspace, category); absence of a row means default-on.

**Producer-facing API** (service-token auth, called by `hermes-agent` and `agent-workflow`):
- `POST /internal/notifications` — `{workspace_id, user_id, category, source_type, source_id,
  feature_id?, task_id?, summary, link, actor_user_id?}`. The service checks
  `notification_preferences` for that `(user_id, workspace_id, category)` before inserting —
  if the user has the category disabled, the call is a no-op (200, not inserted). This is the
  single preference-gate chokepoint referenced in the product spec's open question — gating
  happens here, not in each producer.
- `POST /internal/notifications/bulk` — same shape, array body, for fan-out to N channel/thread
  members in one call (used by hermes-agent when a channel message needs to notify every member
  except the author).

**User-facing API** (cookie/session auth via `workflow-bff`, matching the `user-service` /
`workflow-backend` auth boundary pattern):
- `GET /api/notifications?view=all|dms|mentions&status=unread|all` — powers the Activity panel's
  three tabs.
- `POST /api/notifications/:id/read` and `POST /api/notifications/read-all`.
- `GET /api/notifications/unread-count` — extends, not replaces, the existing
  `useWorkspaceUnreadCount`/`getUnreadMentions` nav-rail badge; the nav rail calls this endpoint
  in addition to (or as a superset of) the existing mention-only count.
- `GET /api/notification-preferences` / `PUT /api/notification-preferences` — the per-user
  settings screen (Mentions / Channel messages / DMs / Feature lifecycle approvals / Task done).

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
  `GET/PUT /api/notification-preferences`.
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
