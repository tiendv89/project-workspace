# v002 — workspace ownership by organization

**Feature**: `m1-identity-and-workspaces`
**Date**: 2026-05-31

## Tables altered

- `workspaces`
  - **Added**: `organization_id uuid NOT NULL` — owning organization. References `organizations.id` in the **user-service** database; stored as a plain UUID with **no foreign key** (cross-DB).
  - **Added index**: `organization_id` (single column) for scoping queries by org.

## Migration sequence

Per `m1-identity-and-workspaces/technical-design.md` §Validation and Release Impact:

1. Add `workspaces.organization_id` as **nullable** (initial v002 migration).
2. Run the user-service seed command — creates the `Kitelabs` organization in `user_db` and backfills `workspace_db.workspaces.organization_id` for every existing row to that org's UUID.
3. Apply `ALTER COLUMN ... SET NOT NULL` (follow-up migration in the same release).

The v002 `schema.dbml` snapshot reflects the **final** post-migration state (NOT NULL). The SQL migration files in `workflow-backend` implement the three-step sequence.

## Design notes

- **No cross-DB FK.** Postgres does not enforce foreign keys across databases. Referential integrity for `workspaces.organization_id → user-service organizations.id` is enforced in application code at the write boundary (workflow-backend trusts the `organization_id` value supplied by user-service via the validated session payload).
- **Backfill safety.** No production client data exists yet — the only workspaces in any environment belong to the Kitelabs internal delivery team. The backfill is bounded and idempotent.
- **Scoping queries.** All workspace-scoped read queries in workflow-backend remain filtered by `workspace_id`; `organization_id` is used for organization-level views (e.g. "show all workspaces in this org") and for the M1 invitation acceptance flow.
- Physical names remain lowercase `snake_case`.
