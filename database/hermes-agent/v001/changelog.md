# v001 — Initial schema

Source migration: `hermes-agent/workflow_gateway/migrations/001_initial_schema.sql`

## Tables added
- `sessions` — one row per chat session; scoped by `workspace_id` + `feature_id`
- `messages` — one row per message; foreign key → `sessions.id` with `ON DELETE CASCADE`

## Notes
- `started_at`, `ended_at`, `last_active_at`, `created_at` are Unix epoch floats (matching Hermes internal convention), not `timestamptz`.
- `workspace_id` and `feature_id` were added to `sessions` by the workflow_gateway layer (not present in the upstream Hermes base schema) to enable per-feature session listing.
