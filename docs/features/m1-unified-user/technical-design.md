# Technical Design

## Feature
- Feature ID: `m1-unified-user`
- Title: Unified User Identity

---

## 1. Current State

### What exists

`user-service` (Go + Gin + pgx, `alexedwards/scs/v2` sessions) was established by `m1-identity-and-workspaces`. The relevant schema (v001, `database/user-service/schema.dbml`) is:

```sql
Table users {
  id           uuid        [primary key]
  email        text        [not null]   -- NOT unique; index on lower(email) only
  display_name text
  avatar_url   text
  created_at   timestamptz
  updated_at   timestamptz
}

Table auth_identities {
  id             uuid        [primary key]
  user_id        uuid        [ref: > users.id]
  provider       text        -- 'google' | 'github'
  provider_sub   text        -- IdP stable user id
  email          text
  email_verified boolean
  created_at     timestamptz

  indexes { (provider, provider_sub) [unique] }
}
```

The schema note on `users.email` reads: *"Last-known primary email; not unique (linked identities can share)"*. There is a non-unique index `idx_users_email_lower` on `lower(email)` but **no unique constraint**.

### Current OAuth callback behavior

The `/auth/<provider>/callback` handler in `user-service`:
1. Exchanges the code for a token with the IdP.
2. Fetches user info (email, sub) from the IdP.
3. Looks up `auth_identities` by `(provider, provider_sub)`.
4. If the identity **does not exist**, it creates a **new `users` row** (new UUID), then inserts the `auth_identity` linked to it.
5. If the identity **exists**, it uses the existing `users` row.

Step 4 is the bug: a user who signs in with Google first, then GitHub (same email), gets two separate `users` rows with different UUIDs. All downstream identity (organization memberships, workspace memberships, sessions) is scoped by `user_id`, so those two accounts are completely siloed.

### Current limitations

- **No email uniqueness** — `users.email` allows duplicate values; the database will not catch a double-registration.
- **No cross-provider account linking by email** — the callback does not attempt to find an existing user by email before creating a new one.
- **No `username` field** — the profile model has `display_name` and `avatar_url` but no stable user-chosen identifier.
- **No profile update endpoint** — `GET /api/me` is read-only; there is no `PATCH /api/me` surface.

### Repo/system boundaries

| Repo | Role |
|---|---|
| `user-service` | Owns identity — `users`, `auth_identities`, sessions, OAuth flows. All changes land here. |
| `management-repo` | Owns canonical schema docs in `database/user-service/`. Schema must be versioned here before implementation. |
| `digital-factory-ui` | Consumes `GET /api/me`. Will gain a profile settings page once the API surface is in place. |
| `workflow-backend` | Unaffected — validates sessions via `/internal/sessions/validate`; the returned `user_id` becomes canonical after the merge. |

---

## 2. Problem Framing

### What must change

1. **Email uniqueness** — `users.email` must become a UNIQUE column (case-insensitive, enforced via a unique index on `lower(email)`). Duplicate rows must be merged before the constraint is applied.
2. **Lookup-or-create by email** — the OAuth callback must search for an existing `users` row by email before creating a new one. If a user with the same email exists (from a different provider), the new `auth_identity` is linked to the existing user, not a new row.
3. **Data migration for existing duplicates** — existing `users` rows that share the same `lower(email)` must be merged into one canonical row. All dependent records (`auth_identities`, `memberships`, `workspace_memberships`) must be repointed to the surviving row.
4. **`username` field** — add a nullable, unique `username` column to `users`. Case-insensitive uniqueness enforced via a partial unique index on `lower(username) WHERE username IS NOT NULL`. During the migration, backfill `username` from `display_name` for all existing users: lowercase, replace spaces with `_`, strip non-alphanumeric characters (except `_` and `-`), truncate to 30 characters, and append a numeric suffix if the result collides with an existing username. Users may update their username later via the profile API.
5. **Profile update API** — add `PATCH /api/me` to let authenticated users update `display_name`, `username`, and `avatar_url`.
6. **Profile UI** — a settings page in `digital-factory-ui` where a signed-in user can view and update their profile fields.

### What must stay stable

- `users.id` UUID values for surviving rows — downstream services reference `user_id` by UUID; only duplicate rows are retired, the surviving row keeps its original UUID.
- The `(provider, provider_sub)` unique index on `auth_identities` — unchanged.
- `GET /api/me` response shape — new fields are additive and non-breaking.
- Session continuity for users whose `user_id` survives the merge — not logged out.

### Fixed assumptions

- Email is the canonical identity anchor. Two accounts with the same email are the same person.
- Only OAuth providers are in scope (Google, GitHub). No email/password auth.
- `user-service` is Go + Gin + pgx + goose migrations (same stack as `m1-identity-and-workspaces`).
- The merge migration must be idempotent and wrapped in a transaction.
- Sessions belonging to retired duplicate user rows become invalid naturally — acceptable at M1 user scale.

---

## 3. Options Considered

### Option A — Email uniqueness: unique index on `lower(email)` (DB-layer enforcement)

**What:** Run a dedup migration first, then add `CREATE UNIQUE INDEX idx_users_email_lower_unique ON users (lower(email))`. Drop the existing non-unique index after.

**Pros:** Enforced at the DB layer; application bugs cannot produce duplicates post-migration. Standard Postgres pattern.

**Cons:** Requires a one-time dedup migration that must succeed before the index is created. If the dedup is wrong, the index creation fails (which is safe — it surfaces the issue rather than hiding it).

**Selected.**

---

### Option B — Application-layer guard only (no DB constraint)

**What:** Keep `email` non-unique; add a pre-insert check in application code.

**Pros:** No migration, no schema change.

**Cons:** Race condition between two concurrent first-logins for the same email — both pass the application check before either inserts. Provides no protection against future direct DB writes or migrations.

**Rejected.** The DB constraint is the only reliable guard.

---

### Option C — Username required at first login

**What:** Block sign-in completion until the user sets a username.

**Pros:** Every user always has a username from day one.

**Cons:** Adds friction; out of scope per the product spec (username is optional, settable later).

**Rejected.**

---

### Option D — Separate `/api/me/profile` endpoint for profile updates

**What:** `PATCH /api/me/profile` instead of `PATCH /api/me`.

**Pros:** Clear resource separation.

**Cons:** `PATCH /api/me` is the REST-standard approach for partial updates to the authenticated user resource. Extra URL segment adds no value.

**Rejected.** `PATCH /api/me` is idiomatic and sufficient.

---

## 4. Chosen Design

### Schema v002 changes

```sql
-- Step 1: add username
ALTER TABLE users ADD COLUMN username text;
CREATE UNIQUE INDEX idx_users_username_lower
  ON users (lower(username))
  WHERE username IS NOT NULL;

-- Step 2: backfill username from display_name for all existing users
--   Derivation rule (applied per row in application code or a PL/pgSQL block):
--     1. lower(display_name)
--     2. replace spaces with '_'
--     3. strip characters that are not [a-z0-9_-]
--     4. truncate to 30 characters
--     5. if the result collides with an already-assigned username, append '_2', '_3', … until unique
--   Users with a null or empty display_name get a null username (they will be prompted to set one via the UI).
UPDATE users
SET username = <derived_slug>   -- implemented in a goose Go migration, not raw SQL
WHERE display_name IS NOT NULL AND display_name <> '';

-- Step 3: dedup migration (inside a transaction)
--   For each group sharing lower(email), keep the row with the oldest created_at.
--   Repoint auth_identities, memberships, workspace_memberships to the canonical user_id.
--   Delete retired user rows.
--   Delete sessions that reference retired user_ids (scs stores user_id in session data).

-- Step 5: enforce email uniqueness
DROP INDEX idx_users_email_lower;
CREATE UNIQUE INDEX idx_users_email_lower_unique ON users (lower(email));
```

The v002 schema snapshot lives at `database/user-service/v002/schema.dbml`. The top-level `database/user-service/schema.dbml` is updated to reflect the final shape.

### OAuth callback — lookup-or-create by email

After fetching IdP user info (email, sub), the handler follows this decision tree inside a serializable transaction:

```
1. SELECT * FROM auth_identities WHERE provider = $1 AND provider_sub = $2
   → found:  use identity.user_id  [returning visitor, same provider]

2. Not found → SELECT * FROM users WHERE lower(email) = lower($idp_email)
   → found:  INSERT auth_identity (provider, provider_sub, …) → existing user_id
             [new provider, same email — link it]

3. Neither found → INSERT users (email, …)
                   INSERT auth_identity → new user_id
                   [brand new user]
```

The serializable isolation level on steps 2–3 prevents two concurrent sign-ins for the same new email from both entering step 3 and creating duplicate rows — one will see the other's insert and retry.

### Profile update API

```
PATCH /api/me
Authorization: session cookie

Body (all fields optional):
{ "display_name": "...", "username": "kite_pye", "avatar_url": "https://..." }

200: updated /api/me payload
409: username already taken
422: validation error (e.g. username format)
```

`username` rules: lowercase alphanumeric + hyphens, 3–30 characters. Normalized to lowercase before storage.

### `GET /api/me` — updated response shape

```json
{
  "id": "...",
  "email": "...",
  "display_name": "...",
  "username": null,
  "avatar_url": "...",
  "linked_providers": ["google"],
  "created_at": "..."
}
```

`username` (nullable) and `linked_providers` (array of provider strings from `auth_identities`) are additive, non-breaking additions.

### Profile settings UI (`digital-factory-ui`)

A settings page (route TBD by frontend — `/settings/profile` or equivalent) with:
- Read: populate form from `GET /api/me`.
- Write: submit changed fields via `PATCH /api/me`.
- Inline validation for username format; surface 409 as "username already taken".
- Linked providers section (read-only in M1, showing which OAuth providers are connected).

---

## 5. Dependency Analysis

### Internal

- **T1 → T2**: Schema docs (`management-repo`) must be written and reviewed before the SQL migration is implemented in `user-service`. The schema is the contract.
- **T2 → T3**: The lookup-or-create OAuth logic depends on the unique email constraint being applied — without it, the dedup guarantee is absent and concurrent sign-ins can still create duplicates.
- **T2 → T4**: `PATCH /api/me` needs the `username` column to exist (added in v002).
- **T4 → T5**: The profile UI depends on `PATCH /api/me` being deployed and reachable.

### External

- No new OAuth App registrations — callback URL and scopes are unchanged.
- No new infrastructure — all changes are within the existing `user-service` process and its Postgres instance.

### Unresolved decisions (must be resolved before T2 implementation)

- **D1 — Session invalidation on merge:** Should the migration actively delete sessions for retired `user_id` values, or rely on natural expiry? Active deletion is cleaner; it requires parsing scs session payloads in the migration to match on `user_id`. **Recommended: active deletion** — add a `DELETE FROM sessions WHERE …` step inside the transaction. Confirm with the team before T2.
- **D2 — Canonical user selection on merge:** When two users share an email, which UUID survives? **Recommended: oldest `created_at`** (first registration wins). Confirm before T2.

---

## 6. Parallelization / Blocking Analysis

```
T1: Schema docs v002 (management-repo)
  └── Can begin now — no blockers
  │
  T2: Migration v002 + data dedup (user-service)
      └── BLOCKED on T1 (schema must be finalized in docs before SQL is written and applied)
      │
      T3: OAuth lookup-or-create by email (user-service)   ── parallel with T4
      T4: PATCH /api/me profile endpoint (user-service)   ── parallel with T3
          └── BLOCKED on T2 (unique email constraint + username column must exist in DB)
          └── T3 and T4 run in parallel
          │
          T5: Profile settings UI (digital-factory-ui)
                └── BLOCKED on T4 (PATCH /api/me must be deployed and reachable)
```

---

## 7. Repository Impact

| Repo | Changes |
|---|---|
| `management-repo` | `database/user-service/v002/schema.dbml` (new). `database/user-service/schema.dbml` updated (username, unique email index). |
| `user-service` | Migration `v002.sql` (dedup + username + unique index). OAuth callback handler (lookup-or-create). `PATCH /api/me` handler. `/api/me` response struct updates. |
| `digital-factory-ui` | Profile settings page. `PATCH /api/me` client call. Username/display name/avatar form. |
| `workflow-backend` | No changes. |
| `workspace-github-adapter` | No changes. |

---

## 8. Validation and Release Impact

### Testing

- **Unit tests (user-service):** OAuth callback — all three branches (existing identity, new identity same email, brand new user). `PATCH /api/me` — success, username 409 conflict, 422 format error.
- **Migration test:** Run the dedup migration against a copy of production data before applying to any live environment. Verify: no duplicate emails remain; all `auth_identities` repoint correctly; retired row count matches expectation.
- **Integration test:** Sign in with Google, then with GitHub using the same email → assert `GET /api/me` returns the same `id` for both sessions.

### Migration impact

- v002 is **non-reversible in practice** (dedup deletes rows). The goose `Down` migration must document this and refuse to run if it would reintroduce duplicates.
- Run during a maintenance window or with the auth callback behind a feature flag.
- Sessions for retired user rows expire naturally. Affected users see a session-expired prompt and re-authenticate — acceptable at M1 scale.

### Backward compatibility

- `GET /api/me` gains `username` (nullable) and `linked_providers` (array). Both are additive. No existing consumer breaks.
- Surviving `user_id` UUIDs are unchanged. Retired UUIDs are gone. Any hard-coded test fixtures referencing a retired UUID will see a missing user — verify before migrating staging.

### Rollout order

1. **T1** (management-repo schema docs) — reviewed and merged first.
2. **T2** (migration) — apply to dev, then staging, then production.
3. **T3 + T4** (callback logic + profile API) — deploy atomically with or after T2. T3 before T2 leaves the unique constraint absent; T4 before T2 references a missing column. Both must wait for T2.
4. **T5** (profile UI) — can deploy independently once T4 is live.
