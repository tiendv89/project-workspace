# Product Specification

## Feature
- Feature ID: `platform-byo-executor`
- Title: Bring-Your-Own-Executor — customer-supplied executor images on the platform
- **Status: deferred** — blocked on `runtime-portable-architecture`. This is a placeholder product spec capturing the long-term direction agreed during the architectural discussion. Activate this feature only after `runtime-portable-architecture` is `done`.

## Dependency

This feature has a hard prerequisite: **`runtime-portable-architecture` must be `done`** before any technical design or implementation work on this feature begins.

`runtime-portable-architecture` delivers the architectural foundation (hexagonal refactor, async submit/reap, ports + adapters + profiles, two local profiles, tenant-context plumbing). This feature builds the customer-facing surface on top of those foundations.

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

## Goals (long-form, deferred)

These are the goals that distinguish this feature from the architectural foundation it depends on. None of them are in scope for `runtime-portable-architecture`.

- A customer can register an executor image (registry URL, version, pull credentials, capability labels) against their workspace.
- A platform-operated conformance test runs against every newly registered or version-bumped image and gates activation on a pass.
- The platform provisions runtime infrastructure on demand, per tenant, and routes each task to the tenant's registered executor.
- The platform supplies a runner agent (binary + container) that customers run in their own infrastructure for the pull shape.
- Tenants are isolated — namespace, network, secrets, observability — across all dimensions.
- Credentials issued to executor instances are minted per-task with the smallest scope sufficient.
- Per-tenant resource usage is tracked for metering and billing.
- Customers have a self-service surface to register images, view their own runs and logs, and check conformance status.

## Non-goals (long-form, deferred)

- Replacing or modifying the architectural foundation delivered by `runtime-portable-architecture`. This feature is purely additive on top of those seams.
- Building the executor SDK or reference Claude executor — they exist (`@workflow/runtime-abi`, `runtime/executors/claude/`).
- Running customer code on shared infrastructure — every executor invocation runs in tenant-scoped infrastructure.
- Supporting non-containerised executors — the contract remains the runtime ABI plus a container image.
- Hosting customers' workspace repos. Customers keep workflow state on their own git provider.

## Open business questions (deferred)

These are documented now so they are not lost, but they will be reopened and answered when this feature is activated. They are intentionally not committed to.

- **B1 — Conformance test scope.** Synthetic suite vs schema-only vs customer fixtures (or combination).
- **B2 — Billing unit.** Per task, per executor-minute, per claim, per push/pull invocation, tiered subscription.
- **B3 — Failure attribution policy.** Customer executor bug vs platform infrastructure issue vs customer workflow problem; who pays / whose SLA bites.
- **B4 — ABI versioning policy.** N concurrent supported versions vs single-version-at-a-time; deprecation windows; in-flight task handling at end-of-support.
- **B5 — Credential model.** Customer-supplied PAT vs GitHub App with per-task installation tokens vs cloud KMS / Vault integration.
- **B6 — Tenant isolation guarantees.** Soft (logical namespaces, shared compute) vs hard (per-tenant compute) vs tiered.
- **B7 — Runner agent host requirements.** Docker daemon, kubelet, or just outbound HTTPS — affects customer reach and runner-agent internal complexity.

## Why we are deferring

The architecture this feature depends on is large enough on its own. Combining the architectural refactor with the customer-facing product surface in one feature was creating a scope that:

- Could not be reviewed coherently (architectural decisions and product decisions interleaved).
- Could not be implemented in stages (every implementation wave needed both architecture and product progress).
- Forced premature commitment to product decisions (billing, conformance, isolation tier) before the architectural pieces were stable.

Splitting allows us to land the runtime architecture first, validate it under real workflow load, and then build the product surface deliberately on top.

## When to activate this feature

Activate this feature (move from `blocked` to `in_design`) when:

1. `runtime-portable-architecture` has reached `done` status.
2. There is appetite to invest in the customer-facing platform surface (this is significant scope on its own).
3. We have at least one prospective customer or design partner whose needs can shape B1–B7.

At activation, this product spec will be re-opened, the deferred questions will be discussed, and a fresh technical design will be authored on top of the architecture this feature's prerequisite delivered.

## References

- `../runtime-portable-architecture/product-spec.md` — the architectural foundation this feature depends on
- `../runtime-portable-architecture/technical-design.md` — the architectural design
- `../runtime-portable-architecture/discussion-orchestrator-architecture.md` — long-form architectural reasoning, including the long-term BYO direction
