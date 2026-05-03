# Product Specification

## Feature
- Feature ID: `platform-byo-executor`
- Title: Bring-Your-Own-Executor — customer-supplied executor images on the platform

## Problem

The agent runtime today ships as a single image bundling orchestrator and Claude executor. It is operated by whoever runs the platform. This works for a single-team setup but does not scale to a platform business where many customers each want to run their own executor — different model providers, custom prompts, internal tools, proprietary code — without giving the platform their source.

Equally, customers in regulated, on-prem, or otherwise locked-down environments cannot accept inbound connections from a platform — they need a model where their executor runs entirely inside their network and reaches out to the platform only over outbound HTTPS.

The platform needs a way to (1) let a customer **register their own executor image**, (2) **prove it conforms** to the runtime ABI, and (3) run their workflows on infrastructure of their choosing — either platform-managed or customer-operated.

## Vision

Workflow is a service. The customer brings a workspace repo, registers an executor image, optionally chooses where their executors run, and the platform handles the rest: claim coordination, lifecycle, observability, billing.

Two execution shapes are first-class, chosen per tenant at registration:

- **Platform-hosted execution.** The platform runs the customer's executor image on its own infrastructure. Easiest onboarding; the customer just provides an image reference.
- **Customer-hosted execution.** The customer runs a platform-supplied runner agent inside their own network. Outbound-only connectivity; their executor never sees the platform's network. Required for enterprise / on-prem / regulated customers.

Both shapes coexist in the same platform deployment; one tenant may use one, another the other.

## Goals

- A customer can register an executor image (registry URL, version, pull credentials, capability labels) against their workspace.
- The platform runs a conformance test against every registered image and gates activation on a pass.
- The platform provisions runtime infrastructure on demand, per tenant, and routes each task to the tenant's registered executor.
- The platform supports both **push** (platform-spawned executor instances) and **pull** (customer-operated runner agents long-polling the platform) for the same `ExecutorPort` contract.
- Tenants are isolated — namespace, network, secrets, observability — so no executor instance can see another tenant's data.
- Credentials issued to executor instances are minted per-task with the smallest scope sufficient (e.g. one repo, one branch, the lifetime of one task).
- Per-tenant resource usage is tracked for metering and billing.
- Customers have a self-service surface to register images, view their own runs and logs, and check conformance status.

## Non-goals

- Building the executor SDK or the reference Claude executor — they exist (`@workflow/runtime-abi`, `runtime/executors/claude/`).
- Running customer code on shared infrastructure — every executor invocation runs in tenant-scoped infrastructure.
- Supporting non-containerised executors — the contract is a container image plus the ABI.
- Hosting customers' workspace repos. Customers keep workflow state on their own git provider; the platform reads/writes via standard git protocol.
- Making the orchestrator workflow-aware of the executor's domain logic. The orchestrator only handles workflow state (claims, lifecycle, side-effects). Domain decisions stay inside the executor.

## Personas

- **Platform operator** (us). Operates the orchestrator pool, supporting services, billing pipeline.
- **Tenant administrator.** Onboards their organisation, registers an executor image, configures workspace repos, manages tenant-scoped credentials.
- **Tenant developer.** Authors workflow tasks in their workspace repo, reviews PRs the executor produces.
- **Executor author.** Builds the executor image. May be the tenant developer, a different team inside the tenant org, or a third-party vendor producing a reusable executor.

## Customer journey

1. **Sign up.** Tenant administrator creates an account, gets a tenant ID and onboarding credentials.
2. **Register an executor image.** Provide image registry URL, version tag, pull credentials, capability labels (e.g. `linux`, `gpu`, `python-3.12`). Platform stores the registration as `pending_conformance`.
3. **Run conformance.** Platform spins up the registered image against a fixed synthetic task suite. On pass, the registration becomes `active`. On fail, the customer sees the failure report.
4. **Choose execution shape.**
   - Platform-hosted (default): nothing more to do.
   - Customer-hosted: download the platform's runner agent binary / container, run it in the desired environment with a registration token. The agent starts long-polling the platform's Work Registry.
5. **Configure a workspace.** Point the platform at a git repo that contains `workspace.yaml` and `tasks/`. Provide a GitHub installation token or App credentials.
6. **Submit work.** Tenant developer pushes feature branches with task YAMLs marked `ready`. The platform claims them and dispatches to the tenant's executor.
7. **Review.** Executor opens PRs in the tenant's repo. Tenant developer reviews; merge triggers downstream lifecycle.
8. **Observe.** Tenant administrator views per-task metrics, logs, conformance status, and bills via the self-service dashboard.

## Capabilities

The platform delivers the following capabilities to tenants:

- **Tenant management** — onboarding, identity, isolation boundaries.
- **Executor image registry** — register, version, deactivate, rotate credentials.
- **Conformance gate** — synthetic task suite that runs against every newly registered or version-bumped image.
- **Workflow execution** — full workflow lifecycle: claim, run, dispatch results, review-fix, workspace-PR lifecycle.
- **Push and pull execution shapes** — tenants choose per workspace.
- **Per-tenant credentials** — short-lived, smallest-scope tokens issued per task.
- **Self-service observability** — per-tenant logs, metrics, run history.
- **Metering and billing** — aggregate per-tenant usage; bill on the agreed unit.

## Scope decisions

These are decided as of this spec; they shape the design and are not open for re-litigation without an explicit revision.

- **Workspace repo lives on the customer's own git provider.** The platform reads and writes via standard git, never mirrors. Their repo is the source of truth for workflow state.
- **The orchestrator pool is a single multi-tenant service** operated by the platform. Customers do not run orchestrator instances. Sharding the pool by tenant is a future scale concern, not day-one.
- **Both push and pull execution shapes are supported** under the same internal contract. The choice is per-tenant configuration.
- **The runtime ABI is the boundary** between platform and executor. Executor authors implement against the ABI; the platform never sees executor source.
- **The platform supplies a runner agent** (binary + container) that customers run in their own infra for the pull shape. The agent is part of the platform deliverable, not customer-built.
- **Each task uses an immutable executor image reference at claim time.** New image versions affect future tasks; in-flight tasks finish on the version they started with.

## Open questions

These remain open and require decisions before the technical design can be approved or implementation can begin.

### B1 — Conformance test scope
What does "passing conformance" mean? Three plausible answers, mix-and-match acceptable:
- A platform-defined synthetic task suite (e.g. five canned tasks the executor must complete correctly).
- A schema-only check (the image accepts the ABI env vars and produces a valid `result.json`).
- Customer-supplied test fixtures (each tenant ships their own conformance suite alongside their image registration).

### B2 — Billing unit
What does the platform meter? Options to decide between (or combine):
- Per task completed.
- Per executor wall-clock minute.
- Per orchestrator-claim event.
- Per push or pull invocation.
- Tiered subscription with included usage.

This shapes the design of the metering pipeline and the per-tenant observability surface.

### B3 — Failure attribution policy
When a task fails, the platform must distinguish three failure modes for SLA, billing, and dispute resolution:
- Customer executor bug (their code crashed, hung, returned invalid `result.json`).
- Platform infrastructure issue (orchestrator crashed, network error, image-pull failure).
- Customer workflow problem (bad task spec, missing dependency).

The policy decision is who pays / whose SLA bites for each class. This drives observability requirements (what evidence the platform must retain to defend each classification).

### B4 — ABI versioning policy
The runtime ABI evolves. Customer images may speak older versions. Decide:
- Major.minor versioning with N concurrent supported versions, or single-version-at-a-time with mandatory upgrade windows?
- How are deprecation windows communicated and enforced?
- What happens to in-flight tasks when a version reaches end-of-support?

### B5 — Credential model
How does the executor get credentials for git push and PR creation?
- Customer provides a long-lived personal access token in workspace config (simplest; weakest security).
- Platform integrates as a GitHub App and mints per-task installation tokens (strongest scoping; requires App per provider).
- Customer-provided cloud KMS / Vault that the platform reads at task-mint time (most flexible; most setup).

### B6 — Tenant isolation guarantees
What is the tenancy contract? Decide between:
- Soft isolation (separate logical namespaces, shared compute, network policies).
- Hard isolation (per-tenant compute, no shared workers).
- Tiered (soft by default, hard for enterprise tier).

This affects pricing, the design of the orchestrator pool, and conformance scope.

## Success metrics

- **Time-to-onboard.** Median minutes from sign-up to first claimed task.
- **Conformance pass rate.** % of registered images passing on first attempt; trend tells us about ABI clarity.
- **Per-task cost (platform side).** Compute and overhead per claim. Drives pricing.
- **Tenant retention.** % of tenants still active 90 days after onboarding.
- **Failure attribution accuracy.** % of failed tasks attributed correctly (validated against post-incident reviews).

## References

- `technical-design.md` — architecture, components, ports, adapters, profiles
- `discussion-orchestrator-architecture.md` — long-form reasoning behind the architectural choices, including the discarded paths
