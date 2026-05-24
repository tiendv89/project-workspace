# Task Breakdown — workspace-github-adapter-sync-multi-repo

Feature status: `ready_for_implementation` | Stage: `tasks` (draft)
Machine state lives in `tasks/T<n>.yaml`.

---

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Config — WebhookSecrets comma-separated field | — |
| T2 | 1 | Webhook package — ReadBody() | — |
| T3 | 2 | Handler + wiring — multi-secret verification | T1, T2 |

---

## T1 — Config — WebhookSecrets comma-separated field

### Description
Replace `GitHubConfig.WebhookSecret string` with `WebhookSecrets string` (comma-separated list
of secrets) in `configs/configs.go`. Update `config.yaml` to document the new field and remove
the old scalar. Update `configs_test.go` to cover: single secret, multiple secrets, and empty
(which must cause startup failure).

Files touched (all in `workspace-github-adapter`):
- `configs/configs.go` — remove `WebhookSecret`, add `WebhookSecrets string`
- `configs/config.yaml` — replace `webhook_secret` with `webhook_secrets`
- `configs/configs_test.go` — add/update test cases for the new field

### Required skills
- go-best-practices

### Subtasks
- [ ] Remove `WebhookSecret string` from `GitHubConfig`
- [ ] Add `WebhookSecrets string \`mapstructure:"webhook_secrets"\`` to `GitHubConfig`
- [ ] Update `config.yaml`: replace `webhook_secret: "a"` with `webhook_secrets: "a"`
- [ ] Add `TestLoad_WebhookSecrets_Multiple`: load config with `webhook_secrets: "s1,s2"`, assert field value
- [ ] Add `TestLoad_WebhookSecrets_Empty`: confirm empty string is loadable (startup guard is in api.go, not Load)
- [ ] Remove test assertion on `cfg.GitHub.WebhookSecret` in `TestLoad_HappyPath`; assert `WebhookSecrets` instead

---

## T2 — Webhook package — ReadBody()

### Description
Add `ReadBody(r *http.Request) ([]byte, error)` to `internal/webhook/webhook.go`. This function
reads the request body up to `maxWebhookBodyBytes` without verifying the signature, returning raw
bytes. The existing `ReadAndVerify` is left in place (it is still tested) but will no longer be
called by `WebhookHandler` after T3.

Files touched (all in `workspace-github-adapter`):
- `internal/webhook/webhook.go` — add `ReadBody`
- `internal/webhook/webhook_test.go` — add tests for `ReadBody`

### Required skills
- go-best-practices

### Subtasks
- [ ] Add `ReadBody(r *http.Request) ([]byte, error)` using `io.ReadAll(io.LimitReader(r.Body, maxWebhookBodyBytes))`
- [ ] Add `TestReadBody_HappyPath`: small body returns bytes
- [ ] Add `TestReadBody_Oversized`: body exceeding limit is truncated/handled correctly

---

## T3 — Handler + wiring — multi-secret verification

### Description
Update `ServiceHandler`, `WebhookHandler`, and `cmd/api/api.go` to use the new multi-secret
list. `WebhookSecret string` on `ServiceHandler` becomes `WebhookSecrets []string` (pre-split
from config). `WebhookHandler` reads the body with `webhook.ReadBody`, then tries
`webhook.VerifySignature` for each secret in order; first match continues, all-fail returns 401.
The startup guard in `api.go` checks `cfg.GitHub.WebhookSecrets == ""` before splitting.

Files touched (all in `workspace-github-adapter`):
- `internal/handler/handler.go` — `WebhookSecret string` → `WebhookSecrets []string`
- `internal/handler/webhook.go` — replace `ReadAndVerify` call with `ReadBody` + try-each loop
- `internal/handler/webhook_handler_test.go` — update existing tests; add cases for multi-secret and unknown-repo rejection
- `cmd/api/api.go` — split `cfg.GitHub.WebhookSecrets` on `,`, guard on empty, wire `WebhookSecrets`

### Required skills
- go-best-practices

### Subtasks
- [ ] `handler.go`: rename field `WebhookSecret string` → `WebhookSecrets []string`
- [ ] `webhook.go`: replace `webhook.ReadAndVerify(c.Request, h.WebhookSecret)` with:
  - `body, err := webhook.ReadBody(c.Request)`
  - loop over `h.WebhookSecrets`, call `webhook.VerifySignature(secret, sig, body)`
  - break on first nil error; 401 if all fail
- [ ] `api.go`: guard `if cfg.GitHub.WebhookSecrets == "" { log.Fatal(...) }`
- [ ] `api.go`: `secrets := strings.Split(cfg.GitHub.WebhookSecrets, ",")` → wire into handler
- [ ] `webhook_handler_test.go`: update all test cases that set `WebhookSecret` to set `WebhookSecrets`
- [ ] `webhook_handler_test.go`: add test — two secrets configured, request signed with second → 200
- [ ] `webhook_handler_test.go`: add test — no secret matches → 401
- [ ] Run `go test ./...` and `golangci-lint run` — all must pass before PR
