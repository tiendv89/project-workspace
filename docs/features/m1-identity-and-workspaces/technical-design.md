# Technical Design

## Feature
- Feature ID: `m1-identity-and-workspaces`
- Title: `Identity, Org & Workspace Foundation`

> Status: **not started.** Authored by the tech lead (`tech-lead` Phase 1) after the
> product spec is approved.

## Current State
Describe the existing system (`workflow-backend` — Go/Gin/pgx; `digital-factory-ui` —
Next.js; no identity/account concept exists yet).

## Constraints
- Self-hosted identity in the Go backend (no managed provider) — see roadmap 1.1.
- Federated login only (Google + GitHub); thin session layer.
- Multi-tenant data model (`workspace_id`/`account_id`) from day one.

## Options Considered
### Option A
- Pros:
- Cons:

### Option B
- Pros:
- Cons:

## Chosen Design
Explain the selected design and why.

## Dependency Analysis
Document dependencies and blocking conditions.

## Parallelization / Blocking Analysis
Explain what can proceed in parallel and what is blocked.
