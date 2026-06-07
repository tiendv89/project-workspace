# Product Specification

## Feature
- Feature ID: `workflow-db-mcp`
- Title: Workflow DB Write API & MCP — agent-facing create/update for DB-owned features

> **Status: deferred placeholder.** Parked at `in_design` pending `workflow-db`. Created so the deferred "write API / MCP" scope referenced in `workflow-db`'s technical design (§3-B, open-question #2, §4.7 Gap A) has a home. Not actively worked yet.

## Problem
`workflow-db` gives the **Go orchestrator** a credential-holding, in-process pgx write path: it claims tasks and writes every execution-state transition (`ready→in_progress→in_review→done`, `→blocked`, auto-ready) directly to Postgres. That is sufficient for the orchestrator to drive a DB-owned (`owner='go'`) feature end-to-end.

What it does **not** provide is a credential-clean write path for **non-runtime clients**:
- **Authoring agents / skills** that need to *materialize* a go feature — create `workspace_features`/`workspace_tasks` rows from an approved task breakdown (`workflow-db` Gap A). In v1 this is done by an operator seed / orchestrator `create` command; there is no agent-facing path.
- **Humans / UI** that need to perform manual lifecycle interventions on a DB-owned feature — `blocked→ready`, `any→cancelled`, `in_review→ready` (reject for rework). In v1 these require direct `psql`.

Handing Postgres credentials to authoring agents or skills to close this gap would violate the credential-isolation pattern (DB creds live with the orchestrator/adapter, never with executor-side agents). The credential-clean answer is an **authenticated write/update API** plus an **MCP server** that exposes it as agent tools.

## Background / dependency
Hard dependency on **`workflow-db`**, which delivers the schema (`owner`, relaxed `source_path`), the in-process write path, and the guarded-`UPDATE` FSM primitive. This feature does **not** reimplement execution-state writes — the orchestrator keeps owning those. It adds an external, authenticated surface for the writes the orchestrator does *not* perform (creation, definition updates, human-intervention transitions), reusing the same schema and FSM guards.

## Goals
- **Authenticated write/update API** over the shared Postgres for DB-owned features, enforcing the same FSM transition guards as the orchestrator's in-process writes.
  - Create a go feature + its tasks (materialization) — closes `workflow-db` Gap A for the agent-driven authoring journey.
  - Update task definitions (narrative fields) for a DB-owned feature.
  - Human-intervention transitions: `blocked→ready`, `blocked→in_review`, `in_review→ready`, `any→cancelled` — applying the unblock-target and cancellation rules.
- **MCP server** exposing the above as tools so authoring agents/skills (e.g. an owner-aware `tech-lead`/`init-feature`) can materialize and update go features without DB credentials.
- **Credential isolation preserved** — clients authenticate to the API (at minimum a shared token; ideally per-client tokens / org scoping); only the API service holds DB creds.
- **Owner scoping** — the API only writes `owner='go'` rows and never touches `owner IS NULL` (legacy) rows, mirroring the sync adapter's boundary.

## Non-goals
- Execution-state writes during a run (claim, status transitions, PR fields, log, auto-ready) — the **Go orchestrator owns these in-process** (`workflow-db`). This feature must not duplicate them.
- The reviewer cycle / drift daemon / handoff trigger — owned by `go-orchestrator-parity`.
- Replacing the orchestrator's in-process create command — the API is the *agent/human-facing* path; the orchestrator may still create internally.
- Read API — already provided by `workflow-backend`.

## Open questions
1. **Auth model** — shared service token vs per-client/per-org tokens; relation to `organization_id` scoping.
2. **API shape** — REST (gin, alongside `workflow-backend`'s read API) vs a dedicated service; and how the MCP server fronts it.
3. **FSM guard reuse** — share the guarded-`UPDATE` query layer with the Go orchestrator (a common query package) vs reimplement, to avoid two FSM definitions drifting.
4. **Home repo** — `workflow-backend` (next to the read API), `workflow-orchestrator`, or a new service.

## Success criteria
- An authoring agent, holding only an API token (no DB creds), can create a go feature + tasks that the Go orchestrator then picks up and drives to `done`.
- A human can unblock / cancel / reject a DB-owned feature through the API, and the orchestrator observes the new state on its next cycle.
- The API rejects illegal FSM transitions and never mutates `owner IS NULL` rows.
