# Technical Design

## Feature
- Feature ID: `test-feature-3`
- Title: User Notification Preferences

## Current State

The platform currently delivers notifications (in-app, email, push) to all users uniformly. There is no per-user preference store and no UI for users to manage which notifications they receive or through which channels.

Key observations (unresolved — GitNexus indexer offline at design time):
- No `notification_preferences` table exists in the database (assumed — to be confirmed)
- The notification dispatch service (assumed to exist) does not consult per-user preferences before sending
- There is no preferences page or section in the user settings UI
- Critical notifications (security, billing) are sent unconditionally

> **Open question:** The exact names and locations of the notification dispatch service, user settings UI component, and existing database schema could not be confirmed — GitNexus and RAG returned no results. These must be verified during implementation.

## Constraints

- Must use the existing notification delivery infrastructure (no new delivery service)
- SMS and webhook channels are out of scope for this iteration
- Security-category notifications must be non-disableable (enforced server-side, not just UI)
- Preferences must be stored per-user and synced across sessions/devices (i.e. server-side persistence, not localStorage)
- The preferences UI must be reachable from the existing user settings page

## Options Considered

### Option A — Flat preference flags per channel per category (chosen)
Store one boolean flag per `(user_id, category, channel)` triple. Simple schema, easy to query, maps directly to checkbox-style UI.

- Pros:
  - Simple, flat schema — easy to read/write atomically
  - Each preference is independently toggle-able
  - Straightforward enforcement at dispatch time (single lookup per `(category, channel)`)
  - Easy to add new categories or channels without schema migrations
- Cons:
  - Can result in many rows per user if categories × channels grows large
  - No concept of "channel priority" or ordering

### Option B — JSON blob per user
Store a single JSONB column on the users table (or a companion table) containing the full preferences object.

- Pros:
  - Flexible schema, easy to extend with new fields
  - Single row per user — simple upsert
- Cons:
  - Harder to query individual preferences server-side (requires JSON path extraction)
  - Enforcement at dispatch time requires deserialising the full blob
  - Schema is implicit — harder to validate and document

## Chosen Design

**Option A** — flat preference flags per `(user_id, category, channel)` triple.

### Data model

```sql
CREATE TABLE notification_preferences (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  category      TEXT NOT NULL,   -- e.g. 'security', 'billing', 'product_updates', 'activity'
  channel       TEXT NOT NULL,   -- e.g. 'in_app', 'email', 'push'
  enabled       BOOLEAN NOT NULL DEFAULT TRUE,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, category, channel)
);
```

**Hardcoded non-disableable categories** (enforced server-side):
- `security`

### API

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/api/v1/users/me/notification-preferences` | Return all preferences for the authenticated user |
| `PUT`  | `/api/v1/users/me/notification-preferences` | Replace the full preference set (upsert) |
| `PATCH`| `/api/v1/users/me/notification-preferences/:category/:channel` | Toggle a single preference |

The `GET` endpoint returns defaults (all enabled) for preferences not yet stored — no row needed until the user changes something.

### Enforcement at dispatch time

Before dispatching a notification, the notification service must:
1. Look up `notification_preferences` for `(user_id, category, channel)`.
2. If a row exists with `enabled = false`, skip dispatch for that channel.
3. If `category = 'security'`, always dispatch regardless of stored preference.

### UI

A new **Notification Preferences** section is added to the existing User Settings page. It renders a matrix of toggles: rows = categories, columns = channels. Security row toggles are rendered as disabled (checked + greyed out) with a tooltip explaining they cannot be turned off.

## Dependency Analysis

| Dependency | Detail |
|---|---|
| `users` table | `notification_preferences.user_id` references it — must confirm exact table name and schema |
| Notification dispatch service | Must be updated to consult preferences before sending — exact service name TBD (GitNexus offline) |
| User settings UI component | New section to be added — exact component name/path TBD |
| Authentication middleware | `GET`/`PUT`/`PATCH` endpoints require authenticated user context |

> **Open questions (to resolve before implementation starts):**
> 1. What is the exact name and repo of the notification dispatch service?
> 2. What is the exact component name and file path of the User Settings page?
> 3. Does a `users` table with a UUID primary key already exist in the database?
> 4. What is the database migration tooling used (e.g. Flyway, Liquibase, raw SQL, Alembic)?
> 5. Are there existing category/channel enum types that should be reused?

## Parallelization / Blocking Analysis

Tasks can be broken into the following parallel tracks once the open questions above are resolved:

```
T1: DB migration (notification_preferences table)
  └── T2: Backend API (GET / PUT / PATCH endpoints)        [depends on T1]
        └── T3: Dispatch enforcement (notification service) [depends on T1]
  └── T4: Frontend UI (Notification Preferences section)   [depends on T2]
```

- **T1** (DB migration) is the root dependency — everything else unblocks after it.
- **T2** (backend API) and **T3** (dispatch enforcement) can proceed in parallel once T1 is done.
- **T4** (frontend UI) can begin integration once T2's API contract is defined (can start with mocks before T2 merges).
