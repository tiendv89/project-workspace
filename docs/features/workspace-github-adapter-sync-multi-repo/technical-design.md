# Technical Design

## Feature
- Feature ID: `workspace-github-adapter-sync-multi-repo`
- Title: Workspace GitHub Adapter — Multi-Workspace Webhook Support

---

## 1. Current State

### Configuration
`GitHubConfig` in `configs/configs.go` has a single scalar field:
```go
type GitHubConfig struct {
    Token         string `mapstructure:"token"`
    WebhookSecret string `mapstructure:"webhook_secret"`
}
```
`config.yaml` maps to `github.webhook_secret`. One value, shared across all webhooks.

### Handler wiring
`cmd/api/api.go` copies the scalar into `ServiceHandler`:
```go
h := &handler.ServiceHandler{
    ...
    WebhookSecret: cfg.GitHub.WebhookSecret,
}
```
`ServiceHandler` stores a single `WebhookSecret string`.

### Webhook verification
`WebhookHandler` calls `webhook.ReadAndVerify(c.Request, h.WebhookSecret)` as its first
operation — before it knows which workspace sent the event. This atomically reads the full
body and verifies the HMAC against the single stored secret.

`webhook.VerifySignature` is already split out as a standalone function (takes `secret, header,
body []byte`) — it is callable separately. But `ReadAndVerify` bundles the body read with
verification, making it impossible to inspect the payload before committing to a secret.

### DB lookup
`GetGitHubSourceByRepo(owner, name)` already exists in
`internal/database/workspace_github_sources_extra.go`. It looks up the workspace by repo
owner/name — the information that is available in every GitHub push payload under
`repository.full_name`. This query is used later in `WebhookHandler.findWorkspaceByRepoURL`,
but only after verification has already succeeded or failed.

### Constraint
`workspace_github_sources` has `ON CONFLICT (workspace_id)`, enforcing one source row per
workspace. The current webhook flow does not need to change this — secrets are config-side, not
DB-side, and the per-workspace lookup already works via `GetGitHubSourceByRepo`.

---

## 2. Problem Framing

### What needs to change
1. Config must accept multiple `"owner/repo" → secret` entries.
2. The webhook handler must read the raw body first, extract repo identity from the JSON, select
   the correct secret for that repo, then verify — rather than verifying before knowing the repo.
3. `webhook.ReadAndVerify` must be decomposed: body reading separated from HMAC verification so
   the handler can interpose the secret-lookup step between them.
4. The startup guard in `cmd/api/api.go` must accept either the legacy scalar or the new list.

### What must remain stable
- `webhook.VerifySignature(secret, header, body)` — public, already tested; keep its signature.
- `GetGitHubSourceByRepo` — already correct; no change needed.
- All sync, queue, and branch-routing logic downstream of verification — untouched.
- Single-workspace operators: zero breaking change; existing config continues to work.

### Fixed assumptions
- Secrets are operator-managed via config file or environment variables (no DB secret storage).
- The adapter is a single process; the secret map is built at startup and stays in memory.
- Repo identity is always available in the GitHub push payload under `repository.full_name`
  (`"owner/repo"`) before the body needs to be discarded.

---

## 3. Options Considered

### Option A — Config list of secrets, try-each verification (chosen)
Add `github.webhook_secrets` as a YAML list of strings. In the handler, read the raw body, then
try `VerifySignature` for each secret in order; accept the first match. No key needed — the HMAC
result itself identifies which secret applies. Workspace lookup (`GetGitHubSourceByRepo`) continues
after verification, unchanged.

- **Pros**: no DB changes; no migration; simplest possible config shape — just a list of secrets;
  no JSON peeking before verification; no map keying; no struct; backwards compatible via scalar
  promotion; `VerifySignature` already exists and is reused as-is.
- **Cons**: requires restart to add/remove a secret; on N configured secrets, up to N HMAC
  operations per request (each is fast and constant-time; not a practical concern for small N).
- **Implementation impact**: ~4 files changed in `workspace-github-adapter`; no schema change.
- **Dependency impact**: none external.

### Option B — Per-workspace secret stored in DB
Add a `webhook_secret` column to `workspace_github_sources`. Store and look up the secret from
the DB row returned by `GetGitHubSourceByRepo`.

- **Pros**: dynamic (no restart to add workspace); secret co-located with workspace record.
- **Cons**: secrets in the DB (encryption concern); requires migration + sqlc regeneration +
  new import/registration API to accept and store the secret; significantly more scope.
- **Implementation impact**: DB migration, sqlc regeneration, updated import handler, new
  endpoint, config changes — much larger surface.
- **Dependency impact**: DB migration must be run before deploy.

Option B is explicitly out of scope per the product spec ("config file and/or environment
variables only"). Option A is the chosen design.

### Option C — Catch-all with secret rotation (try all secrets)
Keep one global slot but try all configured secrets until one verifies.

- **Pros**: simplest config shape.
- **Cons**: timing-safe comparison still has to try every secret per request; doesn't let
  operators issue distinct secrets per workspace; masks misconfiguration.
- **Implementation impact**: small but wrong semantically.

Rejected: doesn't meet the per-workspace isolation goal.

---

## 4. Chosen Design

### Config layer

`GitHubConfig` gains one field — a plain string slice:

```go
type GitHubConfig struct {
    Token          string   `mapstructure:"token"`
    WebhookSecret  string   `mapstructure:"webhook_secret"`  // legacy scalar
    WebhookSecrets []string `mapstructure:"webhook_secrets"` // list of secrets
}
```

Add a `ResolvedWebhookSecrets() []string` method on `GitHubConfig`:
- If `WebhookSecrets` is non-empty: return it.
- If `WebhookSecrets` is empty and `WebhookSecret` is non-empty: return `[]string{WebhookSecret}` for backwards compatibility.
- If both empty: return nil (caller treats this as fatal at startup).

`config.yaml` example (new shape):
```yaml
github:
  token: "ghp_..."
  # Legacy single-workspace form (still supported — zero config change required):
  # webhook_secret: "single_secret"

  # Multi-workspace form:
  webhook_secrets:
    - "secret_for_ws_1"
    - "secret_for_ws_2"
```

### Webhook package

Add `ReadBody(r *http.Request) ([]byte, error)` to `internal/webhook/webhook.go`:
- Reads the body up to `maxWebhookBodyBytes` with `io.LimitReader`.
- Does **not** verify. Returns raw bytes.
- Existing `ReadAndVerify` is kept for backwards compatibility but is no longer called by
  `WebhookHandler` (it may be removed in a future cleanup).

### Handler

`ServiceHandler.WebhookSecret string` → `ServiceHandler.WebhookSecrets []string`.

New `WebhookHandler` flow:
1. `body, err := webhook.ReadBody(r)` — read raw body.
2. Try `webhook.VerifySignature(secret, header, body)` for each secret in `WebhookSecrets`.
   - First match: continue.
   - All fail: return 401 `"signature verification failed"`.
3. Continue with existing push-event routing logic (unchanged) — `findWorkspaceByRepoURL`
   still resolves the workspace from the push payload after verification.

### Startup wiring (`cmd/api/api.go`)

```go
secrets := cfg.GitHub.ResolvedWebhookSecrets()
if secrets == nil {
    log.Fatal().Msg("github.webhook_secret or github.webhook_secrets is required")
}
h := &handler.ServiceHandler{
    ...
    WebhookSecrets: secrets,
}
```

Remove the existing `cfg.GitHub.WebhookSecret == ""` guard; replace with the nil-map check.

### Affected repositories
- `workspace-github-adapter` only.

### Compatibility
- Operators with `github.webhook_secret` set and `github.webhook_secrets` absent: zero config
  change required; the single secret becomes a catch-all.
- Operators migrating to multi-workspace: add `github.webhook_secrets` list; remove or leave
  the scalar (it is ignored when the list is non-empty).
- No DB migration. No API change. No queue/sync logic change.

---

## 5. Dependency Analysis

| Dependency | Status | Notes |
|---|---|---|
| `webhook.VerifySignature` | Stable — no change | Already takes `(secret, header, body)` |
| `GetGitHubSourceByRepo` | Stable — no change | Already looks up by owner/name |
| Viper mapstructure | Stable | `[]string` slice is natively supported — no struct needed |
| No DB migration | ✅ Resolved | Config-only approach removes this dependency |
| No new external service | ✅ Resolved | In-memory map; no external secret store |

No unresolved dependencies.

---

## 6. Parallelization / Blocking Analysis

```
T1: Config layer — WebhookSecrets []string, ResolvedWebhookSecrets(), config.yaml, configs_test.go
  └── Can begin now — no blockers

T2: Webhook package — ReadBody(), webhook_test.go addition
  └── Can begin now — no blockers

T1 and T2 run in parallel.

  T3: Handler + wiring — ServiceHandler.WebhookSecrets, WebhookHandler two-step flow, api.go
      └── BLOCKED on T1 (WebhookSecretMap() must exist and be testable before wiring)
      └── BLOCKED on T2 (ReadBody() must exist before handler can call it)
```

---

## 7. Repository Impact

| Repo | Impact |
|---|---|
| `workspace-github-adapter` | All changes land here: config, webhook package, handler, api wiring |
| All other repos | None |

---

## 8. Validation and Release Impact

### Tests
- `configs/configs_test.go`: add cases for `webhook_secrets` list loading, `ResolvedWebhookSecrets()`
  with list, scalar fallback, and both-empty nil return.
- `internal/webhook/webhook_test.go`: add test for `ReadBody` (happy path, oversized body).
- `internal/handler/webhook_handler_test.go`: update existing tests to use `WebhookSecrets` map
  instead of `WebhookSecret` string; add cases for unknown repo (→ 401), catch-all secret,
  and per-repo secret routing.

### Migration / config impact
- Operators must not store `webhook_secrets` values in VCS — same policy as the existing scalar.
- Recommended: inject via environment variables using Viper's env-override mechanism
  (e.g. `GITHUB_WEBHOOK_SECRET` for the scalar; for the list, Docker Compose / K8s secrets
  are the typical approach since Viper does not natively expand env vars into list entries —
  operators should use config file mounting with secret injection at build/deploy time).
- Document in README that `webhook_secrets` entries override `webhook_secret` when both present.

### Rollout
- Deploy is a drop-in replacement: if only `webhook_secret` is set, behaviour is identical.
- Operators add `webhook_secrets` in config and redeploy to activate multi-workspace mode.
- No downtime required; no database operation.
