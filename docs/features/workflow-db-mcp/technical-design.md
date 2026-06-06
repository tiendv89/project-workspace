# Technical Design

## Feature
- Feature ID: `workflow-db-mcp`
- Title: Workflow DB Write API & MCP — agent-facing create/update for DB-owned features

> Phase 1 technical design has **not** started. Deferred placeholder — produced via `tech-lead` only after `product-spec.md` is approved and `workflow-db` has settled the in-process write path and FSM-guard query layer this feature will reuse.

## Current State
To be written after product-spec approval. Baseline: `workflow-db` delivers the schema and the Go orchestrator's in-process pgx write path (claim + FSM-guarded transitions). `workflow-backend` provides the read API. There is no agent/human-facing *write* path; the spec covers why.

## Constraints
- Depends on `workflow-db`. Must reuse its schema and guarded-`UPDATE` FSM transitions — do not define a second FSM.
- Must not duplicate execution-state writes (orchestrator-owned). Only creation, definition updates, and human-intervention transitions.
- Preserve credential isolation: only the API service holds DB creds; clients authenticate.
- Owner scoping: write only `owner='go'` rows; never touch `owner IS NULL`.

## Options Considered
### Option A
- Pros:
- Cons:

### Option B
- Pros:
- Cons:

## Chosen Design
To be written.

## Dependency Analysis
Hard dependency on `workflow-db`. Coordinate the FSM-guard query layer so the API and the Go orchestrator share one transition definition.

## Parallelization / Blocking Analysis
To be written in Phase 1.
