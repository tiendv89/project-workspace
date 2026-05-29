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

1. Config must accept a list of `{owner, token}` entries — one per GitHub organisation/account.
2. The `github.Adapter` must resolve the correct token by GitHub owner before creating an HTTP
   client, across all four adapter methods.
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

### Option A — Per-owner token map, comma-separated string in config (chosen)

Add `github.token_map` to config as a comma-separated string of `owner:token` pairs (e.g.
`"org-A:ghp_abc,org-B:ghp_xyz"`). At startup the string is split on `,`, each entry split on `:`
to build a `map[string]string`. The adapter constructor gains a second parameter `tokenMap
map[string]string`. Inside the adapter, add a `tokenFor(owner string) string` resolver: returns
the map entry for that owner, or falls back to the global `a.token`. All four adapter methods call
`tokenFor` before creating a client.

- **Pros**: zero interface change; single resolver function; all token logic in one place; backwards
  compatible (empty string = existing behavior); no DB migration; consistent with how
  `webhook_secrets` is handled in the previous feature; easy env-var override
  (`GITHUB_TOKEN_MAP=org-A:ghp_abc,org-B:ghp_xyz`); `handler.Token` fields can be cleanly
  removed.
- **Cons**: requires process restart to add a new workspace/token; owner value must not contain
  `,` or `:` (safe for all valid GitHub owner names); map lookup is exact-match on owner (no
  wildcard).
- **Implementation impact**: 3 files changed in `workspace-github-adapter` (configs, adapter,
  wiring). No schema change. No new struct needed in config.
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

### Config layer — new `TokenMap` string field

`GitHubConfig` gains a `TokenMap string` field — a comma-separated list of `owner:token` pairs.
No new struct is needed:

```go
type GitHubConfig struct {
    Token         string `mapstructure:"token"`
    TokenMap      string `mapstructure:"token_map"`
    WebhookSecret string `mapstructure:"webhook_secret"`
}
```

`config.yaml` example with multiple orgs:
```yaml
github:
  token: "ghp_default_fallback"
  token_map: "org-A:ghp_abc,org-B:ghp_xyz"
```

Environment variable override: `GITHUB_TOKEN_MAP=org-A:ghp_abc,org-B:ghp_xyz`.

Single-workspace operators continue using only `github.token` — `token_map` stays empty.
An absent or empty `token_map` string means "no overrides"; the adapter falls back to `a.token`
for every call, preserving existing behaviour exactly.

### Adapter — `tokenMap` field + `tokenFor` resolver

`Adapter` gains a `tokenMap map[string]string` field (pre-built from the config slice at
construction). The constructor signature changes:

```go
type Adapter struct {
    token    string
    tokenMap map[string]string
}

func New(defaultToken string, tokenMap map[string]string) *Adapter {
    if defaultToken == "" {
        defaultToken = os.Getenv("GITHUB_TOKEN")
    }
    return &Adapter{token: defaultToken, tokenMap: tokenMap}
}

func (a *Adapter) tokenFor(owner string) string {
    if t, ok := a.tokenMap[owner]; ok && t != "" {
        return t
    }
    return a.token
}
```

`SyncWorkspace`, `FetchFeature`, and `FetchTask` each already have `repoURL` available. Update
each to call `parseRepoURL` → extract owner → call `a.tokenFor(owner)` instead of `a.token`:

```go
// Before
c := newClient(a.token)

// After
owner, _, err := parseRepoURL(repoURL)
...
c := newClient(a.tokenFor(owner))
```

`repoTarget()` (used by `ImportWorkspace` / `FetchWorkspaceMetadata`) is also updated: when
`input.Token == ""`, use `a.tokenFor(owner)` instead of `a.token`. The explicit-override
behaviour (`input.Token != "" → use it`) is preserved.

### Wiring — handler `Token` fields removed

The config `TokenMap` string is split at startup and passed to `ghadapter.New`. Each comma-delimited
entry is split on the first `:` to extract owner and token:

```go
// cmd/api/api.go and cmd/worker/worker.go
tokenMap := make(map[string]string)
for _, entry := range strings.Split(cfg.GitHub.TokenMap, ",") {
    entry = strings.TrimSpace(entry)
    if entry == "" {
        continue
    }
    owner, token, ok := strings.Cut(entry, ":")
    if !ok || owner == "" || token == "" {
        log.Fatal().Str("entry", entry).Msg("invalid github.token_map entry: expected owner:token")
    }
    tokenMap[owner] = token
}
h := ... {
    GitHub: ghadapter.New(cfg.GitHub.Token, tokenMap),
    // Token string field removed entirely
}
```

`handler.ServiceHandler.Token` and `worker.Handler.Token` are removed. Callers that previously
passed `Token: h.Token` in `ImportInput` now pass no token; the adapter resolves it internally via
`tokenFor`.

### Startup validation

After config loading, if `token_map` is non-empty, emit one log line per entry at `INFO` level
listing the owner (never the token value). If the global `token` is empty and `token_map` is
non-empty, emit a `WARN` log: workspaces with owners not in `token_map` will fail at sync time.
This is intentionally a warning, not a fatal — the operator may have all owners covered by the
map.

At sync/fetch time, when `tokenFor` would return `""` (both map entry and fallback are empty), the
adapter returns a clear `SourceError` with code `ErrGitHubUnauthorized` and message
`"no GitHub token configured for owner \"<owner>\""` rather than forwarding a bare 401.

### Affected repositories

`workspace-github-adapter` only. No other repo is touched.

### Compatibility

- Adding `token_map` to config is purely additive. Operators who do not add it see no behaviour
  change.
- `handler.ServiceHandler.Token` and `worker.Handler.Token` are removed. Any code outside this
  repo that embeds `ServiceHandler` or `worker.Handler` directly would need updating — but both
  structs are internal to this service.
- `ghadapter.New` signature changes from `New(token string)` to `New(defaultToken string, tokenMap
  map[string]string)`. All call sites are in this repo (`cmd/api/api.go`, `cmd/worker/worker.go`,
  tests). No external callers.

---

## 5. Dependency Analysis

| Dependency | Status | Notes |
|---|---|---|
| `domain.GitHubWorkspaceAdapter` interface | Stable — no change | Token routing is adapter-internal |
| `parseRepoURL` in `internal/github` | Stable — already exists | Used to extract owner in `FetchFeature`, `FetchTask`, `SyncWorkspace` |
| Viper mapstructure | Stable | `[]TokenEntry` unmarshals directly; no custom decoder needed |
| No DB migration | ✅ Resolved | Config-only approach |
| No new external service | ✅ Resolved | In-process map; no external secret store |
| `ghadapter.New` call sites | Contained | Only `cmd/api/api.go`, `cmd/worker/worker.go`, and tests — all in this repo |

No unresolved dependencies.

---

## 6. Parallelization / Blocking Analysis

```
T1: Config layer — TokenMap string field in GitHubConfig, Load/Init updates, configs_test.go
  └── Can begin now — no blockers

T2: Adapter token resolution — Adapter.tokenMap, tokenFor(), updated New() constructor,
    FetchFeature / FetchTask / SyncWorkspace / repoTarget() updated, adapter_test.go
  └── Can begin now — no blockers
      (adapter defines its own token map via map[string]string; no dependency on config types)

T1 and T2 run in parallel.

  T3: Wiring + cleanup — cmd/api/api.go, cmd/worker/worker.go: build tokenMap from config,
      pass to New(); remove Token field from ServiceHandler and worker.Handler; remove
      Token: h.Token from ImportInput call sites; startup warn log; tokenFor empty-token error
      └── BLOCKED on T1 (cfg.GitHub.TokenMap must exist before it can be converted in wiring)
      └── BLOCKED on T2 (ghadapter.New() must accept tokenMap before cmd/ code can compile)
```

---

## 7. Repository Impact

| Repo | Impact |
|---|---|
| `workspace-github-adapter` | All changes: `configs/`, `internal/github/adapter.go`, `cmd/api/api.go`, `cmd/worker/worker.go`, `internal/handler/handler.go`, `internal/worker/handler.go` |
| All other repos | None |

---

## 8. Validation and Release Impact

### Tests

- `configs/configs_test.go`: add cases for `token_map` comma-separated string loading; verify
  empty string produces empty map; verify single-token backwards compat case; verify malformed
  entry triggers fatal at startup.
- `internal/github/adapter_test.go` (and `fetch_targeted_test.go`): update `ghadapter.New` calls
  to pass second argument; add test cases for per-owner token selection and fallback-to-default
  behaviour.
- `internal/handler/webhook_handler_test.go`, `internal/handler/import_test.go`: remove `Token`
  field from `ServiceHandler` construction in tests.
- `internal/worker/` tests: remove `Token` field from `worker.Handler` construction.

### Migration / config impact

- Adding `github.token_map` to `config.yaml` is opt-in. Operators with a single workspace make no
  change.
- Multi-org operators add `token_map` entries and may remove `github.token` if all orgs are
  covered by the map (leaving `token` empty is valid provided every owner is in the map).
- No DB migration. No queue schema change.

### Rollout

- No downtime required. The change is config-file-only; a normal redeploy picks it up.
- Deploy the new binary, update config with `token_map` entries for any additional orgs, restart.
- Token values must not appear in VCS — inject via Docker Compose / K8s secret mounts or
  environment-variable-driven config file templating at deploy time.
- Rollback: deploy the previous binary. The old config (without `token_map`) continues to work.
