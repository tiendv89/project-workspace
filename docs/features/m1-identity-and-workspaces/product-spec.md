# Product Specification

## Feature

- Feature ID: `m1-identity-and-workspaces`
- Title: `Identity, Org & Workspace Foundation`
- Milestone: **M1 — Open the Black Box** (see `docs/roadmap-milestone.md`)

## Problem

The platform has **no concept of a user, an account, or a workspace today** — and M1
turns an already-running, already-paid delivery *service* into a *product* by letting
the client log in and watch their delivery. Before a client can watch anything, there
must be an identity spine: who they are, which organization they belong to, which
workspace is theirs, and what they're allowed to see.

This feature builds that spine — the foundation every later milestone (M2–M6) hangs
off. It deliberately builds the **identity data model**, not an auth system.

## Goals

- **Identity data model:** `user` (profile), `account`/`org`, `workspace`,
  `membership` (user ↔ org ↔ role), and **per-workspace scoping**.
- **Federated login only — Google + GitHub.** Consume them as identity providers;
  build the **profile + org/workspace layer** on top.
- **Thin session layer:** a library-handled session/cookie after the IdP hands back
  identity — glue, not an auth system.
- **Multi-tenant from day one:** every stateful row carries `workspace_id` /
  `account_id` per the `overview.md` schema rules; `snake_case` physical names.
- **GitHub-as-provider sets up downstream:** the same GitHub identity that logs a
  client in can later authorize repo access for the bot milestone — a deliberate,
  free downstream win.

## Non-goals

- **No auth system of our own** — no password store, no OAuth *server*, no MFA. We
  federate Google + GitHub and add a thin session layer only.
- **No client actions of any kind** — no commenting, approving, `@mention`,
  spec-drafting. Those are M2+. This feature is identity + membership only; the
  read-only viewing surface itself is the sibling feature
  `m1-client-delivery-visibility`.
- **No billing, metering, tiers, BYO key, or payment** — M1 sells by hand (B2B,
  invoiced); monetization is M4.
- **No GitHub App / bot identity** — the delivery team operates on the repos as it
  does today.
- **No custom roles** — only the preset roles needed for M1 viewing/membership.

## User Journey

1. A client is invited to (or signs in to) the platform.
2. They authenticate with **Google or GitHub** — no password to create.
3. On first sign-in a `user` profile is created and linked to their `account`/`org`
   and the `workspace` for their engagement, via a `membership` with a scoped role.
4. They land in their organization context, scoped to the workspace(s) they belong to.
   (What they *see* there is delivered by `m1-client-delivery-visibility`.)

## Data Model (for technical design)

| Entity | Purpose |
|---|---|
| `user` | one human identity + profile; linked to one or more IdP identities |
| `auth_identity` | `user_id` ↔ provider (`google`/`github`) + provider UID (account linking) |
| `account` / `org` | the tenancy boundary; owns workspaces |
| `workspace` | a delivery engagement; belongs to exactly one account; carries `workspace_id` |
| `membership` | `user_id` ↔ `account_id` ↔ role; per-workspace scoping |
| `session` | thin session/cookie after IdP callback |

## Success Criteria

- A client signs in via Google/GitHub and reaches their org/workspace context with no
  password and no platform-built auth server.
- Access is scoped: a member sees only the workspaces their membership allows.
- The data model is multi-tenant (`workspace_id`/`account_id` everywhere) and ready
  for M2–M6 to build on.

## Dependencies

- **None** (this is the M1 foundation).
- **Blocks:** `m1-client-delivery-visibility` (needs login + workspace scoping first),
  and every later milestone.
