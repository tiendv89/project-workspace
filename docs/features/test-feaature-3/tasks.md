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

T2: API key management (generate, store, revoke, scope)
  └── Can begin now — no blockers

  T3: Rate limiting middleware (sliding-window, Redis-backed)
    └── BLOCKED on T2 (API key identity must exist to key rate-limit counters)
    └── BLOCKED on D2 (Redis availability must be confirmed for production config)

  T4: REST API v1 routes — workspaces, projects, tasks, users, comments
    └── BLOCKED on T1 (schema baseline must be frozen)
    └── BLOCKED on T2 (auth middleware must be in place)
    └── T3 and T4 run in parallel once their respective blockers are cleared

  T5: Webhook registration & async dispatch
    └── BLOCKED on T2 (API key auth required for webhook registration endpoint)
    └── BLOCKED on D1 (async job queue must be confirmed/provisioned)

  T6: OpenAPI docs portal (Swagger UI at /developer)
    └── BLOCKED on T4 (routes must exist to generate schema from)

  T7: Integration tests & end-to-end validation
    └── BLOCKED on T3 (rate limiting must be testable)
    └── BLOCKED on T4 (routes must be implemented)
    └── BLOCKED on T5 (webhook dispatch must be implemented)
    └── BLOCKED on T6 (docs portal must be live)
```

---

## Index

| ID | Wave | Title | Depends On |
|---|---|---|---|
| T1 | 1 | Data model audit & OpenAPI schema baseline | — |
| T2 | 1 | API key management | — |
| T3 | 2 | Rate limiting middleware | T2 |
| T4 | 2 | REST API v1 routes | T1, T2 |
| T5 | 2 | Webhook registration & async dispatch | T2 |
| T6 | 3 | OpenAPI docs portal | T4 |
| T7 | 4 | Integration tests & end-to-end validation | T3, T4, T5, T6 |

---

## T1 — Data model audit & OpenAPI schema baseline

### Description
Audit all existing entity schemas (workspaces, projects, tasks, users, comments) and produce a frozen OpenAPI 3.0 baseline document. This schema serves as the contract for all v1 routes and must be agreed upon before route implementation begins.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Review existing database schema for all 5 entity types
- [ ] Document field names, types, nullability, and relations
- [ ] Draft OpenAPI 3.0 YAML covering all entity response shapes
- [ ] Identify any fields that must be excluded from public API responses (internal IDs, secrets)
- [ ] Get schema sign-off before marking done

---

## T2 — API key management

### Description
Implement API key generation, secure storage (hashed), revocation, and scope enforcement (`read`, `write`, `admin`). This is the authentication foundation that all protected routes and the webhook registration endpoint depend on.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Design `api_keys` database table (id, workspace_id, key_hash, scopes, created_at, revoked_at)
- [ ] Implement key generation (cryptographically random, prefixed, e.g. `pk_live_...`)
- [ ] Implement key hashing on storage (never store plaintext)
- [ ] Implement key validation middleware (lookup by hash, check revoked, check scope)
- [ ] Expose admin endpoints: `POST /api/v1/api-keys`, `DELETE /api/v1/api-keys/:id`, `GET /api/v1/api-keys`
- [ ] Unit test key generation, hashing, and scope enforcement

---

## T3 — Rate limiting middleware

### Description
Implement a sliding-window rate limiter enforcing 1,000 requests/minute per API key, backed by Redis with an in-memory fallback for development. Must return standard `429 Too Many Requests` responses with `Retry-After` headers.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Integrate Redis client (or confirm existing client in codebase)
- [ ] Implement sliding-window counter keyed by API key ID
- [ ] Wire middleware into the `/api/v1/` route prefix
- [ ] Return `429` with `Retry-After` and `X-RateLimit-*` headers on limit exceeded
- [ ] Implement in-memory fallback when Redis is unavailable
- [ ] Load test middleware at 1,200 req/min to verify 429 triggers correctly

---

## T4 — REST API v1 routes

### Description
Implement all v1 CRUD routes for the 5 entity types: workspaces, projects, tasks, users, and comments. All routes must be protected by the API key middleware from T2 and respect scope enforcement.

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
- [ ] Return consistent error shapes (`{ error: { code, message } }`) for all 4xx/5xx
- [ ] Write unit tests for each route (auth required, scope enforcement, 404 handling)

---

## T5 — Webhook registration & async dispatch

### Description
Allow workspace admins to register webhook endpoint URLs and subscribe to platform events. On each matching platform action, enqueue an async job that delivers a signed HTTP POST to the registered URL with 3 retries and exponential backoff.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Design `webhook_subscriptions` table (id, workspace_id, url, events[], secret, created_at)
- [ ] Design `webhook_delivery_log` table (id, subscription_id, event, status, attempts, last_attempt_at)
- [ ] Implement webhook registration endpoint: `POST /api/v1/webhooks`, `DELETE /api/v1/webhooks/:id`, `GET /api/v1/webhooks`
- [ ] Implement event emitter that fires on: task created, task status changed, comment added, project created
- [ ] Implement async dispatch worker: sign payload with HMAC-SHA256, POST to endpoint, log result
- [ ] Implement retry logic: 3 attempts, exponential backoff (1s, 5s, 25s)
- [ ] Unit test signing, retry logic, and delivery log writes

---

## T6 — OpenAPI docs portal

### Description
Auto-generate an OpenAPI 3.0 schema from the v1 route annotations and serve an interactive Swagger UI at `/developer`. The portal must be publicly accessible without authentication.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Integrate OpenAPI schema generation library compatible with the server framework
- [ ] Annotate all v1 routes with schema decorators/comments
- [ ] Serve generated schema at `GET /api/v1/openapi.json`
- [ ] Mount Swagger UI at `/developer` (no auth required)
- [ ] Verify schema parses correctly in Swagger Editor
- [ ] Add `info`, `servers`, `contact`, and `license` fields to the schema

---

## T7 — Integration tests & end-to-end validation

### Description
Write a full integration test suite covering all v1 routes, rate limiting, webhook dispatch, and the docs portal. This is the final quality gate before the feature is handed off.

### Required skills
- typescript-best-practices

### Subtasks
- [ ] Set up test environment with seeded database and Redis
- [ ] Test all REST routes end-to-end (happy path + error cases)
- [ ] Test rate limiting: verify 429 after 1,000 requests/min
- [ ] Test webhook dispatch: mock endpoint receives signed payload, retries on failure
- [ ] Test API key scopes: read-only key cannot POST/DELETE
- [ ] Test `/developer` portal accessible without auth
- [ ] Confirm zero regressions in existing app routes
- [ ] All tests pass before marking done
