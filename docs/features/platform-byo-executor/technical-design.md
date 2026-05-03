# Technical Design

## Feature
- Feature ID: `platform-byo-executor`
- Title: Bring-Your-Own-Executor — customer-supplied executor images on the platform

> Status: draft. Reflects the architectural direction agreed in
> `discussion-orchestrator-architecture.md`. This document deliberately
> leaves several questions open (T-Q*) — they are technical decisions
> that should be made together with this design's review.

## Current State

Today's runtime is single-tenant, single-machine, and bundled:

- One Docker image contains both orchestrator (`runtime/orchestrator/`) and Claude executor (`runtime/executors/claude/`).
- A `docker compose up` starts one or more `agent-N` containers; each runs an orchestrator process.
- The orchestrator loop is **blocking**: pull → eligibility → claim → spawn child → await child → dispatch result → sleep.
- Multiple agents run via multiple containers, coordinating only via git push race on GitHub.
- The `ExecutorAdapter` interface exists; `SubProcessAdapter` is its only implementation.
- Workflow state lives in the management git repo (one per workspace).

This works for one team / one machine / one image. It does not support multi-tenancy, customer-supplied executor images, or customer-controlled execution infrastructure — all required by the product spec.

## Constraints

Lifted from the product spec and previous architectural decisions:

1. **Workflow state remains in git.** The customer's repo is the system of record. No DB replacement; a DB may exist as a derived read-side cache for dashboards and search.
2. **Multi-tenant from day 1.** No per-tenant orchestrator deployment. One platform-operated pool serves all tenants.
3. **Both push and pull execution shapes** must be supported under one internal contract.
4. **M:N orchestrators-to-executors** in every profile, including local dev. The bundled-image model is a packaging convenience, not the architecture.
5. **Executor image is opaque.** Platform never has source access; it only invokes via the ABI.
6. **The runtime ABI is the contract.** Adding non-Claude executors must require zero orchestrator changes.
7. **Per-task credential scoping.** Long-lived tenant-wide credentials inside an executor are not acceptable for enterprise customers.

## Options Considered

### Decision D1 — Orchestrator topology

#### Option D1a — Per-tenant orchestrator pods
Each tenant gets their own orchestrator pod(s). Strong tenant isolation; simple per-tenant config. Cost: minimum-floor compute per tenant, fleet ops overhead, customer DX where they "operate a pod" rather than "buy workflow as a service".

#### Option D1b — Single multi-tenant orchestrator pool — **chosen**
One platform-operated pool of stateless orchestrator workers polls all tenants. Better resource efficiency, single deployment to operate, customer DX matches "managed service". Sharding by tenant ID is the eventual scale lever; not day-one.

The trust model fits because the orchestrator only handles workflow state — it never executes customer code. Customer code runs only inside executor instances, which are tenant-scoped per task. Cross-tenant compute sharing in the orchestrator is safe.

### Decision D2 — Execution dispatch model

#### Option D2a — Blocking sub-process (today)
Orchestrator awaits child exit before next cycle. Concurrency = pool size. Idle pods needed for bursts. Doesn't scale.

#### Option D2b — Non-blocking submit + asynchronous reap — **chosen**
The orchestrator submits a task to an executor instance, records a handle, returns to its loop. A separate reap mechanism collects completed results. Pool size scales with workflow throughput (claims per second), not with concurrent task count. Cluster / network capacity scales executor count independently.

### Decision D3 — Executor reachability

#### Option D3a — Push only (orchestrator → executor)
Orchestrator initiates connections to the executor. Lower latency, simpler. Requires inbound network access to the executor — unacceptable for many enterprise customers.

#### Option D3b — Pull only (executor → orchestrator)
Executors initiate all connections (long-poll). Outbound-only firewall posture. Adds operational complexity (need a Work Registry service); higher per-task latency.

#### Option D3c — Both push and pull, per tenant — **chosen**
Both shapes are first-class adapter families behind the same `ExecutorPort` contract. Tenants choose per workspace at registration. Push for platform-hosted simplicity; pull for customer-hosted flexibility. Pull is essential for enterprise / on-prem segments.

### Decision D4 — State store

#### Option D4a — Git as system of record (today)
Task YAML, logs, branches, PRs all in the customer's git repo. Full audit, easy human inspection.

#### Option D4b — Promote a DB to system of record
DB owns workflow state; git becomes a deployment artifact. Faster reads, native concurrency primitives. Loses git's audit and offline-friendliness; introduces sync complexity for branches and PRs.

**Chosen: D4a**, with a derived DB cache permitted for dashboards and platform-side analytics. Git stays authoritative.

## Chosen Design

### Architectural pattern: hexagonal (ports + adapters)

The orchestrator core depends only on a fixed set of TypeScript interfaces ("ports"). Concrete implementations ("adapters") are wired into those ports at startup based on a named "profile". The same orchestrator binary runs in every environment; only the adapter set differs.

See `discussion-orchestrator-architecture.md` Appendix A for the full reasoning, port-level table, and profile compositions. See Appendix B in that document for the system diagram.

### Top-level components

```
                    Customer / tenant
       ┌──────────────────────────────────────┐
       │  Workspace repo (git, customer-host) │
       │  Executor image registration         │
       └────────────┬─────────────────────────┘
                    │ git protocol
                    │ image reference
                    ▼
       ┌──────────────────────────────────────┐
       │  Platform                             │
       │                                       │
       │  Orchestrator pool (M, stateless)     │
       │     ─ claim concern                   │
       │     ─ review-fix concern              │
       │     ─ workspace-PR-lifecycle concern  │
       │     ─ shared reap loop                │
       │                                       │
       │  Supporting services                  │
       │     ─ Work Registry (pull)            │
       │     ─ Briefing / result transport     │
       │     ─ Credential broker               │
       │     ─ Image registration catalog      │
       │     ─ Conformance test runner         │
       │     ─ Event / metrics pipeline        │
       └────────────┬──────────────────────────┘
                    │  push (platform→exec)
                    │  pull (exec→platform via Work Registry)
                    ▼
       ┌──────────────────────────────────────┐
       │  Executor instances (N)               │
       │  Heterogeneous, per-tenant            │
       └──────────────────────────────────────┘
```

### The ports

The orchestrator core depends on these interfaces. Each has multiple adapter implementations.

| Port | Purpose |
|---|---|
| `ExecutorPort` | Full executor lifecycle: `submit`, `listCompleted`, `readResult`, `ack`. Push and pull both implement this. |
| `BriefingTransportPort` | Deliver briefing to the executor. |
| `WorkflowStatePort` | Read/write task YAML, append logs. Backed by git in every profile. |
| `CredentialPort` | Mint per-task scoped credentials for the executor. |
| `WorkspacePullPort` | Materialize the customer's workspace repo for the orchestrator's use. |
| `ImageResolverPort` | Resolve a tenant's executor image at claim time. |
| `EventEmitterPort` | Emit structured events / metrics. |
| `SchedulerPort` | Cycle cadence, tenant fairness. |
| `ClockPort` | Time, sleep, deadlines (mocked in tests). |

### The `ExecutorPort` contract

```ts
interface ExecutorPort {
  submit(input: ExecutorInput): Promise<ExecutorHandle>;
  listCompleted(): Promise<ExecutorCompletion[]>;
  readResult(handle: ExecutorHandle): Promise<ExecutorResult>;
  ack(handle: ExecutorHandle): Promise<void>;
}
```

The orchestrator's claim and review-fix concerns depend only on these four methods. The choice of push vs pull, the choice of network mechanism (HTTP, queue, blob storage, K8s API, sub-process, etc.) is entirely an adapter-internal detail.

### The three workflow concerns

The orchestrator pool runs three concerns:

1. **Claim concern.** Polls the customer's workspace repo, claims eligible tasks via git push race, calls `ExecutorPort.submit()` to dispatch the task. Records the handle on the task YAML and returns. Spawns one executor per claim.
2. **Review-fix concern.** Polls in-review PRs. For tier-1 conflicts, spawns an executor (`subkind=rebase`) to resolve conflict markers. For unresolved review threads, spawns an executor (`subkind=respond`) to address comments. Same `ExecutorPort.submit` flow.
3. **Workspace-PR lifecycle concern.** Pure git/API operations: open the management-repo PR at claim time, merge it when the impl PR merges, recover stuck PRs. Never spawns an executor.

A **shared reap loop** alongside the concerns enumerates completed work via `ExecutorPort.listCompleted()`, routes each completion by its handle's label kind (`impl` → claim concern's dispatcher; `review-fix` → review-fix dispatcher), and acks the handle.

### Adapter families

Each `ExecutorPort` adapter chooses one of two reachability patterns:

#### Push family
Orchestrator submits work directly to an executor instance it can reach.

- `SubProcessAdapter` — local dev. Executor is a child process of the orchestrator. `submit` blocks; `listCompleted` is trivial.
- `DockerRunAdapter` — local M:N dev. Orchestrator spawns ephemeral docker containers via the Docker socket.
- `HttpClientAdapter` — submit via HTTP `POST` to a long-running executor service the platform can reach. Result delivered via callback or fetch.
- `K8sJobAdapter` (if/when adopted as a production target) — `kubectl create job` with image pull from the tenant's registered image.
- `LambdaAdapter`, `QueueProducerAdapter`, etc. — additional push variants behind the same interface.

#### Pull family
Executors initiate all connections; orchestrator never touches the executor's network.

- `RunnerProtocolAdapter` — submit puts work into the platform's Work Registry; runner agents in customer infra long-poll for it. Same pattern as GitHub Actions self-hosted runners.

The platform supplies the **runner agent** (binary + container) that customers run in their infra. The runner agent:
- Authenticates with platform-issued registration token.
- Long-polls Work Registry for work matching its labels.
- Pulls the assigned task; downloads briefing.
- Spawns the local executor (could be sub-process, docker run, k8s job — the runner agent's internal choice).
- Streams logs back via outbound HTTPS.
- Uploads result.json to the result artifact store.
- Acks the work item.

### Profile system

Adapters are bundled into named profiles selected at startup:

| Profile | Use case | ExecutorPort | Reach pattern |
|---|---|---|---|
| `local-subprocess` | Orchestrator-engineer dev loop; today's bundled image | `SubProcessAdapter` | push (in-proc) |
| `local-docker` | First true M:N profile; BYO-executor local testing | `DockerRunAdapter` | push (Docker socket) |
| `local-kind` | Production-parity dev on a laptop (optional) | whichever production adapter | push or pull |
| `prod-push-http` | Platform-hosted execution; long-running executor service | `HttpClientAdapter` | push |
| `prod-pull-runner` | Customer-hosted execution; runner agents in customer infra | `RunnerProtocolAdapter` | pull |

A production deployment runs **multiple ExecutorPort adapters concurrently** — one for each tenant's chosen execution shape. Tenant config selects which adapter handles their tasks.

### Loop topology

Day 1: one sequential cycle inside an orchestrator process — claim concern, then review-fix, then workspace-PR-lifecycle, then sleep. Mirrors today's `agent-loop.ts`. Splits into independent concurrent loops only when measured cadence needs diverge. Detail in `discussion-orchestrator-architecture.md`.

### Multi-tenant fairness

Each cycle, the orchestrator pool's claim concern visits tenants in round-robin order with a bounded number of claims per tenant per cycle. Prevents one busy tenant from starving others. Sharding the pool by tenant ID is the future-scale lever; not day-one.

### Workflow state pattern

Git remains authoritative for workflow state. The orchestrator pool's `WorkflowStatePort` adapter clones each workspace repo, reads/writes task YAMLs, commits and pushes. A future caching mirror (read-side) is permitted but does not own the state.

## Dependency Analysis

### External dependencies
- `@workflow/runtime-abi` (existing). May need version bump for new fields (handle, labels, subkinds).
- A container registry where customers push their executor images. Platform reads via image pull credentials registered per tenant.
- A blob / object store for result artifacts and runner-uploaded logs.
- An identity provider / token issuer (for tenant accounts and runner-agent registration tokens).

### Cross-feature dependencies
- `agent-runtime-split` (T1–T7, all done) — provides the ABI foundation. No further work required from that feature.
- No other in-flight features block this.

### Codebase-side dependencies (must land before customer-facing work)

1. **Port extraction.** Refactor today's inline adapters in `runtime/orchestrator/` into the port interfaces named above. Implement the `local-subprocess` profile factory that wires today's behaviour. No functional change visible.
2. **`DockerRunAdapter` + `local-docker` profile.** First true M:N profile. Unblocks BYO-executor local testing.
3. **Production execution adapter.** Pick first: push-via-HTTP or pull-via-Runner-Protocol. Recommend pull-first because it's the harder shape and forces the architectural seams to be honest.
4. **Work Registry service.** New platform service. Long-poll API for runner agents; durable storage of in-flight items; label-based work matching; heartbeat tracking.
5. **Runner agent binary / container.** Platform-supplied; customers run in their infra. Implements the pull-side protocol.
6. **Credential broker.** Mints per-task scoped tokens. GitHub App integration is the most common case.
7. **Image registration catalog + conformance runner.** Stores registrations, runs the conformance suite, gates activation.
8. **Tenant management.** Onboarding, isolation, identity, billing primitives.
9. **Self-service surface.** Dashboard / CLI for tenants to register, view runs, view metrics.

## Parallelization / Blocking Analysis

Implementation can proceed in five waves. Each wave is independently shippable.

### Wave 1 — Adapter extraction (must be first)
- Extract today's inline orchestrator into ports + adapters.
- Implement `local-subprocess` profile (no behaviour change).
- Comprehensive fake adapters for hermetic testing.

### Wave 2 — Local M:N
- `DockerRunAdapter` + `local-docker` profile.
- Customers can now register and conformance-test their image locally against the real orchestrator code.
- Blocks: nothing else after Wave 1.

### Wave 3 — Production execution adapters (parallel)
- Wave 3a: `RunnerProtocolAdapter` + Work Registry service + Runner agent.
- Wave 3b: `HttpClientAdapter` (push variant).
- These can be done in either order or in parallel by separate teams. Recommend 3a first because it forces the cleanest seams.

### Wave 4 — Platform services (parallel after Wave 1)
- 4a: Credential broker (GitHub App integration).
- 4b: Image registration catalog.
- 4c: Conformance test runner (depends on 4b for the catalog and Wave 2 for the local image-run capability).
- 4d: Event / metrics pipeline (per-tenant isolation).
- 4e: Tenant management.

These don't block Waves 1–3; they're parallel platform-side workstreams.

### Wave 5 — Customer-facing
- Self-service registration UI / CLI.
- Tenant observability dashboard.
- Documentation: runner agent install guide, ABI reference, conformance description.

Wave 5 closes the loop for customer onboarding.

## Open technical questions

These are decisions to make in the technical design review (in addition to the business questions in `product-spec.md`).

### T-Q1 — Where do briefing and result artifacts live?
Options: a per-tenant blob store (S3 etc.), per-task ephemeral PVC, inline in HTTP requests, or a mix. Trade-off is large-payload cost vs latency vs operational complexity.

### T-Q2 — Which production adapter ships first, push or pull?
Both must exist eventually. The argument for pull-first is that it forces the most architecturally honest seams. The argument for push-first is shorter time to platform-hosted onboarding for non-enterprise tenants.

### T-Q3 — Runner agent host requirements
What does the runner agent need on the host? Docker daemon? Kubelet? Just a Linux box with HTTPS out? The lower the requirements, the broader the customer reach but the more the runner agent has to do internally.

### T-Q4 — Reap mechanism: shared loop vs per-concern
Day-1 likely a shared reap loop routed by handle label (Pattern 2 in the discussion doc). Confirm during review.

### T-Q5 — Versioning of the ABI between platform and runner agent
The platform-issued runner agent and the platform's orchestrator must speak compatible protocol versions. How are upgrades coordinated when customers run old runner agents in long-lived environments? Suggest: dual-version support window with explicit deprecation; runner agent's handshake declares its version.

### T-Q6 — How does the conformance runner execute the candidate image?
Conformance must run the customer's image in a controlled sandbox to validate ABI compliance. This implies the platform has a "conformance execution" environment — most likely the same `prod-push-http` adapter pointed at an isolated ephemeral environment per conformance run.

### T-Q7 — Resource limits and quotas per tenant
Bound CPU, memory, run time, concurrent tasks, image-pull rate. Where does this enforcement live (orchestrator, Work Registry, executor adapter)? Suggest the Work Registry / executor adapter is the natural enforcement point.

## References

- `product-spec.md` — business goals, customer journey, scope decisions, open business questions
- `discussion-orchestrator-architecture.md` — long-form architectural reasoning, system diagram, port table, profile catalog
- `agent-runtime-split` feature — provides the ABI foundation this design builds on
