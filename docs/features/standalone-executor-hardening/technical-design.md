# Technical Design

## Feature
- Feature ID: `standalone-executor-hardening`
- Title: Standalone Executor Hardening — decoupled dispatcher + spawn-on-the-fly, mirroring prod in `local-docker`

> Phase 1 (design). Builds directly on `runtime-portable-architecture` (done) and resolves a tech-debt item carried in `platform-byo-executor` (broker `registry-size` / in-process `dockerInFlight`). Canonical prior reasoning: `docs/features/runtime-portable-architecture/discussion-orchestrator-architecture.md`.
>
> **Scope note:** persistent log storage (S3/MinIO, per-run `result.json` link, `runs[]` schema) was descoped to feature **`executor-log-object-storage`** (same branch). This feature only takes the standalone executor's logs *off* the management repo; it is ABI-neutral.

## Design principles (from product owner)

1. **Orchestrator owns the workflow, nothing else.** Strip from the orchestrator everything not about workflow state: direct container spawning, the Docker socket, and credential handling all move out.
2. **Executor is standalone and isolated.** It receives an already-claimed task, materialises its own repos, runs the agent, writes `result.json`. On the standalone path it logs to **stdout** (no management-repo write); persistent log storage is a separate feature. It knows nothing about the orchestrator.
3. **Orchestrator and executor are decoupled — they never reference or call each other.** All communication is indirect, through two infrastructure queues: a **dispatch queue** (orchestrator → dispatcher → executor spawn) and the existing **completion broker** (executor → broker → orchestrator drain).
4. **Dev mirrors prod.** The `local-docker` profile gains the dispatcher so its data flow is component-identical to production; only the spawn adapter (`DockerRunAdapter` → future `K8sJobAdapter`) differs.

## 1. Current state

The runtime is portable (ports/adapters/profiles, async submit/reap) after `runtime-portable-architecture`:

- **Profiles** selected by `RUNTIME_PROFILE` at startup (`runtime/orchestrator/src/main.ts:253`, default `local-subprocess`): `local-subprocess` (bundled — in-process broker, `SubProcessAdapter`) and `local-docker` (`DockerRunAdapter` + Go `HttpBrokerAdapter` + Redis).
- **Claim is orchestrator-owned and the executor is claim-agnostic** — status→`in_progress` + claim commit/push in `runtime/orchestrator/src/task/claim.ts` (`:281`, `:305-325`); executor spawned only if the claim is won (`main.ts:331-344`).
- **`local-docker` today couples the orchestrator to infra:** the orchestrator itself runs `docker run` via a mounted Docker socket (`DockerRunAdapter`, `runtime/orchestrator/src/executor/docker-run.ts`), resolves credentials (`EnvCredentialAdapter`, `runtime/orchestrator/src/infra/credential/env.ts`) passing `GITHUB_TOKEN`/`SSH_PRIVATE_KEY` as `-e` vars, and tracks spawn concurrency with an **in-process `dockerInFlight` counter** that resets on restart and can't be shared across orchestrators (tech debt from `platform-byo-executor`; correct fix is a broker `registry-size` endpoint).
- **Completion broker** (Go, `runtime/broker/`) is Redis-backed using a **sorted-set peek-and-lock** store (XREADGROUP/XACK semantics with explicit `lockMs`), reached over HTTP. Runner posts `{handle, nonce, result}` to `/callback`; any orchestrator drains via `listCompleted` (opportunistic M:N).
- **Executor** (`runtime/executors/claude/`) self-materialises its repos (`materializeRepo`, `index.ts`) into per-handle `exec-<handle>` workdirs, runs the agent, writes `result.json`, and **flushes logs to the management git repo** via `flushLog()` (`runtime/executors/claude/src/flush-log.ts`).
- The **runner wrapper** (`runtime/runner-wrapper/runner.js`) is the platform entrypoint in every profile.

Repo boundary: all of the above is in the **`workflow`** repo (`git@github.com:tiendv89/agent-workflow.git`).

## 2. Problem framing

**What must change:**
- The orchestrator must stop spawning executors directly. It enqueues a dispatch job; a new **dispatch service** spawns. The orchestrator runs unprivileged (no Docker socket, no credentials).
- On the standalone path, the executor must stop writing logs to the management repo. In this feature that means **disabling the git flush** (logs go to stdout, captured by the dispatcher); persistent storage is `executor-log-object-storage`.
- `local-docker` must mirror the production data flow (orchestrator → queue → dispatcher → executor → broker → orchestrator).

**What must remain stable:**
- The **`local-subprocess` (bundled) profile is untouched** and keeps working — including its git logging.
- The executor's agent-running behaviour, prompts, and `result.json` are unchanged — **this feature is ABI-neutral**.
- The claim protocol and workflow FSM stay orchestrator-owned.

**Fixed assumptions:** ports/adapters/profiles model is the substrate; the executor is already claim-agnostic; production k8s is **out of scope** (the dispatcher's spawn-adapter seam is kept clean for a future `K8sJobAdapter`; whether the prod orchestrator runs as a k8s CronJob is a later decision).

## 3. Options considered

### 3.1 Dispatch transport
- **B. Dedicated dispatch Redis Stream owned by the dispatcher (chosen).** The dispatch queue is its own Redis Stream + consumer group: the orchestrator `XADD`s a job; the dispatcher pool consumes via `XREADGROUP`, with redelivery of stuck entries via `XAUTOCLAIM` and a dispatch DLQ after K deliveries. The **broker is not involved** in dispatch — it stays single-purpose (completion queue + handle registry). Redis is shared *infrastructure*, not shared *code*: broker and dispatcher each own their own queue, no shared endpoints.
  - *Pros:* broker keeps one responsibility; the dispatcher owns dispatch end-to-end and is independently deployable; Streams consumer groups are the idiomatic work-distribution primitive (built-in redelivery, no custom lock bookkeeping); **M:N to a stateless dispatcher pool for free** — the orchestrator never addresses a specific dispatcher. *Cons:* the orchestrator gains a Redis client + credentials — minor, and Redis access is not host-level privilege, so it doesn't compromise the unprivileged-orchestrator goal.
- **A. Extend the broker service with a dispatch queue (rejected).** Orchestrator and dispatcher would exchange jobs through broker HTTP endpoints (`POST /dispatch`, `/dispatch/claim`, `/dispatch/ack`). *Rejected* — overloads the broker with a second responsibility and couples the dispatcher to broker-specific endpoints (broker + dispatcher effectively share code and lifecycle). The "only one component touches Redis" property it preserved is not worth that coupling.
- **C. External queue (NATS / RabbitMQ / SQS).** *Cons:* new infra for no capability we lack; a future adapter can swap it.

> Symmetry: this mirrors the completion path (executor → broker → orchestrator). Both directions meet at shared Redis infrastructure; neither orchestrator nor executor/dispatcher calls the other directly.

### 3.2 Where credentials live
- **A. Dispatcher is the sole credential holder (chosen).** `CredentialPort` moves out of the orchestrator into the dispatcher. Dev: dispatcher holds env and injects `-e` at spawn. Prod (future): the dispatcher creates a Job whose spec **references Secret names**; the kubelet injects. The **dispatch-job payload carries no secrets.**
- **B. Orchestrator resolves creds into the job payload.** *Rejected* — re-privileges the orchestrator and puts secrets on the queue.

### 3.3 Executor log handling (this feature only)
- **A. Config-gated git flush; off on standalone (chosen).** `LOG_SINK=git|none` injected at spawn. `local-subprocess` defaults to `git` (unchanged); the dispatcher sets `none` for `local-docker`, so the executor logs to stdout only. ABI-neutral, no new infra.
- **B. Build the S3 sink now.** *Rejected/descoped* — that is feature `executor-log-object-storage`; not on the critical path for proving the decoupled architecture.
- **C. Keep git flush on `local-docker`.** *Rejected* — keeps the management-repo coupling and is pointless in an ephemeral container with a read-only clone.

### 3.4 Dispatcher topology
- **A. Shared dispatch queue, a pool of stateless dispatchers (chosen).** Any dispatcher consumes any job (M:N), mirroring the broker's opportunistic drain. Global spawn concurrency via the broker `registry-size` endpoint (resolves the `dockerInFlight` debt).
- **B. One dispatcher per orchestrator.** *Rejected* — re-couples orchestrator and spawn lifecycle.

## 4. Chosen design

### Data flow (`local-docker`, mirrors prod)
```
orchestrator                      broker (Redis)                   dispatcher                 executor (ephemeral)
  │ claim task (git)                   │                               │                            │
  │ broker.register(handle,nonce) ───► │ handle: registered            │                            │
  │ XADD dispatch-stream {job,nosecret}─► │ dispatch stream (Redis)       │                            │
  │                                    │ ◄── XREADGROUP <group> ────────│                            │
  │                                    │                               │ inject creds + LOG_SINK=none│
  │                                    │                               │ docker run exec-<handle> ─►│ materialise repos
  │                                    │ ──────────────────────────────│ XACK dispatch-stream       │ run agent (logs → stdout)
  │                                    │ ◄──────── POST /callback {handle,nonce,result} ────────────│ write result.json
  │ ◄── listCompleted (drain) ─────────│                               │                            │ (runner posts, exits)
  │ record result; advance FSM         │                               │
  │ broker.ack ───────────────────────►│ handle: acked                 │
```
The **dispatch stream** is plain Redis owned by the dispatcher's consumer group; the **handle registry + completion queue** are the broker. The orchestrator and executor never address each other, and the orchestrator never addresses a specific dispatcher. `ExecutorPort.submit()` becomes **`XADD` to the dispatch stream** (`QueueDispatchAdapter`); the relocated `DockerRunAdapter` lives in the dispatcher. `result.json` is unchanged.

### New / changed components (all in `workflow` repo)

- **`runtime/abi/`** — new `DispatchJob` type (payload below) + the **dispatch-stream contract** (stream key, consumer-group name). New `LOG_SINK` entry in the runner env contract. **No change to `ExecutorResult`** (ABI-neutral).
- **`runtime/broker/`** (Go) — **does not host the dispatch queue or any dispatch state.** One small addition only: **`GET /registry-size`** (count of in-flight handles — resolves the `dockerInFlight` debt; the dispatcher reads it to enforce the global spawn cap). Completion queue + sorted-set store otherwise unchanged. (No `dispatched` flag — dispatch state lives in the dispatch stream; terminal dispatch failure surfaces as a synthetic completion via the existing `/callback`.)
- **`runtime/dispatcher/`** (new folder, sibling of `broker`/`orchestrator`/`executors`) — **owns the dispatch Redis Stream**: consumes via `XREADGROUP` (consumer group), redelivers stuck entries via `XAUTOCLAIM`, routes to a dispatch DLQ after K deliveries; holds `DockerRunAdapter` + `CredentialPort`; injects creds + `LOG_SINK=none`; **idempotency guard** (skip if a container labelled `platform.handle=<handle>` exists); enforces the global spawn cap via the broker `registry-size`; `XACK`s after a successful spawn. On terminal dispatch failure (DLQ after K deliveries) it posts a **synthetic `failed` completion** to the broker `/callback` for that `handle`/`nonce` — the same channel the crash safety-net uses — so the orchestrator learns through the normal completion path.
- **`runtime/orchestrator/`** — `QueueDispatchAdapter` (ExecutorPort → `XADD` to the dispatch stream; gains a Redis client); `createLocalDockerProfile` drops `DockerRunAdapter`, `EnvCredentialAdapter`, and the Docker socket; **dispatch reconciler** in the poll loop; registers handle+nonce before enqueue. No log-link persistence (descoped).
- **`runtime/executors/claude/`** — `flushLog` becomes a no-op when `LOG_SINK=none` (logs to stdout); `git` (default) keeps today's behaviour for the bundled path. No `result.json` change.
- **Compose** — `local-docker` stack gains `dispatcher`; `redis` + `broker` already present; `orchestrator` loses the socket mount. No MinIO. `local-subprocess` compose unchanged.

### DispatchJob payload (credential-free)
```
{ handle, nonce, kind,                                   // identity + dispatch discriminator (impl|review-fix|rebase)
  task_id, feature_id, workspace_id,
  task_repo_url, task_repo_branch, task_base_branch, task_repo_base_branch,
  mgmt_repo_url, executor_workdir,
  callback_url,                                          // broker completion endpoint
  budget_tokens?, implementation_model?, enqueued_at }
```
Secrets (`GITHUB_TOKEN`, `SSH_PRIVATE_KEY`) are **not** in the payload — the dispatcher injects them.

### Dispatch reliability (failure surface from async dispatch)
- **Handle lifecycle at the broker:** `registered` (orchestrator) → `completed` (callback) → `acked`. Dispatch state (queued / claimed / done / DLQ) lives in the **dispatch stream**, not the broker.
- **Idempotency:** dispatcher checks for an existing `platform.handle=<handle>` container before spawning → redelivery (via `XAUTOCLAIM`) never double-spawns. Key = `handle`.
- **Dispatch reliability is owned by the dispatcher** (it owns the stream): `XAUTOCLAIM` redelivers stuck entries; after K deliveries the job goes to a DLQ and the dispatcher posts a **synthetic `failed` completion** to `/callback`. Dispatch failures therefore reach the orchestrator through the **normal completion path** — no dispatched-vs-not bookkeeping at the orchestrator.
- **Reconciler (orchestrator poll loop)** is a simple backstop for the one case the stream can't self-heal — *no dispatcher alive at all* (job sits unclaimed, nothing `XAUTOCLAIM`s it): for an `in_progress` task with a persisted handle and **no completion past `EXECUTION_DEADLINE`**, re-enqueue (idempotent — the handle guard prevents double-spawn) up to N times, then `blocked`.

### Concurrent-coexistence & isolation
- `local-subprocess` (bundled) and `local-docker` (dispatcher) run side by side: different `RUNTIME_PROFILE` per orchestrator service; bundled uses no containers/dispatcher/broker, so they don't contend.
- Handles are UUIDs (globally unique) → no broker-handle collisions. Distinct `WORKSPACES_ROOT` per instance. Container label `platform.handle=<handle>`.
- GitHub identity/rate-limit is shared in dev (acceptable, low volume); per-tenant token deferred to prod/`executor-credential-isolation`.
- Spawn concurrency is global (dispatcher + `registry-size`), not the old per-process counter.

### Resolutions to the product-spec open questions
| Q | Resolution |
|---|---|
| **Q1 Dispatch transport & queue** | Dedicated **Redis Stream + consumer group owned by the dispatcher** (orchestrator `XADD`; dispatcher `XREADGROUP`/`XAUTOCLAIM`; DLQ after K deliveries). Broker stays completion-only (+ `registry-size`, handle `dispatched` flip). `local-subprocess` untouched. |
| **Q2 Log sink** | `LOG_SINK=git\|none` injected at spawn. Standalone (`local-docker`) → `none` (stdout). Bundled → `git` (unchanged). **Persistent S3 storage descoped to `executor-log-object-storage`.** |
| **Q3 Claim location** | Already resolved — executor claim-agnostic; only the git-flush opt-out remains (Q2). |
| **Q4 Credentials & isolation** | Dispatcher is sole credential holder (dev: env inject; prod: Secret references). Co-resident isolation via per-profile/instance roots + UUID handles + label scoping. |
| **Q5 Dispatch reliability** | Owned by the dispatcher (stream `XAUTOCLAIM` redelivery + DLQ); terminal dispatch failure posted as a synthetic `failed` completion (normal path). Handle register before enqueue; idempotency by handle. Orchestrator reconciler is a simple no-completion-by-`EXECUTION_DEADLINE` re-enqueue backstop. |

## 5. Dependency analysis

- **Internal:** `runtime-portable-architecture` (done) — ports/adapters/profiles + async submit/reap (satisfied). The broker `registry-size` endpoint (long-noted tech debt) is implemented here (T2).
- **Blocks downstream:**
  - `executor-log-object-storage` — persistent log storage builds on this feature's `LOG_SINK` seam and the dispatcher's credential-injection path.
  - `workflow-db` — the Go/Postgres orchestrator drives this same standalone executor over the dispatcher; its design must declare this dependency.
- **External/tooling:** Redis (already present). **No MinIO / object store in this feature.** No new managed services.
- **Out of scope (kept clean, not built):** `K8sJobAdapter` and the production k8s deployment (incl. whether the orchestrator runs as a CronJob); persistent logging.
- **Unresolved:** none blocking.

## 6. Parallelization / blocking analysis

External decisions: none unresolved — all open questions are answered in §4.

```
T1: ABI — DispatchJob payload + dispatch-stream contract (key, consumer group) + runner LOG_SINK env  (no ExecutorResult change)  (repo: workflow)
  └── Can begin now — no blockers
T2: Broker — GET /registry-size only; broker does NOT host the dispatch queue or any dispatch state  (repo: workflow)
  └── Can begin now — no blockers (independent of the DispatchJob schema)
  └── T1 and T2 run in parallel
  │
  T3: Executor — gate flushLog on LOG_SINK (none → stdout, git → unchanged)  (repo: workflow)
  │   └── BLOCKED on T1 (LOG_SINK env contract frozen)
  T4: Dispatcher service (runtime/dispatcher/) — own the dispatch Redis stream (XREADGROUP/XAUTOCLAIM, DLQ),
  │   relocate DockerRunAdapter, hold CredentialPort, inject creds + LOG_SINK=none, idempotency guard,
  │   global cap via broker registry-size, XACK after spawn, synthetic failed completion on DLQ  (repo: workflow)
  │   └── BLOCKED on T1 (DispatchJob + stream contract frozen), T2 (registry-size must exist)
  T5: Orchestrator — QueueDispatchAdapter (XADD to dispatch stream), drop socket+credential adapter from
  │   local-docker profile, dispatch reconciler, register handle before enqueue  (repo: workflow)
  │   └── BLOCKED on T1 (DispatchJob + stream contract frozen)
  │   └── T3, T4 and T5 run in parallel
  │
  T6: Compose + dev wiring — local-docker stack (redis, broker, dispatcher, orchestrator);
  │   keep local-subprocess bundled compose working; .env templates  (repo: workflow)
  │   └── BLOCKED on T3 (executor honours LOG_SINK), T4 (dispatcher service), T5 (orchestrator enqueue)
  │
  T7: Integration + parity test — bundled ∥ local-docker concurrently; prove decoupled flow,
      idempotency, reconciliation, unprivileged orchestrator, no mgmt-repo log writes on standalone path  (repo: workflow)
      └── BLOCKED on T6 (full stack wired)
```

Wave 1: **T1 ∥ T2**. Wave 2: **T3 ∥ T4 ∥ T5**. Wave 3: **T6**. Wave 4: **T7**.

## 7. Repository impact

| Repo (`workspace.yaml` id) | Why |
|---|---|
| `workflow` | All implementation: `runtime/abi` (T1), `runtime/broker` (T2), `runtime/executors/claude` (T3), `runtime/dispatcher` new (T4), `runtime/orchestrator` (T5), compose/env (T6), tests (T7). |
| `management-repo` | Only this feature's docs (design/tasks) — no implementation. |

Every task targets a single repo (`workflow`) — no cross-repo task.

## 8. Validation and release impact

- **Testing:** unit (`QueueDispatchAdapter` `XADD`; dispatcher consumer-group consume + `XAUTOCLAIM` redelivery + DLQ; idempotency + concurrency cap; `flushLog` LOG_SINK gating; reconciler state machine); broker test for `registry-size`; dispatcher test that a DLQ'd job posts a synthetic `failed` completion; integration in T7 — bundled ∥ local-docker concurrently, end-to-end decoupled flow, induced dispatcher-crash redelivery (no double-spawn), induced lost-dispatch (reconciler re-enqueue).
- **ABI / compatibility:** **ABI-neutral** — no `result.json` change; `local-subprocess` byte-for-byte unchanged (git logging retained); no change to agent behaviour or prompts.
- **Migration/config:** new dev infra — `dispatcher` service + dispatch/LOG_SINK env in `.env.template`; orchestrator loses the Docker socket mount. No MinIO, no data migration.
- **Rollout:** purely additive — `local-docker` opt-in per orchestrator instance via `RUNTIME_PROFILE`; bundled remains the default/fallback. Production (k8s) deferred; spawn-adapter seam kept clean. **Known tradeoff:** until `executor-log-object-storage` lands, `local-docker` run logs are ephemeral (stdout / `docker logs` only) — not persisted or RAG-indexed.
- **Handoff:** unblocks `executor-log-object-storage` and `workflow-db`.
