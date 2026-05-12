# Product Specification

## Feature
- Feature ID: `platform-byo-executor`
- Title: Bring-Your-Own-Executor — customer-supplied executor images on the platform
- **Status: active** — `runtime-portable-architecture` is `done`. This feature is now in design.

## Open Technical Debt

The following internal items are deferred until this feature is activated. They were noted during earlier orchestrator work and belong here because they require the executor registration model this feature defines.

- **Broker `registry-size` endpoint**: The orchestrator's `local-docker` concurrency guard currently uses a local in-process counter (`dockerInFlight`) to track how many executor containers are running. This counter resets on orchestrator restart and cannot be shared across multiple orchestrator instances. The correct fix is a `GET /registry-size` endpoint on the Go broker service (backed by a Redis `SCAN broker:reg:*` or a dedicated counter key), exposed as `registrySize(): Promise<number>` on the `CompletionBrokerPort` interface. This becomes load-bearing when tenants have multiple orchestrators competing for the same executor pool. Tracked in code as `TODO` in `workflow/runtime/orchestrator/src/main.ts`.

## Dependency

**`runtime-portable-architecture` is `done`.** This feature now builds the customer-facing surface on top of that foundation.

The architectural reasoning behind both features lives in `../runtime-portable-architecture/discussion-orchestrator-architecture.md`. That document is the canonical record; do not duplicate it here.

## Problem

The agent runtime, even after `runtime-portable-architecture` lands, will still ship and run a single platform-controlled executor image. To turn the platform into a service many customers can use, customers need to:

- Bring their own executor image (their own model provider, prompts, internal skills, proprietary tooling) — without sharing source.
- Choose where their executor runs — on platform-managed infrastructure (push) or inside their own network (pull, GitHub-Actions-runner-style, outbound-only).
- Trust that their data, credentials, and runs are isolated from other customers.
- See their own usage, logs, and bills through a self-service surface.

These needs do not exist in `runtime-portable-architecture`'s scope and intentionally do not affect its design. They are the product surface that turns a portable runtime into a multi-tenant platform business.

## Vision

A workflow-as-a-service platform: a customer registers a workspace and an executor image (or installs a runner agent), passes a conformance test, and gets the full task lifecycle — claim, execute, review, merge — handled by the platform. Across many tenants concurrently, with strong isolation, scoped credentials, and per-tenant observability and billing.

Two execution shapes coexist per platform deployment, chosen per-tenant:

- **Platform-hosted execution.** Push-based; platform spawns the customer's executor on its own infrastructure.
- **Customer-hosted execution.** Pull-based; a platform-supplied runner agent lives in the customer's network, long-polls the platform for work, and never accepts inbound connections. Required for enterprise / on-prem / regulated customers.

## Goals

These goals distinguish this feature from the architectural foundation it depends on. None are in scope for `runtime-portable-architecture`.

- A customer can register an executor image (registry URL, version, pull credentials, capability labels) against their workspace.
- A platform-operated conformance test runs against every newly registered or version-bumped image and gates activation on a pass.
- The platform provisions runtime infrastructure on demand, per tenant, and routes each task to the tenant's registered executor.
- The platform supplies a runner agent (binary + container) that customers run in their own infrastructure for the pull shape.
- Tenants are isolated — namespace, network, secrets, observability — across all dimensions.
- Credentials issued to executor instances are minted per-task with the smallest scope sufficient.
- Per-tenant resource usage is tracked for metering and billing.
- Customers have a self-service surface to register images, view their own runs and logs, and check conformance status.

## Non-goals

- Replacing or modifying the architectural foundation delivered by `runtime-portable-architecture`. This feature is purely additive on top of those seams.
- Building the executor SDK or reference Claude executor — they exist (`@workflow/runtime-abi`, `runtime/executors/claude/`).
- Running customer code on shared infrastructure — every executor invocation runs in tenant-scoped infrastructure.
- Supporting non-containerised executors — the contract remains the runtime ABI plus a container image.
- Hosting customers' workspace repos. Customers keep workflow state on their own git provider.

## Open business questions

These must be resolved during technical design.

- **B1 — Conformance test scope.** Synthetic suite vs schema-only vs customer fixtures (or combination).
- **B2 — Billing unit.** Per task, per executor-minute, per claim, per push/pull invocation, tiered subscription.
- **B3 — Failure attribution policy.** Customer executor bug vs platform infrastructure issue vs customer workflow problem; who pays / whose SLA bites.
- **B4 — ABI versioning policy.** N concurrent supported versions vs single-version-at-a-time; deprecation windows; in-flight task handling at end-of-support.
- **B5 — Credential model.** Customer-supplied PAT vs GitHub App with per-task installation tokens vs cloud KMS / Vault integration.
- **B6 — Tenant isolation guarantees.** Soft (logical namespaces, shared compute) vs hard (per-tenant compute) vs tiered.
- **B7 — Runner agent host requirements.** Docker daemon, kubelet, or just outbound HTTPS — affects customer reach and runner-agent internal complexity.


## References

- `../runtime-portable-architecture/product-spec.md` — the architectural foundation this feature depends on
- `../runtime-portable-architecture/technical-design.md` — the architectural design
- `../runtime-portable-architecture/discussion-orchestrator-architecture.md` — long-form architectural reasoning, including the long-term BYO direction
