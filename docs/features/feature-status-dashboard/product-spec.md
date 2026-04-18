# Product Specification

## Feature
- Feature ID: `feature-status-dashboard`
- Title: Feature & Task Status Visualization Dashboard

## Problem

The workspace tracks features and tasks entirely through YAML files and markdown documents. As the number of active features and tasks grows, getting a quick read on overall progress requires manually reading multiple files across nested directories. There is no at-a-glance view of:

- Which features are in which lifecycle stage
- Which tasks are blocked, in progress, or waiting on dependencies
- Which tasks are ready to start but haven't been claimed
- How work is distributed across repos and actor types

This creates friction for the product owner and tech lead who need to stay oriented without deep-diving into the file system constantly.

## Goals

1. **Feature overview** — show all features in the workspace with their current lifecycle stage and stage review status at a glance.
2. **Task board per feature** — for any given feature, display all tasks with their status (todo / ready / in_progress / blocked / in_review / done / cancelled) and which repo they target.
3. **Blocked & stalled highlighting** — surface tasks that are `blocked` or have been `in_progress` longer than expected so they can be acted on quickly.
4. **Dependency awareness** — indicate which tasks are waiting on incomplete dependencies vs. which are genuinely ready to claim.
5. **Web-based UI** — accessible in a browser; no authentication required for this phase.

## Non-goals

- Authentication or access control (future phase)
- Editing task state through the UI (read-only)
- Integration with external project management tools (Jira, Linear, etc.)
- Mobile-optimized layout
- Real-time push updates (polling or manual refresh is acceptable)

## User stories

| As a… | I want to… | So that… |
|---|---|---|
| Product owner | See all features and their stages in one view | I can track overall delivery progress without opening files |
| Tech lead | See all tasks for a feature with their current status | I know what is blocked, in review, or ready to pick up |
| Tech lead | See which tasks are ready but unclaimed | I can assign or trigger them promptly |
| Product owner | See which features are blocked or stalled | I can intervene and remove blockers quickly |

## Proposed UX — Web dashboard

A Next.js application serves a web UI that reads feature and task data from the workspace's git-tracked YAML files.

### Features list view

A table or card grid showing every feature:

| Feature | Stage | Review status | Tasks summary |
|---|---|---|---|
| feature-status-dashboard | product_spec | draft | — |
| task-branch-lifecycle | handoff | approved | 3 done, 0 blocked |
| agent-runtime-hardening | in_implementation | — | 1 done, 1 blocked, 2 ready |

Status badges use distinct colors:
- `in_progress` → blue
- `blocked` → red
- `ready` → green
- `done` → grey
- `in_review` → yellow

### Feature detail view

Clicking a feature opens a detail panel showing:
- Feature metadata (stage, review status, last history entry)
- Task list with columns: ID, title, status, repo, actor type, depends on, PR link (if any)
- Blocked tasks highlighted with their `blocked_reason`
- Tasks with unmet dependencies shown as "waiting" with dependency IDs listed

### Data refresh

The UI fetches data from the NestJS API, which reads YAML files directly from disk on each request. No caching — always reflects the current git-tracked state.

## Data layer

**Current phase**: Next.js server-side code reads `docs/features/<feature_id>/status.yaml` and `docs/features/<feature_id>/tasks/*.yaml` directly from the filesystem (the local clone of the management repo).

**Future migration path**: the data layer will be abstracted behind a repository interface so that the underlying store can be swapped to a relational database (e.g. PostgreSQL) without changing the UI or API routes. The technical design must account for this interface boundary.

## Architecture summary

- **Framework**: Next.js — full-stack, handles both the React UI and server-side data access in one project (`digital-factory-ui` repo)
- **Data access**: server components or API routes read YAML files via `fs` on the server; no client-side file access
- **API routes** (optional): `GET /api/features`, `GET /api/features/[id]`, `GET /api/features/[id]/tasks` — useful if the frontend needs to refetch without a full page reload
- **Data source**: filesystem YAML files in the management repo local clone (path configured via env var)
- **Deployment**: local dev server for now; no staging or production environment required in this phase

## Success criteria

- All features in `docs/features/` appear with correct stage, review status, and task summary.
- All tasks per feature show correct status, repo, actor type, and dependency state.
- Blocked tasks are visually distinct (red badge, reason shown).
- The dashboard loads without authentication.
- The data layer is behind a repository interface, ready for a future DB swap.
- The app starts with a single command from the repo root.
