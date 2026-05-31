# v001 — user-service initial schema

**Feature**: `m1-identity-and-workspaces`
**Date**: 2026-05-31

## Tables added

### Identity
- `users` — one row per human; holds last-known email, display name, avatar. Indexed by `lower(email)` for case-insensitive lookup.
- `auth_identities` — link between a `user` and an IdP identity (Google `sub`, GitHub user id). Unique on `(provider, provider_sub)`. One user may have multiple identities (account linking).

### Tenancy
- `organizations` — the tenancy boundary (synonymous with "org"). Owns workspaces (via `workspaces.organization_id` in the workspace DB). Slug is unique.
- `memberships` — many-to-many between `users` and `organizations`, with a `role` (`platform_admin` | `client_member` for M1). Unique on `(user_id, organization_id)`.
- `workspace_memberships` — optional per-workspace scope override. If present for a `(user, org)` pair, the user is scoped to **only** those workspaces in that org. If absent, the user sees all workspaces in the org. `workspace_id` is a plain UUID with **no foreign key** — the `workspaces` table lives in the workspace DB.

### Onboarding
- `organization_invitations` — pre-provisioned invites. Matched at first login by verified provider email. `workspace_ids` is `null` (all workspaces) or a JSONB array of workspace UUIDs to scope the invited user to specific workspaces on acceptance.

### Sessions
- `sessions` — managed by `alexedwards/scs/v2` + `scs/postgresstore`. Schema dictated by the library. Listed here for completeness; created by scs's bundled migration, not by application code.

## Design notes

- **Tenancy**: the user-service uses `organization_id` as its tenancy boundary, not `workspace_id`. `users` are global (a person can belong to multiple orgs), so they cannot be partitioned by org or workspace.
- **Cross-DB references**: `workspace_memberships.workspace_id` and `organization_invitations.workspace_ids[]` reference rows in the workspace DB. No foreign keys are declared (Postgres does not enforce cross-database FKs). Application code at the boundary is responsible for referential integrity.
- **Email matching**: `users.email` and `organization_invitations.email` are matched case-insensitively via `lower(email)` functional indexes — IdPs vary in case behaviour on local-parts.
- **Provider identity**: `auth_identities.(provider, provider_sub)` is the only stable lookup key for "is this returning user the same person as before?" Email is not stable (users change primary emails).
- Physical names use lowercase `snake_case` throughout.
