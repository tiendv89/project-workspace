# Task Breakdown — workflow-migrations-transfer

Feature status: `in_tdd` | Tasks stage: `draft` | Machine state lives in `tasks/T<n>.yaml`

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Add migrations and auto-run to workflow-backend | — |
| T2 | 2 | Remove migrations and migrate binary from workspace-github-adapter | T1 |

---

## T1 — Add migrations and auto-run to workflow-backend

### Description

Copy the 11 goose SQL migration files verbatim from `workspace-github-adapter/database/migrations/` into `workflow-backend/internal/database/migrations/`. Add `internal/database/migrate.go` that embeds the files via `//go:embed` and exposes `RunMigrations(ctx, databaseURL)` — same pattern as the existing adapter implementation. Both `pressly/goose/v3` and `jackc/pgx/v5` are already present in `workflow-backend/go.mod`; no new dependencies required.

Wire the migration call into `cmd/api-service/main.go` before `database.Connect`: create a 2-minute context, call `database.RunMigrations`, and `log.Fatalf` on failure so the process exits before any HTTP traffic is accepted. No Dockerfile changes and no `docker-compose.yml` changes are needed for this task.

### Required skills

- go-best-practices

### Subtasks

- [ ] Create `internal/database/migrations/` directory
- [ ] Copy files `00001` through `00011` from `workspace-github-adapter/database/migrations/` — content unchanged
- [ ] Add `internal/database/migrate.go` with `//go:embed migrations/*.sql`, `MigrationFS embed.FS`, and `RunMigrations(ctx context.Context, databaseURL string) error` using `sql.Open("pgx", ...)`, `goose.SetBaseFS`, `goose.SetDialect("postgres")`, `goose.UpContext`
- [ ] Add `database/sql` and `embed` imports to `migrate.go`; `pgx/v5/stdlib` is already an indirect dep — verify it is importable directly or add as direct
- [ ] In `cmd/api-service/main.go`, add migration call after `config.Load()` and before `database.Connect()`:
  ```go
  migCtx, migCancel := context.WithTimeout(context.Background(), 2*time.Minute)
  defer migCancel()
  if err := database.RunMigrations(migCtx, cfg.DatabaseURL); err != nil {
      log.Fatalf("migrations: %v", err)
  }
  ```
- [ ] Run `go build ./...` — confirm it compiles
- [ ] Run `go test ./...` — confirm existing tests still pass
- [ ] Verify `go vet ./...` is clean

---

## T2 — Remove migrations and migrate binary from workspace-github-adapter

### Description

Once T1 is merged and the migration files are confirmed present in `workflow-backend`, remove all migration ownership from `workspace-github-adapter`:

- Delete `database/migrations/` (all 11 SQL files).
- Delete `database/migrate.go` (the `RunMigrations` function and embed directive).
- Delete `cmd/migrate/` (the standalone one-shot binary).
- Update `Dockerfile`: remove the `go build ./cmd/migrate` step and the `COPY --from=builder /out/migrate /migrate` line.
- Update `docker-compose.yml`: remove the `migrate` service entirely; change `adapter-service` and `adapter-worker` `depends_on` so both depend on `postgres: condition: service_healthy` only (the migration gate is now owned by `workflow-backend` api-service startup).

### Required skills

- go-best-practices

### Subtasks

- [ ] Delete `database/migrations/00001_workspaces.sql` through `00011_workspace_sync_runs_uuid_refs.sql`
- [ ] Delete `database/migrate.go`
- [ ] Delete `cmd/migrate/main.go` and `cmd/migrate/` directory
- [ ] In `Dockerfile`, remove `go build -o /out/migrate ./cmd/migrate` from the builder stage RUN command
- [ ] In `Dockerfile`, remove `COPY --from=builder /out/migrate /migrate`
- [ ] In `docker-compose.yml`, remove the `migrate:` service block
- [ ] In `docker-compose.yml`, update `adapter-service.depends_on` — remove `migrate` entry, keep `postgres: condition: service_healthy` and `redis: condition: service_healthy`
- [ ] In `docker-compose.yml`, update `adapter-worker.depends_on` — remove `migrate` entry, keep `postgres: condition: service_healthy` and `redis: condition: service_healthy`
- [ ] Run `go build ./...` — confirm it compiles without the deleted packages
- [ ] Run `go test ./...` — confirm existing tests pass
- [ ] Confirm no other Go file in the repo imports `github.com/tiendv89/workspace-github-adapter/database` for migration purposes
