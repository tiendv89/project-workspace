# Product Specification

## Feature
- Feature ID: `m1-unified-user`
- Title: Unified User Identity

## Problem

Users who sign in with Google and users who sign in with GitHub are treated as two separate identities in the system, even if they share the same email address. This creates duplicate accounts, fragments user data, and prevents a consistent user experience across auth providers.

There is also no concept of a user profile — no username, avatar, or display name — which limits future personalisation and social features.

## Goals

1. **Unified identity by email** — a user is uniquely identified by their email address regardless of which OAuth provider they authenticate with. Signing in with Google and GitHub from the same email address resolves to the same user record.
2. **OAuth provider linking** — a single user account can have one or more linked OAuth providers (Google, GitHub). The system records which providers are linked to each account.
3. **Profile foundation** — introduce a user profile model with fields for display name, username (unique), and avatar URL. These fields are optional at sign-in and can be set or updated later.
4. **Backwards-compatible migration** — existing users are migrated to the unified model without losing their data or being forced to re-authenticate.

## Non-goals

- Username enforcement at sign-in (username is optional and settable later).
- Social features (follow, mention, etc.) — this spec only lays the data foundation.
- Email/password authentication — only OAuth providers are in scope for this feature.
- Merging accounts with different email addresses.
- Self-service account deletion or provider unlinking (future scope).

## User Stories

- As a user who previously signed in with Google, when I sign in with GitHub using the same email, I see my existing account and data — not a new empty account.
- As a user, I can set a display name, username, and avatar on my profile after signing in.
- As a new user signing in for the first time (via either provider), an account is created automatically and linked to that provider.
- As an existing user, my current data is preserved after the migration with no action required from me.

## Acceptance Criteria

1. **Same email, two providers → one account**: signing in via Google and then via GitHub with the same email address results in one user record with both providers linked. No duplicate user is created.
2. **New user via any provider**: a first-time sign-in creates a user record with `email` set, the provider linked, and profile fields (`display_name`, `username`, `avatar_url`) as null.
3. **Email is unique**: the database enforces a unique constraint on `email` in the users table. Duplicate emails cannot exist.
4. **Provider link table**: a separate `user_oauth_providers` (or equivalent) table records `(user_id, provider, provider_user_id)` with a unique constraint on `(provider, provider_user_id)`.
5. **Profile update**: a user can set `display_name`, `username`, and `avatar_url` via an API endpoint (or UI — defined in technical design). `username` must be unique across all users.
6. **Migration**: all existing users are migrated to the unified schema. Users with the same email across providers are merged into a single record; the migration is idempotent and reversible.
7. **No re-authentication required**: existing sessions remain valid after the migration.

## Future Considerations

- Username sign-in (in addition to OAuth) as a third auth pathway.
- User-to-user visibility and social graph features that depend on stable usernames.
- Avatar upload (currently only avatar URL by reference is in scope).
- Multiple email addresses per user.
