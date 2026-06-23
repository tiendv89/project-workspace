# Task Breakdown — Public API & Developer Webhooks

**Feature:** `test-feaature-3` | **Status:** in_tdd | **Stage:** tasks
> Machine state lives in `tasks/T<n>.yaml`. This file is the narrative planning document.

---

## Dependency Diagram

```
D1: Confirm async job queue (existing or new) ──┐
D2: Confirm Redis availability in prod env      ──┘ resolve before T5 and T3 respectively

T1: Data model audit & OpenAPI schema baseline
  └── Can begin now — no blockers

T2: API key management — generate, store, revoke, scope
  └── Can begin now — no blockers

  T3: Rate limiting middleware — sliding-window, Redis-backed
    └── BLOCKED on T2 (API key identity must exist to key rate-limit counters)
    └── BLOCKED on D2 (Redis availability must be confirmed for production config)

  T4: REST API v1 routes — workspaces, projects, tasks, users, comments
    └── BLOCKED on T1 (schema baseline must be frozen)
    └── BLOCKED on T2 (auth middleware must be in place)
    └── T3 and T4 run in parallel once their respective blockers are cleared

  T5: Webhook registration & async dispatch
    └── BLOCKED on T2 (API key auth required for webhook registration endpoint)
    └── BLOCKED on D1 (async job queue must be confirmed/provisioned)

  T6: OpenAPI docs portal — Swagger UI at /developer
    └── BLOCKED on T4 (routes must exist to generate schema from)

  T7: API key admin UI — workspace admin panel page (human task)
    └── BLOCKED on T4 (API endpoints must exist before UI can be wired up)
    └── T6 and T7 run in parallel

  T8: Integration tests & end-to-end validation
    └── BLOCKED on T3 (rate limiting must be testable)
    └── BLOCKED on T4 (routes must be implemented)
    └── BLOCKED on T5 (webhook dispatch must be implemented)
    └── BLOCKED on T6 (docs portal must be live)
    └── BLOCKED on T7 (admin UI must be complete)
```

---

## Index

| ID | Wave | Title | Depends On | Actor |
|---|---|---|---|---|
| T1 | 1 | Data model audit & OpenAPI schema baseline | — | agent |
| T2 | 1 | API key management — generate, store, revoke, scope | — | agent |
| T3 | 2 | Rate limiting middleware — sliding-window, Redis-backed | T2 | agent |
| T4 | 2 | REST API v1 routes — workspaces, projects, tasks, users, comments | T1, T2 | agent |
| T5 | 2 | Webhook registration & async dispatch | T2 | agent |
| T6 | 3 | OpenAPI docs portal — Swagger UI at /developer | T4 | agent |
| T7 | 3 | API key admin UI — workspace admin panel page | T4 | human |
| T8 | 4 | Integration tests & end-to-end validation | T3, T4, T5, T6, T7 | agent |

---

## T1 — Data model audit & OpenAPI schema baseline

### Description
Audit all existing entity schemas (workspaces, projects, tasks, users, comments) and produce a frozen OpenAPI 3.0 baseline document. This schema serves as the contract for all v1 routes and must be agreed upon before route implementation begins. Fields that must be excluded from public API responses (internal IDs, secrets, internal flags) must be explicitly documented.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Review existing database schema for all 5 entity types
- [ ] Document field names, types, nullability, and relations
- [ ] Draft OpenAPI 3.0 YAML covering all entity response shapes
- [ ] Identify and document fields excluded from public API responses
- [ ] Get schema sign-off before marking done

---

## T2 — API key management — generate, store, revoke, scope

### Description
Implement API key generation, secure storage (hashed), revocation, and scope enforcement (`read`, `write`, `admin`). This is the authentication foundation that all protected routes, the rate limiter, and the webhook registration endpoint depend on.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Design `api_keys` table: `id`, `workspace_id`, `key_hash`, `scopes`, `created_at`, `revoked_at`
- [ ] Implement key generation (cryptographically random, prefixed e.g. `pk_live_...`)
- [ ] Store key hash only — never plaintext
- [ ] Implement key validation middleware: lookup by hash, check revoked_at, check scope
- [ ] Expose admin endpoints: `POST /api/v1/api-keys`, `DELETE /api/v1/api-keys/:id`, `GET /api/v1/api-keys`
- [ ] Unit test: key generation, hashing, scope enforcement, revocation

---

## T3 — Rate limiting middleware — sliding-window, Redis-backed

### Description
Implement a sliding-window rate limiter enforcing 1,000 requests/minute per API key, backed by Redis with an in-memory fallback for development. Returns standard `429 Too Many Requests` with `Retry-After` and `X-RateLimit-*` headers on limit exceeded.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Integrate Redis client (or confirm existing client in codebase)
- [ ] Implement sliding-window counter keyed by API key ID
- [ ] Wire middleware into `/api/v1/` route prefix
- [ ] Return `429` with `Retry-After` and `X-RateLimit-Limit`, `X-RateLimit-Remaining` headers
- [ ] Implement in-memory fallback when Redis is unavailable
- [ ] Load test at 1,200 req/min to verify 429 triggers correctly

---

## T4 — REST API v1 routes — workspaces, projects, tasks, users, comments

### Description
Implement all v1 CRUD routes for the 5 entity types. All routes protected by API key middleware from T2, scope-enforced, and validated against the OpenAPI schema from T1. Consistent error shapes required across all routes.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Scaffold `/api/v1/` router with versioning prefix
- [ ] Implement workspace routes: `GET /workspaces`, `GET /workspaces/:id`
- [ ] Implement project routes: `GET`, `POST`, `PATCH`, `DELETE /projects`
- [ ] Implement task routes: `GET`, `POST`, `PATCH`, `DELETE /tasks`
- [ ] Implement user routes: `GET /users`, `GET /users/:id`
- [ ] Implement comment routes: `GET`, `POST`, `DELETE /comments`
- [ ] Validate request bodies against OpenAPI schema from T1
- [ ] Return consistent error shape: `{ error: { code, message } }` for all 4xx/5xx
- [ ] Unit test each route: auth required, scope enforcement, 404 handling, pagination

---

## T5 — Webhook registration & async dispatch

### Description
Allow workspace admins to register webhook endpoint URLs and subscribe to platform events. On each matching platform action, enqueue an async job that delivers a signed HTTP POST to the registered URL with 3 retries and exponential backoff. Best-effort delivery — no replay in v1.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Design `webhook_subscriptions` table: `id`, `workspace_id`, `url`, `events[]`, `secret`, `created_at`
- [ ] Design `webhook_delivery_log` table: `id`, `subscription_id`, `event`, `status`, `attempts`, `last_attempt_at`
- [ ] Implement webhook CRUD: `POST /api/v1/webhooks`, `DELETE /api/v1/webhooks/:id`, `GET /api/v1/webhooks`
- [ ] Implement event emitter on: task created, task status changed, comment added, project created
- [ ] Implement async dispatch: sign payload with HMAC-SHA256, POST to endpoint, log result
- [ ] Implement retry logic: 3 attempts, exponential backoff (1s, 5s, 25s)
- [ ] Unit test: signing, retry behavior, delivery log writes

---

## T6 — OpenAPI docs portal — Swagger UI at /developer

### Description
Auto-generate an OpenAPI 3.0 schema from v1 route annotations and serve an interactive Swagger UI at `/developer`. Must be publicly accessible without authentication. Serves as the developer-facing reference for all v1 API consumers.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Integrate OpenAPI schema generation library compatible with the server framework
- [ ] Annotate all v1 routes with schema decorators/comments
- [ ] Serve generated schema at `GET /api/v1/openapi.json`
- [ ] Mount Swagger UI at `/developer` — no auth required
- [ ] Verify schema parses in Swagger Editor without errors
- [ ] Add `info`, `servers`, `contact`, and `license` fields to schema

---

## T7 — API key admin UI — workspace admin panel page

### Description
Build the workspace admin panel page that lets admins generate, view, and revoke API keys. This is a human-owned task — requires design review and accessibility sign-off before completion. Wired to the API endpoints from T4.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Design admin panel page layout (key list, generate button, revoke action)
- [ ] Wire to `GET /api/v1/api-keys` for listing
- [ ] Wire to `POST /api/v1/api-keys` for generation — display full key once on creation
- [ ] Wire to `DELETE /api/v1/api-keys/:id` for revocation with confirmation dialog
- [ ] Scope badge display (read / write / admin)
- [ ] Accessibility review and sign-off
- [ ] Manual QA pass before marking done

---

## T8 — Integration tests & end-to-end validation

### Description
Full integration test suite covering all v1 routes, rate limiting, webhook dispatch, docs portal, and admin UI. This is the final quality gate before the feature is handed off to production.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Set up test environment with seeded database and Redis
- [ ] Test all REST routes end-to-end: happy path + error cases
- [ ] Test rate limiting: verify 429 fires after 1,000 requests/min
- [ ] Test webhook dispatch: mock endpoint receives signed payload, retries on failure
- [ ] Test API key scopes: read-only key cannot POST/DELETE
- [ ] Test `/developer` portal accessible without auth
- [ ] Test admin UI: generate, list, revoke flows
- [ ] Confirm zero regressions in existing app routes
- [ ] All tests green before marking done
