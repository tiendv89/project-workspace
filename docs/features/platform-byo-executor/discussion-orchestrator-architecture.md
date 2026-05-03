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

The orchestrator's three workflow concerns (claim, review-fix,
workspace-PR-lifecycle) all stay the same. What changes is **inside the
two concerns that spawn executors** (claim and review-fix): the
previously-blocking "await child exit" step splits into a non-blocking
submit + a later reap. The third concern (workspace-PR-lifecycle) does
not spawn executors and is unchanged.

#### Which concerns spawn executors

| Concern | Spawns executor? | Why |
|---|---|---|
| Claim | ✅ Yes | Implementation work — the executor edits code in the impl repo |
| Review-fix | ✅ Yes | Two cases: `respond-to-review` (executor edits files to address review threads) and tier-1 conflict resolution in `auto-rebase` (executor resolves conflict markers in agent-authored files) |
| Workspace PR lifecycle | ❌ No | Pure GitHub API + git operations — no code editing |

```
The three workflow concerns of the orchestrator
─────────────────────────────────────────────────

CONCERN 1 — Claim                          (spawns executors)
  today (blocking):                        platform (async K8s Job):
    claim eligible task                      claim eligible task
    spawn executor child                     kubectl create job
                                               label: kind=impl
                                               label: task_id=T7
    AWAIT child.exit (mins–hours) ◄─ here    record job_name, return
    dispatch result                          (reaped later — see below)

CONCERN 2 — Review-fix                     (spawns executors — NEW: also async)
  today (blocking):                        platform (async K8s Job):
    poll in-review PRs                       poll in-review PRs
    for each conflicting PR (tier-1):        for each conflicting PR (tier-1):
      spawn executor child                     kubectl create job
      AWAIT child.exit ◄─ here too              label: kind=review-fix
      dispatch rebase result                    label: subkind=rebase
                                              record job_name, return
    for each PR with open threads:           for each PR with open threads:
      spawn executor child                     kubectl create job
      AWAIT child.exit ◄─ here too              label: kind=review-fix
      dispatch respond-to-review result         label: subkind=respond
                                              record job_name, return

CONCERN 3 — Workspace PR lifecycle         (no executor spawn — unchanged)
  open management-repo PR at claim time (synchronous, in claim concern)
  poll workspace PRs for merge readiness
  on impl PR merged → merge workspace PR
  recover stuck/conflicting workspace PRs

REAP MECHANISM                              (shared by concerns 1 and 2)
  list all completed K8s Jobs (any kind)
  for each completed Job:
    read result.json from PVC / S3 / stdout
    switch on label.kind:
      ─ kind=impl         → dispatchClaimResult()
      ─ kind=review-fix   → dispatchReviewFixResult() (sub-route on subkind)
    delete Job
  list failed / timed-out Jobs:
    same routing → dispatch blocked side-effects
```

The bottleneck is fixed because **both spawning concerns no longer
wait**. Each phase is bounded by network round trips, not by executor
wall-time. One orchestrator pod can manage hundreds or thousands of
in-flight Jobs across both concerns simultaneously, while concern 3
continues working the same way it does today.

#### Pattern choice for the reap mechanism

Two ways to structure result-collection:

- **Pattern 1 — Per-concern reap.** Each spawning concern owns its own
  Jobs and reaps them independently. Cleaner boundaries; two reap
  implementations.
- **Pattern 2 — Shared reap, routed by Job label.** One reap loop
  enumerates all completed Jobs, dispatches by `label.kind` to the
  right side-effect handler. DRYer; the reap component knows about all
  Job types.

**Recommendation: Pattern 2.** Fewer moving parts at the cost of a tiny
dispatch-by-label step. The Job's labels carry enough context for clean
routing.

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
three workflow concerns (claim, review-fix, workspace-PR-lifecycle) run
sequentially in one cycle, or as independent concurrent loops?

In TypeScript / Node.js, the runtime is single-threaded with cooperative
concurrency. "Parallel loops" here means **multiple async functions
running concurrently in the same event loop** — not threads, not
processes. They interleave at `await` points. This is fine for our
workload because every phase is I/O-bound (HTTP, git, K8s API), not
CPU-bound.

#### Shape A — One sequential cycle (simpler — what today's code does)

```ts
async function runOneCycle(): Promise<void> {
  await claimConcern();          // claim eligible tasks, submit/reap executors
  await reviewFixConcern();      // auto-rebase + respond-to-review on in-review PRs
  await workspacePrConcern();    // poll workspace PRs, merge ready ones, recover stuck
}

async function runAgentLoop(): Promise<void> {
  while (true) {
    await runOneCycle();
    await sleep(IDLE_MS);
  }
}
```

- All three concerns share one cadence.
- One logical "cycle" — easy to reason about, easy to log, easy to test.
- One git-mutation flow per cycle (fewer surprises around concurrent
  pushes from the same pod).
- Fine when each concern is fast — and they are, because we offloaded
  the long-running part of the claim concern to K8s Jobs.
- This is what today's `agent-loop.ts` does already; the change is only
  inside `claimConcern` (split blocking await → submit + later reap).

#### Shape B — Three independent async loops (more flexible)

```ts
async function claimLoop(): Promise<void> {
  while (true) {
    await claimConcern();
    await sleep(CLAIM_INTERVAL_MS);    // e.g. 10_000
  }
}

async function reviewFixLoop(): Promise<void> {
  while (true) {
    await reviewFixConcern();
    await sleep(REVIEW_INTERVAL_MS);   // e.g. 30_000 — review feedback is human-paced
  }
}

async function workspacePrLoop(): Promise<void> {
  while (true) {
    await workspacePrConcern();
    await sleep(WS_PR_INTERVAL_MS);    // e.g. 60_000 — merges are infrequent
  }
}

async function main(): Promise<void> {
  await Promise.all([
    claimLoop(),
    reviewFixLoop(),
    workspacePrLoop(),
  ]);
}
```

- Each loop runs at the cadence its concern actually demands.
  - **Claim** wants to be tight (fast pickup of new work).
  - **Review-fix** is human-paced (no value polling every 5 s).
  - **Workspace-PR** is event-rare (mostly idle; fires only on impl-PR merge).
- A slow concern doesn't delay the others.
- Closer to how mature K8s controllers behave (one informer/work-queue
  per resource type).
- Cost: more concurrency to reason about. Need synchronisation on
  shared state — specifically anything that mutates the local git
  working tree or the same task YAML. A single in-process mutex around
  git operations is usually enough; the rest is read-only from
  separate concerns.

#### Note on internal sub-phases in spawning concerns

Both `claimConcern` and `reviewFixConcern` involve running executors,
so both have an internal "submit + reap" structure in the platform
model. The reap step can be:

- **Folded into each concern** (each concern reaps its own Jobs), or
- **Extracted as a shared reap loop** (single reap loop dispatches by
  `label.kind` — recommended Pattern 2 above).

If you choose the shared-reap pattern, your top-level loops become
four, not three:

```ts
async function main(): Promise<void> {
  await Promise.all([
    claimLoop(),         // submits impl Jobs, returns
    reviewFixLoop(),     // submits review-fix Jobs, returns
    workspacePrLoop(),   // pure API/git, no Jobs
    reapLoop(),          // collects + routes results from impl + review-fix
  ]);
}
```

`workspacePrConcern` never has Jobs to reap, so it's unaffected.

This is still a second-order decision — start with three concerns, one
sequential cycle, internal submit-then-reap inside the spawning
concerns. Split when measured.

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
   captured in *Loop topology* above. The "3 main loops" are the
   orchestrator's three workflow concerns (claim, review-fix,
   workspace-PR-lifecycle). In TypeScript / Node.js, "parallel loops"
   means multiple async functions sharing the event loop. Day 1 use
   one sequential cycle (Shape A); split into three independent async
   loops (Shape B) only when measured cadence needs diverge.
8. *"review-fix also wakes the executor up"* — corrected the spawning
   model. Both **claim** and **review-fix** spawn executors (impl
   work, respond-to-review, tier-1 conflict resolution). The K8s Job
   submit/reap pattern applies to both; only `workspace-PR-lifecycle`
   is purely deterministic. The shared reap mechanism (Pattern 2)
   routes completed Jobs by label kind, optionally as a fourth loop.
9. *"basically our architecture is M orchestrators and N executors —
   we should change to M:N even locally"* — confirmed. The bundled
   image is a packaging convenience for one local case, not the
   model. Three local profile variants documented:
   `local-subprocess` (today, 1:1), `local-docker` (M:N via Docker
   socket — first true M:N profile, BYO-executor capable), and
   `local-kind` (production-parity via local K8s). Adoption order:
   keep subprocess; add `DockerRunAdapter` + `local-docker` next
   (blocks platform-byo-executor); then `K8sJobAdapter` for prod;
   `local-kind` last and optional.
10. *"if we don't use K8s Job but a long-polling app — result
    retrieval should be a mechanism, not depend on K8s"* — corrected.
    K8s-heavy diagrams earlier in the doc were misleading: K8s Job is
    one implementation of the abstract `ExecutorPort` contract
    (submit / listCompleted / readResult / ack). Six concrete
    implementations enumerated: sub-process, K8s Job,
    long-polling HTTP service, message queue, HTTP callback, blob
    storage polling. The orchestrator core depends only on the four
    interface methods — never on the implementation. A long-polling
    executor service is a first-class option, no K8s required.
11. *"executor can be in different infra — how was GitHub runner
    designed?"* — captured the push vs pull dichotomy. GitHub
    Actions is the canonical pull-based model: outbound-only
    runners, label-based work matching, three-component
    architecture (orchestrator + work registry + runner agent).
    Both push and pull adapters fit the same `ExecutorPort`
    contract. Pull is essential for enterprise / on-prem / regulated
    customers who cannot accept inbound platform connections.
12. *"don't take K8s into our high level architecture — draw a
    system diagram with all components"* — produced Appendix B with
    an infrastructure-neutral system diagram. Three layers (tenant,
    platform, executor fleet); platform contains the orchestrator
    pool + supporting services; executor fleet contains both
    push-spawned and pull-based instances coexisting per-tenant.
    No specific runtime is privileged; all execution mechanisms are
    treated as adapter implementations behind `ExecutorPort`.

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

| Port | Purpose | Local-profile adapter | K8s-profile adapter | Alt (queue / long-poll) adapter |
|---|---|---|---|---|
| `ExecutorPort` | **Full executor lifecycle** — submit, list completed, read result, ack. See "Result retrieval is a port, not a constraint" below. | `SubProcessAdapter` (child process; submit blocks → completes synchronously) | `K8sJobAdapter` (`kubectl create job`; list via Job status) | `LongPollHttpAdapter` (HTTP submit + long-poll completion) / `QueueAdapter` (publish + subscribe) |
| `BriefingTransportPort` | Deliver briefing.md to the executor | `LocalFileBriefingAdapter` (path on shared FS) | `ConfigMapBriefingAdapter` (mount ConfigMap) | `S3SignedUrlBriefingAdapter` (pre-signed URL) / inline in submit payload |
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

## Result retrieval is a port, not a constraint

A core insight that's easy to lose in K8s-heavy diagrams: the
orchestrator should not bake in *how* it retrieves executor results.
"Submit a task and later collect its result" is an abstract concern.
K8s Jobs are *one* implementation of it. There are several others,
and the orchestrator core should not know which one is in use.

This is the contract `ExecutorPort` exposes:

```ts
interface ExecutorPort {
  /** Submit a task; returns an opaque handle the orchestrator stores. */
  submit(input: ExecutorInput): Promise<ExecutorHandle>;

  /** List every previously-submitted task that has finished
   *  (completed, failed, or timed out) and is ready to be reaped. */
  listCompleted(): Promise<ExecutorCompletion[]>;

  /** Read the full result for a given handle. */
  readResult(handle: ExecutorHandle): Promise<ExecutorResult>;

  /** Mark the result as reaped (delete K8s Job, ack queue message,
   *  delete temp file, etc.) so the same result is not delivered twice. */
  ack(handle: ExecutorHandle): Promise<void>;
}
```

The orchestrator's claim and reap loops depend only on this interface.
Below are six concrete ways to implement it. The choice is independent
of *where the executor runs* — the same executor binary can be reached
via any of these.

| Mechanism | `submit` | `listCompleted` | `readResult` | `ack` | When it fits |
|---|---|---|---|---|---|
| **Sub-process** (today) | spawn child, await exit | trivial — exit blocks | read `RESULT_PATH` file | unlink temp file | Single-machine local dev |
| **K8s Job** | `kubectl create job` | `kubectl get jobs status=Complete` | read PVC / Job logs | `kubectl delete job` | Production K8s |
| **Long-polling executor service** | `POST /tasks` with briefing | `GET /tasks?completed=true` (long-poll) | `GET /tasks/{id}/result` | `DELETE /tasks/{id}` | Customer runs a stateful executor service; **no K8s required** |
| **Message queue** | `publish(in_queue, payload)` | subscribe to `out_queue`, drain | parse message body | `ack(message_id)` | Decoupled fleets, on-prem split |
| **HTTP callback** | `POST /run` with callback URL | maintained internally — callbacks fill a buffer | callback body | mark internal entry done | Push-based, executor knows orchestrator URL |
| **Blob storage polling** | upload briefing to `s3://in/{id}` | list `s3://out/` for new objects | `GET s3://out/{id}.json` | delete blob | Stateless, durable, cheap |

### What this means in practice

- **The K8s Job pattern shown earlier in this doc is one example, not the
  only mechanism.** The discussion's diagrams show K8s because that's a
  concrete production target — but every reference to `kubectl create
  job` could equally be `POST /tasks`, `publish(queue)`, or `upload S3
  blob`.
- **Long-polling is a first-class option.** A customer who runs an
  executor as a long-lived HTTP service (autoscaler keeps it warm,
  internal queueing handles concurrency) is a perfectly valid platform
  configuration. The orchestrator doesn't care.
- **The retrieval mechanism and the execution mechanism are
  independent.** You can submit work to an executor service while
  reading results from a queue; or submit to K8s but read from S3.
  These are implementation choices inside the adapter, not new ports.

### Why this matters for the platform spec

Several of the open questions in `product-spec.md` (Q5 network model,
Q9 failure attribution) hinge on the assumption that everything goes
through K8s Jobs. If the platform supports multiple `ExecutorPort`
implementations — e.g. K8s Job for hosted-execution tenants and
long-polling HTTP for BYOI (bring-your-own-infra) tenants — those
questions need answers per implementation, or the abstraction needs to
hide the difference.

The recommended invariant: **the orchestrator core depends only on
`ExecutorPort`'s four methods. Implementation-specific concerns
(networking, transport, isolation) are entirely inside each adapter.**

## The three profiles

```
┌─────────────────────────────────────────────────────────────────────────┐
│                       Orchestrator core                                 │
│  (eligibility, claim, briefing, dispatch — knows nothing about infra)  │
└──┬─────────┬──────────┬──────────┬──────────┬──────────┬──────────────┘
   │         │          │          │          │          │
   ▼         ▼          ▼          ▼          ▼          ▼
 Exec    Briefing     State      Creds      Image      Events
 Port     Port         Port       Port       Port       Port
 (full
  exec
  lifecycle:
  submit,
  list,
  read,
  ack)
   │         │          │          │          │          │
═══╪═════════╪══════════╪══════════╪══════════╪══════════╪═══
   │         │          │          │          │          │
   │  ┌──────┴──────────┴──────────┴──────────┴──────────┴──┐
   │  │                                                     │
   │  │   ┌─ LOCAL profile ───────────────────────────────┐ │
   │  │   │                                               │ │
   │  └─► │ SubProc   LocalFile   Git    Env   Static  Stdout │ │
   │      │                                               │ │
   │      └───────────────────────────────────────────────┘ │
   │                                                         │
   │      ┌─ K8S profile ─────────────────────────────────┐ │
   │      │                                               │ │
   └────► │ K8sJob    ConfigMap   Git    GhApp  WSConfig  Loki │ │
          │           (+ PVC for                  +K8sSecret    │ │
          │            results)                                 │ │
          └───────────────────────────────────────────────┘ │
                                                              │
          ┌─ LONG-POLL profile ────────────────────────────┐ │
          │                                                │ │
          │ LongPoll  HttpInline  Git    HttpAuth WSConfig HttpLog│ │
          │ HTTP                                            │ │
          └───────────────────────────────────────────────┘ │
                                                              │
          ┌─ QUEUE profile ─────────────────────────────────┐ │
          │                                                 │ │
          │ QPub+QSub MsgInline   DB     Vault   WSConfig  Kafka │ │
          │                                                 │ │
          └────────────────────────────────────────────────┘ │
                                                              │
          ┌─────────────────────────────────────────────────┐ │
          │  ...future profiles (Lambda, on-prem VM, etc.)  │ │
          │  plug in here without touching the core.        │ │
          └─────────────────────────────────────────────────┘ │
                                                                        │
══════════════════════════════════════════════════════════════════════ ┘
```

### M:N is the target across all profiles

The architectural target is **M orchestrators : N executors** in every
deployment shape. Today's bundled image (orchestrator + executor in the
same container, paired 1:1 via child process) is a **packaging
convenience for the simplest local case** — not a design constraint.

Reasons to commit to M:N everywhere, including local:

- **One code path** — the async submit/reap logic is exercised in dev,
  not only in prod. Bugs that only manifest in the decoupled flow are
  caught early.
- **BYO-executor testability** — customers (or the executor team) can
  register their image and test against the real orchestrator on a
  laptop without forking the platform's Dockerfile.
- **Heterogeneous fleets** — M orchestrators spawning N executors of
  *different images* is testable on one laptop. This is the actual
  platform shape.
- **Profile parity** — the gap between local and prod is just the
  adapter set, not the architecture.

The bundled image stays available for the very fastest dev-inner-loop
(orchestrator engineers iterating on orchestrator code, no Docker
required), but it is **one variant**, not the model.

### Local profile variants — three shapes for laptop dev

There are three local profile variants in increasing fidelity. All are
the same orchestrator binary; only the adapter set differs.

#### Variant 1 — `local-subprocess` (fastest dev loop, 1:1 bundled)

Today's model. M orchestrator containers, each with the executor binary
baked into the same image. `SubProcessAdapter` spawns the executor as a
child process.

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

**Use case**: orchestrator engineers iterating on orchestrator code; no
Docker socket needed; tightest test cycle.
**Limitation**: cannot host a customer-supplied executor image.

#### Variant 2 — `local-docker` (first true M:N locally)

M orchestrator containers, **no bundled executor**. Each orchestrator
does `docker run tenant/executor:v1` per claimed task via the Docker
socket. Spawned executor is an ephemeral, separate container — possibly
a different image per task or per tenant.

```
┌──────────────────────────┐         docker run
│ orchestrator container 1 │ ─────────────────────►  ┌──────────────┐
│  └─ DockerRun adapter ─┐ │                         │ exec for T7  │
│  (mounts /var/run/     ││ │                         │ (ephemeral)  │
│   docker.sock)         ││ │                         └──────────────┘
└────────────────────────┘ │
                           │
┌──────────────────────────┐         docker run       ┌──────────────┐
│ orchestrator container 2 │ ─────────────────────►  │ exec for T8  │
└──────────────────────────┘                          │ (different   │
                                                       │  image, OK!) │
                                                       └──────────────┘
```

- Briefing: shared host volume mounted into the spawned executor
- Result: shared host volume read after executor exits
- State: local git clone
- Creds: env vars passed via `docker run -e`
- Events: orchestrator captures executor's stdout/stderr via Docker
- Cost: Docker socket mount (light DinD trade-off, acceptable locally)

**Use case**: BYO-executor testing, multi-executor scenarios, the first
profile that exercises async submit/reap end-to-end.
**This is the target for local development on the platform feature.**

#### Variant 3 — `local-kind` (production-equivalent on a laptop)

A tiny K8s cluster (kind / k3d / minikube) running on the dev machine.
Same `K8sJobAdapter` as production — orchestrator submits Jobs into the
local cluster.

```
┌──────────────────────────┐
│ orchestrator container   │
│  └─ K8sJob adapter ──────┼──► kind cluster
└──────────────────────────┘     ├── platform namespace (orchestrator)
                                  └── tenant-A namespace
                                       └── exec Job pod
```

- Briefing: ConfigMap mount (same as prod)
- Result: PVC + label (same as prod)
- State: local git clone
- Creds: K8s secret (mocked)
- Events: stdout (or local Loki if you want)

**Use case**: pre-deploy integration testing, production-equivalent
parity, validating K8s manifests before they hit a real cluster.
**Cost**: cluster setup overhead; slower spin-up; eats laptop RAM.

### Recommended adoption order

The path from today's bundled local image to a full M:N platform is
incremental — each step is additive, none requires rewriting the
previous one.

1. **Today** — `local-subprocess` (bundled image). Already works.
   Keep this profile available indefinitely as the dev-fastest option
   for orchestrator engineers.
2. **Step 1: implement `DockerRunAdapter` + `local-docker` profile.**
   This is the **first M:N profile** and the one that unlocks
   BYO-executor local testing. The platform feature blocks on this.
3. **Step 2: implement `K8sJobAdapter` + `k8s` profile.**
   Production scale, multi-tenant, async per-task pods.
4. **Step 3 (optional): implement `local-kind` profile.**
   Same `K8sJobAdapter` as step 2, just pointed at a local kind/k3d
   cluster. Adds production-parity testing on a laptop. Skip until
   pre-deploy parity becomes valuable.

The platform-byo-executor feature itself depends on step 2 landing,
and benefits enormously from step 1 landing first (testability,
faster iteration on the customer-DX surface).

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
> (executor lifecycle, briefing transport, workflow state, credentials,
> image resolution, event emission). Adapters for each port are
> injected at startup based on a named profile. The same orchestrator
> binary runs in every environment; differences are in adapter
> selection, not code. Adding a new infrastructure target is a new
> profile, not a fork. The platform supports both push-style execution
> (orchestrator submits work to executor instances it can reach) and
> pull-style execution (executor agents in customer infrastructure
> long-poll the platform for work) under the same `ExecutorPort`
> contract.

---

# Appendix B — System diagram

The diagram below collects every component identified in the
discussion, drawn at infrastructure-neutral level. No execution
mechanism is privileged; "executor" means any process that fulfils
the ABI contract, regardless of where it runs or how it was reached.

```
╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                                ║
║    CUSTOMER / TENANT                  ◀──── many tenants per platform ────▶   ║
║   ─────────────────                                                            ║
║                                                                                ║
║   ┌────────────────────┐         ┌─────────────────────┐                      ║
║   │  Workspace repo     │         │  Executor image      │                      ║
║   │  (git, customer-    │         │  registration        │                      ║
║   │   hosted)           │         │                      │                      ║
║   │                     │         │  ─ image reference   │                      ║
║   │  ─ tasks/T*.yaml    │         │  ─ registry creds    │                      ║
║   │  ─ docs/            │         │  ─ conformance pass  │                      ║
║   │  ─ workspace.yaml   │         │  ─ labels (linux/gpu/│                      ║
║   │                     │         │     etc.)            │                      ║
║   └─────────┬──────────┘         └──────────┬──────────┘                      ║
║             │                                │                                  ║
║             │ git ops                        │ identifies which image           ║
║             │ (read state /                  │ to use per task                  ║
║             │  write claims /                │                                  ║
║             │  open PRs)                     │                                  ║
║             │                                │                                  ║
╚═════════════╪════════════════════════════════╪════════════════════════════════╝
              │                                │
              │                                │
╔═════════════╪════════════════════════════════╪════════════════════════════════╗
║   PLATFORM (multi-tenant; single source of truth for workflow lifecycle)       ║
║   ─────────                                  │                                  ║
║             │                                │                                  ║
║   ┌─────────▼────────────────────────────────▼────────────────────────────┐  ║
║   │                                                                        │  ║
║   │      ORCHESTRATOR POOL  (M stateless instances)                        │  ║
║   │      ─────────────────                                                  │  ║
║   │                                                                        │  ║
║   │     ┌────────────────┐  ┌────────────────┐  ┌────────────────────┐   │  ║
║   │     │ Claim concern   │  │ Review-fix     │  │ Workspace-PR        │   │  ║
║   │     │                 │  │ concern         │  │ lifecycle concern    │   │  ║
║   │     │  poll workspace │  │                 │  │                      │   │  ║
║   │     │  claim ready    │  │  poll in-review │  │  open WS PR at claim │   │  ║
║   │     │  submit work    │  │  spawn for      │  │  merge on impl-PR    │   │  ║
║   │     │                 │  │  rebase &       │  │  recover stuck PRs   │   │  ║
║   │     │  (spawns        │  │  respond-to-    │  │                      │   │  ║
║   │     │   executors)    │  │  review         │  │  (no executor spawn) │   │  ║
║   │     │                 │  │                 │  │                      │   │  ║
║   │     └────────┬───────┘  └────────┬───────┘  └──────────┬───────────┘   │  ║
║   │              │                    │                      │              │  ║
║   │              └───────────┬────────┘                      │              │  ║
║   │                          │                                │              │  ║
║   │                          ▼                                ▼              │  ║
║   │     ┌──────────────────────────────────┐    ┌─────────────────────────┐ │  ║
║   │     │   ExecutorPort  (interface)       │    │  WorkflowStatePort      │ │  ║
║   │     │   ─────────────                    │    │  ───────────────────    │ │  ║
║   │     │   submit / listCompleted /        │    │  read / write task YAML │ │  ║
║   │     │   readResult / ack                │    │  append logs            │ │  ║
║   │     └──┬───────────────────────────┬──┘    └────────────┬────────────┘ │  ║
║   │        │                            │                     │              │  ║
║   │        │ push family                │ pull family         │ git          │  ║
║   │        ▼                            ▼                     │              │  ║
║   │   ┌─────────────────┐      ┌────────────────────┐         │              │  ║
║   │   │ Push adapters    │      │ Pull adapters       │         │              │  ║
║   │   │  ─ direct submit │      │  ─ submit = enqueue │         │              │  ║
║   │   │    to executor   │      │    to Work Registry │         │              │  ║
║   │   │    instance      │      │  ─ executor pulls   │         │              │  ║
║   │   │                  │      │                     │         │              │  ║
║   │   └────────┬────────┘      └──────────┬─────────┘         │              │  ║
║   │            │                            │                    │              │  ║
║   │   ┌────────┴───────────────────────────┴─────────────────────┘              │  ║
║   │   │                                                                        │  ║
║   │   │  Reap loop (shared, runs alongside the concerns)                       │  ║
║   │   │  ──────── routes completions back to the originating concern by       │  ║
║   │   │           job-handle label kind (claim / review-fix subkind)           │  ║
║   │   │                                                                        │  ║
║   │   └────────────────────────────────────────────────────────────────────────┘  ║
║   │                                                                              │  ║
║   └──────────────────────────────────────────────────────────────────────────┘  ║
║                                                                                   ║
║                                                                                   ║
║   PLATFORM SUPPORTING SERVICES                                                    ║
║   ────────────────────────────                                                    ║
║                                                                                   ║
║   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐        ║
║   │ Work         │  │ Briefing     │  │ Result       │  │ Credential   │        ║
║   │ Registry     │  │ transport    │  │ artifact     │  │ broker       │        ║
║   │              │  │              │  │ store        │  │              │        ║
║   │ - durable    │  │ - delivers   │  │ - receives   │  │ - mints      │        ║
║   │ - long-poll  │  │   briefing.md│  │   result.json│  │   per-task   │        ║
║   │   API for    │  │   to executor│  │ - stores     │  │   tokens     │        ║
║   │   pull       │  │              │  │   stdout/    │  │ - per-tenant │        ║
║   │ - matches    │  │              │  │   logs       │  │   secrets    │        ║
║   │   labels     │  │              │  │              │  │              │        ║
║   └──────────────┘  └──────────────┘  └──────────────┘  └──────────────┘        ║
║                                                                                   ║
║   ┌──────────────┐  ┌──────────────┐  ┌──────────────┐                          ║
║   │ Image        │  │ Conformance  │  │ Event /      │                          ║
║   │ registration │  │ test runner  │  │ metrics      │                          ║
║   │ catalog      │  │              │  │ pipeline     │                          ║
║   │              │  │ - validates  │  │              │                          ║
║   │ - per-tenant │  │   ABI        │  │ - per-tenant │                          ║
║   │   image refs │  │ - smoke      │  │   isolation  │                          ║
║   │ - registry   │  │   tasks      │  │ - billing    │                          ║
║   │   credentials│  │ - gates      │  │   metering   │                          ║
║   │              │  │   activation │  │              │                          ║
║   └──────────────┘  └──────────────┘  └──────────────┘                          ║
║                                                                                   ║
╚═════╪══════════════════════════════════════════════════════╪═════════════════════╝
      │                                                      │
      │ submit (push)                                        │ long-poll work
      │ deliver briefing                                     │ upload result
      │ collect result                                       │ heartbeat
      │                                                      │
╔═════▼══════════════════════════════════════════════════════▼═════════════════════╗
║                                                                                   ║
║   EXECUTOR INSTANCES  (N total — heterogeneous, per-tenant, anywhere)            ║
║   ──────────────────                                                              ║
║                                                                                   ║
║   PUSH-spawned executors                       PULL-based runners                 ║
║   (platform reaches them)                      (they reach platform)              ║
║   ───────────────────────                      ───────────────────────            ║
║                                                                                   ║
║   ┌────────────────────────┐                  ┌────────────────────────────┐    ║
║   │ Tenant A executor       │                  │ Tenant B runner agent       │    ║
║   │ ─ ephemeral per task   │                  │ ─ runs in their VPC          │    ║
║   │ ─ image: A/exec:v1.2.3 │                  │ ─ outbound HTTPS only        │    ║
║   │ ─ platform-spawned     │                  │ ─ pulls from Work Registry   │    ║
║   └────────────────────────┘                  │ ─ image: B/exec:custom       │    ║
║                                                └────────────────────────────┘    ║
║   ┌────────────────────────┐                                                     ║
║   │ Tenant A executor       │                  ┌────────────────────────────┐    ║
║   │ (another claimed task)  │                  │ Tenant C runner agent       │    ║
║   └────────────────────────┘                  │ ─ on-prem, air-gapped        │    ║
║                                                │ ─ tunnels out via proxy      │    ║
║   ┌────────────────────────┐                  │ ─ image: C/exec:internal     │    ║
║   │ Tenant D long-running   │                  └────────────────────────────┘    ║
║   │ executor service        │                                                     ║
║   │ ─ HTTP service mode    │                  Each runner / executor:             ║
║   │ ─ platform pushes work │                   ─ reads briefing                   ║
║   └────────────────────────┘                   ─ runs to completion               ║
║                                                 ─ writes result.json              ║
║                                                 ─ uploads / returns result        ║
║                                                                                   ║
╚═══════════════════════════════════════════════════════════════════════════════════╝
```

## Reading the diagram

### Three layers
1. **Customer / tenant** owns two artifacts: a workspace repo (workflow
   state, customer-hosted git) and an executor image registration (a
   pointer + credentials, validated by conformance).
2. **Platform** is the orchestrator pool plus supporting services. The
   pool is stateless and multi-tenant. Every workflow concern lives
   here. Every cross-tenant policy (fairness, billing, conformance)
   lives here.
3. **Executor instances** are heterogeneous and per-tenant. They live
   wherever the tenant chose — push-spawned in platform-controlled
   infra, or pull-based in customer-controlled infra. Both shapes
   coexist; the orchestrator does not know the difference.

### Three workflow concerns inside the orchestrator
- **Claim** — finds new work, claims it via git push race, submits an
  executor (spawns one).
- **Review-fix** — handles in-review PRs that need rebase or
  respond-to-review (also spawns executors).
- **Workspace-PR lifecycle** — pure git/API work; never spawns an
  executor.

### One port, two adapter families
- `ExecutorPort` is the only seam the orchestrator core sees for
  execution.
- **Push adapters** put work directly onto an executor instance the
  platform can reach.
- **Pull adapters** put work into the Work Registry; executors elsewhere
  long-poll for it. Same interface, different network topology.
- A shared **reap loop** routes completed work back to the originating
  concern.

### Supporting services are platform-internal
Briefing transport, result store, credential broker, image catalog,
conformance runner, event/metrics pipeline. These are platform-side
shared services. None of them are part of the orchestrator core; they
are all reached via their own ports/adapters.

### Two coexisting execution shapes per platform
The platform supports both push and pull simultaneously. A single
tenant might use push (platform-spawned ephemeral executors); another
might use pull (their own runner agent in their VPC); a third might
use a long-running HTTP service. None of these affect any other
tenant. The choice is per-tenant, recorded as part of executor image
registration.

## What this diagram intentionally does NOT show

- No specific compute runtime (no Kubernetes, no Docker, no Lambda).
  The diagram is infrastructure-neutral. Specific adapters
  (Kubernetes, long-poll, queue, sub-process, etc.) are
  implementation details inside the push or pull adapter families.
- No specific transport (no S3, no PVC, no ConfigMap). Briefing /
  result transport are abstract services that an adapter chooses an
  implementation for.
- No specific orchestrator runtime (no specific process manager,
  language). The pool is "M stateless instances"; the implementation
  detail of "how M instances are deployed" is a separate concern.

This is the high-level architecture. Specific deployments choose
specific adapters and runtimes inside this shape — they never modify
the shape itself.
