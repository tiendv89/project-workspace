# Product Specification

## Feature
- Feature ID: `workflow-db`
- Title: Workflow State Database — Agent Write Path and Relational Storage

## Problem

Today every agent action — claiming a task, updating status, logging progress, marking done — is a git commit and push to the management repo. This works at low concurrency but creates compounding problems as the platform scales:

The git-based claim protocol uses push-rejection as its concurrency primitive. Two agents racing for the same task both write to a branch and the slower push loses. This works, but it is slow (full git round-trip per claim), has a retry cost, and becomes a bottleneck under high agent parallelism.

Workflow state — features, tasks, stages, log entries, dependencies — lives as YAML files that must be opened and parsed one by one to answer questions like "what tasks are ready right now?" or "which features are blocked and why?" There is no queryable record, no referential integrity, and no event history that can be sliced or aggregated.

This is the foundation we need to fix before the platform can grow. The database becomes the system of record for workflow state. Agents write to it instead of git. The management repo retains narrative artifacts (product specs, technical designs, tasks.md) but is no longer the source of truth for live task state.

## Goals

- Move agent task writes (claim, status transition, log entries, blocked state) from git commits to database operations.
- Replace the git push-rejection claim protocol with a database-backed atomic claim (optimistic locking or `SELECT FOR UPDATE`).
- Store features, tasks, stages, log entries, and dependencies in a relational schema with foreign keys and constraints.
- Expose a live read API so the dashboard and other consumers can query workflow state without rebuilding from YAML files.
- Support cross-feature queries: all ready tasks, all blocked tasks with reason, task dependency graph, agent activity by time range.
- Import existing YAML state into the database without data loss; preserve git history as archive.
- Keep git for code artifacts and narrative documents — only live task state moves to the database.

## Non-goals

- Not replacing git for implementation repos or narrative files (`tasks.md`, `product-spec.md`, `technical-design.md`).
- Not building a full Jira replacement — no issue assignment, sprint planning, or time tracking in v1.
- Not real-time push notifications in v1 — polling is acceptable for the dashboard.
- Not the UI read layer for the workspace dashboard — that is handled by `workspace-data-backend`.

## Key open questions (to resolve in technical design)

1. **Database choice** — PostgreSQL (full-featured, widely hosted) vs SQLite (zero-infra, single-file). At current scale SQLite may be sufficient; Postgres is more operationally familiar.
2. **API layer** — REST vs GraphQL. REST is simpler; given the dashboard has a defined data shape, REST is likely sufficient.
3. **Agent write path** — do agents call the API directly (requires network from container), or does the agent-runtime mediate all DB writes? The latter keeps DB credentials out of agent context.
4. **Claim protocol** — optimistic locking vs `SELECT FOR UPDATE`. What is the right mechanism for the new atomic claim?
5. **Auth** — the write API (used by agent-runtime) needs at minimum a service token. Is that sufficient for v1?
6. **Deployment** — local Docker Compose for development, hosted Postgres for production?
7. **Migration strategy** — one-shot import at cutover, or dual-write during transition?

## Success criteria

- Agents claim and update task state via database operations, not git commits.
- All existing feature and task state importable from YAML with no data loss.
- Dashboard reads live state from the database with no static build step.
- Cross-feature queries (all ready tasks, all blocked tasks) work in a single API call.
- Git management repo YAML files are no longer the live source of truth after cutover.
