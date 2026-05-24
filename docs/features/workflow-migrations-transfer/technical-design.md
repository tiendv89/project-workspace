   # Technical Design

## Feature
- Feature ID: `workflow-migrations-transfer`
- Title: `Move DB Migrations from workspace-github-adapter to workflow-backend`

---

## 1. Current State

### workspace-github-adapter
- `database/migrations/` — 11 goose SQL files (`00001` through `00011`), embedded via `//go:embed` in `database/migrate.go`
- `database/migrate.go` — `RunMigrations(ctx, databaseURL)` using `pressly/goose/v3` + `pgx/v5/stdlib`
- `cmd/migrate/main.go` — standalone one-shot binary that calls `RunMigrations` and exits
- `Dockerfile` — builds three binaries: `/adapter-service`, `/adapter-worker`, `/migrate`
- `docker-compose.yml` — `migrate` service runs `/migrate` as a one-shot job; `adapter-service` and `adapter-worker` have `depends_on: migrate: condition: service_completed_successfully`

### workflow-backend
- No migration files, no migration runner
- `go.mod` already includes `pressly/goose/v3 v3.24.3` and `jackc/pgx/v5 v5.7.4` — both needed for migration are already imported
- `cmd/api-service/main.go` — calls `database.Connect` (pgxpool) then starts serving immediately; no migration step
- `docker-compose.yml` — single `api-service` entry that joins the `workspace-github-adapter_default` external network; no postgres service defined

### Current limitations
- `workflow-backend` (the primary API service) has an implicit operational dependency on `workspace-github-adapter`'s `migrate` service having already run. It does not enforce this at startup.
- If `workflow-backend` is deployed first, or `workspace-github-adapter` is restarted without postgres, the schema may be absent and `workflow-backend` will serve requests against a database with no tables.
- The semantic ownership is inverted: the adapter (write side) defines the schema that the API service (read side) consumes. The API service should be the schema authority.
- No automatic migration on startup — operator must remember to run the `migrate` service or binary at deploy time.

---

## 2. Problem Framing

### What must change
- Migration SQL files must live in `workflow-backend/internal/database/migrations/`.
- `workflow-backend` must call `RunMigrations` before accepting traffic.
- `workspace-github-adapter` must stop owning or running migrations.

### What must remain stable
- The migration SQL content is unchanged — files are moved, not modified.
- goose versioning sequence (`00001`–`00011`) is preserved exactly; no version renumbering.
- `DATABASE_URL` injection is unchanged in both services.
- Both services continue using the same PostgreSQL database instance.
- `workspace-github-adapter` continues to connect to PostgreSQL and write rows normally.

### Fixed assumptions
- `pressly/goose/v3` remains the migration tool.
- goose tracks applied migrations in the `goose_db_version` table; because the files and their checksums are unchanged, goose will correctly detect already-applied migrations and skip them on subsequent startups.

---

## 3. Options Considered

### Option A — Move files to workflow-backend; keep a separate migrate binary in workflow-backend

Port the existing `cmd/migrate/main.go` pattern to `workflow-backend`. Operators run a migrate job at deploy time; api-service does not self-migrate.

- **Pros**: familiar pattern; migration and service startup are decoupled; a failed migration does not block process startup at all
- **Cons**: manual step still required; the gap between deploy and schema readiness remains; does not solve the "forget to migrate" problem
- **Implementation impact**: similar file move, plus adding a `cmd/migrate/` binary to workflow-backend
- **Dependency impact**: no change to startup order

### Option B — Move files to workflow-backend; auto-run migrations inside api-service startup (chosen)

`workflow-backend` embeds the SQL files and calls `RunMigrations` in `main.go` before `database.Connect` and before the HTTP server starts. If migration fails, `log.Fatalf` exits the process — no traffic is served against a broken schema.

- **Pros**: schema readiness is a startup guarantee; no manual operator step; deployment is self-contained; first-boot and re-deploy behave identically
- **Cons**: startup time increases slightly on first deploy or after adding new migrations; a bad migration SQL blocks service startup until fixed
- **Implementation impact**: one new package file (`internal/database/migrate.go`), one directory (`internal/database/migrations/`), two-line change to `cmd/api-service/main.go`
- **Dependency impact**: `workspace-github-adapter` must no longer depend on its own `migrate` service completing — adapter services should depend only on `postgres: service_healthy`; operator startup order for local dev must be: workflow-backend first (runs migrations), then adapter services

### Option C — Shared migration package in a third repo / module

Extract migrations into a shared Go module that both services import.

- **Pros**: single authoritative source; neither service "owns" the schema
- **Cons**: introduces a new repo and inter-service module dependency; significant operational overhead for a two-service system; far exceeds the scope of the problem
- **Not chosen.**

---

## 4. Chosen Design

**Option B — auto-migration in workflow-backend startup.**

### Changes to workflow-backend

1. **`internal/database/migrations/`** — copy the 11 SQL files verbatim from `workspace-github-adapter/database/migrations/`. No SQL content changes.

2. **`internal/database/migrate.go`** — new file:
   ```go
   //go:embed migrations/*.sql
   var MigrationFS embed.FS

   func RunMigrations(ctx context.Context, databaseURL string) error {
       db, err := sql.Open("pgx", databaseURL)
       // ... goose.SetBaseFS, goose.SetDialect, goose.UpContext
   }
   ```
   Pattern is identical to `workspace-github-adapter/database/migrate.go`. goose and pgx/stdlib are already in `go.mod`.

3. **`cmd/api-service/main.go`** — add migration call before `database.Connect`:
   ```go
   migCtx, migCancel := context.WithTimeout(context.Background(), 2*time.Minute)
   defer migCancel()
   if err := database.RunMigrations(migCtx, cfg.DatabaseURL); err != nil {
       log.Fatalf("migrations: %v", err)
   }
   ```
   If migrations fail, the process exits with a non-zero code. No HTTP server is started.

4. **No Dockerfile changes** — `workflow-backend` does not need a separate migrate binary; migrations run inline.

5. **No docker-compose.yml changes** — `workflow-backend/docker-compose.yml` connects via the external adapter network; the api-service will run migrations when it starts against that postgres. No structural change needed.

### Changes to workspace-github-adapter

1. **Remove `database/migrations/`** — all 11 SQL files deleted.
2. **Remove `database/migrate.go`** — `RunMigrations` function and embed directive deleted.
3. **Remove `cmd/migrate/`** — standalone migrate binary deleted.
4. **`Dockerfile`** — remove the `go build ./cmd/migrate` step and the `COPY --from=builder /out/migrate /migrate` line.
5. **`docker-compose.yml`** — remove the `migrate` service entirely; update `adapter-service` and `adapter-worker` `depends_on` to `postgres: condition: service_healthy` only (the explicit migration gate is replaced by the api-service startup guarantee).

### Startup ordering after change

In local development:
1. Start postgres and redis (from adapter compose or standalone).
2. Start `workflow-backend` api-service — it runs migrations, then begins serving.
3. Start `adapter-service` and `adapter-worker` — they connect to a fully migrated schema.

Adapter services that start before api-service will connect to postgres successfully (postgres is healthy) but operate against an unmigrated schema until api-service runs. In practice this window is small and only matters for fresh-database first-boot. If needed, a health probe can be added in future work.

### Compatibility

- goose tracks applied migrations in `goose_db_version`. Moving the files to workflow-backend does not change file checksums or version numbers; goose will correctly skip already-applied migrations on re-start.
- No data is touched. This is a pure ownership transfer of schema-management responsibility.

---

## 5. Dependency Analysis

| Dependency | Status | Notes |
|---|---|---|
| `pressly/goose/v3` in workflow-backend `go.mod` | **Already present** (`v3.24.3`) | No new import needed |
| `jackc/pgx/v5/stdlib` in workflow-backend `go.mod` | **Already present** (`v5.7.4`) | `database/sql` + pgx stdlib required by goose |
| Migration SQL content | Stable — no changes | Files copied verbatim; checksums preserved |
| goose version table (`goose_db_version`) | No change | goose uses the same table regardless of which service runs it |
| `DATABASE_URL` env var | Both services already require it | No change to config |
| T2 depends on T1 | Hard dependency | SQL files must exist in workflow-backend before they are deleted from workspace-github-adapter |

---

## 6. Parallelization / Blocking Analysis

```
T1: Add migrations + auto-run to workflow-backend    [workflow-backend]
  └── Can begin now — no blockers

  T2: Remove migrations + migrate binary from workspace-github-adapter    [workspace-github-adapter]
    └── BLOCKED on T1 (migration SQL files must be established in workflow-backend
        before they are deleted from workspace-github-adapter — deleting first
        would lose the files if T1 is not merged)
```

T1 and T2 are strictly sequential. T2 is a cleanup task; it is safe to merge only after T1's PR is merged and the files are confirmed present in workflow-backend.

---

## 7. Repository Impact

| Repo | Change |
|---|---|
| `workflow-backend` | Add `internal/database/migrations/` (11 SQL files), `internal/database/migrate.go`, 2-line change to `cmd/api-service/main.go` |
| `workspace-github-adapter` | Remove `database/migrations/`, `database/migrate.go`, `cmd/migrate/`, update `Dockerfile`, update `docker-compose.yml` |
| All others | Unaffected |

---

## 8. Validation and Release Impact

### Testing expectations

- **T1**: Verify `go build ./...` passes in workflow-backend after adding files. Add or update a test that calls `RunMigrations` against a real (testcontainers) or stubbed postgres; confirm it completes without error. Confirm that starting api-service with a fresh database applies all 11 migrations before the HTTP server accepts requests. Confirm that re-starting api-service with an already-migrated database is a no-op (goose skips applied versions).
- **T2**: Verify `go build ./...` passes in workspace-github-adapter after removals. Verify docker-compose `migrate` service is gone and `adapter-service`/`adapter-worker` start cleanly against a pre-migrated postgres.

### Migration / config impact

- No new environment variables.
- Existing `DATABASE_URL` on both services is unchanged.
- `goose_db_version` table is unaffected.

### Rollout concerns

- **Deploy order matters**: `workflow-backend` must start (and complete migrations) before `adapter-service` on any first-boot against a fresh database. For existing deployments where migrations have already been applied, adapter-service can start in any order.
- If T1 and T2 are deployed simultaneously against a fresh database, there is a brief window where neither service has run migrations yet. Deploy T1 first, confirm api-service has started successfully, then deploy T2.

### Backward compatibility

- No schema changes. No API changes. No data migration.
- After T2 merges, `workspace-github-adapter` no longer ships a `/migrate` binary; any external tooling or CI scripts that reference that binary must be updated (none are known).
