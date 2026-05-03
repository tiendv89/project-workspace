# Product Specification

## Feature
- Feature ID: `runtime-portable-architecture`
- Title: Portable runtime architecture — extract today's bundled orchestrator/executor into ports, adapters, and profiles

## Problem

Today's agent runtime is bundled and blocking:

- Orchestrator and executor ship in **one Docker image**.
- The orchestrator's cycle **does not continue until the executor finishes** the current task. One worker handles one task at a time, for the full duration of the task.
- The implementation is wired to a single deployment shape (sub-process inside a container).

This shape was the right starting point — it got us a working agent runtime. But it constrains every direction we want to grow:

- Adding a second deployment target (a different scheduler, a different cluster, a different topology) means a fork, not a configuration change.
- Concurrency is bounded by the number of orchestrator workers we run, because each worker is busy for the full task duration.
- Local dev and production execute against different code paths once we add any production-only behaviour.
- We cannot give the executor team release independence without the architectural seams to separate them.

We need the runtime's architecture to be **portable** — same orchestrator binary across local dev, production, and any future deployment target — and **non-waiting** — the orchestrator's cycle should not stall on any single executor.

This feature is the architectural foundation. It does not ship customer-facing capabilities; those depend on it but are out of scope here.

## Vision

The orchestrator becomes a small, infrastructure-agnostic core. Concrete behaviour for "how do we launch executors", "how do we deliver a briefing", "how do we collect a result", "where does workflow state live" is provided by adapters injected at startup based on a named profile. Local dev, production, and future deployment shapes are all the same binary with different adapter sets.

The orchestrator's cycle never waits for an executor to finish. Submitting a task returns immediately with a handle; results are collected by a separate reap step in a later cycle.

## Goals

- Refactor today's inline orchestrator code into a small set of TypeScript port interfaces with at least one adapter implementation each.
- Define a profile mechanism that wires a chosen adapter set into the ports at startup. Today's behaviour ships as the `local-subprocess` profile and is preserved bit-for-bit.
- Add a second profile, `local-docker`, that runs the **same Claude executor image** as a separate container per task — the **first M:N profile**. This proves the architecture works for separate-container deployments without any production infrastructure.
- Convert the orchestrator's claim cycle from synchronous (waits for executor to finish) to asynchronous (submits, returns; reaps results later). Pool size scales with workflow throughput, not with concurrent task count.
- Provide hermetic test coverage by adding a fake adapter for every port. The orchestrator core can be tested with no Docker, no cluster, no network.
- Document the runtime's portability contract well enough that adding a third profile (production-targeting) in a follow-on feature is purely additive — a new adapter set, no core changes.

## Non-goals

- Customer-supplied executor images. The runtime continues to use the existing Claude executor image; no second executor image is registered or run.
- Customer onboarding, tenant management, billing, conformance, image registration catalog, observability dashboards. None of these exist in this feature.
- Production push or pull adapters (HTTP service, runner protocol, K8s, queue, etc.). Adding one is a separate feature; this one ships only the local profiles needed to validate the architecture.
- Multi-tenancy as a runtime property. The architecture is tenant-context-aware (so a future feature can enable it without a refactor), but no tenant boundaries are enforced or tested in this feature.
- Replacing the existing claim-via-git protocol. Workflow state remains in git, exactly as today.

## Audience

This feature is platform-internal. The "users" served by it are:

- **Orchestrator engineers** — gain a smaller, more testable core; can iterate on workflow logic without touching execution mechanism code.
- **Executor engineers** — gain a stable ABI boundary and a fake-orchestrator harness for hermetic dev loops.
- **Future feature teams** — gain the architectural seams needed to ship customer-facing features (BYO executor, alternative deployment shapes, multi-tenancy) without re-architecting first.

There is no customer-facing surface. Customers see no change.

## Capabilities (technical, not customer-facing)

The feature delivers the following internal capabilities:

- A documented set of ports the orchestrator core depends on — the contract between the workflow logic and the world.
- At least one adapter implementation per port (the `local-subprocess` profile).
- A second profile, `local-docker`, demonstrating M:N execution with the same orchestrator binary and the same executor image, separated into per-task containers.
- Asynchronous executor lifecycle — `submit / listCompleted / readResult / ack` — replacing today's blocking child-process await.
- Fake adapters per port enabling unit and integration tests with no infrastructure.
- A profile registry mechanism so adding a new profile is a registration call, not a fork.

## Scope decisions

These are decided as of this spec and should not be re-litigated in technical design without an explicit revision.

- **The architecture follows the hexagonal / ports-and-adapters pattern** described in `discussion-orchestrator-architecture.md`. The discussion document is the long-form reasoning record.
- **Workflow state remains in git.** No DB; no replication. A git-backed `WorkflowStatePort` adapter is the only state implementation in this feature.
- **The existing Claude executor image is the only executor used.** Image registration, conformance, and customer-supplied images are out of scope.
- **Two profiles ship in this feature: `local-subprocess` and `local-docker`.** A production profile is a follow-on feature.
- **Orchestrator becomes asynchronous via `submit / listCompleted / readResult / ack`.** This is the contract; how each adapter implements those four methods is local to the adapter.
- **Tenant context flows through orchestrator code paths.** No tenant boundaries are enforced or visible at runtime, but the code is shaped so a future multi-tenant deployment is additive, not a rewrite.

## Out of scope (explicit list, deferred to follow-on features)

The following are explicitly deferred. They depend on this feature; they do not happen inside it.

- Customer registers an executor image
- Customer chooses execution shape (push vs pull)
- Conformance test runner
- Tenant signup, identity, isolation, namespace strategy
- Billing / metering
- Self-service dashboard for tenants
- Per-task scoped credential minting (GitHub App integration)
- Push or pull production adapter (HTTP service, runner protocol, K8s, queue)
- Customer-facing documentation / runner agent distribution

A future feature, currently sketched in the discussion document as `platform-byo-executor`, will pick these up. That feature will reference this one as a hard prerequisite.

## Open questions

Most of the architectural questions are resolved (see the technical design). Two genuinely open questions remain at the product level.

### B1 — How aggressively do we exercise the async path locally?
The `local-docker` profile uses the same async `submit / listCompleted / readResult / ack` flow as a future production adapter. Should the local profile also stress-test concurrency (e.g. spawn 10 simultaneous executors for one orchestrator) by default? Trade-off: realism vs developer-laptop resource use.

### B2 — What does "tenant-context-aware code" mean in practice for this scope?
We agree the code should be shaped to support multi-tenancy in a future feature without a rewrite. But how far do we go in this feature? Options:
- Plumb a `tenant_id` through every orchestrator call site, even though it's always the same value.
- Define the tenant boundary in interfaces only; defer all plumbing.
- Something in between.

This is a calibration question — the answer affects how much code in this feature is "pre-emptive" vs deferred to the multi-tenancy feature that uses it.

## Success criteria

This feature is done when:

1. Today's behaviour is preserved exactly under the `local-subprocess` profile — no functional regression.
2. The same orchestrator binary, with `--profile local-docker`, runs N orchestrator containers spawning per-task Claude executor containers via the Docker socket. Tasks complete identically to `local-subprocess`.
3. The orchestrator's cycle no longer waits for an executor to finish. Verifiable by submitting a long-running task and observing the orchestrator continue to process other concerns (review-fix, workspace-PR-lifecycle) during that task's lifetime.
4. Every port has a fake adapter; the orchestrator core has a hermetic test suite that runs with no Docker, no cluster, no network.
5. A new profile can be added in a follow-on feature as a registration call (one profile factory function), with no changes to orchestrator core code.

## References

- `technical-design.md` — architectural decisions, ports, profiles, implementation waves
- `discussion-orchestrator-architecture.md` — long-form reasoning behind the architecture, including the discarded paths and the long-term vision toward the deferred BYO product feature
