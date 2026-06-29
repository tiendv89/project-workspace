# v004 — feature-id FK correctness, init PR tracking, repo URL, and model policy

**Features**: `workflow-db` (00016, 00018, 00019, 00020), `feature-initialization-compatible` (00017)
**Date**: 2026-06-29
**Migrations**: 00016–00020

## Tables altered

### `workspace_features`

- **Added standalone `UNIQUE` on `feature_id`** (00016, workflow-db) — `feature_id` previously only appeared in the composite `(workspace_id, feature_id)` unique index. Migration 00016 adds `UNIQUE (feature_id)` so it can serve as a single-column FK target.
- **Added**: `init_pr_url text` nullable (00017, feature-initialization-compatible) — URL of the initialization PR created for this feature by the Go orchestrator.
- **Added**: `init_pr_merged boolean NOT NULL DEFAULT FALSE` (00017, feature-initialization-compatible) — tracks whether the init PR has been merged on GitHub.
- **Index added**: standalone `feature_id [unique]`

### `workspace_tasks`

- **FK re-pointed**: `feature_id` now references `workspace_features.feature_id` instead of `workspace_features.id` (00016, workflow-db). Tasks join on the public business-key UUID, not the surrogate PK.

### `workspace_feature_documents`

- **FK re-pointed**: `feature_id` now references `workspace_features.feature_id` (00018, standalone `fix(db)`). Existing rows that still held the surrogate `id` were data-fixed to the corresponding `feature_id` business-key value before the constraint was added.

### `workspace_repos`

- **Added**: `repo_url text` nullable (00019, workflow-db) — GitHub URL for this repo.

## Tables added

### `models` (00020, workflow-db)

Catalog of available LLM models. `model_id TEXT UNIQUE` is the string identifier used by clients (e.g. `claude-sonnet-4-6`). Seeded on migration run with: Claude Haiku 4.5, Claude Sonnet 4.6, Claude Opus 4.8.

### `workspace_model_policies` (00020, workflow-db)

Per-workspace, per-phase model assignment. `phase` names a workflow phase; `model_id` points to the model to use. A partial unique index (`WHERE is_default = true`) enforces at most one default per `(workspace_id, phase)`.

## Migration sequence

| # | File | Feature | Change |
|---|------|---------|--------|
| 00016 | `fix_feature_id_fk.sql` | workflow-db | standalone UNIQUE on `workspace_features.feature_id`; `workspace_tasks` FK re-pointed |
| 00017 | `init_pr_url.sql` | feature-initialization-compatible | `init_pr_url`, `init_pr_merged` added to `workspace_features` |
| 00018 | `fix_document_activity_feature_id_fk.sql` | fix(db) | `workspace_feature_documents` FK re-pointed; document and activity rows data-fixed |
| 00019 | `workspace_repos_add_repo_url.sql` | workflow-db | `repo_url` added to `workspace_repos` |
| 00020 | `model_policy.sql` | workflow-db | `models` + `workspace_model_policies` tables created; 3 models seeded |

## Design notes

- **FK correctness (00016 + 00018).** Before these migrations, `workspace_tasks` and `workspace_feature_documents` FKed to `workspace_features.id` (the surrogate PK). The intended target is `workspace_features.feature_id` — the public business-key UUID that the API and all readers filter by. 00016 fixes tasks; 00018 fixes documents and also data-fixes `workspace_activity_events` rows (which have no FK, but carry `feature_id` for read queries). The surrogate `id` is now the internal row key only.
- **`workspace_activity_events.feature_id`** has no FK (denormalized timeline). Rows were data-fixed in 00018 for read consistency, but no constraint is added.
- **`init_pr_merged` default.** Defaults to `false`; updated to `true` when GitHub reports the PR merged. Absent (NULL behaviour is N/A — column is NOT NULL) until a PR is provisioned.
- **Model seeding.** Migration 00020 inserts models using `ON CONFLICT (model_id) DO NOTHING` — idempotent.

## Promotion

The top-level `database/workspace/schema.dbml` is promoted to this v004 snapshot at documentation time. Source of truth for the physical schema remains `workflow-backend/migrations`.
