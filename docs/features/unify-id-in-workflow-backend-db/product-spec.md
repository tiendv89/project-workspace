
# Product Specification

## Feature
- Feature ID: `unify-task-feature-ids`
- Title: Unify `id`/`task_id` and `id`/`feature_id` into a single identity column

## Problem

The `workflow-backend` Postgres schema (schema authority: `workflow-backend/internal/database/migrations`, consumed by the sync writer in `workspace-github-adapter` and read by `digital-factory-ui`) currently carries **two independently-generated UUID columns per row** on both of its core entity tables:

- `workspace_features`: `feature_id uuid PK` (business key, referenced by FKs from `workspace_tasks`, `workspace_feature_documents`, `workspace_activity_events`) — confirmed in `docs/features/workspace-data-backend/technical-design.md` and migration `00009_use_uuid_feature_ids_for_tasks_documents_and_activity_events.sql` / `00016_fix_feature_id_fk.sql` (workflow-backend PR #35). It is not confirmed there is a separate surrogate `id` on `workspace_features` distinct from `feature_id` — this needs to be verified during technical design against the live schema (`\d workspace_features`), since RAG excerpts only show `feature_id` as the table's PK column in the documented design. **Open question, see below.**
- `workspace_tasks`: **two** UUID columns exist and are confirmed distinct in the live schema — `id` (row primary key, `gen_random_uuid()` default) and `task_id` (business key, intended stable identity for external references, also `gen_random_uuid()`-defaulted independently). This is explicitly documented as a live, exploited bug class in `docs/features/go-orchestrator-ui-tasks/technical-design.md`:
  - For **ts-owned tasks**, `workspace-github-adapter`'s `UpsertWorkspaceTask` (`internal/database/workspace_tasks.sql.go`) resolves one UUID (`task_uuid`, looked up by `(workspace_id, feature_id, task_name)` or freshly generated) and inserts **the same value** into both `id` and `task_id` — so `id === task_id` always holds for ts tasks, by construction, not by any DB constraint.
  - For **go-owned tasks**, `workflow-backend`'s `insertGoTask` (`internal/database/queries.go:1143-1184`) does **not** include `task_id` in its INSERT column list — `task_id` gets its own independent default, diverging from `id`.
  - The frontend (`digital-factory-ui`) exposes both fields on `TaskSummary` (`id`, `task_id`) and has at least two call sites (`TaskDiffTab`, `useTaskReviewThread`) that pass `task.id` to a backend route (`GET /api/workspaces/:workspaceId/tasks/:taskId/diff`) whose handler resolves via `Reader.GetWorkspaceTaskByID`, which actually queries `WHERE task_id = $2` — i.e. it matches on the **business key**, not the primary key it's named after. This silently worked for ts tasks (`id == task_id`) and silently broke for go tasks (`id != task_id`), surfacing as "task not found" errors.
  - `workspace_tasks` has a unique constraint on `(workspace_id, feature_id, task_name)`, **not** on `task_id` alone — `task_id`'s only real invariant is uniqueness because it's a UUID default, which is coincidental, not enforced.

This dual-ID shape is confusing (which column is a caller supposed to send: `id` or `task_id`/`feature_id`?), has already caused one shipped bug, and forces every new endpoint, DTO, and UI call site to re-decide which of the two fields is authoritative case by case.

## Goals

1. **Investigate and confirm the current schema shape** for both `workspace_features` and `workspace_tasks` in `workflow-backend` (live `\d` output / migration history), to settle the open question above about whether `workspace_features` truly has a redundant surrogate `id` column distinct from `feature_id`, or whether `feature_id` is already the sole PK (as the indexed technical design suggests) and only `workspace_tasks` has the dual-column problem.
2. **Decide and document a unification design**: collapse each table down to a single identity column (`id`), used both as the DB primary key and as the externally-visible business identifier, removing the redundant `task_id` / `feature_id` (or `id`) column wherever a genuine duplicate exists.
3. **Produce a migration plan** (goose migration(s) in `workflow-backend/internal/database/migrations`) that:
   - Backfills/reconciles divergent values (the go-task case where `id != task_id`) before dropping a column — decide and record which value wins (favor the pre-existing FK target, `feature_id`/`task_id`, since it's what's referenced from `workspace_activity_events`, `workspace_feature_documents`, and API routes today).
   - Updates all foreign keys currently pointing at the column being dropped.
   - Updates unique/index definitions accordingly.
4. **Inventory and update every call site** that references the field being removed, across:
   - `workflow-backend` (sqlc queries, `Reader`/`Queries` methods, `insertGoTask`, `UpsertWorkspaceTask`-equivalent Go paths, handler DTOs).
   - `workspace-github-adapter` (`UpsertWorkspaceTask` in `internal/database/workspace_tasks.sql.go`, `internal/adapter/db/adapter.go` sync paths).
   - `digital-factory-ui` (`TaskSummary`/`FeatureSummary` TypeScript types in `src/services/workflow-backend/types.ts`, `client.ts` route builders, and consuming components/hooks such as `TaskDiffTab`, `useTaskReviewThread`, `SpecPanel`, `board-meta.ts`).
5. **Confirm whether `task_id`/`feature_id` (as currently understood) are referenced anywhere else in code as an actual identifier** (vs. purely a DB-internal convenience) — the request notes uncertainty here; this must be resolved as part of the investigation, not assumed, since the go-orchestrator-ui-tasks findings already show `task_id` **is** used as the real external/business identifier by at least one production route and by frontend labels (e.g. `SpecPanel` renders `task.task_id?.toUpperCase()`).

## Non-goals

- This spec does not itself change any code or schema — it scopes the investigation and the unification migration for a subsequent technical design and task breakdown.
- No change to `workspace_activity_events.task_id`/`feature_id` semantics beyond following whatever the unified column ends up being named — the events table's own `id` (its row PK) is out of scope for renaming.
- No change to `workspace_repos.id`/`repo_id` or `workspaces.id`/`slug` — those are a different identity pattern (surrogate PK + human slug) and are explicitly out of scope; this feature is limited to `workspace_features` and `workspace_tasks`.
- No behavior change to task YAML files or the git-based source of truth (`docs/features/<feature_id>/tasks/*.yaml`) — `task_name`/`feature_name` (the human-readable `T1`, `<feature-id>` slugs from YAML) are untouched; this feature only concerns the UUID identity columns in the Postgres mirror.
- Does not address the `go-orchestrator-ui-tasks` frontend fix itself (switching `task.id` → `task.task_id` in `TaskDiffTab`/`useTaskReviewThread`) — that bug may already be fixed independently; if the unification lands first, that frontend code becomes correct-by-construction instead of needing the point fix.

## Open questions (for technical design)

- Does `workspace_features` actually have a redundant `id` column distinct from `feature_id`, or is `feature_id` already its sole PK? RAG excerpts of the documented schema show only `feature_id uuid PK` for `workspace_features`, with no separate `id` — this needs a live schema check (`workflow-backend` Postgres `\d workspace_features`) before finalizing scope, since the user's premise names an `id`/`feature_id` pair, but the indexed design docs found here do not show that duplication for the features table the way they do for `workspace_tasks`.
- Confirm every FK, unique index, and read path that targets `workspace_tasks.id` vs `workspace_tasks.task_id` today (e.g. `Reader.GetWorkspaceTaskByID`, `RecoverTask`, diff/review-thread routes) so none are silently left pointing at the dropped column post-migration.
- Confirm whether any external consumer (webhooks, `agent-workflow` orchestrator, other services) calls workflow-backend's API using `task_id`/`feature_id` as a request/response field name that must remain stable, vs. purely internal DB usage — this determines whether the unified column can be renamed to plain `id` in the API surface or must keep the `task_id`/`feature_id` name for backward compatibility.
