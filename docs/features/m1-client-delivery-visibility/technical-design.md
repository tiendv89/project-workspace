# Technical Design

## Feature
- Feature ID: `m1-client-delivery-visibility`
- Title: `Client Delivery Visibility (read-only)`

> Status: **not started.** Authored by the tech lead (`tech-lead` Phase 1) after the
> product spec is approved.

## Current State
Describe the existing system (`digital-factory-ui` Next.js dashboard reads workflow
state today; `workflow-backend` Go API). Identity comes from
`m1-identity-and-workspaces`.

## Constraints
- **Strictly read-only** — no write path may be introduced.
- Visibility scoped by membership (per `m1-identity-and-workspaces`).
- Presented for a non-engineer client audience.

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
Depends on `m1-identity-and-workspaces` (auth + workspace scoping).

## Parallelization / Blocking Analysis
Explain what can proceed in parallel and what is blocked.
