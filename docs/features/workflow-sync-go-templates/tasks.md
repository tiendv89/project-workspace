# Task Breakdown — workflow-sync-go-templates

Feature status: `in_tdd` → `ready_for_implementation` (after tasks approval)  
Stage: `tasks` (awaiting approval)  
Machine state (status, log, PR) lives in `tasks/T<n>.yaml` — not here.

---

## Index

| ID | Wave | Title | Repo | Depends on |
|---|---|---|---|---|
| T1 | 1 | Tooling — Makefile, .golangci.yml, move migrations | `workflow-backend` | — |
| T2 | 1 | Config + logging — configs/ package, viper, zerolog | `workflow-backend` | — |
| T3 | 1 | HTTP conventions — response package, errorz discipline | `workflow-backend` | — |
| T4 | 2 | Cobra entrypoint + middleware wiring | `workflow-backend` | T2, T3 |
| T5 | 1 | Tooling — Makefile, .golangci.yml | `workspace-github-adapter` | — |
| T6 | 1 | Config + logging — configs/ package, viper, zerolog | `workspace-github-adapter` | — |
| T7 | 2 | Handler extraction + entrypoint refactor + HTTP conventions | `workspace-github-adapter` | T6 |

---

## T1 — Tooling: Makefile, .golangci.yml, move migrations

### Description
Add the standard Go microservice tooling to `workflow-backend` and relocate migration files to the repo root where the template expects them.

- Add `Makefile` with targets: `run-api`, `migrate-up`, `migrate-down-1`, `new-migration`, `lint`, `test`
  - `run-api`: `go run ./cmd api -c configs/config.yaml`
  - `migrate-up`: `go run ./cmd migration -u 0 -c configs/config.yaml`
  - `migrate-down-1`: `go run ./cmd migration -d 1 -c configs/config.yaml`
  - `lint`: `golangci-lint run`
  - `test`: `go test ./... -race`
  - Note: the `cmd` entrypoint structure is created in T4; for now, leave `run-api` and migrate targets as comments or stubs pointing at `cmd/api-service` until T4 lands
- Add `.golangci.yml` from the template verbatim; set `goimports.local-prefixes: github.com/tiendv89/workflow-backend`
- Move `internal/database/migrations/*.sql` → `migrations/` at repo root; update the path string passed to the migration runner in `cmd/api-service/main.go` (`database.RunMigrations`)
- Run `golangci-lint run` and fix all resulting errors (lint errors discovered here are in scope)
- Run full test suite (`go test ./... -race`) — must pass before PR

### Required skills
- `go-best-practices`

### Subtasks
- [ ] Add `Makefile` with all six targets
- [ ] Add `.golangci.yml` (copy from template, set `goimports.local-prefixes`)
- [ ] Move `internal/database/migrations/` → `migrations/`
- [ ] Update migration path in `cmd/api-service/main.go`
- [ ] Update `Dockerfile` if it references `internal/database/migrations`
- [ ] Run `golangci-lint run`; fix all errors
- [ ] Run `go test ./... -race`; confirm green

---

## T2 — Config + logging: configs/ package, viper, zerolog

### Description
Replace `workflow-backend`'s env-only config loading with a `configs/` package backed by viper + YAML with env-variable overrides, and replace stdlib `log` with zerolog throughout.

**configs/ package:**
- `configs/configs.go`: `Load(path string) (*Config, error)` function using viper; `v.SetEnvKeyReplacer("::" → "_")`, `v.AutomaticEnv()`; no global `G` pointer — return the struct explicitly
- `configs/config.yaml`: YAML with all config keys; placeholders for sensitive values (`DATABASE_URL`, `ADAPTER_SERVICE_URL`, etc.)
- `Config` struct covers: `Log.Level`, `API.Port`, `API.StaleThresholdMinutes`, `API.AdapterServiceURL`, `Database.URL`
- Remove `internal/config/config.go`; update `cmd/api-service/main.go` to call `configs.Load(cfgFile)` for its config

**zerolog:**
- Add `github.com/rs/zerolog` to `go.mod`
- Replace all `log.Printf` / `log.Fatalf` / `log.Println` (stdlib) with zerolog equivalents in `cmd/api-service/main.go`, `internal/service/workspace.go`, `internal/adapter/rpc.go`, `internal/database/`
- Initialize zerolog in `cmd/api-service/main.go`: parse level from `cfg.Log.Level`, set `zerolog.TimeFieldFormat`

The cobra entrypoint is wired in T4; this task updates the existing `main.go` to use viper-loaded config and zerolog — the entrypoint shape is left as-is for now.

### Required skills
- `go-best-practices`

### Subtasks
- [ ] Add `configs/configs.go` with `Load()` function
- [ ] Add `configs/config.yaml` with all keys
- [ ] Add `github.com/rs/zerolog` and `github.com/spf13/viper` to `go.mod`; run `go mod tidy`
- [ ] Remove `internal/config/config.go`
- [ ] Update `cmd/api-service/main.go` to call `configs.Load`
- [ ] Replace all stdlib `log.*` calls with zerolog; initialize zerolog level from config
- [ ] Run `golangci-lint run`; fix errors
- [ ] Run `go test ./... -race`; confirm green

---

## T3 — HTTP conventions: response package, errorz discipline

### Description
Extract the inline response-building logic from `workflow-backend`'s handler into a shared `response` package, and eliminate all inline `SourceError{...}` literals by routing construction through named constructors.

**Response package** (`internal/app/api/response/`):
- `RespondOK(c *gin.Context, data interface{})` → `c.JSON(200, apiSuccessResponse{Success: true, Data: data})`
- `RespondError(c *gin.Context, se domain.SourceError)` → computes HTTP status from `se.Code`, writes `apiErrorResponse`
- `RespondValidationError(c *gin.Context, code domain.ErrorCode, msg string)` → shorthand for validation responses
- `ParsePagination(c *gin.Context) (page, limit int, ok bool)` — extracted from handler

Move the following out of `internal/handler/workspace.go` into the response package:
- `respondOK`, `respondError`, `respondSourceError`, `sourceErrorHTTPStatus`, `parsePagination`
- `apiSuccessResponse`, `apiErrorResponse`, `apiErrorBody` type definitions

Update `internal/handler/workspace.go` to call `response.*` helpers — no JSON shape changes.

**errorz discipline:**
- Audit `internal/handler/workspace.go` and `internal/service/workspace.go` for any inline `domain.SourceError{...}` struct literals; replace with constructor calls (`domain.NewDatabaseError`, `domain.NewValidationError`, etc.)
- Add `domain.ErrValidationInvalidQuery` constructor if missing
- Add `domain.NewDatabaseNotFound` if missing (already exists — verify)

### Required skills
- `go-best-practices`

### Subtasks
- [ ] Create `internal/app/api/response/` directory and `http_response.go`
- [ ] Move `apiSuccessResponse`, `apiErrorResponse`, `apiErrorBody` type defs into response package
- [ ] Implement `RespondOK`, `RespondError`, `RespondValidationError`, `ParsePagination`
- [ ] Update `internal/handler/workspace.go` to use `response.*` helpers
- [ ] Audit for inline `SourceError{...}` literals; replace with constructor calls
- [ ] Run `golangci-lint run`; fix errors
- [ ] Run `go test ./... -race`; confirm green

---

## T4 — Cobra entrypoint + middleware wiring

### Description
Refactor `workflow-backend`'s monolithic `cmd/api-service/main.go` into a cobra CLI following the template's `cmd/main.go` + `cmd/api/` + `cmd/migration/` layout, and wire the request-ID and structured log middleware.

**New file layout:**
```
cmd/
  main.go              — cobra root; registers api + migration commands; --config flag (required)
  api/
    api.go             — api subcommand RunE: init zerolog from config, wire DB/adapters/services/handlers, start gin
  migration/
    migration.go       — migration subcommand RunE: migrate-up (n=0 means all) or migrate-down (n steps)
```

**cobra root (`cmd/main.go`):**
- `--config` / `-c` flag marked required
- `cobra.OnInitialize`: call `configs.Load(cfgFile)` and initialize zerolog
- Register `api.Command` and `migration.Command`

**api subcommand (`cmd/api/api.go`):**
- Wire gin with: `requestid.New()`, `middleware.Log(skipPathSet)`, `gin.Recovery()`, CORS
- Create `internal/app/api/middleware/log.go` — structured request/response log middleware (from template)
- Construct `database.Pool`, `adapter.Client`, `service.WorkspaceService`, `handler.WorkspaceHandler`; call `handler.RegisterRoutes(api)`
- Use `signal.NotifyContext` for graceful shutdown (template pattern)

**migration subcommand (`cmd/migration/migration.go`):**
- Flags: `-u N` (migrate up N steps; 0 = all), `-d N` (migrate down N steps)
- Call `database.RunMigrations` with path from config

Remove `cmd/api-service/` directory (replaced by the new layout) after wiring is confirmed working.

Add `github.com/spf13/cobra` and `github.com/gin-contrib/requestid` to `go.mod`; run `go mod tidy`.

### Required skills
- `go-best-practices`

### Subtasks
- [ ] Add `github.com/spf13/cobra` and `github.com/gin-contrib/requestid` to `go.mod`
- [ ] Create `cmd/main.go` with cobra root and `--config` flag
- [ ] Create `cmd/api/api.go` — api subcommand with gin setup and middleware wiring
- [ ] Create `internal/app/api/middleware/log.go` (structured request/response log)
- [ ] Create `cmd/migration/migration.go` — migration subcommand
- [ ] Remove `cmd/api-service/` directory
- [ ] Update `Makefile` targets (`run-api`, `migrate-up`, `migrate-down-1`) to point at `./cmd`
- [ ] Verify `docker-compose.yml` and `Dockerfile` entrypoint commands; update if needed
- [ ] Run `golangci-lint run`; fix errors
- [ ] Run `go test ./... -race`; confirm green

---

## T5 — Tooling: Makefile, .golangci.yml (adapter)

### Description
Add standard Go microservice tooling to `workspace-github-adapter`. No code changes — tooling only.

- Add `Makefile` with targets:
  - `run-service`: `go run ./cmd/adapter-service serve -c configs/config.yaml`
  - `run-worker`: `go run ./cmd/adapter-worker work -c configs/config.yaml`
  - `lint`: `golangci-lint run`
  - `test`: `go test ./... -race`
  - Note: `run-service` and `run-worker` target the cobra subcommand added in T7; stub as `go run ./cmd/adapter-service` until T7 lands
- Add `.golangci.yml` from the template verbatim; set `goimports.local-prefixes: github.com/tiendv89/workspace-github-adapter`
- Run `golangci-lint run` and fix all resulting errors

### Required skills
- `go-best-practices`

### Subtasks
- [ ] Add `Makefile` with four targets
- [ ] Add `.golangci.yml` (copy from template, set `goimports.local-prefixes`)
- [ ] Run `golangci-lint run`; fix all errors
- [ ] Run `go test ./... -race`; confirm green

---

## T6 — Config + logging: configs/ package, viper, zerolog (adapter)

### Description
Replace `workspace-github-adapter`'s env-only config loading with a `configs/` package backed by viper + YAML, and replace stdlib `log` with zerolog in both binaries.

**configs/ package:**
- `configs/configs.go`: `Load(path string) (*Config, error)` using viper; no global `G`
- `configs/config.yaml`: YAML with all keys — `log.level`, `server.port`, `database.url`, `redis.url`, `github.token`, `github.webhook_secret`
- `Config` struct wraps all fields currently in `internal/config/config.go`
- Remove `internal/config/config.go`; update both `cmd/adapter-service/main.go` and `cmd/adapter-worker/main.go` to call `configs.Load`

**zerolog:**
- Add `github.com/rs/zerolog` to `go.mod`
- Replace all `log.Printf` / `log.Fatalf` / `log.Println` in both `cmd/adapter-service/main.go` and `cmd/adapter-worker/main.go` with zerolog
- Also replace in `internal/adapter/db/`, `internal/github/`, `internal/webhook/`, `internal/queue/`
- Initialize zerolog level from `cfg.Log.Level` in both entrypoints

The cobra subcommand refactor and handler extraction happen in T7; this task updates both `main.go` files in-place to use the new config and zerolog while leaving their overall structure unchanged.

### Required skills
- `go-best-practices`

### Subtasks
- [ ] Add `configs/configs.go` with `Load()` function
- [ ] Add `configs/config.yaml` with all keys
- [ ] Add `github.com/rs/zerolog` and `github.com/spf13/viper` to `go.mod`; run `go mod tidy`
- [ ] Remove `internal/config/config.go`
- [ ] Update `cmd/adapter-service/main.go` to call `configs.Load`
- [ ] Update `cmd/adapter-worker/main.go` to call `configs.Load`
- [ ] Replace all stdlib `log.*` calls with zerolog across both binaries and internal packages
- [ ] Initialize zerolog level in both entrypoints
- [ ] Run `golangci-lint run`; fix errors
- [ ] Run `go test ./... -race`; confirm green

---

## T7 — Handler extraction + entrypoint refactor + HTTP conventions (adapter)

### Description
The primary structural refactor for `workspace-github-adapter`: extract all handler and business logic from the 800-line `cmd/adapter-service/main.go` into testable internal packages, create a shared HTTP response/error helper package, adopt cobra in both binaries, and clean up both entrypoints to wiring-only.

**Handler extraction:**
Extract from `cmd/adapter-service/main.go` into:

| Source (main.go) | Destination |
|---|---|
| `importWorkspaceHandler` + import helpers (`findExistingImport`, `createImportPlaceholder`, `createImportPlaceholderWithQueries`, `upsertGitHubSourceWithQueries`, `insertRunningRun`, `markRunFailed`, `writeExistingImport`) | `internal/handler/import.go` |
| `internalWorkspaceHandler` | `internal/handler/sync.go` |
| `webhookHandler` + routing helpers (`findWorkspaceByRepoURL`, `enqueueTargetedSync`, `enqueueWorkspaceSync`, `enqueueWorkspaceSyncs`, `enqueueTaskSync`, `basePushTargetedSyncPayloads`) | `internal/handler/webhook.go` |
| `writeJSON`, `writeSourceError`, `writeAnyError` | `internal/httputil/response.go` |
| `pgUUID`, `uuidString` | `internal/pgutil/uuid.go` |
| `parseGitHubRepo`, `slugify`, `workspaceIDFromSyncPath`, `workspaceSyncTaskID` | `internal/urlutil/github.go` (parseGitHubRepo, slugify) and `internal/handler/util.go` (workspaceIDFromSyncPath, workspaceSyncTaskID) |
| `serviceHandler` struct + `taskEnqueuer` interface | `internal/handler/handler.go` |
| `isDedupeError`, `isUniqueViolation`, `isUniqueConstraintViolation` | `internal/pgutil/errors.go` |

**Worker extraction:**
Extract Asynq task handler functions from `cmd/adapter-worker/main.go` into `internal/worker/`:
- Task handler functions (the functions passed to `asynq.NewServeMux()`) → `internal/worker/workspace_sync.go`, `internal/worker/task_sync.go`
- Keep `cmd/adapter-worker/main.go` as wiring-only after extraction

**httputil response package (`internal/httputil/response.go`):**
- `WriteOK(w, status, value)` — wraps `writeJSON`
- `WriteSourceError(w, se)` — replaces `writeSourceError`; uses `domain.SourceError` status mapping
- No JSON envelope shape changes

**errorz discipline:**
- Replace any inline `domain.SourceError{...}` literals in the extracted handler files with constructor calls

**Cobra entrypoints:**
- `cmd/adapter-service/main.go`: cobra root, single `serve` subcommand with `--config` flag; RunE wires deps and starts `http.Server`
- `cmd/adapter-worker/main.go`: cobra root, single `work` subcommand with `--config` flag; RunE wires Asynq server

After extraction, `cmd/adapter-service/main.go` should be ~60 lines (imports + cobra root + RunE wiring only).

### Required skills
- `go-best-practices`

### Subtasks
- [ ] Add `github.com/spf13/cobra` to `go.mod`; run `go mod tidy`
- [ ] Create `internal/handler/handler.go` — `serviceHandler` struct + `taskEnqueuer` interface
- [ ] Create `internal/httputil/response.go` — `WriteOK`, `WriteSourceError`, `WriteAnyError`
- [ ] Create `internal/pgutil/uuid.go` — `pgUUID`, `uuidString`
- [ ] Create `internal/pgutil/errors.go` — `isDedupeError`, `isUniqueViolation`, `isUniqueConstraintViolation`
- [ ] Create `internal/urlutil/github.go` — `parseGitHubRepo`, `slugify`
- [ ] Create `internal/handler/import.go` — import handler + import helpers
- [ ] Create `internal/handler/sync.go` — sync handler
- [ ] Create `internal/handler/webhook.go` — webhook handler + routing helpers
- [ ] Create `internal/handler/util.go` — `workspaceIDFromSyncPath`, `workspaceSyncTaskID`
- [ ] Extract worker task handlers into `internal/worker/`
- [ ] Replace inline `SourceError{...}` literals with constructor calls in extracted files
- [ ] Refactor `cmd/adapter-service/main.go` to cobra root + `serve` subcommand (~60 lines)
- [ ] Refactor `cmd/adapter-worker/main.go` to cobra root + `work` subcommand
- [ ] Update `Makefile` `run-service` / `run-worker` targets to use cobra subcommand flags
- [ ] Update `Dockerfile` entrypoint if it invokes `main.go` directly
- [ ] Run `golangci-lint run`; fix errors
- [ ] Run `go test ./... -race`; confirm green
