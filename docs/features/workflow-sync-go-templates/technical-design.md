# Technical Design

## Feature
- Feature ID: `workflow-sync-go-templates`
- Title: Sync Go Microservice Structure — workflow-backend & workspace-github-adapter

---

## Current State

### Template (`workflow/templates/go-microservice`)
The canonical reference defines these conventions:
- **Entrypoint**: single `cmd/main.go` using cobra with `api` and `migration` subcommands; config file path passed via `-c` flag
- **Config**: `configs/` package at repo root; viper loads a YAML file with env-variable overrides; global `configs.G *Config` pointer
- **Logging**: zerolog via `github.com/rs/zerolog`
- **HTTP framework**: gin, with `gin-contrib/requestid` and a structured request/response log middleware
- **HTTP response helpers**: `internal/app/api/response/` package — `RespondSuccess`, `RespondFailure`, `AbortWithErrorResponse`; envelope shape: `{code int, message string, data any, request_id string}`
- **Error type**: `internal/domain/errorz/` — `errorz.Error{Code int, Message string}`; codes encode HTTP status × 1000 + discriminator
- **Route structure**: `internal/app/api/route/v1/{domain}/handler.go`
- **Domain layer**: `entity/`, `repository/` interfaces, `service/`, `errorz/`
- **Infrastructure layer**: `internal/inf/` — GORM models + concrete repository implementations
- **DB package**: `pkg/db/` — GORM client, TransactionManager
- **Migrations**: `migrations/` at repo root
- **Tooling**: `Makefile` (`run-api`, `migrate-up`, `migrate-down-1`, `lint`, `test`), `.golangci.yml`

### workflow-backend (current)
- `cmd/api-service/main.go`: monolithic main — HTTP server setup, middleware wiring, route registration, and signal handling all inline; no cobra
- `internal/config/config.go`: reads env variables only; no YAML, no viper
- `internal/handler/workspace.go`: flat handler struct; custom `apiSuccessResponse{success, data}` and `apiErrorResponse{success, error}` envelopes inline
- `internal/service/workspace.go`: business logic; direct dependency on `database.*` types
- `internal/domain/errors.go`: `SourceError{Code ErrorCode string, Message, Source, Retryable, Path}` — string-code error type
- `internal/database/`: pgx + pgxpool; sqlc-generated queries; migrations at `internal/database/migrations/`
- No Makefile, no `.golangci.yml`, no zerolog, no request-ID middleware

### workspace-github-adapter (current)
- `cmd/adapter-service/main.go`: ~800 lines — HTTP mux setup, all three HTTP handlers, business logic (import placeholder, sync run insertion, GitHub URL parsing, slugification), and a dozen helper functions all in `package main`; no cobra
- `cmd/adapter-worker/main.go`: Asynq worker setup; task handlers inline; no cobra
- `internal/config/config.go`: env-only loading; no YAML, no viper
- `internal/domain/errors.go`: same `SourceError` shape as workflow-backend (minor constructor coverage differences)
- `internal/database/`: sqlc-generated types; no migration files (adapter shares DB managed by workflow-backend)
- No Makefile, no `.golangci.yml`, no zerolog, no request-ID middleware

---

## Constraints

1. **API contract must not change.** `digital-factory-ui` consumes workflow-backend's HTTP API. Response field names in the JSON payload — including envelope fields — must remain stable.
2. **sqlc is retained** in workspace-github-adapter. The product spec explicitly excludes GORM migration.
3. **stdlib `net/http` is retained** in workspace-github-adapter. Gin migration is out of scope.
4. **Dual-binary deployment** of workspace-github-adapter is preserved. The adapter ships as two Docker images (`adapter-service`, `adapter-worker`). These remain separate binaries.
5. **Database schema** is frozen for both repos.

---

## Problem Framing

Six concrete gaps exist across both repos:

| Gap | workflow-backend | workspace-github-adapter |
|---|---|---|
| No Makefile / `.golangci.yml` | ✗ | ✗ |
| stdlib `log` instead of zerolog | ✗ | ✗ |
| Env-only config vs YAML + viper | ✗ | ✗ |
| Non-standardized HTTP response helpers | ✗ | ✗ |
| Ad-hoc error construction (no package discipline) | ✗ | ✗ |
| Migrations not at repo root | ✗ | N/A (no migrations) |

Plus one adapter-specific structural gap:
- **Handler logic lives in `main` package** — `cmd/adapter-service/main.go` mixes HTTP routing, three handler implementations, import/sync business logic, and ~12 helper functions in one 800-line file. No testable separation.

---

## Options Considered

### Option A — Full template parity (including GORM, numeric error codes, single binary)
Adopt every template convention verbatim: GORM replaces pgx/sqlc, error codes become ints (HTTP×1000+discriminator), a single cobra binary replaces the adapter's dual binaries.

- **Pros**: Maximum conformance to template; future template improvements propagate directly.
- **Cons**: GORM migration is a high-risk rewrite; numeric error codes break the existing JSON API contract consumed by `digital-factory-ui`; collapsing two binaries requires deployment changes. All explicitly excluded by product spec non-goals.
- **Verdict**: Rejected.

### Option B — Structural + tooling alignment, preserve API contract (chosen)
Adopt the template's project layout conventions, tooling, logging, config loading, and code organization discipline — but:
- Keep the existing JSON error/response envelope shapes (preserving API contract)
- Retain sqlc and stdlib `net/http` in the adapter
- Keep dual-binary deployment for the adapter; add cobra for the `-c config.yaml` flag pattern within each binary
- Create a `response` package in each repo that wraps the repo's existing envelope shape in a shared helper (standardizing where responses are produced, not what they look like)

- **Pros**: Achieves all tooling and code discipline goals; zero API breakage; bounded scope.
- **Cons**: Template envelope shape differs from what we produce — documented acceptable deviation.
- **Verdict**: Chosen.

### Option C — Tooling only (Makefile, golangci)
Add Makefile and `.golangci.yml` but leave code structure untouched.

- **Pros**: Lowest risk, smallest diff.
- **Cons**: Doesn't address logging, config, or handler isolation gaps; agents still encounter inconsistent patterns across repos.
- **Verdict**: Rejected as insufficient.

---

## Chosen Design

### Shared conventions for both repos

**1. Tooling**
- Add `Makefile` with targets: `run-api` (or `run-service` / `run-worker`), `migrate-up`, `migrate-down-1`, `lint`, `test`
- Add `.golangci.yml` verbatim from the template (linters: `errcheck`, `gosimple`, `govet`, `ineffassign`, `staticcheck`, `unused`, `gofmt`, `goimports`, `misspell`, `unconvert`, `unparam`, `bodyclose`, `exportloopref`, `gocritic`, `noctx`); set `goimports.local-prefixes` to the repo's module path

**2. Config package**
- Add `configs/` directory at repo root
- `configs/configs.go`: viper loading function; takes the config file path; calls `v.AutomaticEnv()` for env-variable overrides; unmarshals into a typed `Config` struct
- `configs/config.yaml`: YAML template with all config keys; sensitive values as placeholder strings
- **No global `G *Config`**: unlike the template, pass the loaded `*Config` to constructors explicitly (the global is an anti-pattern for testing; both repos already pass config explicitly)
- Old `internal/config/config.go` is removed; callers updated to use `configs.Load(path)`
- Env-variable override naming: viper key delimiter `::` → env key `_` (matches template)

**3. Logging**
- Replace all `log.Printf` / `log.Fatalf` (stdlib) with zerolog equivalents: `log.Info()`, `log.Fatal()`, `log.Warn()`, etc.
- Initialize zerolog level from config `log.level`; set `zerolog.TimeFieldFormat`
- For gin (workflow-backend): add `gin-contrib/requestid` + structured request/response log middleware (`internal/app/api/middleware/log.go` verbatim from template)

**4. Response package**
Each repo gets `internal/app/api/response/` (workflow-backend uses gin; adapter uses stdlib). The package exposes helpers that wrap the **repo's existing JSON envelope** — not the template's `{code, message, data}` shape — to preserve API contracts with `digital-factory-ui`.

workflow-backend response package:
```go
func RespondOK(c *gin.Context, data interface{})    // {success: true, data: data}
func RespondError(c *gin.Context, se domain.SourceError)  // {success: false, error: {...}}
func RespondValidationError(c *gin.Context, msg string)   // {success: false, error: {...}}
```

workspace-github-adapter response package (stdlib):
```go
func WriteOK(w http.ResponseWriter, status int, value interface{})
func WriteSourceError(w http.ResponseWriter, se domain.SourceError)
```

All inline `c.JSON(...)` and `writeJSON(...)` calls in handlers are replaced by these helpers. No JSON shape changes.

**5. Error package discipline**
Both repos already have `internal/domain/errors.go` with well-defined `SourceError` and constructor functions. The gap is consistency of constructor naming and coverage. Changes:
- Ensure all error construction goes through named constructors (no inline `SourceError{...}` literals in handlers or services)
- Align constructor set: add any constructors present in one repo but missing in the other where applicable
- The type and JSON shape stay exactly as-is — this is a code-discipline change, not a type change

**Note on template deviation**: The template uses `errorz.Error{Code int}`. We retain `SourceError{Code ErrorCode string}` because changing to numeric codes would alter the JSON error `code` field, breaking `digital-factory-ui`. This deviation is intentional and documented.

**6. Migrations location (workflow-backend only)**
Move migration files from `internal/database/migrations/` → `migrations/` at repo root. Update the migration runner's path reference.

### workflow-backend specific

**Entrypoint (cobra)**
Refactor `cmd/api-service/main.go` into:
```
cmd/
  main.go           — cobra root; registers api + migration subcommands; --config flag
  api/
    api.go          — api subcommand RunE: init zerolog, load config, wire DB/services/handlers, start gin
  migration/
    migration.go    — migration subcommand RunE: run goose/migrate-up/down
```

Middleware added in the `api` subcommand's `RunE`:
- `requestid.New()`
- `middleware.Log(skipPathSet)`
- `gin.Recovery()`
- CORS (existing inline CORS logic extracted)

The route registration stays in `handler.RegisterRoutes(rg)` — no structural change to handler or service.

**Handler layer**
- `internal/handler/workspace.go`: replace all inline `apiSuccessResponse` / `apiErrorResponse` literals with `response.RespondOK` / `response.RespondError`
- Move `respondOK`, `respondError`, `respondSourceError`, `sourceErrorHTTPStatus`, `parsePagination` out of `workspace.go` into the `response` package

### workspace-github-adapter specific

**Handler extraction from `main.go`**
Split `cmd/adapter-service/main.go` from one 800-line file into:
```
cmd/adapter-service/
  main.go           — wiring only: load config, build deps, register mux routes, start server (~50 lines)
internal/handler/
  import.go         — importWorkspaceHandler + all import helpers (findExistingImport, createImportPlaceholder, slugify, etc.)
  sync.go           — internalWorkspaceHandler
  webhook.go        — webhookHandler + webhook routing helpers (writeExistingImport, basePushTargetedSyncPayloads, etc.)
internal/httputil/
  response.go       — writeJSON, writeSourceError, writeAnyError helpers (shared by handlers)
internal/pgutil/
  uuid.go           — pgUUID, uuidString (shared helpers)
internal/urlutil/
  github.go         — parseGitHubRepo
```

The `serviceHandler` struct moves to `internal/handler/` as a shared handler struct that is constructed in `cmd/adapter-service/main.go` and injected.

`cmd/adapter-worker/main.go`: extract Asynq task handler functions into `internal/worker/` (parallel to the `handler/` extraction).

**Entrypoint (cobra)**
Each binary adds cobra for the `-c config.yaml` flag:
- `cmd/adapter-service/main.go`: cobra root with single `serve` subcommand; `--config` flag
- `cmd/adapter-worker/main.go`: cobra root with single `work` subcommand; `--config` flag

---

## Dependency Analysis

### Internal dependencies
- T3 (workflow-backend HTTP conventions) has no hard dependency on T2 (config/logging) — the `response` and `errorz` packages are pure logic. However, the gin middleware (`middleware.Log`) uses zerolog. This middleware is wired in T4 (entrypoint). Therefore T3 can run fully in parallel with T2.
- T4 (workflow-backend entrypoint) depends on both T2 (configs package must exist for cobra to load it) and T3 (response/errorz packages must exist for the api subcommand to wire correctly).
- T7 (adapter handler extraction) depends on T6 (zerolog must be available to replace stdlib log inside the extracted handlers; configs package must exist for handler constructor signatures).

### External dependencies
- None. All changes are internal refactors. No new external service dependencies.

### Vendor/tooling
- `github.com/rs/zerolog` — add to both repos (already in template; new dependency for these repos)
- `github.com/spf13/cobra` — add to workflow-backend (already in template; new dependency)
- `github.com/spf13/viper` — add to both repos
- `github.com/gin-contrib/requestid` — add to workflow-backend
- `gopkg.in/yaml.v3` — may be needed for config YAML (viper handles this)
- workspace-github-adapter retains `github.com/hibiken/asynq`, `github.com/jackc/pgx/v5`, sqlc — no change

### Blocking decisions
- **API envelope shape**: Decision is fixed — preserve existing envelope. No further approval needed.
- **Error code type**: Decision is fixed — retain string codes. No further approval needed.
- **Adapter dual-binary**: Decision is fixed — retained. No further approval needed.

### Release dependencies
- Both repos' CI pipelines run `go build` and `go test`. Adding zerolog, cobra, and viper as new dependencies requires `go mod tidy` and a `go.sum` update — CI picks these up automatically on PR.
- `.golangci.yml` addition: CI pipelines may need a lint step added. Check `.github/workflows/ci.yaml` in each repo during task execution and add `golangci-lint run` if absent.

---

## Parallelization / Blocking Analysis

```
T1: workflow-backend — tooling (Makefile, .golangci.yml, move migrations/ to root)
  └── Can begin now — no blockers

T2: workflow-backend — config + logging (configs/ package with viper + YAML, zerolog)
  └── Can begin now — no blockers
  └── T1 and T2 run in parallel

T3: workflow-backend — HTTP conventions (response package, errorz discipline, update handlers/service)
  └── Can begin now — no blockers
  └── T1, T2, and T3 run in parallel
  │
  T4: workflow-backend — cobra entrypoint + middleware wiring (requestid, log middleware, CORS)
      └── BLOCKED on T2 (configs/ package must exist; zerolog must be initialized in entrypoint)
      └── BLOCKED on T3 (response/errorz packages must exist to wire api subcommand)

T5: workspace-github-adapter — tooling (Makefile, .golangci.yml)
  └── Can begin now — no blockers
  └── T5 runs in parallel with T1–T3

T6: workspace-github-adapter — config + logging (configs/ package with viper + YAML, zerolog, both binaries)
  └── Can begin now — no blockers
  └── T5 and T6 run in parallel
  │
  T7: workspace-github-adapter — handler extraction + entrypoint refactor + HTTP conventions
      └── BLOCKED on T6 (zerolog must replace stdlib log inside extracted handlers; configs/ must exist for handler wiring)

Note: T4 and T7 are in different repos and run in parallel with each other once their respective blockers are cleared.
```

---

## Repository Impact

| Repo | Tasks | Changes |
|---|---|---|
| `workflow-backend` | T1–T4 | Makefile, .golangci.yml, migrations/ move, configs/ package, zerolog, response package, errorz discipline, cobra entrypoint, request-ID + log middleware |
| `workspace-github-adapter` | T5–T7 | Makefile, .golangci.yml, configs/ package, zerolog, handler extraction (3 handlers + helpers out of main), response/error helpers into internal/, cobra for both binaries |

No changes to `digital-factory-ui`, `rag-service`, `git-nexus`, or `management-repo`.

---

## Validation and Release Impact

### Testing
- All existing tests in both repos must pass after each task. The refactors are behaviour-preserving.
- `golangci-lint run` must pass (zero errors) before any PR is opened.
- workflow-backend has integration tests (`internal/integration/`) that exercise the full handler→service→DB path; these validate that the response package and handler refactor don't change observable behaviour.
- workspace-github-adapter has unit tests for handlers, domain, GitHub adapter, and webhook parsing; these validate the extraction refactor.

### Migration path
- Moving `internal/database/migrations/` → `migrations/` in workflow-backend requires updating the path string in `database.RunMigrations(ctx, cfg.DatabaseURL)`. The migration runner (`golang-migrate` or goose — confirm during T1) must be pointed at the new root path. No SQL is changed.

### Rollout
- All changes are additive refactors with no schema or API changes. Each task can be reviewed and merged independently.
- workflow-backend and workspace-github-adapter deploy as Docker images; no special release coordination required beyond normal CI.
- `.golangci.yml` addition may surface pre-existing lint errors. The implementing agent must fix all lint errors before opening a PR (per workspace pre-push-checks rule). Expect a non-trivial set of initial lint fixes — treat these as part of the task scope.

### Backward compatibility
- JSON API contracts: unchanged (explicitly preserved).
- Config loading: both repos transition from env-only to YAML + env-override. The YAML file provides defaults; env vars override. Existing Docker/compose deployments that set env vars continue to work without change — env overrides take precedence.
- Deployment: dual-binary structure of workspace-github-adapter is preserved. No Dockerfile or compose changes required beyond ensuring the `-c configs/config.yaml` flag is passed (or a default path is used).
