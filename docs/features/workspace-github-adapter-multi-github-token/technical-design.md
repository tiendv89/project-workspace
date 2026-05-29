# Technical Design

## Feature
- Feature ID: `workspace-github-adapter-multi-github-token`
- Title: Multi GitHub Token Support for Workspace GitHub Adapter

---

## 1. Current State

### Configuration

`GitHubConfig` in `configs/configs.go` carries a single scalar token field:

```go
type GitHubConfig struct {
    Token         string `mapstructure:"token"`
    WebhookSecret string `mapstructure:"webhook_secret"`
}
```

`cmd/api/api.go` and `cmd/worker/worker.go` each read `cfg.GitHub.Token` at startup and pass it in
two places: to the adapter constructor and as a field on the handler struct.

### Adapter construction

`ghadapter.New(cfg.GitHub.Token)` creates a single `github.Adapter` whose `token` field is fixed
for the lifetime of the process:

```go
type Adapter struct {
    token string
}

func New(token string) *Adapter { ... }
```

`New` falls back to `os.Getenv("GITHUB_TOKEN")` when the argument is empty.

### Token usage across call sites

| Call site | How token is supplied |
|---|---|
| `ImportWorkspace` / `FetchWorkspaceMetadata` | `domain.ImportInput.Token` — per-call override exists; falls back to `a.token` inside `repoTarget()` |
| `SyncWorkspace` | `newClient(a.token)` — always uses adapter's stored token |
| `FetchFeature` | `newClient(a.token)` — always uses adapter's stored token |
| `FetchTask` | `newClient(a.token)` — always uses adapter's stored token |

`ImportWorkspace` and `FetchWorkspaceMetadata` already have a per-call token override mechanism via
`domain.ImportInput.Token`. `SyncWorkspace`, `FetchFeature`, and `FetchTask` do not — they
hard-wire to `a.token`.

### Handler token fields

Both `handler.ServiceHandler` and `worker.Handler` carry a `Token string` field that is populated
with `cfg.GitHub.Token` at startup and passed as `ImportInput.Token` in the import and sync flows.
This duplicates the token out of the adapter and into the handler layer.

### Constraint

The previous feature (`workspace-github-adapter-sync-multi-repo`) addressed per-workspace webhook
secret routing. That design is config-only (`github.webhook_secrets`) and does not touch token
resolution. These two problems are parallel and do not conflict.

---

## 2. Problem Framing

### What needs to change

1. The existing `github.token` config field must be extended to accept a comma-separated list of
   `owner:token` pairs in addition to the existing bare-token form. No new field is introduced.
2. The `github.Adapter` must parse the token string at construction and resolve the correct token
   by GitHub owner before creating an HTTP client, across all four adapter methods.
3. `handler.ServiceHandler.Token` and `worker.Handler.Token` become vestigial once the adapter
   handles routing internally — they should be removed to prevent stale per-handler overrides from
   masking the routing logic.

### What must remain stable

- `domain.GitHubWorkspaceAdapter` interface — no signature changes. Token routing is an
  implementation detail of the adapter, not a contract exposed to callers.
- `domain.ImportInput.Token` — kept as an explicit per-call override for tests and one-off API
  calls. When non-empty it still takes precedence over any map entry.
- All sync logic, queue logic, webhook routing, and DB layer — untouched.
- `ghadapter.New` fallback to `GITHUB_TOKEN` env var — preserved for single-token operators.

### Fixed assumptions

- Tokens are operator-managed via config file or environment variables. No DB storage of tokens.
- The adapter is a single process; the token map is built at startup and stays in memory.
- GitHub owner extraction from a `repoURL` is already implemented in `parseRepoURL` (the
  `Adapter` package). No new URL parsing is required.
- The matching key is the GitHub owner string (case-sensitive, exact match), not a prefix or
  pattern. Operators must use the exact string as it appears in the GitHub URL.

---

## 3. Options Considered

### Option A — Extend existing `token` field to a comma-separated list of bare tokens (chosen)

Keep `github.token` as the single config field. Extend its value format to support a
comma-separated list of bare PATs: `"ghp_abc,ghp_xyz"`. At startup the string is split on `,`
to produce a `[]string`. The adapter tries tokens in order for each request; the first token that
successfully authenticates against the target repo's owner is cached in an in-memory
`map[owner]string` for subsequent calls to the same owner.

- **Pros**: zero interface change; zero config-struct change (`Token string` stays as-is); no new
  field introduced; no `owner:token` syntax — operators just list PATs; backwards compatible — a
  single bare token (no comma) works exactly as before; env-var override unchanged
  (`GITHUB_TOKEN=ghp_abc,ghp_xyz`); `handler.Token` fields can be cleanly removed.
- **Cons**: requires process restart to add a token; first call to a new owner probes tokens in
  order (at most N GitHub API calls before caching kicks in, where N = number of tokens); lookup
  is per-owner not per-repo (one owner → one token).
- **Implementation impact**: `configs/configs.go` struct unchanged; adapter gains `tokens []string`
  + `tokenCache map[string]string` + `tokenFor(owner)` with probe-and-cache logic. ~2 files
  changed. No schema change.
- **Dependency impact**: none external.

### Option B — Per-workspace token stored in DB

Add a `github_token` column to `workspace_github_sources`. The sync worker reads the token from
the DB row before calling GitHub.

- **Pros**: dynamic (no restart); co-located with the workspace record.
- **Cons**: secrets in the DB (encryption concern); requires migration + sqlc regeneration +
  updated import API to accept a token parameter; significantly more scope. Explicitly out of
  scope per product spec.
- **Implementation impact**: DB migration, sqlc regeneration, updated import handler, new endpoint,
  config changes.

### Option C — Thread token through all call sites

Add a `token string` parameter to `SyncWorkspace`, `FetchFeature`, `FetchTask` in the
`domain.GitHubWorkspaceAdapter` interface. Each caller resolves the token per workspace and passes
it explicitly.

- **Pros**: explicit — token source is visible at each call site.
- **Cons**: interface change = all callers change + all test doubles change; pushes routing logic
  out of the adapter into every caller; the caller then needs the owner→token map anyway, so the
  map logic just moves up the stack.
- **Implementation impact**: larger — interface + adapter + handler + worker + tests.

Option A is the chosen design. Option B is out of scope per the product spec. Option C is more
invasive with no benefit over A for the goals stated.

---

## 4. Chosen Design

### Config layer — no struct change

`GitHubConfig` is unchanged. `Token string` already exists; operators extend its value with a
comma-separated list of bare PATs:

```go
// configs/configs.go — no change needed
type GitHubConfig struct {
    Token         string `mapstructure:"token"`
    WebhookSecret string `mapstructure:"webhook_secret"`
}
```

`config.yaml` examples:

```yaml
# Single workspace — existing format, no change
github:
  token: "ghp_abc"
```

```yaml
# Multiple orgs — list additional PATs separated by commas
github:
  token: "ghp_abc,ghp_xyz"
```

Environment variable: `GITHUB_TOKEN=ghp_abc,ghp_xyz` — same field, same env var name.

### Adapter — `tokens []string` + probe-and-cache

`Adapter` gains a `tokens []string` field (the split list) and a `tokenCache map[string]string`
(owner → resolved token, populated lazily). The constructor signature changes:

```go
type Adapter struct {
    tokens     []string
    tokenCache map[string]string
}

// New creates a new Adapter. token is split on "," to build the token list.
// Falls back to GITHUB_TOKEN env var when the list is empty.
func New(token string) *Adapter {
    tokens := splitTokens(token)
    if len(tokens) == 0 {
        if t := os.Getenv("GITHUB_TOKEN"); t != "" {
            tokens = []string{t}
        }
    }
    return &Adapter{tokens: tokens, tokenCache: make(map[string]string)}
}

// splitTokens splits a comma-separated token string into a slice of non-empty tokens.
func splitTokens(raw string) []string { ... }
```

`New` signature stays `New(token string)` — the call sites in `cmd/api/api.go` and
`cmd/worker/worker.go` pass `cfg.GitHub.Token` unchanged.

`tokenFor(ctx, owner string) string` probes tokens in order on first access and caches the result:

```go
func (a *Adapter) tokenFor(ctx context.Context, owner string) string {
    if t, ok := a.tokenCache[owner]; ok {
        return t
    }
    // Try each token; cache the first one that is non-empty (probe on first use).
    // Actual 401 errors from GitHub surface as SourceErrors from the caller.
    for _, t := range a.tokens {
        if t != "" {
            a.tokenCache[owner] = t
            return t
        }
    }
    return ""
}
```

For the probe-on-401 retry path (resolving which token works for a given owner), `SyncWorkspace`,
`FetchFeature`, and `FetchTask` attempt the call with `tokenFor(owner)`, and on a 401
`SourceError` invalidate the cache entry and retry with the next token in the list. The first
successful response caches that token for the owner.

`repoTarget()` (used by `ImportWorkspace` / `FetchWorkspaceMetadata`) is also updated: when
`input.Token == ""`, use `a.tokenFor(ctx, owner)` instead of `a.tokens[0]`. The explicit-override
behaviour (`input.Token != "" → use it`) is preserved.

### Wiring — handler `Token` fields removed; `New` call unchanged

`ghadapter.New(cfg.GitHub.Token)` call sites in `cmd/api/api.go` and `cmd/worker/worker.go` are
unchanged — `New` still accepts a single string, internally splits it on `,`.

The only wiring change is removing `Token: cfg.GitHub.Token` from the handler structs:

```go
// Before
h := &handler.ServiceHandler{
    GitHub: ghadapter.New(cfg.GitHub.Token),
    Token:  cfg.GitHub.Token,   // ← removed
    ...
}

// After
h := &handler.ServiceHandler{
    GitHub: ghadapter.New(cfg.GitHub.Token),
    ...
}
```

`handler.ServiceHandler.Token` and `worker.Handler.Token` are removed. Callers that previously
passed `Token: h.Token` in `ImportInput` now pass no token; the adapter resolves it internally via
`tokenFor`.

### Startup validation

After splitting, emit an `INFO` log line with the token count (never the values themselves). If
the split produces an empty list and `GITHUB_TOKEN` env var is also empty, emit a `WARN` log.

At sync/fetch time, when all tokens in the list fail to authenticate for a given owner (all return
401), the adapter returns a clear `SourceError` with code `ErrGitHubUnauthorized` and message
`"no valid GitHub token found for owner \"<owner>\""` rather than forwarding a bare 401.

### Affected repositories

`workspace-github-adapter` only. No other repo is touched.

### Compatibility

- `GitHubConfig` struct is unchanged. `ghadapter.New` signature is unchanged. A bare
  `github.token` value (no commas) continues to work exactly as before — zero operator action
  required for existing single-workspace deployments.
- `handler.ServiceHandler.Token` and `worker.Handler.Token` are removed. Both structs are internal
  to this service; no external callers.

---

## 5. Dependency Analysis

| Dependency | Status | Notes |
|---|---|---|
| `domain.GitHubWorkspaceAdapter` interface | Stable — no change | Token routing is adapter-internal |
| `parseRepoURL` in `internal/github` | Stable — already exists | Used to extract owner in `FetchFeature`, `FetchTask`, `SyncWorkspace` |
| Viper mapstructure | Stable | `Token string` field unchanged; comma-split done at startup — no custom decoder needed |
| No DB migration | ✅ Resolved | Config-only approach |
| No new external service | ✅ Resolved | In-process map; no external secret store |
| `ghadapter.New` call sites | Contained | Only `cmd/api/api.go`, `cmd/worker/worker.go`, and tests — all in this repo |

No unresolved dependencies.

---

## 6. Parallelization / Blocking Analysis

```
T1: Adapter token resolution — Adapter.tokens/tokenCache, splitTokens(), tokenFor() probe-and-cache,
    updated New() internals, FetchFeature / FetchTask / SyncWorkspace / repoTarget() updated,
    adapter_test.go
  └── Can begin now — no blockers
      (New() signature unchanged; no config-struct change needed)

  T2: Wiring + cleanup — remove Token field from ServiceHandler and worker.Handler; remove
      Token: h.Token from ImportInput call sites; startup warn log; tokenFor all-fail error
      └── BLOCKED on T1 (adapter tokenFor must exist before handler removal is safe)
```

---

## 7. Repository Impact

| Repo | Impact |
|---|---|
| `workspace-github-adapter` | All changes: `internal/github/adapter.go`, `cmd/api/api.go`, `cmd/worker/worker.go`, `internal/handler/handler.go`, `internal/worker/handler.go` — `configs/` untouched |
| All other repos | None |

---

## 8. Validation and Release Impact

### Tests

- `internal/github/adapter_test.go`: add `splitTokens` unit tests (single token, comma-separated
  list, empty string, whitespace trimming); add `tokenFor` probe-and-cache tests for single-token,
  multi-token success on first, multi-token success on second (simulated 401 on first).
- `internal/github/adapter_test.go` (and `fetch_targeted_test.go`): update `ghadapter.New` calls
  to pass second argument; add test cases for per-owner token selection and fallback-to-default
  behaviour.
- `internal/handler/webhook_handler_test.go`, `internal/handler/import_test.go`: remove `Token`
  field from `ServiceHandler` construction in tests.
- `internal/worker/` tests: remove `Token` field from `worker.Handler` construction.

### Migration / config impact

- `GitHubConfig` struct is unchanged. Existing `github.token` values (bare single token) continue
  to work with no config edit needed.
- Multi-org operators append additional PATs: `token: "ghp_abc,ghp_xyz"`.
- No DB migration. No queue schema change.

### Rollout

- No downtime required. The change is config-file-only; a normal redeploy picks it up.
- Deploy the new binary, append additional PATs to `github.token` (comma-separated), restart.
- Token values must not appear in VCS — inject via Docker Compose / K8s secret mounts or
  environment-variable-driven config file templating at deploy time.
- Rollback: deploy the previous binary. The existing bare `github.token` value continues to work.
