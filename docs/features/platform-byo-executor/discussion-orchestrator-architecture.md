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
