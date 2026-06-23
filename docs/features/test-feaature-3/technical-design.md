# Technical Design

## Feature
- Feature ID: `test-feaature-3`
- Title: `Public API & Developer Webhooks`

## Current State
The platform has no public-facing API surface. All data access is through the internal web application. There is no API key management, no versioning infrastructure, no webhook dispatch system, and no developer documentation portal. The management repo (`management-repo`) is currently the only registered repository in `workspace.yaml`.

Key limitations today:
- Zero programmatic access for customers or integrators
- No event emission system — platform actions are fire-and-forget within the app
- No rate limiting or auth middleware for external consumers
- No OpenAPI/Swagger schema generation pipeline

## Constraints
- Only one repo is registered in `workspace.yaml`: `management-repo`. All tasks must target this repo.
- No existing API versioning conventions to conform to — we are establishing v1 from scratch.
- Must not break existing internal web app flows during rollout.
- Rate limiting must be enforced at the API gateway / middleware layer — not at the database level.
- Webhook delivery is best-effort in v1 (no guaranteed delivery, no replay).
- REST only — no GraphQL in v1.
- No OAuth 2.0 in v1 — API key authentication only.

## Options Considered

### Option A — Monolithic REST API in the existing application server
Extend the existing backend server with new REST routes under `/api/v1/`, adding API key middleware, webhook dispatch, and rate limiting as middleware layers.

- Pros:
  - Reuses existing data models and ORM
  - Single deployment unit — no new service to operate
  - Faster to ship v1
- Cons:
  - Public API traffic shares resources with internal web app traffic
  - Harder to version independently in future
  - Rate limiting applies to all app traffic if middleware is misconfigured

### Option B — Standalone API service (separate microservice)
Build a dedicated API service that exposes public routes, owns API key management, webhook dispatch, and rate limiting, calling the core platform's internal services.

- Pros:
  - Clean separation — public API can be scaled independently
  - Future-proof for versioning, OAuth, and GraphQL additions
  - Blast radius of public API bugs isolated from core app
- Cons:
  - Higher operational overhead — new deployment, new CI/CD pipeline
  - Requires inter-service communication layer (gRPC or REST internal)
  - More up-front engineering effort

### Option C — API Gateway + thin Lambda/function handlers
Use a managed API gateway (AWS API Gateway, Kong, etc.) to handle auth, rate limiting, and routing, with thin handler functions per resource.

- Pros:
  - Rate limiting and auth offloaded to managed infrastructure
  - Near-zero operational overhead for scaling
- Cons:
  - Vendor lock-in
  - Cold-start latency for serverless handlers
  - More complex local development experience
  - Doesn't solve webhook dispatch — still needs a service

## Chosen Design

**Option A — Monolithic REST API in the existing application server**, scoped to the management repo for this feature iteration.

**Rationale:**
- Only one repo is registered (`management-repo`), so a microservice split is out of scope.
- v1 scope is intentionally narrow (5 entity types, read/write, no streaming) — the overhead of a separate service is not justified.
- The monolithic approach is the fastest path to unblocking enterprise deals while keeping operational complexity low.
- Rate limiting will be implemented as a dedicated middleware layer that can be extracted later.

**Design summary:**
1. **API Key Management** — generate, store (hashed), and revoke API keys with configurable scopes (`read`, `write`, `admin`). Keys are associated with a workspace.
2. **REST API v1** — versioned routes under `/api/v1/` covering: workspaces, projects, tasks, users, comments. Standard CRUD where applicable.
3. **Webhook System** — customers register endpoint URLs and select event types. On platform action, an async job dispatches a signed HTTP POST to registered endpoints. Best-effort delivery with 3 retries and exponential backoff.
4. **Rate Limiting Middleware** — 1,000 requests/min per API key, enforced in-process using a sliding-window counter backed by Redis (or in-memory fallback for dev).
5. **OpenAPI Documentation** — auto-generated from route annotations, published at `/developer` as an interactive Swagger UI.

**Affected repositories:** `management-repo` only.

## Dependency Analysis

### Internal dependencies
- **Data models** — API routes depend on existing entity schemas (workspaces, projects, tasks, users, comments). Schema must be stable before route implementation begins.
- **Authentication middleware** — API key validation middleware must be in place before any protected route can be tested end-to-end.
- **Async job queue** — webhook dispatch requires an async worker (background job queue). Must be provisioned before webhook dispatch is wired up.
- **Redis / rate-limit store** — rate limiting middleware depends on a key-value store. Can use in-memory fallback during development.

### External dependencies
- **No new external vendors required** — Redis is assumed to already be available or replaceable with in-memory for v1.
- **OpenAPI tooling** — a schema generation library compatible with the existing server framework must be selected and integrated.

### Blocking decisions
- **D1:** Confirm which async job queue library/infrastructure is already in use (or select one) — blocks webhook dispatch task.
- **D2:** Confirm Redis availability in the deployment environment — blocks production rate limiting task.

### Release dependencies
- API key management UI (customer-facing) is not in scope for this feature — keys will be generated via API or admin panel only at launch.
- Developer portal URL (`/developer`) must be publicly accessible without authentication.

## Parallelization / Blocking Analysis

```
D1: Confirm async job queue (existing or new) ──┐
D2: Confirm Redis availability in prod env      ──┘ resolve before T4 and T3 respectively; low-effort decisions

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
    └── T3 and T4 run in parallel once T2 and T1 are done respectively

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

## Repository Impact

| Repo | Impact |
|---|---|
| `management-repo` | All changes land here — API routes, middleware, webhook system, docs portal, tests |

All tasks in this feature target `management-repo` exclusively. No other repos are registered in `workspace.yaml`.

## Validation and Release Impact

### Testing expectations
- Unit tests for API key hashing, scope validation, and rate-limit counter logic.
- Integration tests covering all v1 REST routes (auth, CRUD, error responses, rate limit headers).
- Webhook dispatch tests: verify signed payload delivery, retry behavior on 4xx/5xx, and exponential backoff.
- OpenAPI schema validation: generated schema must be parseable by standard Swagger tooling.

### Migration / config impact
- New database tables required: `api_keys`, `webhook_subscriptions`, `webhook_delivery_log`.
- New environment variables: `RATE_LIMIT_STORE_URL` (Redis), `WEBHOOK_SIGNING_SECRET`.
- No changes to existing database tables or internal auth flows.

### Rollout concerns
- API routes must be gated behind a feature flag for initial rollout to avoid exposing incomplete endpoints.
- Rate limiting middleware must be tested under load before enabling in production to avoid false positives.
- Webhook endpoint registration should be restricted to workspace admins only.

### Backward compatibility
- Existing internal web app routes are unaffected — `/api/v1/` namespace is new and does not collide with any existing routes.
- No breaking changes to existing sessions, auth, or UI flows.

### Deployment / handoff implications
- Redis must be provisioned (or in-memory fallback confirmed acceptable) before production deployment.
- Developer portal must be indexed by search engines — ensure `/developer` is not behind authentication.
- A changelog entry and announcement email to beta API customers should accompany the launch.
