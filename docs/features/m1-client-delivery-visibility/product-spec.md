# Product Specification

## Feature

- Feature ID: `m1-client-delivery-visibility`
- Title: `Client Delivery Visibility (read-only)`
- Milestone: **M1 — Open the Black Box** (see `docs/roadmap-milestone.md`)

## Problem

We already sell delivery as a service; our worker team (humans + agents) already
delivers. The gap is not revenue — it's that **the client never sees the team or the
process.** They hand us a project and receive output. This feature cracks that black
box open: a logged-in client **watches their delivery happen**.

This is the first visible step from **services → product** — the *same* engagement,
now visible, not a new SKU.

## Goals

- A logged-in client org **sees its workspace**: features, tasks, progress, and what
  the worker team (human + agent) is doing — in near-real-time or on refresh.
- Present delivery state legibly to a **non-engineer client**: feature/task status,
  what's in progress, what's blocked, what's done, recent activity.
- **Strictly read-only.** The client observes; they do not act.
- Scoped by the identity spine: a client sees **only** the workspaces their membership
  allows.

## Non-goals

- **No client actions of any kind** — no commenting, no approving, no `@mention`, no
  spec-drafting in-product. All of that is **M3 (The Thread)**.
- **No spec submission feature** — the client's only input is the spec, handed over
  **offline / off-platform** for M1.
- **No identity/auth work** — that's the sibling feature
  `m1-identity-and-workspaces`; this feature consumes it.
- **No billing, metering, tiers, or payment** — M4.
- **No agent conversation surface** — the agent is still a worker in M1; conversation
  is M2/M3.

## User Journey

1. A client (authenticated via `m1-identity-and-workspaces`) opens the platform.
2. They land on their workspace and **watch the delivery**: a board/overview of
   features and tasks with live status, progress, blocked items, and an activity feed
   of what the team did.
3. They can drill into a feature or task to see its detail (status, progress, log) —
   **read-only**.
4. They refresh / it updates; they never see an action control.

## What the client sees (for technical design to refine)

- Feature list with lifecycle status + progress.
- Task status across the workflow columns (todo → … → done), read-only.
- Per-task detail: status, dependencies, blocked reason, activity log.
- An activity / "what the team is doing" feed.
- *Open design question:* which delivery state is client-appropriate vs.
  internal-only, and how it's presented to a non-engineer.

## Success Criteria

- A logged-in client watches their workspace's delivery progress without any action
  control anywhere in the UI.
- Visibility is correctly scoped — a client never sees a workspace they aren't a
  member of.
- The surface reads existing delivery state (workflow/task state) without introducing
  any write path.

## Dependencies

- **Depends on:** `m1-identity-and-workspaces` (login + org/workspace scoping must
  exist first).
- **Blocks:** nothing in M1; M3 (The Thread) later turns this watch-only surface into
  a participate surface.
