# Product Specification

## Feature

- Feature ID: `m1-fix-import-no-organization`
- Title: `Workspace Import — Attach to Organization`
- Milestone: **M1 — Open the Black Box** (sibling fix to `m1-identity-and-workspaces`)

## Problem

The **workspace import** path creates workspace rows **without an
`organization_id`**, but the schema delivered by `m1-identity-and-workspaces`
makes `organization_id` **`NOT NULL`** on `workspace` (multi-tenant from day one
— every stateful row carries `account_id`/`organization_id` per the M1 identity
spine).

The two are incompatible: import fails at insert time, and any imported
workspace that did land before the constraint is unattributable — it has no
tenancy owner, so the client visibility surface
(`m1-client-delivery-visibility`) cannot scope it to a member.

This is a correctness gap in the M1 spine, not a new capability. Without the
fix, **no workspace can be imported** under the M1 schema, and no imported
workspace can be shown to a client.

## Goals

- **Every imported workspace is attached to exactly one organization** at
  creation time — `organization_id` is always set, never `NULL`.
- The import flow **resolves the target organization explicitly** from the
  caller's context (the importing user's membership / selected org), not by
  guessing or defaulting.
- The import path **fails loudly and early** if no organization can be
  resolved, instead of attempting a `NULL` insert.
- **Backfill / reconcile** any pre-existing workspace rows that are missing
  `organization_id` so the `NOT NULL` constraint can hold without data loss —
  or document each unattributable row and decide its fate explicitly.
- Membership and per-workspace scoping continue to work end-to-end after import
  — an imported workspace is visible to its org's members and **only** to them.

## Non-goals

- **No new import sources or UI.** This is a fix to the existing import path,
  not a new product surface.
- **No changes to the identity model** (`user`, `auth_identity`, `account`/
  `organization`, `membership`) — those are owned by
  `m1-identity-and-workspaces`. This feature consumes that model.
- **No multi-org / cross-org import semantics.** A workspace belongs to exactly
  one organization (per the M1 schema); we do not introduce shared ownership.
- **No retroactive permissions change.** Imported workspaces inherit the same
  membership/role rules as natively-created workspaces — we are not redefining
  who can see what.
- **No billing, metering, or quota work** — M4.

## User Journey

1. An operator (or the import job) initiates a workspace import in a context
   where the target organization is known (the importing user's current org,
   or an explicitly chosen org they are a member of).
2. The import resolves `organization_id` from that context and persists the
   workspace row with `organization_id` set.
3. The workspace immediately appears under that organization's scope; members
   of that org can see it; non-members cannot.
4. If the context cannot resolve an organization, the import is rejected with
   a clear error — no `NULL` row is created.

## Success Criteria

- The `workspace.organization_id NOT NULL` constraint holds in the database
  with no exceptions after the fix is deployed.
- Importing a workspace from any supported entry point produces a row whose
  `organization_id` matches the caller's resolved organization.
- An attempt to import without a resolvable organization returns a clear
  failure; no partial / orphan row is created.
- All pre-existing workspace rows either have a valid `organization_id` or
  have been explicitly resolved (reassigned, archived, or deleted) — none
  remain `NULL`.
- The client visibility surface (`m1-client-delivery-visibility`) shows
  imported workspaces to the correct org's members and only to them.

## Dependencies

- **Depends on:** `m1-identity-and-workspaces` (defines `organization`,
  `workspace.organization_id`, and the membership scoping rules this fix
  must honour).
- **Blocks:** `m1-client-delivery-visibility` for any flow that relies on
  imported workspaces — the visibility surface cannot scope a workspace with
  no `organization_id`.
