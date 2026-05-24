# Product Specification

## Feature
- Feature ID: `workflow-sync-go-templates`
- Title: Sync Go Microservice Structure — workflow-backend & workspace-github-adapter

## Problem

Both `workflow-backend` and `workspace-github-adapter` were built incrementally and diverged from the canonical Go microservice template at `workflow/templates/go-microservice`. The divergences span project layout, entrypoint design, config loading, logging, HTTP response conventions, error types, and tooling.

This creates three practical problems:
1. **Agent inconsistency** — agents working across these repos encounter different conventions for the same concerns (config loading, error handling, HTTP responses), increasing the chance of mistakes and rework.
2. **Missing tooling** — neither repo has a `Makefile` or `.golangci.yml`, so there is no standard way to run, migrate, lint, or test the service locally.
3. **Maintenance burden** — deviating from the template means improvements to the template do not propagate, and onboarding new contributors requires repo-specific knowledge that should not exist.

## Goals

1. Align both repos to the canonical template's project layout (`cmd/`, `configs/`, `internal/app/api/`, `internal/domain/`, `internal/inf/`, `pkg/`, `migrations/`)
2. Adopt template entrypoint pattern — cobra CLI with `api` and `migration` subcommands — in both repos
3. Replace stdlib `log` with zerolog in both repos
4. Replace env-only config loading with `configs/` package using viper + YAML, backed by env overrides
5. Adopt standardized HTTP response envelope (`response.RespondSuccess` / `response.RespondFailure`) in both repos
6. Replace string-code `SourceError` / `ErrorCode` with typed `errorz.Error{Code int}` (HTTP×1000+discriminator convention) in both repos
7. Add `Makefile` with standard targets (`run-api`, `migrate-up`, `migrate-down-1`, `lint`, `test`) to both repos
8. Add `.golangci.yml` with the template's linter set to both repos
9. Move migration files from `internal/database/migrations/` to `migrations/` at repo root in both repos
10. Add request-ID middleware to both repos

## Non-goals

- Rewriting business logic or changing API contracts — HTTP routes, request/response field names, and database schemas stay the same
- Migrating `workspace-github-adapter` from sqlc to GORM — sqlc is an acceptable divergence for its use case (generated type-safe queries); the template's GORM usage is a starting point, not a mandate
- Migrating `workspace-github-adapter` from stdlib `net/http` to gin — acceptable divergence if the HTTP handler structure is cleaned up and the response/error conventions align
- Adding new product features

## Scope

| Repo | In scope |
|---|---|
| `workflow-backend` | All goals above |
| `workspace-github-adapter` | All goals above; sqlc and stdlib `net/http` are retained but handler code must be extracted out of `main.go` |

## Success criteria

- Both repos pass `golangci-lint run` with zero errors using the template's `.golangci.yml` linter set
- Both repos have a working `make run-api` and `make test`
- Both repos have a working `make migrate-up` using the root `migrations/` directory
- HTTP responses in both repos use the template's `SuccessResponse` / `ErrorResponse` envelope shape
- `workspace-github-adapter`'s `cmd/adapter-service/main.go` is reduced to wiring only — all handler logic extracted into `internal/`
- Both repos use zerolog for structured logging
- Both repos load config from `configs/config.yaml` with env-variable overrides
