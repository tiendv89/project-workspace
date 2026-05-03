# Discussion — Orchestrator architecture for the platform

> **Status**: ongoing discussion document, not a decision record. Captures
> reasoning to be revisited as the product spec evolves. When a decision is
> reached, lift it into `product-spec.md` (Goals / Architecture invariants)
> and reference this file from the relevant Q.

This document records the architectural discussion behind several of the
open questions (Q1, Q5, Q6, Q7) in `product-spec.md`. The questions
themselves remain open; what is captured here is the *shape of the
problem* and the *direction we are leaning*, with reasoning that will help
re-enter the discussion later.

---

## Context: how the runtime works today

Today's runtime is single-tenant, single-machine:

- Orchestrator + Claude executor are bundled in **one Docker image**.
- A `docker compose up` starts one (or more) `agent-N` containers.
- Each container runs its own orchestrator process (`main.ts`).
- The orchestrator loop is **blocking**:
  ```
  pull workspaces → eligibility → claim → spawn child → await child exit (up to 2 hrs)
                  → side-effects → sleep → repeat
  ```
- The executor is a child process spawned via `SubProcessAdapter`; the
  orchestrator `await`s its exit before starting the next cycle.
- Multiple agents run in parallel by running multiple containers, each
  with their own loop. They coordinate only via **GitHub git push race**
  (first-push-wins on the task branch).

This model is:
- Simple to reason about
- Has no single point of failure (one container's crash doesn't affect
  others)
- Scales horizontally by adding containers
- Uses git as the system of record (state, audit, claim coordination)

Everything below is what changes (and what doesn't) when this becomes a
multi-tenant platform.

---

## The platform shift — two levels of "one or many orchestrators"

The "should we have one orchestrator or many" question splits into **two
questions at different levels**, with different answers.

### Level 1 — Who operates the orchestrator?

- **Today (per-tenant ops)**: customer runs their own agent containers on
  their own infra.
- **Platform (platform-operated)**: platform runs an orchestrator pool;
  customer never deploys an orchestrator pod. They register a workspace
  and an executor image and get workflow as a service.

**Direction we're leaning:** platform-operated single multi-tenant pool
(sharded later if scale demands).

Reasoning:
- **Customer DX** — customers buy "managed agent runtime", not "operate
  this orchestrator pod yourself."
- **Resource efficiency** — bursts smooth across tenants; idle tenants
  pay zero compute. Per-tenant pools have a fixed minimum-floor cost per
  customer.
- **Trust model fits** — orchestrator handles only workflow state
  (already in customer's git). It never executes untrusted code. So the
  platform can safely share orchestrator compute across tenants without
  isolation risk.
- **Operational sanity** — one orchestrator deployment to upgrade,
  monitor, scale. Per-tenant pools become a fleet.
- **Sharding when needed** — at 1000+ tenants, shard the pool by
  `tenant_id`. Each shard is itself a multi-tenant pool serving its
  slice. Standard SaaS pattern. Not a day-one constraint.

### Level 2 — Within the platform pool, one process or many?

This is the same question we already answered for today's runtime: N
workers polling independently, racing via git claim. **Same answer
holds inside the platform pool.** The difference is they're
platform-owned and multi-tenant aware.

---

## The bottleneck problem (raised 2026-05-03)

> The orchestrator (if blocking) will be the bottleneck for our system?

**Yes — exactly the right concern.** This is the most important
architectural decision in the whole feature, and it's the place where the
single-machine model silently fails at platform scale.

### Why it bottlenecks

In today's design, the orchestrator does two things in the same loop:
1. **Workflow management** — poll, claim, dispatch results (cheap,
   milliseconds).
2. **Executor lifecycle** — `await child.exit()` (expensive, minutes to
   hours).

Bundling these is fine on a single machine. At platform scale it breaks:

- Each worker is busy for the full task duration.
- N workers → ceiling of N concurrent tasks across **all tenants**.
- To handle 500 concurrent tasks, you'd need 500 idle worker pods.
- That isn't a real platform — it's a fleet of expensive busy-waiters.

### The fix — orchestrator submits, K8s waits

Hand executor lifecycle to **Kubernetes Jobs**. A K8s Job is exactly the
right primitive: *"run this pod to completion, I'll come back later for
the result."*

```
Orchestrator cycle (non-blocking, runs continuously):

  Phase 1 — Claim new work (fast)
    for each tenant (round-robin, bounded per cycle):
      poll workspace repo
      claim eligible task (git push race — same as today)
      kubectl create job ─── tenant's executor image
                          ── env vars (TASK_ID, ...)
                          ── briefing as ConfigMap
                          ── labels: tenant=A, task=T7, feature=X
      record job_name in task YAML, commit "in_progress"
      ▸ no waiting — Job runs in background

  Phase 2 — Reap completed work (fast)
    list Jobs with label platform=true, status=Complete
    for each completed job:
      read result.json from Job's PVC / S3 / stdout
      dispatch side-effects (PR open, status update, log entry)
      delete Job

  Phase 3 — Reap failures / timeouts
    similar — failed Jobs trigger blocked status + side-effects

  sleep 5–30 s
  loop
```

Each phase is bounded by **network round trips**, not by executor
wall-time. One orchestrator pod can manage hundreds or thousands of
in-flight Jobs.

### What this gives us

| Property | Blocking model | Async / K8s Job model |
|---|---|---|
| Concurrency ceiling | = number of orchestrator workers | = K8s cluster capacity |
| Idle cost per pod | grows with concurrency target | stays small (pool sized for workflow throughput, not compute hours) |
| Orchestrator crash impact | child process killed | Job keeps running; new orchestrator pod resumes by listing Jobs |
| Per-tenant scaling | needs per-tenant pods | natural (Job count per tenant scales freely) |
| Burstability | poor — need idle pods for spikes | excellent — K8s spins up Jobs on demand |

The critical property: **orchestrator pool size is decoupled from
concurrent task count**. Size the pool for *workflow events per second*
(claims, dispatches), not for *executor compute hours*.

### Where state lives

Stateless orchestrator + reconciliation pattern (standard K8s
controller):

- **Task YAML** holds a pointer: `task.execution.k8s_job = "exec-T7-abc"`.
  Customer-visible source of truth for workflow state.
- **K8s Job labels/annotations** carry runtime context: `tenant_id`,
  `task_id`, `feature_id`, briefing hash. Runtime authority.
- **Orchestrator** is stateless. On startup, it lists Jobs with
  `label: platform=true` and reconciles their status against task YAMLs.
  No durable orchestrator state needed.

### Loop topology — sequential cycle vs parallel loops

A practical question once the orchestrator is non-blocking: should the
three phases (claim, reap completed, reap failures) run sequentially in
one cycle, or as independent concurrent loops?

In TypeScript / Node.js, the runtime is single-threaded with cooperative
concurrency. "Parallel loops" here means **multiple async functions
running concurrently in the same event loop** — not threads, not
processes. They interleave at `await` points. This is fine for our
workload because every phase is I/O-bound (HTTP, git, K8s API), not
CPU-bound.

#### Shape A — One sequential cycle (simpler)

```ts
async function runOneCycle(): Promise<void> {
  await claimPhase();          // poll, claim, dispatch new executors
  await reapCompletedPhase();  // collect finished, dispatch side-effects
  await reapFailuresPhase();   // collect failed/timed-out, mark blocked
}

async function runAgentLoop(): Promise<void> {
  while (true) {
    await runOneCycle();
    await sleep(IDLE_MS);
  }
}
```

- All three phases share one cadence.
- One logical "cycle" — easy to reason about, easy to log, easy to test.
- One git-mutation flow per cycle (fewer surprises around concurrent
  pushes from the same pod).
- Fine when phases are fast — and they are, because we offloaded the
  long-running part to K8s Jobs.
- This is what today's `agent-loop.ts` already looks like; the only
  change is splitting `runOneCycle` into three internal phases.

#### Shape B — Three independent async loops (more flexible)

```ts
async function claimLoop(): Promise<void> {
  while (true) {
    await claimPhase();
    await sleep(CLAIM_INTERVAL_MS);   // e.g. 10_000
  }
}

async function reapCompletedLoop(): Promise<void> {
  while (true) {
    await reapCompletedPhase();
    await sleep(REAP_INTERVAL_MS);    // e.g. 2_000 — tighter for UX
  }
}

async function reapFailuresLoop(): Promise<void> {
  while (true) {
    await reapFailuresPhase();
    await sleep(FAILURE_INTERVAL_MS); // e.g. 30_000 — failures are rare
  }
}

async function main(): Promise<void> {
  await Promise.all([
    claimLoop(),
    reapCompletedLoop(),
    reapFailuresLoop(),
  ]);
}
```

- Each loop has its own cadence. Reaping completions can be tight
  (sub-second perceived latency for the customer); claiming can be
  slower; failure detection slower still.
- A slow phase doesn't delay the others.
- Closer to how mature K8s controllers behave (one informer/work-queue
  per resource type).
- Cost: more concurrency to reason about. Need synchronisation on
  shared state — specifically anything that mutates the local git
  working tree or the same task YAML. A single in-process mutex around
  git operations is usually enough; the rest is read-only from
  separate concerns.

#### Across pods

Multiple orchestrator pods give parallelism for free regardless of
which internal shape you pick:

- Shape A × 3 pods → 3 concurrent cycles, each doing all phases.
- Shape B × 3 pods → 9 concurrent loops (3 phases × 3 pods).

The git claim race + Job-list reaping handles cross-pod coordination
the same way in either case. No coordination service needed.

#### Recommended progression

1. **Day 1** — single pod, Shape A (sequential cycle). Mirrors today's
   `runOneCycle`; minimal change. Validate the K8s Job pattern works.
2. **Day 2** — scale to N pods, still Shape A internally. Free
   parallelism across pods via the existing claim race.
3. **Day 3 (if measured)** — split into Shape B when you have evidence
   that completion-reap latency hurts UX or that mixing cadences is
   limiting throughput.
4. **Day 4 (if measured)** — specialise pod roles (claim-pods vs
   reap-pods) when fleet size makes homogeneity wasteful. Most
   platforms never need this.

Each step is additive — no rewrites, just splits.

### What stays unchanged

The customer's executor image is **completely unaware** of this. From
its perspective, it gets env vars + a briefing path, runs, writes
`result.json`, exits. Whether it was spawned by `node spawn()` or
`kubectl create job` is invisible.

- The **ABI** is the same.
- The **conformance test** is the same.
- The customer's **local dev loop** (`fake-orchestrator run --image
  my-executor:dev`) is the same.

This is purely an orchestrator-side change — exactly what the existing
`ExecutorAdapter` interface was designed for. Today's `SubProcessAdapter`
becomes one of two adapters; `K8sJobAdapter` is the other. Same
interface, different implementation.

---

## How this shapes the open questions

| Spec question | Effect |
|---|---|
| **Q1 — Pod lifecycle** | Pushes strongly toward **ephemeral per-task pods via K8s Jobs**. Long-running per-tenant pods become anti-pattern (idle cost, lifecycle complexity). |
| **Q5 — Network model** | Becomes "orchestrator pool in platform namespace, executor Jobs in tenant namespace". Briefing via ConfigMap or PVC; result via PVC + label, S3, or push endpoint. No sidecar. |
| **Q6 — Versioning under load** | Cleanly handled — each task captures the executor image tag at claim time (snapshot semantics). Orchestrator pool is unaffected by tenant version churn. Running tasks finish on their pinned version. |
| **Q7 — Multi-executor per tenant** | Cleanly supported — claim-time logic looks up `executor_image` per task type or per workspace config. Routing lives in the orchestrator pool. |
| **New Q (implicit)** | *"How does the orchestrator know an executor is done?"* Two viable patterns: poll Jobs each cycle (simpler, scales fine to thousands), or use K8s informer / watch API for event-driven completion. Polling is what most controllers do. |

---

## Candidate paragraphs to lift into product-spec.md

When the discussion settles, two paragraphs in `## Goals` (or a new
`## Architecture invariants` section) lock the operational shape:

1. **Workflow as a service.**
   > The platform operates a single multi-tenant orchestrator pool.
   > Customers do not run orchestrator pods. Each task's executor runs in
   > a tenant-isolated pod spawned per-task by the orchestrator pool,
   > using the tenant's registered image. Sharding the orchestrator pool
   > by tenant is a future scale concern, not a day-one constraint.

2. **Non-blocking orchestrator.**
   > The platform orchestrator does not block on executor completion.
   > Each claimed task is dispatched as a Kubernetes Job in the tenant's
   > namespace; the orchestrator records the Job reference in the task
   > YAML and returns to its polling loop. Completion is detected
   > asynchronously by listing in-flight Jobs and reaping completed
   > ones. Orchestrator pool size scales with workflow throughput
   > (claims and dispatches per second), not with concurrent task count.

These two together force consistent answers to Q1, Q5, Q6, and the
implicit "how does the orchestrator scale" question, and prevent a
later temptation to "just block, it's simpler" — which is what would
silently kill platform scaling.

---

## Things still on the discussion shelf

- **Result delivery mechanism** — PVC + label, S3 bucket per tenant,
  push to a callback endpoint, or executor writes back to its own
  workspace and the orchestrator reads from there. Each has tradeoffs
  in ops complexity, security, and tenant-isolation guarantees.
- **Briefing delivery mechanism** — ConfigMap (size-bounded, fast,
  immutable), PVC (larger payloads, slower spawn), or download from a
  signed URL (decoupled, requires executor to fetch).
- **Image pull credentials** — registry auth lives where? Tenant-scoped
  K8s `imagePullSecret` per namespace is the obvious answer; lifecycle
  on rotation is the messy part.
- **Per-task K8s namespace vs per-tenant** — one namespace per tenant
  with multiple Jobs running concurrently inside it, or a fresh
  namespace per task? Per-tenant is cheaper and more standard;
  per-task gives stronger isolation guarantees at high cost.
- **Fairness across tenants** — bounded claims-per-cycle per tenant is
  enough on day one. At scale, may need real scheduler logic
  (priority, quotas, fair queuing). Don't build this until measured.
- **Orchestrator HA / leader election** — N stateless orchestrator
  pods polling tenants in a sharded fashion (each pod owns a slice).
  Leader election is needed only for cross-pod coordination tasks
  (e.g. tenant onboarding triggers, infrastructure provisioning).
  Most workflow operations are sharded and need no coordination.

---

## Conversation history pointers

The reasoning above was developed across the following exchanges in
the initial spec discussion:

1. *"why both agents share the same workspaces volume — and the fix"* —
   established that today's claim protocol assumes per-agent isolated
   git working trees. Per-agent named volumes (`workspaces-agentN`) is
   the local-machine fix. (See workflow repo commit `c17c346`.)
2. *"orchestrator and executor as different teams"* — established that
   the existing ABI is the team boundary; three packaging patterns
   (single image / DockerRunAdapter / multi-stage build) suit
   different team and trust shapes. Pattern B (`DockerRunAdapter`,
   two images) is the natural fit for the platform play.
3. *"platform-byo-executor as a feature"* — captured ten open
   questions (Q1–Q10) in `product-spec.md`.
4. *"one or many orchestrator at platform scale"* — split into
   Level 1 (operations) and Level 2 (concurrency); landed on
   platform-operated single pool with N workers internally.
5. *"the orchestrator if blocking will be the bottleneck"* — the
   conversation captured here. Answer: decouple via K8s Jobs.
6. *"think like an architect — local + K8s + alternative infra,
   module-injection seam between orchestrator and executor"* — the
   appendix below. Answer: hexagonal architecture with profile-bundled
   adapters; the core is infra-agnostic, the surroundings swap per
   environment.
7. *"so 3 main loops should be run in parallel as well right?"* —
   captured in *Loop topology* above. Answer: in TypeScript / Node.js,
   "parallel loops" means multiple async functions sharing the event
   loop. Day 1 use one sequential cycle (Shape A); split into three
   independent async loops (Shape B) only when measured cadence
   needs diverge.

---

# Appendix — Portable architecture across local, K8s, and alternative infra

> **Why this matters.** We will run this tool in at least three shapes:
> a developer's laptop (no cluster, fast loop), production Kubernetes
> (multi-tenant, scaled), and at least one alternative we haven't
> committed to yet (queue-based, serverless, on-prem VM, etc.). If the
> orchestrator–executor boundary leaks infra assumptions, every new
> environment is a rewrite. If we keep the boundary clean, every new
> environment is a wiring change.

## Architectural principle

Treat the orchestrator as an **infra-agnostic core** surrounded by
**ports** (interfaces) that are filled by **adapters** (concrete
implementations) at startup. This is hexagonal architecture / ports
and adapters.

Concretely:
- The **core** contains workflow logic only — eligibility, claim,
  briefing generation, result dispatch, side-effect orchestration. It
  knows nothing about Docker, K8s, S3, or queues.
- A **port** is a TypeScript/Go interface the core depends on (e.g.
  `ExecutorPort`, `BriefingTransportPort`, `ResultTransportPort`).
- An **adapter** is one implementation of a port (e.g.
  `K8sJobExecutorAdapter`, `S3BriefingAdapter`, `LocalFileResultAdapter`).
- A **profile** is a named bundle of adapter choices that fits one
  deployment shape (e.g. `local`, `k8s`, `queue`).

The same orchestrator binary runs everywhere. The profile chosen at
startup determines which adapters are wired into which ports.

## The ports

These are the seams in the system. Each one needs to be a real
interface, not an embedded assumption.

| Port | Purpose | Local-profile adapter | K8s-profile adapter | Alt (queue) adapter |
|---|---|---|---|---|
| `ExecutorPort` | Launch the executor for one task; await completion | `SubProcessAdapter` (child process) | `K8sJobAdapter` (`kubectl create job`) | `QueueProducerAdapter` (publish job message) |
| `BriefingTransportPort` | Deliver briefing.md to the executor | `LocalFileBriefingAdapter` (path on shared FS) | `ConfigMapBriefingAdapter` (mount ConfigMap) | `S3SignedUrlBriefingAdapter` (pre-signed URL) |
| `ResultTransportPort` | Receive result.json from the executor | `LocalFileResultAdapter` (read RESULT_PATH) | `PVCResultAdapter` (read from Job's PVC) | `S3ResultAdapter` / `HttpCallbackAdapter` |
| `WorkflowStatePort` | Read/write task YAML, append logs | `GitWorkflowStateAdapter` (clone + commit + push) | `GitWorkflowStateAdapter` (same — git stays the truth) | `DBWorkflowStateAdapter` (Postgres) for high-throughput |
| `CredentialPort` | Mint scoped credentials for executor pods (GitHub token, SSH key, image pull) | `EnvCredentialAdapter` (read from process env) | `GitHubAppCredentialAdapter` + `K8sSecretAdapter` (per-task scoped tokens, namespaced secrets) | `VaultCredentialAdapter` (HashiCorp Vault) |
| `WorkspacePullPort` | Materialize the customer's workspace repo locally | `GitClonePullAdapter` (today) | `GitClonePullAdapter` (same) | `GitMirrorPullAdapter` (caching mirror) |
| `ImageResolverPort` | Resolve tenant's executor image at claim time | `StaticImageResolver` (read from agent.yaml) | `WorkspaceConfigImageResolver` (read from tenant's workspace.yaml + image registry config) | same as K8s |
| `EventEmitterPort` | Emit structured events (claims, dispatches, errors) | `StdoutJsonEmitter` (today) | `StructuredLogEmitter` (Loki / CloudWatch) + `MetricsEmitter` (Prometheus) | `KafkaEventEmitter` (Kafka topic) |
| `SchedulerPort` | When to run next cycle, fairness across tenants | `SimpleSleepScheduler` (idle_sleep_seconds) | `FairTenantScheduler` (round-robin, bounded claims/cycle) | same as K8s |
| `ClockPort` | Time, sleep, deadlines | `RealClock` | `RealClock` | `RealClock` (fake in tests) |

Each port has a **fake adapter** for tests. This lets the orchestrator
core be tested hermetically — no Docker, no cluster, no network — by
wiring fakes into every port.

## The three profiles

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       Orchestrator core                                 │
│  (eligibility, claim, briefing, dispatch — knows nothing about infra)  │
└──┬─────────┬──────────┬──────────┬──────────┬──────────┬──────────┬───┘
   │         │          │          │          │          │          │
   ▼         ▼          ▼          ▼          ▼          ▼          ▼
 Exec    Briefing    Result      State      Creds      Image      Events
 Port     Port        Port        Port       Port       Port       Port
   │         │          │          │          │          │          │
   │         │          │          │          │          │          │
═══╪═════════╪══════════╪══════════╪══════════╪══════════╪══════════╪═══
   │         │          │          │          │          │          │
   │  ┌──────┴──────────┴──────────┴──────────┴──────────┴──────────┴──┐
   │  │                                                                │
   │  │   ┌─ LOCAL profile ──────────────────────────────────────────┐ │
   │  │   │                                                          │ │
   │  └─► │ SubProc   LocalFile   LocalFile   Git    Env   Static  Stdout │ │
   │      │                                                          │ │
   │      └──────────────────────────────────────────────────────────┘ │
   │                                                                    │
   │      ┌─ K8S profile ────────────────────────────────────────────┐ │
   │      │                                                          │ │
   └────► │ K8sJob   ConfigMap   PVC        Git    GhApp WSConfig Loki │ │
          │                                       +K8sSecret             │ │
          └──────────────────────────────────────────────────────────┘ │
                                                                        │
          ┌─ QUEUE profile (alt) ────────────────────────────────────┐ │
          │                                                          │ │
          │ QPub     S3SignedUrl HttpCallback DB    Vault WSConfig Kafka │ │
          │                                                          │ │
          └──────────────────────────────────────────────────────────┘ │
                                                                        │
          ┌──────────────────────────────────────────────────────────┐ │
          │  ...future profiles (Lambda, on-prem VM, etc.) plug in   │ │
          │  here without touching the core.                         │ │
          └──────────────────────────────────────────────────────────┘ │
                                                                        │
══════════════════════════════════════════════════════════════════════ ┘
```

### Local profile — laptop dev loop

Optimised for speed and zero infra. Everything runs on the developer's
machine.

```
┌──────────────────────────┐
│ orchestrator process     │
│  └─ SubProcess adapter ─┐│
│                         ││
│ child: executor binary ◄┘│   ← briefing on local FS
│  └─ writes result.json ──┼─► local FS  → orchestrator reads it
└──────────────────────────┘
```

- Briefing: file on disk
- Result: file on disk
- State: local git clone
- Creds: env vars
- Events: stdout JSON

This is what `docker compose up` on a laptop runs. The executor is a
child process of the orchestrator. Useful for orchestrator developers
and for executor teams testing their image with `fake-orchestrator`.

### K8s profile — production multi-tenant

Optimised for scale and tenant isolation.

```
┌──────────────────────────────┐
│ Platform namespace            │
│ ┌──────────────────────────┐  │
│ │ orchestrator pool (HA)    │  │
│ │  └─ K8sJob adapter ─┐    │  │
│ └─────────────────────┼────┘  │
└───────────────────────┼───────┘
                        │ kubectl create job
                        ▼
       ┌─────────────────────────────────────┐
       │ Tenant A namespace                   │
       │  ┌──────────────────────────────┐   │
       │  │ executor Job pod (per-task)   │   │
       │  │  briefing ◄ ConfigMap mount   │   │
       │  │  result.json → PVC + label    │◄──┼─── orchestrator reaps later
       │  │  image: tenant-A:v1.2.3        │   │
       │  └──────────────────────────────┘   │
       │  NetworkPolicy: deny cross-namespace │
       └─────────────────────────────────────┘
```

- Briefing: ConfigMap (small) or PVC (large)
- Result: PVC the orchestrator mounts read-only after Job completes
- State: same git, but accessed through a per-cycle clone or a cached
  mirror service
- Creds: GitHub App per-task installation tokens + per-tenant K8s
  secrets for image pulls
- Events: structured logs to platform log stack + Prometheus metrics

### Queue profile — alternative future shape

For decoupled fleets, on-prem split, or third-party executors that
shouldn't share infra with the platform.

```
┌──────────────────────────┐
│ orchestrator (any infra) │
│ └─ QueueProducer adapter ┘
│         │
│         ▼ publishes
│   ┌────────────────┐
│   │ task queue      │ (NATS / Kafka / SQS)
│   └────────────────┘
│         │
│         ▼ consumed by
│   ┌────────────────────────┐
│   │ executor worker fleet   │
│   │ (anywhere; on-prem,     │
│   │  customer infra, etc.)  │
│   └────────────────────────┘
│         │
│         ▼ result message
│   ┌────────────────┐
│   │ result topic    │
│   └────────────────┘
│         │
│         ▼ consumed by
│  orchestrator (reaps results)
└──────────────────────────┘
```

This profile decouples *where the executor runs* from *who the platform
trusts*. The platform never sees the executor pod; it only sees the
result message. Useful if a customer wants to run executors on their own
infra for compliance reasons.

## Mechanism — how the profile is selected and adapters injected

### Configuration

`agent.yaml` (or platform config) selects the profile and allows
per-port overrides:

```yaml
runtime:
  profile: k8s            # local | k8s | queue | custom
  overrides:              # optional, override individual ports
    event_emitter: stdout # debug an issue without rebuilding
    credential: env       # local creds even though we're on k8s
```

The profile name maps to a registered factory function in the
orchestrator binary:

```ts
type ProfileFactory = (config: Config) => RuntimePorts;

const profiles: Record<string, ProfileFactory> = {
  local: localProfileFactory,
  k8s: k8sProfileFactory,
  queue: queueProfileFactory,
  // future profiles register here
};
```

### Wiring

At startup, `main.ts` calls the factory for the chosen profile, then
applies any overrides. The result is a `RuntimePorts` struct that gets
passed into the orchestrator core. The core only sees the ports — it
has no knowledge of which adapters were chosen.

```ts
// pseudocode
const ports = profiles[config.runtime.profile](config);
const overridden = applyOverrides(ports, config.runtime.overrides);
const orchestrator = new Orchestrator(overridden);
await orchestrator.run();
```

### Adding a new profile

To add (say) a Lambda profile:
1. Implement adapters for the ports that differ (executor =
   `LambdaInvokeAdapter`, briefing = `S3BriefingAdapter`, result =
   `LambdaReturnValueAdapter`).
2. Register the profile factory: `profiles.lambda = lambdaProfileFactory`.
3. Done. No core changes; no other adapter changes.

This is the durability the architecture buys: new infra is additive,
not invasive.

## Where this leaves the executor side

The executor sees **the ABI and only the ABI**. It reads env vars,
reads `BRIEFING_PATH`, writes `RESULT_PATH`, exits with a status code.
It doesn't know whether the orchestrator is local, in K8s, or behind a
queue. It doesn't know which adapter wired its inputs.

That's the whole point of keeping the ABI as the team boundary. The
executor team writes one container; the platform handles the rest by
choosing the right adapter set.

## Operational and testing benefits

- **Local dev** of the orchestrator runs against fake adapters or the
  `local` profile — no cluster needed, full hermetic tests.
- **Executor teams** dev against `fake-orchestrator`, which uses the
  `local` profile internally to drive their image with realistic
  inputs.
- **Integration tests** swap one adapter at a time (e.g. real K8s,
  fake everything else) to test that adapter in isolation.
- **Production debugging** can override one port at a time
  (e.g. switch event emitter to stdout while leaving everything else
  as K8s) without rebuilding or redeploying — just config change.
- **New infras** are a new profile, not a fork.

## What needs to land in the codebase to enable this

The current code already has *one* port done well (`ExecutorAdapter`).
The architectural work is to extract the rest of the seams and define
their interfaces. Roughly:

1. Define `RuntimePorts` interface bundle in `runtime/abi/`.
2. Extract today's inline adapters (git workflow state, stdout emitter,
   local file briefing/result, env credentials) behind ports.
3. Implement the `local` profile factory using the extracted adapters.
4. Implement the `k8s` profile factory using K8s Jobs, ConfigMaps,
   PVCs, GitHub App tokens.
5. Add fake adapters for every port; convert existing tests to use them.
6. Add profile selection + override mechanism in `main.ts`.

This is itself a tractable, multi-task feature once the spec lands —
likely the **first** technical task before any platform-specific work.
The platform-byo-executor feature should depend on this scaffolding
existing, not build it ad hoc.

## Candidate addition to product-spec.md

When this hardens, lift this paragraph into `## Architecture
invariants`:

> The orchestrator is implemented against a fixed set of ports
> (executor launch, briefing transport, result transport, workflow
> state, credentials, image resolution, event emission). Adapters for
> each port are injected at startup based on a named profile (`local`,
> `k8s`, future `queue` etc.). The same orchestrator binary runs in
> every environment; differences are in adapter selection, not code.
> Adding a new infrastructure target is a new profile, not a fork.
