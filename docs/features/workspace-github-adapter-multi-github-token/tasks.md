# Task Breakdown — workspace-github-adapter-multi-github-token

Feature status: `in_tdd` | Stage: `tasks` (draft) | Machine state lives in `tasks/T<n>.yaml`.

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|-----------|
| T1 | 1 | Adapter multi-token: splitTokens, tokenFor probe-and-cache | — |
| T2 | 2 | Wiring cleanup: remove handler Token fields | T1 |

---

## T1 — Adapter multi-token: splitTokens, tokenFor probe-and-cache

### Description

Update `internal/github/adapter.go` to support a comma-separated list of bare PATs in the
existing `token` string. `New(token string)` signature stays unchanged; internally it splits the
value on `,` to build `tokens []string`.

Add `tokenCache map[string]string` (owner → resolved token) to `Adapter`. Implement
`splitTokens(raw string) []string` and `tokenFor(ctx context.Context, owner string) string`.
`tokenFor` checks the cache first; on miss, probes `tokens` in order by attempting a lightweight
GitHub API call (e.g. checking repo existence) until one succeeds, then caches the winner. If all
tokens return 401/403 for the given owner, return a clear `SourceError` with code
`ErrGitHubUnauthorized` and message `"no valid GitHub token found for owner \"<owner>\""`.

Update the four adapter methods that currently hard-code `a.token`:

- `SyncWorkspace` — call `parseRepoURL(repoURL)` to get owner, then `a.tokenFor(ctx, owner)`.
- `FetchFeature` — same pattern.
- `FetchTask` — same pattern.
- `repoTarget()` (used by `ImportWorkspace` / `FetchWorkspaceMetadata`) — when `input.Token == ""`,
  use `a.tokenFor(ctx, owner)` instead of `a.token`. When `input.Token != ""`, keep using it
  (explicit override preserved).

Update `internal/github/adapter_test.go` and `internal/github/fetch_targeted_test.go`:
- Pass `cfg.GitHub.Token` string as before to `ghadapter.New` — no call-site change.
- Add unit tests for `splitTokens` (single, comma-separated, empty, whitespace).
- Add tests for `tokenFor`: single-token hit, multi-token hit on first, multi-token hit on second
  (simulated 401 on first), all-fail path.

### Required skills
- go-best-practices

### Subtasks
- [ ] Add `tokens []string` and `tokenCache map[string]string` fields to `Adapter` struct
- [ ] Implement `splitTokens(raw string) []string` — split on `,`, trim whitespace, drop empties
- [ ] Update `New(token string)` to call `splitTokens`, fall back to `GITHUB_TOKEN` env var when list is empty
- [ ] Implement `tokenFor(ctx, owner)` — cache check → probe in order → cache winner → all-fail SourceError
- [ ] Update `SyncWorkspace` to use `tokenFor`
- [ ] Update `FetchFeature` to use `tokenFor`
- [ ] Update `FetchTask` to use `tokenFor`
- [ ] Update `repoTarget()` to use `tokenFor` when `input.Token == ""`
- [ ] Add `splitTokens` unit tests
- [ ] Add `tokenFor` probe-and-cache unit tests (single, multi-success-first, multi-success-second, all-fail)
- [ ] Run `golangci-lint run` — zero errors
- [ ] Run full test suite — all pass

---

## T2 — Wiring cleanup: remove handler Token fields

### Description

Remove the vestigial `Token string` field from both handler structs and all their downstream
`ImportInput` call sites, now that the adapter resolves tokens internally.

Files to change:

- `internal/handler/handler.go` — remove `Token string` from `ServiceHandler`.
- `internal/worker/handler.go` — remove `Token string` from `worker.Handler`.
- `cmd/api/api.go` — remove `Token: cfg.GitHub.Token` from `ServiceHandler` construction; add
  startup log of token count (not values) after `ghadapter.New`.
- `cmd/worker/worker.go` — remove `Token: cfg.GitHub.Token` from `worker.Handler` construction.
- `internal/handler/import.go` — remove `Token: h.Token` from `domain.ImportInput{...}`.
- `internal/worker/workspace_sync.go` — remove `Token: h.Token` from `domain.ImportInput{...}`.

Update any test files that set `Token:` on either handler struct — remove those field assignments.

Add a startup `WARN` log in both `cmd/api/api.go` and `cmd/worker/worker.go` when
`cfg.GitHub.Token` is empty (after `ghadapter.New`) so operators catch misconfiguration early.

### Required skills
- go-best-practices

### Subtasks
- [ ] Remove `Token string` from `internal/handler/handler.go` (`ServiceHandler`)
- [ ] Remove `Token string` from `internal/worker/handler.go` (`worker.Handler`)
- [ ] Remove `Token: cfg.GitHub.Token` from `cmd/api/api.go` handler construction
- [ ] Add startup INFO log of token count in `cmd/api/api.go` (count only, never token values)
- [ ] Add startup WARN log when token string is empty in `cmd/api/api.go`
- [ ] Remove `Token: cfg.GitHub.Token` from `cmd/worker/worker.go` handler construction
- [ ] Add startup WARN log when token string is empty in `cmd/worker/worker.go`
- [ ] Remove `Token: h.Token` from `internal/handler/import.go` `ImportInput` literal
- [ ] Remove `Token: h.Token` from `internal/worker/workspace_sync.go` `ImportInput` literal
- [ ] Fix any test files that reference `ServiceHandler.Token` or `worker.Handler.Token`
- [ ] Run `golangci-lint run` — zero errors
- [ ] Run full test suite — all pass
