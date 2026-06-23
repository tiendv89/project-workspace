# Task Breakdown — m1-unified-user

Feature status: `in_tdd` → `ready_for_implementation` (pending tasks approval)
Stage: `tasks` (draft)
Machine state lives in `tasks/T<n>.yaml` — do not add status/log fields here.

## Index

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | Migration v002 — email unique + username backfill + dedup | — |
| T2 | 2 | OAuth callback — lookup-or-create by email | T1 |
| T3 | 2 | Profile update API — PATCH /api/me | T1 |
| T4 | 3 | Profile settings UI | T3 |

---

## T1 — Migration v002 — email unique + username backfill + dedup

### Description

Write and apply the `user-service` v002 database migration. This migration is the foundation for all other tasks — it enforces the invariants that allow safe account linking and profile management.

The migration must run in a single transaction and perform these steps in order:

1. `ALTER TABLE users ADD COLUMN username text`
2. `CREATE UNIQUE INDEX idx_users_username_lower ON users (lower(username)) WHERE username IS NOT NULL`
3. **Backfill username from display_name** for all existing rows where `display_name` is non-null and non-empty:
   - `lower(display_name)` → replace spaces with `_` → strip `[^a-z0-9_-]` → truncate to 30 chars
   - On collision: append `_2`, `_3`, … until unique
   - Rows with null/empty `display_name` get `username = null`
4. **Dedup users by email** (per D2: keep oldest `created_at`):
   - For each group sharing `lower(email)`, designate the oldest row as canonical
   - `UPDATE auth_identities SET user_id = <canonical_id> WHERE user_id = <retired_id>`
   - `UPDATE memberships SET user_id = <canonical_id> WHERE user_id = <retired_id>` (skip if `(canonical_id, organization_id)` already exists)
   - `UPDATE workspace_memberships SET user_id = <canonical_id> WHERE user_id = <retired_id>` (skip if duplicate)
   - **Profile merge (D3):** `UPDATE users SET display_name = COALESCE(newer.display_name, canonical.display_name), avatar_url = COALESCE(newer.avatar_url, canonical.avatar_url) WHERE id = canonical_id`
   - `DELETE FROM sessions WHERE token IN (SELECT token FROM sessions WHERE <payload references retired_user_id>)` (active session deletion per D1)
   - `DELETE FROM users WHERE id = <retired_id>`
5. `DROP INDEX idx_users_email_lower`
6. `CREATE UNIQUE INDEX idx_users_email_lower_unique ON users (lower(email))`

Use a goose Go migration (not a raw SQL migration) for steps 3 and 4 — the collision-handling and session-payload parsing require application logic.

Known existing duplicate to handle:
- Canonical: `aa0b1ee9-ad02-4099-9a07-297390316692` (GitHub, `pye`, 2026-06-06)
- Retired: `02417639-bfec-422e-8889-099554e33186` (Google, `Duc Tran`, 2026-06-23)
- After merge: `aa0b1ee9` has both providers linked; display_name becomes `Duc Tran`, avatar becomes Google avatar, username stays `pye`

Test the migration against a DB snapshot before applying to staging or production. Verify: no duplicate emails remain; auth_identities correctly repointed; session count for retired IDs is zero.

### Required skills

- go-best-practices
- postgres-best-practices

### Subtasks

- [ ] Write goose Go migration file `v002_unified_user.go`
- [ ] Step 1–2: add `username` column + unique index
- [ ] Step 3: backfill username from display_name (Go logic, collision-safe)
- [ ] Step 4: dedup users — repoint dependents, apply D3 profile merge, delete sessions, delete retired rows
- [ ] Step 5–6: drop old email index, create unique email index
- [ ] Run migration against dev DB; verify constraints hold
- [ ] Write goose `Down` migration that documents irreversibility and refuses to run if duplicates would re-emerge
- [ ] Test: confirm `aa0b1ee9` now has both Google + GitHub auth_identities and correct profile fields

---

## T2 — OAuth callback — lookup-or-create by email

### Description

Update the `/auth/<provider>/callback` handler in `user-service` to implement the three-step lookup-or-create by email. This prevents new duplicate users from being created after the migration enforces the unique email constraint.

The new decision tree (inside a serializable transaction):

1. `SELECT * FROM auth_identities WHERE provider = $1 AND provider_sub = $2`
   → found: use `identity.user_id` (returning visitor, same provider)
2. Not found → `SELECT * FROM users WHERE lower(email) = lower($idp_email)`
   → found: `INSERT auth_identity` linking new provider to existing `user_id`
3. Neither found → `INSERT users` then `INSERT auth_identity` (new user)

The serializable isolation on steps 2–3 prevents a race between two concurrent first-logins for the same email — one will see the other's insert and retry.

Also update `GET /api/me` response struct to include `username` (nullable) and `linked_providers` (array of provider strings from `auth_identities`).

### Required skills

- go-best-practices

### Subtasks

- [ ] Update OAuth callback handler — replace blind `INSERT users` with 3-step lookup-or-create
- [ ] Wrap steps 2–3 in a serializable transaction
- [ ] Update `GET /api/me` response struct: add `username`, `linked_providers`
- [ ] Unit tests — all three callback branches (existing identity, new identity same email, brand new user)
- [ ] Integration test: sign in Google then GitHub same email → same `user_id` returned by `/api/me`

---

## T3 — Profile update API — PATCH /api/me

### Description

Add a `PATCH /api/me` endpoint to `user-service` that lets an authenticated user update their profile fields: `display_name`, `username`, and `avatar_url`. All fields are optional in the request body.

Behaviour:
- Requires a valid session cookie (`RequireAuth` middleware).
- Only the fields present in the request body are updated (partial update semantics).
- `username` is normalized to lowercase before storage.
- `username` validation: `^[a-z0-9][a-z0-9_-]{1,28}[a-z0-9]$` (3–30 chars, alphanumeric + `_` and `-`, cannot start or end with `_`/`-`).
- Returns `409` if the requested username is already taken.
- Returns `422` on validation error with a field-level error message.
- Returns `200` with the updated `/api/me` payload on success.

### Required skills

- go-best-practices

### Subtasks

- [ ] Add `PATCH /api/me` route and handler
- [ ] Implement partial-update logic (only update fields present in body)
- [ ] Username normalization (lowercase) and format validation
- [ ] Handle unique constraint violation → 409 response
- [ ] Unit tests: success, 409 username conflict, 422 format error, 401 unauthenticated
- [ ] Update API docs / OpenAPI spec if one exists

---

## T4 — Profile settings UI

### Description

Add a profile settings page to `digital-factory-ui` where a signed-in user can view and update their profile. The page reads from `GET /api/me` and submits changes via `PATCH /api/me`.

Fields to display and allow editing:
- Display name
- Username (with inline format hint and conflict error)
- Avatar URL (text input; avatar preview if URL is a valid image)

Additional read-only section:
- Linked providers (e.g. "Google", "GitHub") — shows which OAuth providers are connected to the account. No link/unlink action in M1.

UX requirements:
- Inline validation for username format (client-side, before submit).
- 409 error from the API surfaced as "Username already taken" inline.
- Success state: show a confirmation toast or inline message.
- Page must be behind an auth guard — redirect to login if unauthenticated.

### Required skills

- frontend-engineer
- nextjs-best-practices

### Subtasks

- [ ] Create profile settings page/route (e.g. `/settings/profile`)
- [ ] Fetch and populate form from `GET /api/me`
- [ ] Implement `PATCH /api/me` client call with partial-update payload
- [ ] Username format validation (client-side)
- [ ] Handle 409 "username taken" inline error
- [ ] Avatar URL preview
- [ ] Linked providers read-only section
- [ ] Auth guard — redirect unauthenticated users to login
- [ ] Add link to profile settings in nav/user menu
