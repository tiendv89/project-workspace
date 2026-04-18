# Product Specification

## Feature
- Feature ID: `workflow-db`
- Title: Workflow State — Git/YAML to Relational Database

## Problem

Workflow state (features, tasks, stages, history) currently lives as YAML files in a git management repo. This works well for low-concurrency operation but has growing limitations:

- **No ad-hoc querying** — answering "show me all blocked tasks across all features" requires scanning every YAML file
- **No relational integrity** — dependencies, stage progressions, and ownership are enforced only by convention and skill logic, not by the data layer
- **Concurrency ceiling** — the one-file-per-task model reduces push conflicts but doesn't eliminate them; under higher agent parallelism, git contention grows
- **No history model** — the `log:` array in each task YAML is append-only text, not queryable event records
- **Dashboard data staleness** — the current dashboard generates static JSON at build time; there is no live read path for a dynamic dashboard

The `FeatureRepository` interface introduced in `feature-status-dashboard/T3` already anticipates this migration — `FilesystemFeatureRepository` is the concrete implementation to replace.

## Goals

1. **Relational storage for workflow state** — features, tasks, stages, log entries, and dependencies stored in a proper schema with foreign keys and constraints
2. **Live read API** — a backend service the dashboard and other tools can query without a rebuild
3. **Agent write path** — agents continue to update task state (claim, in_progress, in_review, blocked) but via API calls instead of git commits to YAML files
4. **Query capabilities** — support for cross-feature queries: all ready tasks, all blocked tasks with reason, task dependency graph, agent activity by time range
5. **Migration** — existing YAML state imported without data loss; git history preserved as archive
6. **Dashboard update** — swap `FilesystemFeatureRepository` for `ApiFeatureRepository` (or equivalent) with no UI changes

## Non-goals

- Not replacing git for code artifacts — implementation repos and the management repo's narrative files (`tasks.md`, `product-spec.md`, `technical-design.md`) stay in git
- Not building a full Jira replacement — no issue assignment, no sprint planning, no time tracking in v1
- Not multi-workspace in v1 — single workspace per DB instance
- Not real-time push notifications in v1 — polling is acceptable for the dashboard

## Key open questions (to resolve in technical design)

1. **Database choice** — PostgreSQL (full-featured, widely hosted) vs SQLite (zero-infra, single-file). At current scale SQLite may be sufficient; Postgres is more operationally familiar. What's the right call?
2. **API layer** — REST vs GraphQL. REST is simpler to build and consume; GraphQL gives flexible querying. Given the dashboard already has a defined data shape, REST is likely sufficient.
3. **Agent write path** — do agents call the API directly (requires network access from container), or does the agent-runtime mediate all DB writes? The latter keeps DB credentials out of agent context.
4. **Claim protocol** — the current git-based claim uses push-rejection as the concurrency primitive. A DB-backed claim needs optimistic locking or `SELECT FOR UPDATE`. What's the right mechanism?
5. **Auth** — the dashboard is currently read-only and unauthenticated. The write API (used by agent-runtime) needs at minimum a service token. Is that sufficient?
6. **Deployment** — where does the DB run? Local Docker Compose for development, hosted Postgres for production? What's the target environment?
7. **Migration strategy** — one-shot import of all YAML at cutover, or dual-write during transition? How do we validate correctness before switching?

## Success criteria

- All existing feature and task state importable from YAML with no data loss
- Dashboard reads from the DB with no static build step required
- Agents can claim, update, and complete tasks via the new write path
- Cross-feature queries (all ready tasks, all blocked tasks) work in a single API call
- Git management repo YAML files are no longer the source of truth after cutover
