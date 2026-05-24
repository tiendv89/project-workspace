# Product Specification

## Feature
- Feature ID: `workflow-migrations-transfer`
- Title: `Move DB Migrations from workspace-github-adapter to workflow-backend`

## Problem

During the `workspace-data-backend` feature, the `goose` SQL migration files and the migration run step were placed in `workspace-github-adapter` (the adapter/write service). This is the wrong home: migrations define the shared PostgreSQL schema that both `workspace-github-adapter` and `workflow-backend` depend on. Owning migrations in the adapter service means the API service (`workflow-backend`) has an implicit startup dependency on a side service having already run migrations — this is fragile, operationally confusing, and violates the principle that the primary API service should own and guarantee its own schema.

Additionally, migrations are not currently run automatically on service startup. Operators must remember to run them manually at deploy time. This creates an error-prone gap between deploys and schema readiness.

## Goals

- Move all `goose` SQL migration files from `workspace-github-adapter` to `workflow-backend`.
- Remove the migration run step from `workspace-github-adapter`.
- Add auto-migration on startup to `workflow-backend`: when the API starts, it runs any pending `goose` migrations before accepting traffic.
- Ensure `workspace-github-adapter` connects to the same PostgreSQL database without owning or running migrations.

## Non-goals

- No changes to the migration SQL content — files are moved, not rewritten.
- No changes to the database schema.
- No changes to `digital-factory-ui` or any other repo.
- No changes to how `DATABASE_URL` is resolved or injected — environment config is unchanged.
- No migration versioning strategy changes — `goose` remains the tool.

## Acceptance Criteria

- All `goose` SQL migration files exist under `workflow-backend` and are absent from `workspace-github-adapter`.
- `workflow-backend` runs pending migrations automatically when the API process starts, before the HTTP server begins accepting requests.
- If migrations fail at startup, the process exits with a non-zero code and a clear error log — it does not start serving traffic with a potentially broken schema.
- `workspace-github-adapter` continues to connect to PostgreSQL and operate correctly without owning migration files or running migrations itself.
- Local `docker-compose` (or equivalent dev setup) reflects the new ownership — only `workflow-backend` runs migrations on startup.
